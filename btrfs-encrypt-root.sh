#!/bin/sh
# Based on shukriadams/btrfs-encrypt-root (AGPL-3.0).
# Run once from the Ubuntu 26.04 live USB after installation, before reboot.
set -eu

script=$(readlink -f "$0")
mp=/mnt/root
keyslot_size=32m

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

show_help() {
    cat <<'HELP'
Usage: btrfs-encrypt-root.sh [--enlarge] [--only-subvols] ROOT BOOT [EFI]
All device names omit /dev/. ROOT is initially unencrypted Btrfs;
BOOT is a separate ext4 partition; EFI is a separate FAT32 partition.
Creates @, @home, @var_cache, @var_log, @var_tmp on the same Btrfs volume.
--enlarge: extend the last root partition into trailing unallocated space.
--only-subvols: create subvolumes without encryption.
HELP
}

# Called from inside the newly installed system.
configure_installed_system() {
    only_subvols=$1
    root_device=$2
    if [ "$only_subvols" = yes ]; then
        source="UUID=$(blkid -s UUID -o value "$root_device")"
    else
        source=/dev/mapper/root
        luks_uuid=$(blkid -s UUID -o value "$root_device")
        printf 'root UUID=%s none luks\n' "$luks_uuid" >> /etc/crypttab
        apt-get update
        apt-get install -y --no-install-recommends cryptsetup systemd-cryptsetup
    fi

    # Preserve the existing /boot and EFI entries, replace only Btrfs mounts.
    awk '$1 !~ /^#/ && ($2=="/" || $2=="/home" || $2=="/var/cache" ||
         $2=="/var/log" || $2=="/var/tmp") {next} {print}' \
         /etc/fstab > /etc/fstab.btrfs-new
    for pair in '/:@' '/home:@home' '/var/cache:@var_cache' \
                '/var/log:@var_log' '/var/tmp:@var_tmp'; do
        path=${pair%:*}
        subvol=${pair#*:}
        printf '%s %s btrfs defaults,subvol=%s 0 0\n' \
            "$source" "$path" "$subvol" >> /etc/fstab.btrfs-new
    done
    mv /etc/fstab.btrfs-new /etc/fstab

    # Ubuntu 26.04 fresh installs use Dracut, not initramfs-tools.
    mkdir -p /etc/dracut.conf.d
    {
        echo 'hostonly="no"'
        echo 'use_fstab="yes"'
        echo 'add_dracutmodules+=" btrfs "'
        if [ "$only_subvols" = no ]; then
            echo 'add_dracutmodules+=" crypt "'
            echo 'install_items+=" /etc/crypttab "'
        fi
    } > /etc/dracut.conf.d/95-btrfs-encrypt-root.conf
    dracut --force --regenerate-all
    update-grub
}

if [ "${1:-}" = //inner ]; then
    configure_installed_system "$2" "$3"
    exit 0
fi

only_subvols=no
enlarge=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --only-subvols) only_subvols=yes; shift ;;
        --enlarge) enlarge=yes; shift ;;
        -h|--help) show_help; exit 0 ;;
        --*) fail "Unknown option: $1" ;;
        *) break ;;
    esac
done
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { show_help; exit 2; }
[ "$(id -u)" -eq 0 ] || fail 'Run as root'
[ "$enlarge" = no ] || [ "$only_subvols" = no ] || fail 'Options are mutually exclusive'
root=$1
boot=$2
efi=${3:-}
[ "$(blkid -s TYPE -o value "/dev/$root")" = btrfs ] || fail 'Root must be Btrfs'
[ "$(blkid -s TYPE -o value "/dev/$boot")" = ext4 ] || fail '/boot must be ext4'
if [ -n "$efi" ]; then
    [ "$(blkid -s TYPE -o value "/dev/$efi")" = vfat ] || fail 'EFI must be FAT32'
fi

# One necessary --enlarge safeguard. Numeric sector comparison, not text order.
if [ "$enlarge" = yes ]; then
    disk=$(lsblk -no PKNAME "/dev/$root" | tr -d '[:space:]')
    partition_number=$(lsblk -no PARTN "/dev/$root" | tr -d '[:space:]')
    last=$(parted -ms "/dev/$disk" unit s print | awk -F: \
        '$1 ~ /^[0-9]+$/ && ($3+0)>max { max=$3+0; number=$1 } END {print number}')
    [ "$partition_number" = "$last" ] || fail '--enlarge requires root to be the last partition'
fi

# Ubuntu's installer may still have the installed OS mounted under /target.
if mountpoint -q /target; then umount -R /target; fi
mkdir -p "$mp"
mount -o subvolid=5 "/dev/$root" "$mp"
[ -z "$(btrfs subvolume list "$mp")" ] || fail 'Expected a fresh Btrfs root with no subvolumes'

# Snapshot the installed system and move home/var data into sibling subvolumes.
btrfs subvolume snapshot "$mp" "$mp/@"
for pair in 'home:@home' 'var/cache:@var_cache' 'var/log:@var_log' 'var/tmp:@var_tmp'; do
    path=${pair%:*}
    subvol=${pair#*:}
    btrfs subvolume create "$mp/$subvol"
    cp -a "$mp/@/$path/." "$mp/$subvol/"
    find "$mp/@/$path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
done
chmod 1777 "$mp/@var_tmp"

# Remove the original flat root, as the upstream script does.
find "$mp" -mindepth 1 -maxdepth 1 \
    ! -name '@' ! -name '@home' ! -name '@var_cache' \
    ! -name '@var_log' ! -name '@var_tmp' -exec rm -rf -- {} +
umount "$mp"

if [ "$only_subvols" = no ]; then
    mount -o subvol=@ "/dev/$root" "$mp"
    btrfs filesystem resize -"$keyslot_size" "$mp"
    umount "$mp"
    cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size "$keyslot_size" "/dev/$root"
    if [ "$enlarge" = yes ]; then
        parted --script "/dev/$disk" resizepart "$partition_number" 100%
        partprobe "/dev/$disk"
    fi
    cryptsetup open "/dev/$root" root
    root_source=/dev/mapper/root
else
    root_source=/dev/$root
fi

mount -o subvol=@ "$root_source" "$mp"
btrfs filesystem resize max "$mp"
for pair in 'home:@home' 'var/cache:@var_cache' 'var/log:@var_log' 'var/tmp:@var_tmp'; do
    path=${pair%:*}
    subvol=${pair#*:}
    mount -o "subvol=$subvol" "$root_source" "$mp/$path"
done

# /boot/efi resides on the ext4 /boot partition, not on the Btrfs root.
mount "/dev/$boot" "$mp/boot"
if [ -n "$efi" ]; then
    mkdir -p "$mp/boot/efi"
    mount "/dev/$efi" "$mp/boot/efi"
fi
mount -t proc proc "$mp/proc"
mount --rbind /sys "$mp/sys"
mount --rbind /dev "$mp/dev"
mount --bind /run "$mp/run"
cp "$script" "$mp/tmp/btrfs-encrypt-root.sh"
chroot "$mp" /bin/sh /tmp/btrfs-encrypt-root.sh //inner "$only_subvols" "/dev/$root"

umount -R "$mp"
if [ "$only_subvols" = no ]; then cryptsetup close root; fi
printf 'Finished. You can reboot.\n'
