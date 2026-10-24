btrfs-encrypt-root
==================

Fresh-install conversion for Ubuntu 26.04.1: LUKS2 encryption, a Timeshift-compatible
Btrfs layout, and matching backups of the separate /boot partition.

Fork of https://github.com/shukriadams/btrfs-encrypt-root, originally from
https://gitlab.com/bronger/btrfs-encrypt-root.

Layout
------

All five subvolumes share one encrypted Btrfs partition. The Btrfs default remains
top-level ID 5; fstab mounts each subvolume by name.

============== =============== ================================
Mount          Subvolume       Included in root snapshots
============== =============== ================================
/              @               Yes
/home          @home           No
/var/cache     @var_cache      No, including all cache contents
/var/log       @var_log        No
/var/tmp       @var_tmp        No
/boot          Separate ext4   Saved by the included boot hooks
/boot/efi      Separate FAT32  No
============== =============== ================================

/boot and the EFI System Partition remain unencrypted. No root-unlock key is
placed in /boot or the initramfs.

Install and convert
-------------------

1. Boot the Ubuntu 26.04.1 live USB in **UEFI mode**. In the installer, choose
   manual partitioning. Use three partitions on the same installation disk:

   * FAT32 EFI System Partition: about 1 GiB, mounted at /boot/efi.
   * ext4: 2 GiB, mounted at /boot.
   * Btrfs: remaining space, mounted at /, initially **unencrypted**.

   Do not create separate home or var partitions, LVM, or Btrfs subvolumes.

2. Finish installation and select **Continue testing**, not reboot. Close the
   installer. Stay in this live session until conversion finishes.

3. Check device names with ``lsblk -f``. The script requires a fresh, flat,
   single-device Btrfs installation with no existing subvolumes. If the installer
   created swap, disable that swapfile and remove its file and fstab entry before
   conversion. Configure swap afterward outside @ and @home, or use zram.

4. Connect to the internet. Install live-session dependencies and download this
   fork's script::

     sudo apt update
     sudo apt install btrfs-progs cryptsetup rsync parted python3 curl
     curl -fL -o btrfs-encrypt-root.sh https://raw.githubusercontent.com/murtazarang/btrfs-encrypt-root/master/btrfs-encrypt-root.sh
     less btrfs-encrypt-root.sh

5. Run it with **ROOT BOOT EFI**, without the /dev/ prefix. For example, only if
   these are your actual partitions::

     sudo sh btrfs-encrypt-root.sh nvme0n1p3 nvme0n1p2 nvme0n1p1

   Confirm the displayed installation disk and choose your LUKS passphrase when
   prompted. The script installs target packages, migrates files with metadata,
   encrypts root, updates fstab/crypttab, and rebuilds all initramfs images and
   GRUB configuration.

6. Reboot only after the script reports success. Verify passphrase unlock and
   normal startup before creating your first Timeshift snapshot.

Options and failures
--------------------

* ``--only-subvols``: creates the same layout and Timeshift setup without
  encryption.
* ``--enlarge``: encrypts a smaller initial root partition, then extends it into
  trailing free space. Requires GPT and root to be the physically last partition.
  Cannot be combined with ``--only-subvols``.
* ``--help``: prints usage without modifying disks.

Checks reject mismatched devices, unexpected mounts, existing subvolumes,
configured swap, insufficient migration space, and partial conversions.
The script is **not safely rerunnable after conversion starts**. If it fails,
do not blindly rerun or reboot; inspect the reported stage. Reinstalling is the
simplest recovery for a disposable fresh installation.

Timeshift and /boot
------------------

Timeshift is configured for Btrfs snapshots of @, with home excluded and all
schedules initially disabled. After your first successful boot, create a snapshot
while APT, dpkg, and kernel updates are idle::

  sudo timeshift --create --comments "Fresh installation" --tags O

The backup hook must report ``Timeshift boot backup complete``. Each completed
snapshot contains ``boot-state/READY``, a checksummed /boot archive, and the
root/boot UUIDs alongside its @ directory. Then configure your preferred schedule
in Timeshift.

