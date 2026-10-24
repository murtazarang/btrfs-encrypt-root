#!/bin/sh
# One-time conversion of a fresh Ubuntu installation from its live USB.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

show_help() {
    cat <<'HELP'
Usage: btrfs-encrypt-root.sh [--only-subvols] [--enlarge] ROOT BOOT [EFI]
Run from the Ubuntu 26.04 live USB after installation, before first reboot.
Device arguments omit /dev/. /boot must be a separate ext4 partition.
Creates @, @home, @var_cache, @var_log, @var_tmp and normally LUKS2 encryption.
--only-subvols  Skip encryption.
--enlarge      Extend the final GPT root partition into trailing free space.
-h, --help     Display help without changing anything.
This is NOT resumable: after an error, inspect the state before reboot/rerun.
HELP
}

assert_root_last_partition() {
    layout_partition_number=$1
    layout_table=$2
    case "$layout_partition_number" in
        ''|0|*[!0-9]*) die 'Cannot determine a valid root partition number';;
    esac
    layout_root_end=$(printf '%s\n' "$layout_table" | awk -F: -v n="$layout_partition_number" '$1==n {gsub("s","",$3);print $3}')
    # Removing the sector suffix makes the field a string. Compare numerically,
    # but retain the original digits so large values are not printed as exponents.
    layout_last_end=$(printf '%s\n' "$layout_table" | awk -F: '
        $1 ~ /^[0-9]+$/ {
            gsub("s","",$3)
            if (($3+0) > (max+0)) max=$3
        }
        END {print max}
    ')
    [ -n "$layout_root_end" ] && [ "$layout_root_end" = "$layout_last_end" ] ||
        die '--enlarge requires root to be the physically last partition'
}

