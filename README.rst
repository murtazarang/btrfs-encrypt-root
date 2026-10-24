btrfs-encrypt-root
==================

Ubuntu 26.04.1 fresh installs: encrypt a Btrfs root with LUKS2 and create
Timeshift-compatible subvolumes. Based on
https://github.com/shukriadams/btrfs-encrypt-root.

Layout
------

============ ============ ==================
Mount        Type         Btrfs subvolume
============ ============ ==================
/            LUKS2/Btrfs  @
/home        LUKS2/Btrfs  @home
/var/cache   LUKS2/Btrfs  @var_cache
/var/log     LUKS2/Btrfs  @var_log
/var/tmp     LUKS2/Btrfs  @var_tmp
/boot        ext4         Separate partition
/boot/efi    FAT32        Separate partition
============ ============ ==================

Timeshift snapshots of @ do not include /home, /var/cache, /var/log or
/var/tmp. Timeshift does not automatically snapshot the separate /boot.

Fresh installation
------------------

1. Boot the Ubuntu 26.04.1 USB in UEFI mode and choose Manual installation.
2. Set up an EFI System Partition (~1 GiB, FAT32) mounted at **/boot/efi**;
   a separate 2 GiB ext4 partition mounted at **/boot**;
   and a **Btrfs** partition mounted at **/**, initially **unencrypted**.
   Do not manually create the five subvolumes.
3. To use ``--enlarge``, make the Btrfs partition relatively small, last in
   physical disk order, and leave the rest of the disk **unallocated after it**.
   Otherwise, use the rest of the disk for Btrfs.
4. Finish installation and choose **Continue testing**, not Reboot.
5. In the live terminal, check actual partition names::

      lsblk -f
      sudo parted /dev/nvme1n1 unit GiB print free

   Install required live-session utilities and download the script::

      sudo apt update
      sudo apt install -y curl btrfs-progs cryptsetup parted
      curl -fL -o btrfs-encrypt-root.sh https://raw.githubusercontent.com/murtazarang/btrfs-encrypt-root/master/btrfs-encrypt-root.sh

6. Run with arguments in **ROOT BOOT EFI** order, without ``/dev/``. Example::

      sudo sh btrfs-encrypt-root.sh nvme1n1p3 nvme1n1p2 nvme1n1p1

   Or, if you left unallocated space after root::

      sudo sh btrfs-encrypt-root.sh --enlarge nvme1n1p3 nvme1n1p2 nvme1n1p1

7. Provide your LUKS passphrase, reboot only after the script reports success,
   then install Timeshift and select Btrfs snapshots of @ only.

The script requires a fresh Ubuntu 26.04 installation. ``--only-subvols``
creates the same subvolumes without encryption. Use independent backups for
/home and /boot. An active swapfile inside @ prevents Btrfs snapshots; use
zram or a separate swap subvolume if swap is needed.