Restoring a snapshot also restores its matching kernel, initramfs, and grub.cfg.
The hooks check filesystem UUIDs and the restored subvolume before writing /boot.
They do not roll back the EFI partition or firmware boot entries.

**Timeshift ignores hook failures.** Check the boot-hook completion message and
markers; Timeshift's own success message is insufficient. Its automatic
"Before restoring" snapshot does not run the backup hook and has no boot archive.
Create and check a normal snapshot before initiating a rollback.

Restore, including from a live USB
---------------------------------

For live recovery, boot the same Ubuntu live USB in UEFI mode, install the tools,
and unlock the root partition, replacing the example device::

  sudo apt update
  sudo apt install timeshift btrfs-progs cryptsetup rsync
  sudo cryptsetup open /dev/nvme0n1p3 root

For either live or installed-system recovery, mount Btrfs top level and list the
snapshots. Skip the unlock command above if root is already unlocked::

  sudo mkdir -p /mnt/btrfs
  sudo mount -o subvolid=5 /dev/mapper/root /mnt/btrfs
  sudo ls /mnt/btrfs/timeshift-btrfs/snapshots

Set SNAPSHOT to the chosen directory, replacing TIMESTAMP below. Check that the
boot backup completed and its checksums match. **Stop if either check fails**::

  SNAPSHOT=/mnt/btrfs/timeshift-btrfs/snapshots/TIMESTAMP
  sudo test -s "$SNAPSHOT/boot-state/READY"
  sudo sh -c 'cd "$1/boot-state" && sha256sum -c SHA256SUMS' sh "$SNAPSHOT"

Copy that snapshot's self-contained restore hook into the current session. This
is required on a live USB because Timeshift runs restore hooks in the current
system. Clear the previous success marker and restore the selected snapshot::

  sudo install -d /etc/timeshift/restore-hooks.d
  sudo install -m 700 "$SNAPSHOT/@/etc/timeshift/restore-hooks.d/50-boot" /etc/timeshift/restore-hooks.d/50-boot
  sudo rm -f "$SNAPSHOT/boot-state/restore-OK"
  sudo timeshift --btrfs --snapshot-device /dev/mapper/root \
    --restore --snapshot "${SNAPSHOT##*/}" --target-device /dev/mapper/root

Confirm that same snapshot and root filesystem. **Decline automatic reboot.**
Require the ``Timeshift boot restore complete`` message and check the newly
created success marker before rebooting::

  sudo test -s "$SNAPSHOT/boot-state/restore-OK"
  sudo test ! -e "$SNAPSHOT/boot-state/restore-FAILED"

With ``--only-subvols``, use the unencrypted root partition instead of
/dev/mapper/root in these recovery commands.

Package baseline and optional YubiKey
------------------------------------

Targets stable Ubuntu 26.04.1 packages as of **2026-10-24**, using official Ubuntu
repositories and normal updates, without version pinning:

* `Timeshift 25.12.4-1 <https://packages.ubuntu.com/resolute/timeshift>`_
  (Btrfs backup/restore hook support).
* `btrfs-progs 6.17.1-1build1 <https://packages.ubuntu.com/resolute/btrfs-progs>`_.
* `cryptsetup / cryptsetup-initramfs 2:2.8.4-1ubuntu4 <https://packages.ubuntu.com/source/resolute/cryptsetup>`_.
* `Dracut 110-11ubuntu0.1 <https://manpages.ubuntu.com/manpages/resolute/man8/update-initramfs.8.html>`_.

The script also installs systemd-cryptsetup. It configures Dracut for a chroot
build from fstab and checks that encrypted-root initramfs images contain crypttab.

A YubiKey can be added later to the existing LUKS2 container with
`systemd-cryptenroll <https://www.freedesktop.org/software/systemd/man/259/systemd-cryptenroll.html>`_,
without reinstalling. FIDO2 unlocking needs
`hmac-secret support <https://docs.yubico.com/hardware/yubikey/yk-tech-manual/yk5-apps-fido.html>`_
(YubiKey 5C firmware 5.2 or later), appropriate crypttab/initramfs configuration,
and a boot test. Keep a working recovery passphrase.

Keep an independent encrypted backup of your files: same-disk snapshots do not
protect against disk failure.