migrate_directory() {
    source_dir=$1
    destination_dir=$2
    [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || die "Invalid source: $source_dir"
    [ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] || die "Invalid destination: $destination_dir"
    source_real=$(readlink -f "$source_dir")
    destination_real=$(readlink -f "$destination_dir")
    case "$destination_real/" in "$source_real/"*) die 'Destination is inside source';; esac
    case "$source_real/" in "$destination_real/"*) die 'Source is inside destination';; esac
    [ -z "$(find "$destination_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die 'Migration destination is not empty'
    rsync -aHAX --numeric-ids -- "$source_dir/" "$destination_dir/"
    differences=$(rsync -aHAX --numeric-ids --checksum --dry-run \
        --itemize-changes --delete -- "$source_dir/" "$destination_dir/")
    [ -z "$differences" ] || die "Migration verification failed: $source_dir; source retained"
    rsync -aHAX --numeric-ids --checksum --remove-source-files -- "$source_dir/" "$destination_dir/"
    find "$source_dir" -depth -mindepth 1 -type d -empty -delete
    [ -z "$(find "$source_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "Unexpected files remain in $source_dir"
}

write_mount_config() {
    config_target=$1
    filesystem_uuid=$2
    encryption_uuid=$3
    [ -f "$config_target/etc/fstab" ] || die 'Installed fstab is missing'
    fstab_tmp=$(mktemp "$config_target/etc/.fstab.btrfs-encrypt-root.XXXXXX")
    awk '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $2 == "/" || $2 == "/home" || $2 == "/var/cache" ||
        $2 == "/var/log" || $2 == "/var/tmp" { next }
        { print }
    ' "$config_target/etc/fstab" > "$fstab_tmp"
    {
        printf '\n# Managed by btrfs-encrypt-root\n'
        printf 'UUID=%s / btrfs defaults,subvol=@ 0 0\n' "$filesystem_uuid"
        printf 'UUID=%s /home btrfs defaults,subvol=@home 0 0\n' "$filesystem_uuid"
        printf 'UUID=%s /var/cache btrfs defaults,subvol=@var_cache 0 0\n' "$filesystem_uuid"
        printf 'UUID=%s /var/log btrfs defaults,subvol=@var_log 0 0\n' "$filesystem_uuid"
        printf 'UUID=%s /var/tmp btrfs defaults,subvol=@var_tmp 0 0\n' "$filesystem_uuid"
    } >> "$fstab_tmp"
    chmod --reference="$config_target/etc/fstab" "$fstab_tmp"
    chown --reference="$config_target/etc/fstab" "$fstab_tmp"
    cp -a "$config_target/etc/fstab" "$config_target/etc/fstab.before-btrfs-encrypt-root"
    mv "$fstab_tmp" "$config_target/etc/fstab"
    if [ -n "$encryption_uuid" ]; then
        crypttab_tmp=$(mktemp "$config_target/etc/.crypttab.btrfs-encrypt-root.XXXXXX")
        if [ -f "$config_target/etc/crypttab" ]; then
            cp -a "$config_target/etc/crypttab" "$config_target/etc/crypttab.before-btrfs-encrypt-root"
            awk '/^[[:space:]]*#/ || NF == 0 || $1 != "root" {print}' \
                "$config_target/etc/crypttab" > "$crypttab_tmp"
        fi
        printf 'root UUID=%s none luks\n' "$encryption_uuid" >> "$crypttab_tmp"
        chmod 600 "$crypttab_tmp"
        chown 0:0 "$crypttab_tmp"
        mv "$crypttab_tmp" "$config_target/etc/crypttab"
    fi
}

mount_owned() {
    mountpoint=$1
    shift
    mount "$@" "$mountpoint"
    owned_mounts="$mountpoint
$owned_mounts"
}

unmount_owned() {
    remaining=
    failed=no
    old_ifs=$IFS
    IFS='
'
    for mounted in $owned_mounts; do
        [ -n "$mounted" ] || continue
        if ! umount -R "$mounted"; then
            failed=yes
            remaining="$remaining$mounted
"
        fi
    done
    IFS=$old_ifs
    owned_mounts=$remaining
    [ "$failed" = no ]
}

cleanup() {
    cleanup_status=$?
    trap - 0
    set +e
    unmount_owned || cleanup_status=1
    if [ "$mapper_opened" = yes ]; then cryptsetup close root || cleanup_status=1; fi
    if [ -n "$mp" ]; then rmdir "$mp" 2>/dev/null; fi
    if [ "$cleanup_status" -ne 0 ]; then
        printf '\nConversion stopped during: %s\n' "$phase" >&2
        printf 'Do not blindly rerun or reboot. No automatic rollback was performed.\n' >&2
        printf 'For a disposable fresh install, reinstalling is the simplest recovery.\n' >&2
    fi
    exit "$cleanup_status"
}

mount_chroot() {
    target=$1
    mount_owned "$target/boot" "$boot_dev"
    if [ -n "$efi_dev" ]; then mount_owned "$target/boot/efi" "$efi_dev"; fi
    mount_owned "$target/proc" -t proc proc
    for bind_dir in dev sys run; do
        mount_owned "$target/$bind_dir" --rbind "/$bind_dir"
        mount --make-rslave "$target/$bind_dir"
    done
}


fstab_matches_device() {
    fstab_mount=$1
    expected_device=$2
    entry=$(awk -v path="$fstab_mount" '!/^[[:space:]]*#/ && $2 == path {print $1}' "$mp/etc/fstab")
    [ -n "$entry" ] || die "fstab has no $fstab_mount entry"
    case "$entry" in
        UUID=*|LABEL=*) resolved_device=$(findfs "$entry");;
        /dev/*) resolved_device=$(readlink -f "$entry");;
        *) die "Unsupported fstab source for $fstab_mount";;
    esac
    [ "$(readlink -f "$resolved_device")" = "$expected_device" ] ||
        die "Selected device does not match installed $fstab_mount"
}

assert_fresh_layout() {
    filesystem_info=$(btrfs filesystem show "$mp")
    [ "$(printf '%s\n' "$filesystem_info" | awk '/Total devices/ {print $3}')" = 1 ] ||
        die 'Only single-device Btrfs filesystems are supported'
    [ "$(btrfs property get -t s "$mp" ro)" = 'ro=false' ] ||
        die 'The top-level subvolume is read-only'
    [ "$(btrfs subvolume get-default "$mp" | awk '{print $2}')" = 5 ] ||
        die 'Default Btrfs subvolume must be top-level ID 5'
    existing_subvolumes=$(btrfs subvolume list "$mp")
    [ -z "$existing_subvolumes" ] ||
        die 'Existing subvolumes detected; a fresh flat installation is required'
    [ -z "$(find "$mp" -mindepth 1 -maxdepth 1 -name '@*' -print -quit)" ] ||
        die 'An @-prefixed entry already exists; possible partial conversion'
    [ ! -e "$mp/.btrfs-encrypt-root-in-progress" ] || die 'Previous conversion marker exists'
    [ -f "$mp/etc/os-release" ] && [ -f "$mp/etc/fstab" ] &&
        [ -s "$mp/var/lib/dpkg/status" ] || die 'Target is not a completed Ubuntu installation'
    grep -Eq '^ID="?ubuntu"?$' "$mp/etc/os-release" || die 'Target must be Ubuntu'
    grep -Eq '^VERSION_ID="?26\.04"?$' "$mp/etc/os-release" || die 'Target must be Ubuntu 26.04'
    for directory in home var/cache var/log var/tmp boot boot/efi proc dev sys run; do
        [ -d "$mp/$directory" ] && [ ! -L "$mp/$directory" ] ||
            die "Expected a real directory at /$directory"
    done
    if awk '!/^[[:space:]]*#/ && $3 == "swap" {found=1} END {exit !found}' "$mp/etc/fstab"; then
        die 'Swap is configured. Remove the fresh installer swapfile and its fstab entry before conversion; configure swap outside @/@home afterward'
    fi
    awk '!/^[[:space:]]*#/ && $2 == "/" {n++; if ($3 != "btrfs") exit 1} END {if (n != 1) exit 1}' \
        "$mp/etc/fstab" || die 'Expected exactly one Btrfs root entry in fstab'
    for mount_path in /home /var/cache /var/log /var/tmp; do
        awk -v path="$mount_path" '!/^[[:space:]]*#/ && $2 == path {exit 1}' "$mp/etc/fstab" ||
            die "An existing separate mount for $mount_path is unsupported"
    done
    if [ -f "$mp/etc/crypttab" ]; then
        awk '!/^[[:space:]]*#/ && $1 == "root" {exit 1}' "$mp/etc/crypttab" ||
            die 'crypttab already defines a root mapping'
    fi
    fstab_matches_device / "$root_dev"
    fstab_matches_device /boot "$boot_dev"
    if [ -n "$efi_dev" ]; then fstab_matches_device /boot/efi "$efi_dev"; fi
    needed=268435456
    for directory in home var/cache var/log var/tmp; do
        bytes=$(du -sx --apparent-size --block-size=1 "$mp/$directory" | awk '{print $1}')
        needed=$((needed + bytes))
    done
    available=$(df -PB1 "$mp" | awk 'NR==2 {print $4}')
    [ "$available" -gt "$needed" ] || die 'Insufficient space for migration and encryption header'
}

create_subvolumes() {
    printf 'Conversion in progress; do not rerun blindly.\n' > "$mp/.btrfs-encrypt-root-in-progress"
    for pair in 'home:@home' 'var/cache:@var_cache' 'var/log:@var_log' 'var/tmp:@var_tmp'; do
        path=${pair%:*}
        subvolume=${pair#*:}
        btrfs subvolume create "$mp/$subvolume"
        migrate_directory "$mp/$path" "$mp/$subvolume"
    done
    chmod 1777 "$mp/@var_tmp"
    btrfs subvolume snapshot "$mp" "$mp/@"
    btrfs subvolume show "$mp/@" >/dev/null
    [ "$(findmnt -n -o FSTYPE --mountpoint "$mp")" = btrfs ] || die 'Root mount changed'
    [ "$(findmnt -n -o UUID --mountpoint "$mp")" = "$filesystem_uuid" ] || die 'Root filesystem UUID changed'
    [ "$(findmnt -n -o FSROOT --mountpoint "$mp")" = / ] || die 'Not at Btrfs top level'
    [ "$(findmnt -rn -R "$mp" -o TARGET | wc -l)" -eq 1 ] || die 'Unexpected nested mounts'
    for subvolume in @home @var_cache @var_log @var_tmp; do
        # Snapshotting top level creates empty stubs for the sibling subvolumes.
        rmdir "$mp/@/$subvolume"
        btrfs subvolume show "$mp/$subvolume" >/dev/null
    done
    # Checked fresh filesystem, verified snapshot, no nested mounts/subvolumes.
    # Explicitly preserve every subvolume this script created.
    find "$mp" -mindepth 1 -maxdepth 1 \
        ! -name '@' ! -name '@home' ! -name '@var_cache' ! -name '@var_log' ! -name '@var_tmp' \
        -exec rm -rf -- {} +
    btrfs subvolume set-default 5 "$mp"
    sync
}

configure_timeshift() {
    config_target=$1
    mkdir -p "$config_target/etc/timeshift"
    python3 - "$config_target/etc/timeshift/timeshift.json" "$filesystem_uuid" "$encryption_uuid" <<'PY'
import json, os, sys
path, filesystem_uuid, encryption_uuid = sys.argv[1:]
if os.path.exists(path):
    with open(path) as source:
        config = json.load(source)
else:
    config = {}
config.update({
    "backup_device_uuid": filesystem_uuid,
    "parent_device_uuid": encryption_uuid,
    "btrfs_mode": "true",
    "include_btrfs_home_for_backup": "false",
    "include_btrfs_home_for_restore": "false",
    "schedule_hourly": "false",
    "schedule_daily": "false",
    "schedule_weekly": "false",
    "schedule_monthly": "false",
    "schedule_boot": "false",
})
temporary = path + ".btrfs-encrypt-root"
with open(temporary, "w") as output:
    json.dump(config, output, indent=2)
    output.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
}

install_timeshift_hooks() {
    hook_target=$1
    mkdir -p "$hook_target/etc/timeshift/backup-hooks.d" "$hook_target/etc/timeshift/restore-hooks.d"
    backup_hook=$hook_target/etc/timeshift/backup-hooks.d/50-boot
    restore_hook=$hook_target/etc/timeshift/restore-hooks.d/50-boot
    {
        printf '#!/bin/sh\nMODE=backup\nROOT_UUID=%s\nBOOT_UUID=%s\n' "$filesystem_uuid" "$boot_uuid"
        cat <<'TIMESHIFT_BOOT_HOOK'
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
snapshot=${TS_SNAPSHOT_PATH:?Timeshift did not supply TS_SNAPSHOT_PATH}
state=
runtime=
stage=
boot_mounted=no
root_mounted=no
state_created=no
state_validated=no

die() { printf 'Timeshift boot %s FAILED: %s\n' "$MODE" "$*" >&2; exit 1; }
write_marker() {
    marker_name=$1
    marker_message=$2
    [ "$state_validated" = yes ] || return 1
    marker_tmp=$(mktemp "$state/.boot-hook-marker.XXXXXX") || return 1
    printf '%s\n' "$marker_message" > "$marker_tmp" || return 1
    mv -fT "$marker_tmp" "$state/$marker_name"
}
cleanup() {
    status=$?
    trap - 0
    set +e
    if [ "$boot_mounted" = yes ]; then
        umount "$runtime/boot" || status=1
    fi
    if [ "$root_mounted" = yes ]; then
        umount "$runtime/root" || status=1
    fi
    if [ -n "$stage" ]; then rm -rf -- "$stage"; fi
    if [ -n "$runtime" ]; then
        rmdir "$runtime/boot" "$runtime/root" "$runtime" 2>/dev/null
    fi
    if [ "$status" -eq 0 ] && [ "$MODE" = restore ]; then
        rm -f "$state/restore-FAILED" || status=1
        if [ "$status" -eq 0 ]; then
            write_marker restore-OK complete || status=1
        fi
    fi
    if [ "$status" -ne 0 ]; then
        message="Timeshift boot $MODE FAILED; do not reboot after a restore until corrected."
        printf '%s\n' "$message" >&2
        logger -t timeshift-boot -- "$message"
        if [ "$state_validated" = yes ]; then
            if [ "$MODE" = restore ]; then rm -f "$state/restore-OK"; fi
            write_marker "$MODE-FAILED" "$message"
            if [ "$MODE" = backup ] && [ "$state_created" = yes ]; then
                rm -f "$state/READY"
            fi
        fi
    else
        printf 'Timeshift boot %s complete: %s\n' "$MODE" "$state"
    fi
    exit "$status"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(id -u)" -eq 0 ] || die 'root is required'
case "$MODE" in backup|restore) ;; *) die 'invalid mode';; esac
case "$snapshot" in /*) ;; *) die 'snapshot path must be absolute';; esac
[ -d "$snapshot/@" ] && [ ! -L "$snapshot/@" ] || die 'Btrfs root snapshot is absent'
[ "$(findmnt -n -o UUID --target "$snapshot/@")" = "$ROOT_UUID" ] || die 'snapshot belongs to another filesystem'
btrfs subvolume show "$snapshot/@" >/dev/null || die 'not a Btrfs snapshot'
snapshot=$(readlink -f "$snapshot")
state=$snapshot/boot-state
[ ! -L "$state" ] || die 'boot-state must not be a symlink'
umask 077
runtime=$(mktemp -d /run/timeshift-boot.XXXXXX)
mkdir "$runtime/boot" "$runtime/root"

check_kernels() {
    found=no
    for kernel in "$1"/vmlinuz-*; do
        [ -f "$kernel" ] || continue
        found=yes
        version=${kernel##*/}
        version=${version#vmlinuz-}
        [ -f "$1/initrd.img-$version" ] || die "missing initrd for $version"
        [ -d "$snapshot/@/usr/lib/modules/$version" ] ||
            [ -d "$snapshot/@/lib/modules/$version" ] || die "snapshot lacks modules for $version"
    done
    [ "$found" = yes ] || die 'no kernel images were found'
}

