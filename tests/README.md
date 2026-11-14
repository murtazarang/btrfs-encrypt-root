# Tests for the current shell script

Run `python3 -m unittest discover -s tests -v`. These tests use temporary directories and stubs for mount, Btrfs, encryption, partitioning, chroot, package-manager and boot commands. They never operate on real block devices.

The previous suite targeted functions (`migrate_directory`, `write_mount_config`, and other safeguards) from a prior implementation. Commit `68b53b3` replaced that implementation without updating the tests. The new suite exercises the present code: basic option parsing; unencrypted subvolume migration using a temporary filesystem fixture; both inner fstab/dracut paths; and the current resize command constructed from `lsblk` output. History preserves the old tests; their coverage is not claimed for the new script.

One test is marked **expected failure**: the current inner script's `sed` expression only rewrites an exact ` / btrfs defaults 0 1` line and does not reject a nonmatching line. Such a file can leave root mounted without `subvol=@` even though the step reports success. This test documents the missing guard; it does not alter the implementation. Verify the exact fstab on the installed target before running conversion.

Not covered: real Btrfs snapshot semantics; mounts and unmounts; LUKS re-encryption and interruption/recovery; actual partition-table and filesystem resizing; initramfs generation; UEFI/GRUB; first boot; Timeshift snapshot/restore; Secure Boot; disk failures; or an Ubuntu 26.04 installation. A pass here is not a real-machine verification.
