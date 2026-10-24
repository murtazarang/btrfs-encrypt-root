#!/usr/bin/env python3
"""Non-destructive regression tests; no mounts or block devices are used.

Run with: python3 -m unittest discover -s tests -v
The shell library is the production script with only its final main invocation
removed. Filesystem operations are restricted to temporary fixture directories.
No sudo is needed; assigning root ownership is mocked for non-root test runners.
These tests do not replace an Ubuntu installation/boot/rollback test.
"""

import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "btrfs-encrypt-root.sh"


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="btrfs-script-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        source = SCRIPT.read_text()
        self.assertRegex(source, r"(?m)^migrate_directory\(\) \{")
        self.assertRegex(source, r"(?m)^write_mount_config\(\) \{")
        library, count = re.subn(r'(?m)^main "\$@"\s*$', "", source)
        self.assertLessEqual(count, 1, "Expected at most one final main invocation")
        self.library = self.base / "library.sh"
        self.library.write_text(library)
        self.mockbin = self.base / "bin"
        self.mockbin.mkdir()
        self.env = os.environ.copy()
        self.env["PATH"] = str(self.mockbin) + os.pathsep + self.env["PATH"]
        self.env["QA_TEST_PATH"] = self.env["PATH"]
        # No test may invoke real storage operations, even if a helper regresses.
        self.forbidden_log = self.base / "forbidden-commands"
        self.env["QA_FORBIDDEN_LOG"] = str(self.forbidden_log)
        for name in ("mount", "umount", "cryptsetup", "btrfs", "parted",
                     "chroot", "swapon", "swapoff", "mkswap", "mkfs.btrfs",
                     "mkfs.ext4", "wipefs", "losetup", "blockdev", "apt",
                     "apt-get", "dpkg", "update-initramfs", "update-grub",
                     "grub-install", "systemctl", "reboot", "shutdown"):
            self.stub(name, '#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$QA_FORBIDDEN_LOG"\nexit 97\n')
        if os.geteuid() != 0:
            self.env["QA_REAL_CHOWN"] = shutil.which("chown")
            self.env["QA_FIXTURE_ROOT"] = str(self.base)
            self.stub("chown", '''#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = 0:0 ]; then
    case "$2" in
        "$QA_FIXTURE_ROOT"/*)
            [ -f "$2" ] && [ ! -L "$2" ] || exit 97
            exit 0 ;;
    esac
fi
exec "$QA_REAL_CHOWN" "$@"
''')

    def stub(self, name, contents):
        path = self.mockbin / name
        path.write_text(contents)
        path.chmod(0o755)
        return path

    def shell(self, command, *args):
        result = subprocess.run(
            ["/bin/sh", "-c", '. "$1"\nPATH=$QA_TEST_PATH\nexport PATH\nshift\n' + command,
             "test-shell", str(self.library), *(str(a) for a in args)],
            cwd=self.base, env=self.env, text=True, capture_output=True,
            timeout=20,
        )
        self.assertFalse(self.forbidden_log.exists(),
                         "A test attempted a real storage workflow")
        return result

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def make_migration(self):
        source = self.base / "source"
        target = self.base / "target"
        source.mkdir()
        target.mkdir()
        return source, target

    @unittest.skipUnless(shutil.which("rsync"), "rsync required")
    def test_migration_preserves_hidden_files_links_and_permissions(self):
        source, target = self.make_migration()
        (source / ".hidden").write_text("hidden contents\n")
        (source / "normal").write_text("regular contents\n")
        (source / "normal").chmod(0o640)
        (source / "empty").mkdir()
        (source / "empty").chmod(0o750)
        os.link(source / "normal", source / "hardlink")
        (source / "symlink").symlink_to("normal")
        source.chmod(0o1777)
        os.utime(source / "normal", (1600000000, 1600000000))
        try:
            os.setxattr(source / "normal", "user.fixture", b"preserved")
            has_xattr = True
        except OSError:
            has_xattr = False
        original = (source / "normal").stat()
        result = self.shell('migrate_directory "$1" "$2"', source, target)
        self.assert_success(result)
        self.assertEqual(list(source.iterdir()), [], "Excluded data remains under @")
        self.assertEqual((target / ".hidden").read_text(), "hidden contents\n")
        self.assertEqual((target / "normal").read_text(), "regular contents\n")
        self.assertTrue((target / "empty").is_dir())
        self.assertEqual(os.readlink(target / "symlink"), "normal")
        self.assertEqual((target / "normal").stat().st_ino,
                         (target / "hardlink").stat().st_ino)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o1777)
        self.assertEqual(stat.S_IMODE((target / "normal").stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE((target / "empty").stat().st_mode), 0o750)
        self.assertEqual((target / "normal").stat().st_mtime_ns, original.st_mtime_ns)
        self.assertEqual((target / "normal").stat().st_uid, original.st_uid)
        self.assertEqual((target / "normal").stat().st_gid, original.st_gid)
        if has_xattr:
            self.assertEqual(os.getxattr(target / "normal", "user.fixture"), b"preserved")

    @unittest.skipUnless(shutil.which("rsync"), "rsync required")
    def test_migration_handles_empty_directory(self):
        source, target = self.make_migration()
        source.chmod(0o1777)
        result = self.shell('migrate_directory "$1" "$2"', source, target)
        self.assert_success(result)
        self.assertEqual(list(source.iterdir()), [])
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o1777)

    def test_failed_copy_does_not_delete_source(self):
        source, target = self.make_migration()
        (source / "important").write_text("keep me")
        self.stub("rsync", "#!/bin/sh\nexit 12\n")
        result = self.shell('migrate_directory "$1" "$2"', source, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / "important").read_text(), "keep me")

    def test_nonempty_migration_destination_is_not_overwritten(self):
        source, target = self.make_migration()
        (source / "important").write_text("source data")
        (target / "important").write_text("existing destination data")
        result = self.shell('migrate_directory "$1" "$2"', source, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / "important").read_text(), "source data")
        self.assertEqual((target / "important").read_text(), "existing destination data")

    def test_overlapping_migration_paths_are_rejected(self):
        source, _ = self.make_migration()
        target = source / "child"
        target.mkdir()
        (source / "important").write_text("source data")
        result = self.shell('migrate_directory "$1" "$2"', source, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / "important").read_text(), "source data")
        self.assertEqual(list(target.iterdir()), [])

    def test_symlink_migration_source_is_rejected(self):
        source, target = self.make_migration()
        (source / "important").write_text("source data")
        link = self.base / "source-link"
        link.symlink_to(source, target_is_directory=True)
        result = self.shell('migrate_directory "$1" "$2"', link, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / "important").read_text(), "source data")
        self.assertEqual(list(target.iterdir()), [])

    @unittest.skipUnless(shutil.which("rsync"), "rsync required")
    def test_verification_difference_does_not_delete_source(self):
        source, target = self.make_migration()
        (source / "important").write_text("keep me")
        real_rsync = shutil.which("rsync")
        self.env["QA_REAL_RSYNC"] = real_rsync
        self.stub("rsync", '''#!/bin/sh
for arg do
    case "$arg" in
        --dry-run) printf '%s\\n' '>fcs....... important'; exit 0 ;;
        --*) ;;
        -*n*) printf '%s\\n' '>fcs....... important'; exit 0 ;;
    esac
done
exec "$QA_REAL_RSYNC" "$@"
''')
        result = self.shell('migrate_directory "$1" "$2"', source, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / "important").read_text(), "keep me")

    def make_config(self):
        target = self.base / "installed"
        (target / "etc").mkdir(parents=True)
        fstab = target / "etc/fstab"
        fstab.write_text(
            "# existing comment\n"
            "UUID=old-root\t/\tbtrfs\tdefaults,noatime\t0\t1\n"
            "UUID=boot   /boot ext4 defaults 0 2\n"
            "UUID=efi /boot/efi vfat umask=0077 0 1\n"
            "UUID=old-home /home btrfs defaults 0 2\n"
            "UUID=storage /srv/storage ext4 defaults,nofail 0 2\n"
        )
        (target / "etc/crypttab").write_text(
            "# unrelated encrypted volume\n"
            "archive UUID=archive-luks none luks\n"
        )
        return target

    def test_mount_configuration_handles_spacing_and_preserves_unrelated_entries(self):
        target = self.make_config()
        result = self.shell('write_mount_config "$1" "$2" "$3"',
                            target, "filesystem-uuid", "luks-uuid")
        self.assert_success(result)
        text = (target / "etc/fstab").read_text()
        entries = [line.split() for line in text.splitlines()
                   if line.strip() and not line.lstrip().startswith("#")]
        expected = {"/": "@", "/home": "@home", "/var/cache": "@var_cache",
                    "/var/log": "@var_log", "/var/tmp": "@var_tmp"}
        for mountpoint, subvolume in expected.items():
            found = [entry for entry in entries if entry[1] == mountpoint]
            self.assertEqual(len(found), 1, (mountpoint, text))
            entry = found[0]
            self.assertEqual(entry[0], "UUID=filesystem-uuid")
            self.assertEqual(entry[2], "btrfs")
            self.assertIn("subvol=" + subvolume, entry[3].split(","))
            self.assertNotIn("subvolid=", entry[3])
        for mountpoint in ("/boot", "/boot/efi", "/srv/storage"):
            self.assertEqual(len([entry for entry in entries if entry[1] == mountpoint]), 1)
        self.assertIn("# existing comment", text)
        crypttab = (target / "etc/crypttab").read_text()
        self.assertIn("archive UUID=archive-luks none luks", crypttab)
        self.assertIn("UUID=luks-uuid", crypttab)
        self.assertNotIn("UUID=filesystem-uuid", crypttab)

    def test_only_subvolumes_does_not_add_encryption(self):
        target = self.make_config()
        original_crypttab = (target / "etc/crypttab").read_text()
        result = self.shell('write_mount_config "$1" "$2" "$3"',
                            target, "filesystem-uuid", "")
        self.assert_success(result)
        self.assertEqual((target / "etc/crypttab").read_text(), original_crypttab)

    def test_owned_mounts_are_cleaned_in_reverse_order(self):
        log = self.base / "unmounted"
        self.env["QA_UNMOUNT_LOG"] = str(log)
        self.stub("mount", "#!/bin/sh\nexit 0\n")
        self.stub("umount", '''#!/bin/sh
for target do :; done
printf '%s\\n' "$target" >> "$QA_UNMOUNT_LOG"
''')
        result = self.shell('''owned_mounts=
mount_owned "$1/root" fixture-root
mount_owned "$1/root/boot" fixture-boot
mount_owned "$1/root/boot/efi" fixture-efi
unmount_owned
[ -z "$owned_mounts" ]
''', self.base)
        self.assert_success(result)
        self.assertEqual(log.read_text().splitlines(), [
            str(self.base / "root/boot/efi"), str(self.base / "root/boot"),
            str(self.base / "root"),
        ])

    def test_cleanup_failure_keeps_the_failed_mount_tracked(self):
        failed = str(self.base / "root/boot")
        self.env["QA_FAILED_MOUNT"] = failed
        self.stub("umount", '''#!/bin/sh
for target do :; done
[ "$target" != "$QA_FAILED_MOUNT" ]
''')
        result = self.shell('''owned_mounts="$1/root/boot/efi
$1/root/boot
$1/root"
if unmount_owned; then
    exit 99
fi
printf '%s' "$owned_mounts"
''', self.base)
        self.assert_success(result)
        self.assertEqual(result.stdout.strip(), failed)

    def prepare_hook(self, mode):
        target = self.base / "hook-install"
        result = self.shell('''filesystem_uuid=fixture-root-uuid
boot_uuid=fixture-boot-uuid
install_timeshift_hooks "$1"
''', target)
        self.assert_success(result)
        generated = target / "etc/timeshift" / (mode + "-hooks.d") / "50-boot"
        # Change executable lookup only, leaving production guard logic intact.
        # The real hooks intentionally use a fixed PATH rather than inheriting it.
        hook = self.base / (mode + "-hook.sh")
        content = generated.read_text()
        needle = "PATH=/usr/sbin:/usr/bin:/sbin:/bin"
        self.assertEqual(content.count(needle), 1)
        hook.write_text(content.replace(needle, "PATH=$QA_TEST_PATH", 1))
        snapshot = self.base / "snapshot"
        (snapshot / "@").mkdir(parents=True)
        self.env["TS_SNAPSHOT_PATH"] = str(snapshot)
        self.env["QA_HOOK_FS_UUID"] = "fixture-root-uuid"
        self.env["QA_HOOK_RUNTIME"] = str(self.base)
        self.stub("findmnt", '#!/bin/sh\nprintf "%s\\n" "$QA_HOOK_FS_UUID"\n')
        self.stub("btrfs", "#!/bin/sh\nprintf 'UUID: fixture-snapshot-uuid\\n'\n")
        self.stub("id", "#!/bin/sh\nprintf '0\\n'\n")
        self.stub("logger", "#!/bin/sh\nexit 0\n")
        self.stub("mktemp", '''#!/bin/sh
if [ "$*" = '-d /run/timeshift-boot.XXXXXX' ]; then
    exec /usr/bin/mktemp -d "$QA_HOOK_RUNTIME/runtime.XXXXXX"
fi
exec /usr/bin/mktemp "$@"
''')
        self.transfer_log = self.base / "hook-transfer-attempts"
        self.env["QA_TRANSFER_LOG"] = str(self.transfer_log)
        for name in ("tar", "rsync"):
            self.stub(name, '#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$QA_TRANSFER_LOG"\nexit 97\n')
        return hook, snapshot

    def run_hook(self, hook):
        result = subprocess.run(["/bin/sh", str(hook)], cwd=self.base,
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertFalse(self.forbidden_log.exists(), "Hook guard allowed a storage operation")
        self.assertFalse(self.transfer_log.exists(), "Hook guard allowed archive/copy operations")
        return result

    def test_restore_hook_refuses_absent_boot_archive_before_mounting(self):
        hook, snapshot = self.prepare_hook("restore")
        (snapshot / "boot-state").mkdir()
        result = self.run_hook(hook)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr.lower())

    def test_restore_hook_refuses_snapshot_from_wrong_filesystem(self):
        hook, _ = self.prepare_hook("restore")
        self.env["QA_HOOK_FS_UUID"] = "another-filesystem"
        result = self.run_hook(hook)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("filesystem", result.stderr.lower())

    def test_rejected_boot_state_symlink_does_not_modify_destination(self):
        hook, snapshot = self.prepare_hook("restore")
        outside = self.base / "unrelated-directory"
        outside.mkdir()
        (outside / "keep").write_text("unrelated data")
        (snapshot / "boot-state").symlink_to(outside, target_is_directory=True)
        result = self.run_hook(hook)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["keep"])
        self.assertEqual((outside / "keep").read_text(), "unrelated data")

    def test_failure_marker_symlink_does_not_overwrite_external_file(self):
        hook, snapshot = self.prepare_hook("restore")
        state = snapshot / "boot-state"
        state.mkdir()
        outside = self.base / "unrelated-file"
        outside.write_text("unrelated data")
        (state / "restore-FAILED").symlink_to(outside)
        result = self.run_hook(hook)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), "unrelated data")

    def test_retried_backup_preserves_existing_completed_boot_state(self):
        hook, snapshot = self.prepare_hook("backup")
        state = snapshot / "boot-state"
        state.mkdir()
        ready = state / "READY"
        ready.write_text("complete\n")
        result = self.run_hook(hook)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(ready.read_text(), "complete\n")

    def test_shell_syntax(self):
        result = subprocess.run(["/bin/sh", "-n", str(SCRIPT)], text=True,
                                capture_output=True, timeout=10)
        self.assert_success(result)

    def test_help_is_available_without_root(self):
        self.stub("id", "#!/bin/sh\nprintf '1000\\n'\n")
        result = self.shell("main --help")
        self.assert_success(result)
        self.assertIn("Usage:", result.stdout)
        self.assertFalse(self.forbidden_log.exists())

    def test_conversion_refuses_nonroot_before_storage_checks(self):
        self.stub("id", "#!/bin/sh\nprintf '1000\\n'\n")
        result = self.shell("main fixture-root fixture-boot fixture-efi")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("root", result.stderr.lower())

    def test_unknown_option_is_rejected_without_storage_access(self):
        result = self.shell("main --not-an-option")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown option", result.stderr.lower())

    def test_conflicting_encryption_and_resize_options_are_rejected(self):
        self.stub("id", "#!/bin/sh\nprintf '0\\n'\n")
        result = self.shell("main --only-subvols --enlarge fixture-root fixture-boot")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be combined", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