if [ "$MODE" = backup ]; then
    [ "$(findmnt -n -o UUID --target /)" = "$ROOT_UUID" ] || die 'backup must run on the installed system'
    [ ! -e "$state" ] || die 'boot-state already exists; inspect it rather than overwrite it'
    mkdir "$state"
    state_created=yes
    state_validated=yes
    cmp /var/lib/dpkg/status "$snapshot/@/var/lib/dpkg/status" || die 'package state changed; take a new snapshot while APT is idle'
    # ext4 shares its superblock with the already-mounted, writable /boot.
    # A second read-only mount would fail; this hook only reads its own mount.
    mount -t ext4 -o rw "UUID=$BOOT_UUID" "$runtime/boot"
    boot_mounted=yes
    check_kernels "$runtime/boot"
    tar --acls --xattrs --numeric-owner --one-file-system \
        --exclude=./efi --exclude=./lost+found \
        -cpf "$state/boot.tar.tmp" -C "$runtime/boot" .
    cmp /var/lib/dpkg/status "$snapshot/@/var/lib/dpkg/status" || die 'package state changed during boot backup'
    mv "$state/boot.tar.tmp" "$state/boot.tar"
    printf '%s\n%s\n' "$ROOT_UUID" "$BOOT_UUID" > "$state/meta"
    (cd "$state" && sha256sum boot.tar meta > SHA256SUMS)
    sync -f "$state/boot.tar"
    printf 'complete\n' > "$state/READY"
