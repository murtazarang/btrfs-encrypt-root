#!/bin/sh
# Based on shukriadams/btrfs-encrypt-root; minimal Ubuntu 26.04 adaptation.
set -e

script=`readlink -f "$0"`
scriptname=`basename "$script"`
scriptpath=`dirname "$script"`

[ `id -u` -eq 0 ] || { echo "ERROR: Must be run as root."; exit 1; }

mp=/mnt/root
keyslot_size=32m


preparation() {
    echo "Prepare"
    if [ $efi = true ]
    then
        umount /target/boot/efi
    fi
    umount /target/boot
    umount /target/cdrom
    umount /target

    mkdir $mp
}

create_subvols() {
    echo "Create subvolumes"
    mount /dev/"$1" $mp
    cd $mp

    btrfs subvolume snapshot . @

    # Only additions to the upstream Btrfs layout. Copy inside the root
    # filesystem so hidden files never pass through the live USB's /tmp.
    for pair in home:@home var/cache:@var_cache var/log:@var_log var/tmp:@var_tmp
    do
        dir=${pair%:*}
        subvol=${pair#*:}
        btrfs subvolume create "$subvol"
        cp -a "@/$dir/." "$subvol/"
        find "@/$dir" -mindepth 1 -maxdepth 1 -exec rm -Rf -- {} +
    done
    chmod 1777 @var_tmp

    find -maxdepth 1 \! -name "@*" \! -name . -exec rm -Rf {} \;

    cd /
    umount $mp
    echo "Mount @ instead of /"
    mount /dev/"$1" -o subvol=@ $mp
}

encrypt_and_enlarge() {
    echo "Encrypt $1"
    btrfs filesystem resize -$keyslot_size $mp
    cd /
    umount $mp
    disk=`lsblk --noheadings --output pkname /dev/"$1"`
    partition_number=`lsblk --noheadings --output partn /dev/"$1" | tr -d "[:space:]"`
    echo 'You may ignore “Warning: keyslot operation could fail …”.'
    echo 'See <https://gitlab.com/cryptsetup/cryptsetup/-/issues/896>.'
    cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size $keyslot_size /dev/"$1"
    if [ $enlarge = yes ]
    then
        echo "Enlarge $1"
        parted --script /dev/"$disk" resizepart "$partition_number" "100%"
    fi
    cryptsetup open /dev/"$1" root
    mount /dev/mapper/root -o subvol=@ $mp
    btrfs filesystem resize max $mp
}

chroot_and_mkinitramfs() {
    echo "Prepare $mp for chroot"
    mount -t proc proc $mp/proc
    mount -t sysfs sys $mp/sys
    mount --bind /dev $mp/dev
    mount --bind /run $mp/run

    if [ $only_subvols = yes ]
    then
        subvol_device=/dev/"$1"
    else
        subvol_device=/dev/mapper/root
    fi
    mount "$subvol_device" -o subvol=@home $mp/home
    mount "$subvol_device" -o subvol=@var_cache $mp/var/cache
    mount "$subvol_device" -o subvol=@var_log $mp/var/log
    mount "$subvol_device" -o subvol=@var_tmp $mp/var/tmp

    mount /dev/"$2" $mp/boot
    if [ ! -z "$3" ]
    then
        mkdir -p $mp/boot/efi
        mount /dev/"$3" $mp/boot/efi
    fi
    cp "$script" $mp/tmp/"$scriptname"
    chmod a+x $mp/tmp/"$scriptname"
    echo "Chrooting and call the script in the other root"
    chroot $mp /tmp/"$scriptname" //inner $only_subvols /dev/"$1"
}

unmount_everything() {
    echo "Unmounting"
    cd /
    for dir in proc sys dev run
    do
        umount $mp/$dir
    done
    if [ $efi = true ]
    then
        umount $mp/boot/efi
    fi
    umount $mp/boot
    umount $mp/var/tmp
    umount $mp/var/log
    umount $mp/var/cache
    umount $mp/home
    umount $mp
    if [ $only_subvols = no ]
    then
        cryptsetup close root
    fi
}

if [ "$1" = "//inner" ]
then
    only_subvols="$2"
    root_uuid=`blkid --output export "$3" | grep ^UUID=`
    if [ "$only_subvols" = "yes" ]
    then
        echo "Patch /etc/fstab"
        sed --in-place "s!^.* / btrfs defaults 0 1\$!$root_uuid / btrfs defaults,subvol=@ 0 1!" /etc/fstab
        device="$root_uuid"
    else
        echo "Patch /etc/fstab"
        sed --in-place 's!^.* / btrfs defaults 0 1$!/dev/mapper/root / btrfs defaults,subvol=@ 0 1!' /etc/fstab
        device=/dev/mapper/root
        echo "root $root_uuid none luks,discard" > /etc/crypttab
        # 26.04 uses Dracut by default; keep it instead of installing
        # the upstream cryptsetup-initramfs package.
        apt-get install -y systemd-cryptsetup
    fi

    echo "$device /home btrfs defaults,subvol=@home 0 2" >> /etc/fstab
    echo "$device /var/cache btrfs defaults,subvol=@var_cache 0 2" >> /etc/fstab
    echo "$device /var/log btrfs defaults,subvol=@var_log 0 2" >> /etc/fstab
    echo "$device /var/tmp btrfs defaults,subvol=@var_tmp 0 2" >> /etc/fstab

    # Dracut must build for the installed filesystem, not the live USB.
    mkdir -p /etc/dracut.conf.d
    echo 'hostonly="no"' > /etc/dracut.conf.d/90-btrfs-encrypt-root.conf
    echo 'use_fstab="yes"' >> /etc/dracut.conf.d/90-btrfs-encrypt-root.conf
    echo 'add_dracutmodules+=" btrfs "' >> /etc/dracut.conf.d/90-btrfs-encrypt-root.conf
    if [ "$only_subvols" = "no" ]
    then
        echo 'add_dracutmodules+=" crypt "' >> /etc/dracut.conf.d/90-btrfs-encrypt-root.conf
        echo 'install_items+=" /etc/crypttab "' >> /etc/dracut.conf.d/90-btrfs-encrypt-root.conf
    fi
    echo "Update initramfs"
    dracut --regenerate-all --force
    update-grub
    exit
fi

show_help() {
    echo "Add @, @home and @var_* subvolumes to a Btrfs root partition,"
    echo "and encrypt it optionally"
    echo
    echo "Usage: btrfs-encrypt-root [options] {root-dev} {boot-dev} [{efi-dev}]"
    echo
    echo "The devices must be given without the /dev/ prefix."
    echo
    echo "  --only-subvols            do not encrypt, only create subvolumes"
    echo "  --enlarge                 enlarge root partition to maximum"
    echo
    echo "--enlarge resizes the root partition to 100%.  This makes encryption"
    echo "much faster, because you make a small partition for just the"
    echo "installation of the base system, and then you call this script,"
    echo "which has to encrypt only the smaller partition.  The enlargement"
    echo "covers only empty space, so no encryption is necessary there."
}

if [ $# -eq 0 ]
then
    show_help
    exit
fi

only_subvols=no
enlarge=no

while :; do
    case $1 in
        -h|-\?|--help)
            show_help
            exit
            ;;
        --only-subvols)
            only_subvols=yes
            ;;
        --enlarge)
            enlarge=yes
            ;;
        --*)
            echo "Invalid option “$1”.  Use --help for more information."
            exit 2
            ;;
        *)
            break
    esac
    shift
done

if [ -z "$3" ]
then
    efi=false
else
    efi=true
fi

if [ -z "$1" -o -z "$2" ]
then
    echo "You must pass the device of the root, boot, and optionally "
    echo "EFI partition (without the /dev/) to this script."
    echo
    echo "Use --help for more information."
    exit 2
fi

preparation
create_subvols "$1"
if [ $only_subvols = no ]
then
    encrypt_and_enlarge "$1"
fi
chroot_and_mkinitramfs "$1" "$2" "$3"
unmount_everything
echo "Finished"
