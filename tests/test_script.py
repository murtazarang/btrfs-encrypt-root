#!/usr/bin/env python3
"""Tests for the current shell implementation; never mounts a block device.

Shell functions are extracted and invoked with temporary directories and stubbed
storage commands. These tests do not replace an Ubuntu Live install, boot,
Timeshift restore or encryption/re-encryption test on disposable hardware.
"""
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
SCRIPT=ROOT/'btrfs-encrypt-root.sh'
SOURCE=SCRIPT.read_text()

def function(name):
    match=re.search(r'^'+re.escape(name)+r'\(\) \{\n.*?^\}',SOURCE,re.M|re.S)
    if not match: raise AssertionError(f'missing function {name}')
    return match.group()

class CurrentScriptTests(unittest.TestCase):
 def setUp(self):
    self.tmp=tempfile.TemporaryDirectory(prefix='btrfs-tests-'); self.addCleanup(self.tmp.cleanup)
    self.root=pathlib.Path(self.tmp.name); self.bin=self.root/'bin'; self.bin.mkdir(); self.log=self.root/'calls'
    self.env=os.environ.copy(); self.env.update(PATH=str(self.bin)+os.pathsep+os.environ.get('PATH',''),TEST_LOG=str(self.log))
    # Storage and host mutation commands can never reach real devices.
    for name in ('mount','umount','cryptsetup','btrfs','parted','chroot','swapon','swapoff','mkswap','mkfs.btrfs','mkfs.ext4','wipefs','losetup','blockdev','apt-get','dracut','update-grub'):
      self.stub(name,'#!/bin/sh\nprintf "%s\\n" "$(basename "$0") $*" >> "$TEST_LOG"\nexit 0\n')
 def stub(self,name,text):
    p=self.bin/name; p.write_text(text); p.chmod(0o755)
 def run_shell(self,script,*args):
    return subprocess.run(['/bin/sh','-c',script,'test-shell',*map(str,args)],cwd=self.root,env=self.env,text=True,capture_output=True,timeout=15)
 def test_shell_syntax(self):
    subprocess.run(['/bin/sh','-n',str(SCRIPT)],check=True)
 def test_help_and_bad_options_do_not_touch_storage(self):
    self.stub('id','#!/bin/sh\n[ "$1" = -u ] && echo 0\n')
    for args in [('--help',),('--not-a-real-option',),()]:
      with self.subTest(args=args):
       r=subprocess.run(['/bin/sh',str(SCRIPT),*args],env=self.env,cwd=self.root,text=True,capture_output=True,timeout=10)
       self.assertEqual(r.returncode,2 if args==('--not-a-real-option',) else 0,r.stderr)
       self.assertFalse(self.log.exists(),'storage command was invoked')
 def prepare_target(self, present, mount_status=0, unmount_status=0):
    cdrom=self.root/'cdrom'
    if present: cdrom.mkdir()
    self.stub('mountpoint',f'#!/bin/sh\n[ "$1" = -q ] && [ "$2" = "$TEST_CDROM" ] || exit 99\nexit {mount_status}\n')
    self.stub('umount',f'#!/bin/sh\nprintf "%s\\n" "$1" >> "$TEST_LOG"\nif [ "$1" = "$TEST_CDROM" ]; then exit {unmount_status}; fi\n')
    self.env['TEST_CDROM']=str(cdrom)
    mp=self.root/'work'
    r=self.run_shell('set -e; efi=true; mp=$1\n'+function('preparation').replace('/target/cdrom',str(cdrom))+'\npreparation',mp)
    return r, self.log.read_text().splitlines(), mp.is_dir()

 def test_preparation_skips_absent_or_unmounted_cdrom(self):
    for present in (False,True):
      with self.subTest(present=present):
        self.log.unlink(missing_ok=True)
        r,calls,created=self.prepare_target(present,32 if present else 99)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(calls,['/target/boot/efi','/target/boot','/target'])
        self.assertTrue(created)
        (self.root/'work').rmdir()

 def test_preparation_unmounts_cdrom_before_target(self):
    r,calls,created=self.prepare_target(True)
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    self.assertEqual(calls,['/target/boot/efi','/target/boot',str(self.root/'cdrom'),'/target'])
    self.assertTrue(created)

 def test_preparation_stops_if_cdrom_unmount_fails(self):
    r,calls,created=self.prepare_target(True,unmount_status=16)
    self.assertEqual(r.returncode,16)
    self.assertEqual(calls,['/target/boot/efi','/target/boot',str(self.root/'cdrom')])
    self.assertFalse(created)

 def test_preparation_stops_if_mountpoint_check_errors(self):
    r,calls,created=self.prepare_target(True,mount_status=1)
    self.assertEqual(r.returncode,1)
    self.assertIn('Could not check mount point',r.stderr)
    self.assertEqual(calls,['/target/boot/efi','/target/boot'])
    self.assertFalse(created)

 def test_subvolume_creation_preserves_contents_and_excludes_home(self):
    fs=self.root/'filesystem'; fs.mkdir()
    for p in ['home','var/cache','var/log','var/tmp']: (fs/p).mkdir(parents=True,exist_ok=True)
    for p in ['home/.hidden','var/cache/cache','var/log/log','var/tmp/temp']:(fs/p).write_text(p)
    # Simulate Btrfs snapshots with copies, scoped strictly to this fixture.
    self.stub('btrfs', '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
if args[:2]==['subvolume','snapshot']:
 dst=pathlib.Path(args[3]); dst.mkdir()
 for p in pathlib.Path('.').iterdir():
  if p == dst: continue
  if p.is_dir(): shutil.copytree(p,dst/p.name,symlinks=True)
  else: shutil.copy2(p,dst/p.name,follow_symlinks=False)
elif args[:2]==['subvolume','create']: pathlib.Path(args[2]).mkdir()
else: raise SystemExit(97)
''')
    r=self.run_shell('mp=$1\n'+function('create_subvols')+'\ncreate_subvols fake',fs)
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    for p,expect in [('@home/.hidden','home/.hidden'),('@var_cache/cache','var/cache/cache'),('@var_log/log','var/log/log'),('@var_tmp/temp','var/tmp/temp')]: self.assertEqual((fs/p).read_text(),expect)
    self.assertFalse((fs/'@/home/.hidden').exists()); self.assertFalse((fs/'@/var/log/log').exists())
    self.assertEqual((fs/'@var_tmp').stat().st_mode & 0o7777,0o1777)
    self.assertEqual({p.name for p in fs.iterdir()},{'@','@home','@var_cache','@var_log','@var_tmp'})
 def inner(self,only_subvols,fstab):
    etc=self.root/'etc'; (etc/'dracut.conf.d').mkdir(parents=True,exist_ok=True); (etc/'fstab').write_text(fstab)
    self.stub('blkid','#!/bin/sh\nprintf "UUID=test-root-uuid\\n"\n')
    match=re.search(r'^if \[ "\$1" = "//inner" \].*?^fi\n\nshow_help\(\)',SOURCE,re.M|re.S)
    self.assertIsNotNone(match)
    text=match.group().rsplit('\n\nshow_help()',1)[0].replace('/etc/',str(etc)+'/')
    r=self.run_shell(text,'//inner',only_subvols,'/dev/fake-root')
    return r,etc
 def test_unencrypted_fstab_and_dracut(self):
    r,etc=self.inner('yes','UUID=old / btrfs defaults 0 1\nUUID=boot /boot ext4 defaults 0 2\n')
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    f=(etc/'fstab').read_text(); self.assertIn('UUID=test-root-uuid / btrfs defaults,subvol=@ 0 1',f)
    for sub in ['@home','@var_cache','@var_log','@var_tmp']: self.assertIn('subvol='+sub,f)
    self.assertIn('UUID=boot /boot ext4 defaults 0 2',f)
    self.assertFalse((etc/'crypttab').exists())
    d=(etc/'dracut.conf.d/90-btrfs-encrypt-root.conf').read_text(); self.assertIn(' btrfs ',d); self.assertNotIn(' crypt ',d)
    self.assertIn('dracut --regenerate-all --force',self.log.read_text()); self.assertIn('update-grub',self.log.read_text())
 @unittest.expectedFailure
 def test_nonmatching_root_fstab_should_be_rejected(self):
    # Desired guard: do not report success when sed did not rewrite root.
    r,etc=self.inner('yes','UUID=old / btrfs defaults,compress=zstd 0 1\n')
    self.assertNotEqual(r.returncode,0,'Conversion should stop when the root entry does not match')
 def test_encrypted_fstab_crypttab_and_dracut(self):
    r,etc=self.inner('no','UUID=old / btrfs defaults 0 1\n')
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    f=(etc/'fstab').read_text(); self.assertIn('/dev/mapper/root / btrfs defaults,subvol=@ 0 1',f)
    self.assertEqual((etc/'crypttab').read_text(),'root UUID=test-root-uuid none luks,discard\n')
    self.assertIn(' crypt ',(etc/'dracut.conf.d/90-btrfs-encrypt-root.conf').read_text())
    self.assertIn('apt-get install -y systemd-cryptsetup',self.log.read_text())
 def test_enlarge_uses_reported_disk_and_partition(self):
    self.stub('lsblk','#!/bin/sh\ncase "$*" in *pkname*) echo nvme0n1;; *partn*) echo 12;; *) exit 2;; esac\n')
    r=self.run_shell('mp=$1; keyslot_size=32m; enlarge=yes\n'+function('encrypt_and_enlarge')+'\nencrypt_and_enlarge nvme0n1p12',self.root)
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    self.assertIn('parted --script /dev/nvme0n1 resizepart 12 100%',self.log.read_text())
 def test_no_enlarge_does_not_resize_partition_table(self):
    self.stub('lsblk','#!/bin/sh\ncase "$*" in *pkname*) echo nvme0n1;; *partn*) echo 3;; *) exit 2;; esac\n')
    r=self.run_shell('mp=$1; keyslot_size=32m; enlarge=no\n'+function('encrypt_and_enlarge')+'\nencrypt_and_enlarge nvme0n1p3',self.root)
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    self.assertNotIn('parted ',self.log.read_text())

if __name__=='__main__': unittest.main()