else
    [ -d "$state" ] || die 'snapshot has no boot-state directory'
    state_validated=yes
    rm -f "$state/restore-OK"
    for item in READY boot.tar meta SHA256SUMS; do
        [ -f "$state/$item" ] && [ ! -L "$state/$item" ] && [ -s "$state/$item" ] ||
            die "missing or unsafe boot-state file: $item"
    done
    printf '%s\n%s\n' "$ROOT_UUID" "$BOOT_UUID" | cmp - "$state/meta" || die 'root/boot UUID manifest does not match'
    actual_checksums=$(cd "$state" && sha256sum boot.tar meta)
    printf '%s\n' "$actual_checksums" | cmp - "$state/SHA256SUMS" || die 'boot archive checksum failed'
    mount -t btrfs -o ro,subvol=@ "UUID=$ROOT_UUID" "$runtime/root"
    root_mounted=yes
    snapshot_uuid=$(btrfs subvolume show "$snapshot/@" | awk '$1 == "UUID:" {print $2}')
    restored_parent=$(btrfs subvolume show "$runtime/root" | awk '$1 == "Parent" && $2 == "UUID:" {print $3}')
    [ -n "$snapshot_uuid" ] && [ "$snapshot_uuid" = "$restored_parent" ] || die 'active @ is not a restored copy of the selected snapshot'
    stage=$(mktemp -d "$state/.restore.XXXXXX")
    tar --acls --xattrs --numeric-owner -xpf "$state/boot.tar" -C "$stage"
    check_kernels "$stage"
    mount -t ext4 -o rw "UUID=$BOOT_UUID" "$runtime/boot"
    boot_mounted=yes
    rsync -aHAX --numeric-ids --delete --exclude=/efi/ --exclude=/lost+found/ "$stage/" "$runtime/boot/"
    sync -f "$runtime/boot"
