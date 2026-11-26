# Unattended LUKS unlock with a YubiKey 5C Nano

This optional guide is for an **already encrypted** Ubuntu Server 26.04.1 installation from this repository: LUKS2, Dracut, systemd-cryptsetup, GRUB, and a separate `/boot`. Run the commands on the installed server, not from the installer USB.

The goal is **Nano inserted: boot without a touch, PIN, or typed passphrase. Nano absent: unlock at the normal boot prompt with the original LUKS passphrase.** Nothing here changes your Linux account or SSH login. Ubuntu supplies the standard Clevis/Dracut integration; [CIQ’s YubiKey plug-in](https://github.com/ctrliq/clevis-yubikey) is a third-party add-on documented for Rocky Linux. It uses the YubiKey’s vendor-documented OTP HMAC challenge-response, not FIDO2. This guide reflects a successful no-touch challenge, a LUKS binding, and inspection of the rebuilt Ubuntu image. It does not establish a completed boot with and without the key.

**Physical security:** Anyone with the server and its enrolled Nano can unlock the disk without the passphrase. No plaintext unlock key is intentionally stored in `/boot`. Keep the original passphrase and arrange a local or out-of-band console before rebooting; ordinary SSH cannot answer the early disk prompt.

## 1. Identify the disk and backup drive

Use one shell for the commands below. Stop on an unexpected result; do not run all steps as one unattended script.

```bash
lsblk -o PATH,TRAN,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS
findmnt --mountpoint /boot -o SOURCE,TARGET,FSTYPE
sudo cryptsetup status root
```

Set `root_dev` to the underlying LUKS2 partition from `cryptsetup status root`, **not** `/dev/mapper/root`. Set `backup_dev` to the **partition** with the backup drive’s label, not its parent disk. The example uses a partition labeled BIG. USB device names can change when you reconnect a drive. Verify both paths before continuing.

```bash
root_dev=/dev/nvme1n1p3    # example: encrypted root partition
backup_dev=/dev/sdf3      # example: USB partition labeled BIG
backup_mount=/mnt/big
k=$(uname -r)
img="/boot/initrd.img-$k"

sudo cryptsetup luksDump "$root_dev" |
  sed -n '/^Keyslots:/,/^Digests:/p'
df -h /boot
```

Check that LUKS2 has the existing passphrase slot and room for another one. Check free space on `/boot` for two more copies of the current image (the saved image and the staged image).

If the backup partition is already mounted, set `backup_mount` to its existing mount point and skip `mkdir` and `mount`. Otherwise:

```bash
sudo mkdir -p "$backup_mount" &&
  sudo mount "$backup_dev" "$backup_mount"
findmnt --mountpoint "$backup_mount" -o SOURCE,TARGET,FSTYPE,OPTIONS
```

Confirm that the source is the intended USB partition and the options include `rw`. If the mount fails or is read-only, stop rather than forcing it. For NTFS on Linux, you can specify `-o rw,umask=077` at the initial mount to restrict local access. This does not encrypt the backup. [mount](https://man7.org/linux/man-pages/man8/mount.8.html) · [findmnt](https://man7.org/linux/man-pages/man8/findmnt.8.html)

## 2. Save the LUKS header and current boot image

The header goes to separate secure storage; the boot-image copy stays on `/boot` so GRUB can load it. Run this **before** adding the Nano binding. Keep any prior known-good backups rather than overwriting them.

```bash
findmnt --mountpoint "$backup_mount" --source "$backup_dev" &&
  findmnt --mountpoint "$backup_mount" -no OPTIONS | grep -Eq '(^|,)rw(,|$)' &&
  sudo test -s "$img" &&
  sudo test ! -e "$img.pre-nano" &&
  backup=$(sudo mktemp -d "$backup_mount/yubikey-luks.XXXXXXXX") &&
  sudo cryptsetup luksHeaderBackup "$root_dev" \
    --header-backup-file "$backup/root-luks.header" &&
  sudo test -s "$backup/root-luks.header" &&
  sudo cp -a "$img" "$img.pre-nano" &&
  printf 'Header: %s/root-luks.header\nBoot image: %s.pre-nano\n' "$backup" "$img"
```

On a Unix-permission filesystem, keep the header file root-only: `sudo chmod 600 "$backup/root-luks.header"`. A restrictive mount mask on NTFS/exFAT/FAT is only a local access control. Keep the backup drive physically secure or encrypted, and do not upload or paste the header. Once both backup paths print, unmount the USB before disconnecting it:

```bash
sudo umount "$backup_mount"
```

[Cryptsetup header backup and security notes](https://man7.org/linux/man-pages/man8/cryptsetup-luksHeaderBackup.8.html)

## 3. Install Clevis and the CIQ plug-in

```bash
sudo apt install clevis clevis-luks clevis-dracut yubikey-manager \
  yubikey-personalization xxd git
```

Ubuntu Resolute’s `clevis-dracut` includes the fix for the Dracut 110 `cryptsetup.target` ordering issue (introduced in `20-1ubuntu2`). There is no separate ordering workaround to add. The CIQ pin uses `ykchalresp` from Ubuntu’s `yubikey-personalization` package; Yubico has retired that upstream tool, so it remains a dependency to check if upgrading Ubuntu releases. [Ubuntu package](https://packages.ubuntu.com/resolute/clevis-dracut) · [Ordering fix](https://github.com/latchset/clevis/issues/545)

The following installs the two upstream executables and the Dracut module from [CIQ’s source](https://github.com/ctrliq/clevis-yubikey/blob/main/src/meson.build), without a Rocky RPM or a build toolchain. It assumes the Ubuntu module path `/usr/lib/dracut/modules.d` and that no other YubiKey pin is installed. Read the linked source before installing code that runs during boot.

```bash
src=$(mktemp -d) &&
  git clone --depth 1 https://github.com/ctrliq/clevis-yubikey.git "$src" &&
  bash -n "$src/src/clevis-encrypt-yubikey" &&
  bash -n "$src/src/clevis-decrypt-yubikey" &&
  bash -n "$src/src/module-setup.sh.in" &&
  sudo install -m 0755 "$src/src/clevis-encrypt-yubikey" \
    "$src/src/clevis-decrypt-yubikey" /usr/bin/ &&
  sudo install -D -m 0755 "$src/src/module-setup.sh.in" \
    /usr/lib/dracut/modules.d/60clevis-pin-yubikey/module-setup.sh
```

## 4. Configure and check the Nano

Connect only the intended YubiKey. The plug-in uses the first OTP-capable YubiKey it finds.

```bash
sudo ykman otp info
```

A factory key normally has slot 1 programmed and slot 2 empty. Leave slot 1 alone. **If OTP slot 2 is empty**, program it once with a fresh challenge-response secret. Do not add `--touch`. Run this privately and do not share the command output; it can show the secret. If slot 2 is already programmed for this setup, skip the write. If you don't know what occupies slot 2, do not overwrite it.

```bash
sudo ykman otp chalresp --generate 2
```

Confirm it responds without touching the Nano. The test challenge is public; the response is discarded. Continue only if it prints the success line.

```bash
sudo timeout 10s ykchalresp -2 -N -x \
  000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  >/dev/null && printf 'Nano answered without touch\n'
```

[Yubico OTP guide](https://docs.yubico.com/software/yubikey/tools/ykman/OTP_Commands.html) · [ykchalresp source](https://github.com/Yubico/yubikey-personalization/blob/master/ykchalresp.c)

## 5. Add a separate disk unlock slot and verify it

```bash
sudo clevis luks list -d "$root_dev"
```

If the expected YubiKey binding is already listed, **don’t bind again**. Otherwise run the following once, supplying your **original LUKS passphrase** when prompted. `{"slot":2}` selects the Nano’s OTP slot, not the LUKS disk slot. Clevis chooses a free LUKS slot and leaves the original in place. If the bind fails, stop and check the header rather than retrying or deleting slots.

```bash
sudo clevis luks bind -d "$root_dev" yubikey '{"slot":2}' &&
  sudo clevis luks list -d "$root_dev"
```

On Clevis v20, a line such as `1: unknown pin 'yubikey'` is expected: the list formatter doesn’t recognize third-party pins, but the decrypt dispatcher loads them. Put the number **before the colon** in `luks_slot`. Keep the redirect so the recovered unlock secret is not printed.

```bash
luks_slot=1
sudo timeout 20s clevis luks pass -d "$root_dev" -s "$luks_slot" \
  >/dev/null && printf 'Nano unlock credential verified\n'
```

Continue only if that success line appears. This validates the recovered credential against the disk slot on the running system. It does not reboot or prove early-boot operation. [Clevis v20 bind](https://github.com/latchset/clevis/blob/v20/src/luks/clevis-luks-bind) · [List and verification code](https://github.com/latchset/clevis/blob/v20/src/luks/clevis-luks-common-functions.in#L150-L347)

## 6. Build and check the new initramfs

This adds persistent Dracut configuration and builds a staged image without replacing the working one. Leave `/etc/crypttab` and GRUB configuration unchanged. If a staged image already exists, inspect it rather than forcing an overwrite.

```bash
sudo test -s "$img.pre-nano" &&
  printf 'add_dracutmodules+=" clevis-pin-yubikey "\n' |
    sudo tee /etc/dracut.conf.d/90-clevis-yubikey.conf &&
  sudo dracut "$img.nano-new" "$k" &&
  sudo lsinitrd "$img.nano-new" |
    grep -E 'etc/crypttab|cryptsetup\.target\.wants/clevis-luks-askpass\.path|clevis-luks-askpass\.(path|service)|clevis-decrypt-yubikey|ykchalresp|libykpers|libusb|usbhid'
```

Check for `etc/crypttab`, the `cryptsetup.target.wants/clevis-luks-askpass.path` symlink and its target unit, `clevis-luks-askpass.service`, `clevis-decrypt-yubikey`, `ykchalresp`, and its USB/YubiKey shared libraries. Seeing only `cryptsetup.target` is not enough. If anything is missing, **do not activate or reboot**. [Dracut configuration](https://manpages.ubuntu.com/manpages/resolute/man5/dracut.conf.5.html) · [Dracut commands](https://manpages.ubuntu.com/manpages/resolute/man8/dracut.8.html)

## 7. Activate and boot

Once the live credential check and the image inspection pass, run the following once. It moves the staged image into the normal path GRUB already uses. If the move already succeeded, don’t repeat it; `.nano-new` is no longer there.

```bash
sudo test -s "$img.pre-nano" &&
  sudo test -s "$img.nano-new" &&
  sudo mv -- "$img.nano-new" "$img" &&
  printf 'Nano boot image activated\n'
```

Leave the Nano inserted, make sure you can reach the boot console, then run `sudo reboot` when ready. Use the kernel version whose image you updated. If GRUB defaults to another version, select the intended kernel under **Advanced options for Ubuntu**.

The normal passphrase prompt may flash briefly: Clevis answers systemd’s existing prompt in parallel. If the prompt stays up, enter the original passphrase. If you need to confirm the absent-Nano route on your machine, do so only with a console available; there is no extra test image to boot as part of installation. [Clevis systemd prompt handler](https://github.com/latchset/clevis/blob/v20/src/luks/systemd/clevis-luks-askpass.in)

**Recovery if the new image doesn’t reach the normal prompt:** In GRUB, select the entry for the **same kernel**, press **e**, and append `.pre-nano` to the matching `initrd.img-<version>` filename on the `initrd` line. Leave any microcode filenames alone. Press **Ctrl+X** to boot the saved image once and enter the original LUKS passphrase. Do not restore the LUKS header for a boot-image problem. [GRUB menu editor](https://www.gnu.org/software/grub/manual/grub/html_node/Menu-entry-editor.html)

## Clarifications

- **Does this format the backup drive, make a partition, or save an ISO?** No. It saves a small binary LUKS header backup on the mounted drive and a separate initramfs copy in `/boot`. It doesn’t copy the full disk or your files. The disk is already encrypted; the backup is taken before adding the Nano, not before encryption.
- **Should I change NTFS to exFAT?** No. NTFS, exFAT, FAT32, and ext4 can store the file. Use the existing writable filesystem. Changing formats would erase the partition and would not encrypt the backup.
- **Why keep the header private?** It doesn’t contain your plaintext password or files, but lets someone check guesses for the old passphrase offline. If they also obtain the encrypted disk or a copy, the old header and old passphrase can still unlock it as long as the volume encryption key hasn’t changed. Merely changing the current passphrase doesn’t revoke an old header.
- **Is a fresh Nano completely empty? Do I need an iPhone or reset?** Neither is needed. A factory-programmed OTP slot 1 is normal. `ykman otp info` verifies occupancy, not the credential type or other YubiKey applications. Enrollment changes only the selected empty OTP slot. Do not reset or reprogram that slot after binding unless you intend to replace the disk’s Nano unlock method.
- **Does this persist after a kernel update?** Yes, during normal Ubuntu kernel updates with Dracut and the plug-in still installed. The disk binding persists and the saved Dracut configuration includes the plug-in in each new boot image. You do not repeat the setup, move an image again, or rebind the Nano. Optionally inspect the first new image with `sudo lsinitrd /boot/initrd.img-<new-version>` before rebooting. Use the new version from `ls -1 /boot/vmlinuz-*`, not `uname -r` while still on the old kernel. The saved `.pre-nano` image is only for its matching kernel.
