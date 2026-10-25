btrfs-encrypt-root
==================

Minimal fork of https://github.com/shukriadams/btrfs-encrypt-root, for fresh
Ubuntu 26.04 installations. Requires UEFI and a separate /boot partition.
Note: Built with Codex, verified on multiple installations, but please check or verify it yourself before you use it.

Preparing Ubuntu
++++++++++++++++

- Boot the Ubuntu 26.04 live USB in UEFI mode and choose Manual installation.
- Create a FAT32 EFI partition mounted at ``/boot/efi`` (about 1 GiB).
- Create an ext4 partition mounted at ``/boot`` (about 2 GiB).
- Create a Btrfs partition mounted at ``/``, initially unencrypted.
- For ``--enlarge``, make the Btrfs partition smaller and leave unallocated
  space immediately after it. It must be the last partition physically.
- Finish installation, choose **Continue testing**, not Restart.

Running the script
++++++++++++++++++

From the live USB desktop, download the script with wget::

  wget https://raw.githubusercontent.com/murtazarang/btrfs-encrypt-root/master/btrfs-encrypt-root.sh

Identify the partition names with ``lsblk -f``. Then run ROOT BOOT EFI, in that
order, without the ``/dev/`` prefix (example only)::

  sudo sh btrfs-encrypt-root.sh nvme1n1p3 nvme1n1p2 nvme1n1p1

To encrypt a smaller root partition, then expand it into the free space::

  sudo sh btrfs-encrypt-root.sh --enlarge nvme1n1p3 nvme1n1p2 nvme1n1p1

``--only-subvols`` creates the same Btrfs layout without encryption.

Layout
++++++

========== ============= ====================================
Mount      Subvolume     Timeshift root snapshot
========== ============= ====================================
/          @             Included
/home      @home         Excluded by default
/var/cache @var_cache    Excluded
/var/log   @var_log      Excluded
/var/tmp   @var_tmp      Excluded
/boot      ext4          Separate partition
/boot/efi  FAT32         Separate EFI partition
========== ============= ====================================

The script follows the upstream mount, chroot and unmount sequence, using
non-recursive bind mounts. Ubuntu 26.04 uses Dracut; during encrypted installs
the script installs ``systemd-cryptsetup`` inside the installed system instead
of upstream's ``cryptsetup-initramfs``. No live-USB apt commands are required.

First-time Timeshift setup (after the first reboot)
+++++++++++++++++++++++++++++++++++++++++++++++

Do this in the installed Ubuntu system, **not** on the live USB.

1. Install Timeshift from Ubuntu's repository::

     sudo apt update
     sudo apt install timeshift

2. Open **Timeshift** from the application menu.
3. In the first-run wizard, choose **BTRFS** (not RSYNC).
4. Select the Btrfs root filesystem (the decrypted LUKS2 volume) as the
   snapshot location. It contains the ``@`` and ``@home`` subvolumes.
5. Keep **Include BTRFS @home subvolume** disabled for both snapshots and
   restores, where those options are shown. Choose any snapshot schedule
   you prefer, or disable scheduled snapshots.
6. Finish the wizard, click **Create** for the first snapshot, and confirm
   it appears in Timeshift's snapshot list.

Only ``@`` is snapshotted. The separate ``@home``, ``@var_cache``,
``@var_log`` and ``@var_tmp`` subvolumes are not included in that snapshot.
These exclusions come from the Btrfs layout; no Timeshift exclusion rules
or custom snapshot hooks are needed.

**Important:** ``/boot`` is a separate ext4 partition and is **not** backed
up by Btrfs snapshots. Keep a separate ``/boot`` backup, especially before
kernel updates, so a restored ``@`` can be matched with the right kernel.
``/boot/efi`` and your personal files also need separate backups.

A YubiKey can be enrolled into LUKS2 later, retaining a passphrase.