fi
TIMESHIFT_BOOT_HOOK
    } > "$backup_hook"
    sed 's/^MODE=backup$/MODE=restore/' "$backup_hook" > "$restore_hook"
    chmod 700 "$backup_hook" "$restore_hook"
}


configure_boot_images() {
    if chroot "$mp" sh -c 'command -v dracut >/dev/null 2>&1'; then
        mkdir -p "$mp/etc/dracut.conf.d"
        {
            printf 'use_fstab=yes\nhostonly_cmdline=no\n'
            printf 'add_dracutmodules+=" btrfs "\n'
            if [ -n "$encryption_uuid" ]; then
                printf 'add_dracutmodules+=" crypt "\n'
                printf 'install_items+=" /etc/crypttab "\n'
            fi
        } > "$mp/etc/dracut.conf.d/90-btrfs-encrypt-root.conf"
    fi
    chroot "$mp" update-initramfs -u -k all
    chroot "$mp" update-grub
    if [ -n "$encryption_uuid" ]; then
        chroot "$mp" /bin/sh -s -- "$encryption_uuid" <<'VERIFY_INITRAMFS'
set -eu
found=no
for image in /boot/initrd.img-*; do
    [ -f "$image" ] || continue
    found=yes
    if command -v dracut >/dev/null 2>&1; then
        lsinitrd -f etc/crypttab "$image" | grep -Fq "UUID=$1" ||
            { echo "Missing root crypttab entry in $image" >&2; exit 1; }
    else
        lsinitramfs "$image" | grep -Eq '(^|/)crypttab$' ||
            { echo "Missing crypttab in $image" >&2; exit 1; }
    fi
done
[ "$found" = yes ] || { echo 'No initramfs images found' >&2; exit 1; }
VERIFY_INITRAMFS
    fi
}

main() {
    only_subvols=no
    enlarge=no
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) show_help; return 0;;
            --only-subvols) only_subvols=yes; shift;;
            --enlarge) enlarge=yes; shift;;
            --) shift; break;;
            -*) die "Unknown option: $1";;
            *) break;;
        esac
    done
    if [ "$#" -eq 0 ]; then show_help; return 0; fi
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die 'Supply ROOT BOOT [EFI] without /dev/'
    [ "$(id -u)" -eq 0 ] || die 'Run as root'
    [ "$only_subvols" = no ] || [ "$enlarge" = no ] ||
        die '--enlarge cannot be combined with --only-subvols'
    [ -d /run/casper ] || [ -d /cdrom/casper ] ||
        die 'Run from the Ubuntu live installation USB, before first reboot'
    for command in awk blkid blockdev btrfs chroot chmod chown cmp cryptsetup df du find \
        findfs findmnt grep id logger lsblk mkdir mktemp mount mountpoint mv partprobe parted \
        python3 readlink rm rmdir rsync sed sha256sum swapon sync tar umount wc; do
        command -v "$command" >/dev/null 2>&1 || die "Missing live-session dependency: $command"
    done
    for name in "$@"; do
        case "$name" in ''|*[!a-zA-Z0-9_.-]*) die "Invalid device name: $name";; esac
        [ -b "/dev/$name" ] || die "Not a block device: /dev/$name"
        [ "$(lsblk -dn -o TYPE "/dev/$name")" = part ] || die "Expected a partition: /dev/$name"
        [ "$(blockdev --getro "/dev/$name")" = 0 ] || die "Device is read-only: /dev/$name"
    done
    root_dev=$(readlink -f "/dev/$1")
    boot_dev=$(readlink -f "/dev/$2")
    efi_dev=
    if [ "$#" -eq 3 ]; then efi_dev=$(readlink -f "/dev/$3"); fi
    [ "$root_dev" != "$boot_dev" ] && [ "$root_dev" != "$efi_dev" ] &&
        [ "$boot_dev" != "$efi_dev" ] || die 'Root, boot and EFI must be distinct'
    [ "$(blkid -s TYPE -o value "$root_dev")" = btrfs ] ||
        die 'Root must be unencrypted Btrfs; already converted devices are refused'
    [ "$(blkid -s TYPE -o value "$boot_dev")" = ext4 ] || die '/boot must be ext4'
    if [ -n "$efi_dev" ]; then
        [ -d /sys/firmware/efi ] || die 'Boot the live USB in UEFI mode'
        [ "$(blkid -s TYPE -o value "$efi_dev")" = vfat ] || die 'EFI partition must be FAT32/vfat'
    elif [ -d /sys/firmware/efi ]; then
        die 'UEFI installation requires the EFI partition argument'
    fi
    disk_name=$(lsblk -dn -o PKNAME "$root_dev" | awk '{$1=$1;print}')
    disk=/dev/$disk_name
    [ -b "$disk" ] || die 'Cannot identify parent disk'
    for device in "$boot_dev" "$efi_dev"; do
        [ -n "$device" ] || continue
        [ "$(lsblk -dn -o PKNAME "$device" | awk '{$1=$1;print}')" = "$disk_name" ] ||
            die 'All supplied partitions must belong to the same installation disk'
    done
    [ ! -e /dev/mapper/root ] || die '/dev/mapper/root is already in use'
    filesystem_uuid=$(blkid -s UUID -o value "$root_dev")
    boot_uuid=$(blkid -s UUID -o value "$boot_dev")
    [ -n "$filesystem_uuid" ] && [ -n "$boot_uuid" ] || die 'Missing filesystem UUID'
    if [ "$enlarge" = yes ]; then
        [ "$(lsblk -dn -o PTTYPE "$disk")" = gpt ] || die '--enlarge requires GPT'
        partition_number=$(lsblk -dn -o PARTN "$root_dev") || die 'Cannot read root partition number'
        partition_number=$(printf '%s\n' "$partition_number" | awk '{$1=$1;print}')
        table=$(parted -ms "$disk" unit s print)
        assert_root_last_partition "$partition_number" "$table"
    fi
    while IFS= read -r swap_path; do
        [ -n "$swap_path" ] || continue
        case "$swap_path" in "$root_dev"|"$boot_dev"|"$efi_dev") die 'A selected device is active swap';; esac
        if [ -f "$swap_path" ]; then
            swap_uuid=$(findmnt -n -o UUID --target "$swap_path")
            [ "$swap_uuid" != "$filesystem_uuid" ] || die 'Target has an active swapfile; disable it first'
        fi
    done <<SWAPS
$(swapon --show --noheadings --raw --output NAME)
SWAPS
    root_mounts=$(findmnt -rn -S "$root_dev" -o TARGET || :)
    boot_mounts=$(findmnt -rn -S "$boot_dev" -o TARGET || :)
    efi_mounts=
    if [ -n "$efi_dev" ]; then efi_mounts=$(findmnt -rn -S "$efi_dev" -o TARGET || :); fi
    case "$root_mounts" in ''|/target) ;; *) die "Root is mounted outside installer /target: $root_mounts";; esac
    case "$boot_mounts" in ''|/target/boot) ;; *) die "Boot is already mounted elsewhere: $boot_mounts";; esac
    case "$efi_mounts" in ''|/target/boot/efi) ;; *) die "EFI is already mounted elsewhere: $efi_mounts";; esac
    if [ -z "$root_mounts" ]; then
        [ -z "$boot_mounts$efi_mounts" ] || die 'Unexpected partial installer mount state'
        ! mountpoint -q /target || die '/target contains a different mounted filesystem'
    else
        # Installation must be finished. Unmount only the verified installer tree.
        umount -R /target
    fi
    owned_mounts=
    mapper_opened=no
    mp=
    phase=preflight
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mp=$(mktemp -d /mnt/btrfs-encrypt-root.XXXXXX)
    mount_owned "$mp" -o ro,subvolid=5 "$root_dev"
    assert_fresh_layout
    printf 'Convert root %s, boot %s, EFI %s on disk %s.\n' "$root_dev" "$boot_dev" "$efi_dev" "$disk"
    printf 'Type the installation disk name (%s) to continue: ' "$disk_name"
    read -r answer
    [ "$answer" = "$disk_name" ] || die 'Confirmation did not match; no conversion performed'
    unmount_owned || die 'Cannot unmount preflight root'

    # Install dependencies while the original root is still intact.
    phase='installing target dependencies'
    mount_owned "$mp" -o subvolid=5 "$root_dev"
    mount_chroot "$mp"
    chroot "$mp" apt-get update
    chroot "$mp" apt-get install -y btrfs-progs cryptsetup-initramfs systemd-cryptsetup timeshift rsync
    timeshift_version=$(chroot "$mp" dpkg-query -W '-f=${Version}' timeshift)
    chroot "$mp" dpkg --compare-versions "$timeshift_version" ge 25.12.4 ||
        die 'Timeshift 25.12.4 or newer is required for boot backup hooks'
    unmount_owned || die 'Cannot unmount dependency installation'
    mount_owned "$mp" -o subvolid=5 "$root_dev"
    assert_fresh_layout

    phase='creating and migrating subvolumes'
    create_subvolumes
    encryption_uuid=
    root_source=$root_dev
    if [ "$only_subvols" = no ]; then
        phase='shrinking Btrfs for the LUKS2 header'
        btrfs filesystem resize -32m "$mp"
        unmount_owned || die 'Root still mounted before encryption'
        phase='encrypting the root partition'
        cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32m "$root_dev"
        if [ "$enlarge" = yes ]; then
            parted --script "$disk" resizepart "$partition_number" 100%
            partprobe "$disk"
        fi
        cryptsetup open "$root_dev" root
        mapper_opened=yes
        root_source=/dev/mapper/root
        encryption_uuid=$(cryptsetup luksUUID "$root_dev")
        [ "$(blkid -s TYPE -o value "$root_source")" = btrfs ] &&
            [ "$(blkid -s UUID -o value "$root_source")" = "$filesystem_uuid" ] ||
            die 'Decrypted mapping does not contain the original Btrfs filesystem'
    else
        unmount_owned || die 'Cannot unmount converted root'
    fi
    phase='configuring mounts and boot images'
    mount_owned "$mp" -o subvol=@ "$root_source"
    btrfs filesystem resize max "$mp"
    for pair in 'home:@home' 'var/cache:@var_cache' 'var/log:@var_log' 'var/tmp:@var_tmp'; do
        path=${pair%:*}
        subvolume=${pair#*:}
        mount_owned "$mp/$path" -o "subvol=$subvolume" "$root_source"
    done
    mount_chroot "$mp"
    write_mount_config "$mp" "$filesystem_uuid" "$encryption_uuid"
    configure_timeshift "$mp"
    install_timeshift_hooks "$mp"
    chroot "$mp" findmnt --verify --verbose
    configure_boot_images
    rm "$mp/.btrfs-encrypt-root-in-progress"
    printf 'Completed fresh-install conversion.\n' > "$mp/etc/btrfs-encrypt-root-completed"
    sync
    phase='final unmount'
    unmount_owned || die 'Final unmount failed; do not reboot yet'
    if [ "$mapper_opened" = yes ]; then
        cryptsetup close root
        mapper_opened=no
    fi
    say 'Finished. Reboot, verify disk unlock, then create and check a Timeshift snapshot.'
    say 'Schedules are disabled until configured in Timeshift. Keep an independent backup.'
}

main "$@"
