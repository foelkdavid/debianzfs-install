#!/usr/bin/env python3
"""Host-safe tests: source functions only; all device/service operations mocked."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="debianzfs-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def bash(self, code, input="", expected=0):
        env = dict(os.environ, TEST_ROOT=str(self.root), REPO=str(REPO), TERM="dumb")
        result = subprocess.run(["bash", "-c", 'source "$REPO/install.sh"\n' + code],
                                input=input, text=True, capture_output=True, env=env, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def ui(self):
        return '''
BOOT_MODE=UEFI
LOG_DIR="$TEST_ROOT/logs"
fgconsole() { return 1; }
ui_init
trap 'installer_exit "$?"' EXIT
trap 'exit "$?"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
'''

    def test_desktop_profiles_and_no(self):
        for profile in ("intel", "amd", "nvidia", "nouveau", "vm"):
            extra = "vmware\ny\n" if profile == "vm" else ""
            output = self.bash(self.ui() + '''
reset_configuration
get_desktop_inputs
printf 'RESULT:%s,%s,%s,%s\\n' "$DEBIAN_DESKTOP" "$GPU_DRIVER" "$VM_GUEST" "$VM_SOFTWARE_RENDERING"
''', f"y\n{profile}\n{extra}")
            self.assertIn(f"RESULT:true,{profile}," + ("vmware,true" if profile == "vm" else "none,false"), output)
        output = self.bash(self.ui() + '''
reset_configuration
get_desktop_inputs
chroot_run() { echo UNEXPECTED-CHROOT; return 99; }
deploy_desktop
printf 'RESULT:%s,%s\\n' "$DEBIAN_DESKTOP" "${GPU_DRIVER:-unset}"
''', "n\n")
        self.assertIn("RESULT:false,unset", output)
        self.assertNotIn("UNEXPECTED-CHROOT", output)

    def test_restart_clears_every_answer_and_secret(self):
        self.bash('''
for key in DEBIAN_DISK1 DEBIAN_DISK2 DEBIAN_MIRROR_MODE DEBIAN_SWAPSIZE DEBIAN_HOSTNAME DEBIAN_SUDOUSER DEBIAN_TIMEZONE DEBIAN_KEYMAP DEBIAN_DESKTOP GPU_DRIVER VM_GUEST VM_SOFTWARE_RENDERING DEBIAN_ENCRYPTION USER_PASSWORD ZFS_PASSPHRASE INSTALL_CONFIRMED; do
    printf -v "$key" stale
done
reset_configuration
for key in DEBIAN_DISK1 DEBIAN_DISK2 DEBIAN_MIRROR_MODE DEBIAN_SWAPSIZE DEBIAN_HOSTNAME DEBIAN_SUDOUSER DEBIAN_TIMEZONE DEBIAN_KEYMAP DEBIAN_DESKTOP GPU_DRIVER VM_GUEST VM_SOFTWARE_RENDERING DEBIAN_ENCRYPTION USER_PASSWORD ZFS_PASSPHRASE INSTALL_CONFIRMED; do
    [[ ! -v $key ]] || exit 12
done
[[ $DEBIAN_ENABLE_DHCP == true && $DEBIAN_MIRROR == https://deb.debian.org/debian ]]
''')

    def test_bios_preflight_stops_before_preparation(self):
        output = self.bash(self.ui() + '''
BOOT_MODE='Legacy BIOS'
root_privileges_check() { return 0; }
live_environment_check() { echo UNEXPECTED-LIVE-CHECK; return 0; }
install_host_requirements() { echo UNEXPECTED-PACKAGES; }
run_prechecks
run_stage preparation install_host_requirements
''', expected=1)
        self.assertIn('Boot mode: Legacy BIOS', output)
        self.assertIn('BIOS installation support is pending', output)
        self.assertNotIn('UNEXPECTED-PACKAGES', output)
        self.assertNotIn('UNEXPECTED-LIVE-CHECK', output)

    def test_https_first_failure_is_not_hidden_by_later_success(self):
        output = self.bash('''
curl() { echo "request:$*"; [[ $* != *first.example* ]]; }
if https_check https://first.example https://second.example; then exit 12; fi
''')
        self.assertIn('first.example', output)
        self.assertNotIn('second.example', output)

    def test_deployment_stage_order_and_clean_skip(self):
        for desktop in ('true', 'false'):
            output = self.bash(f'''
INSTALL_CONFIRMED=true DEBIAN_DESKTOP={desktop}
run_stage() {{ printf '%s\\n' "$1"; }}
run_installation
''')
            self.assertEqual('Deploy Hyprland desktop' in output, desktop == 'true')
            if desktop == 'true':
                self.assertLess(output.index('Create user account'), output.index('Deploy Hyprland desktop'))
                self.assertLess(output.index('Deploy Hyprland desktop'), output.index('Rebuild final initramfs'))
                self.assertLess(output.index('Rebuild final initramfs'), output.index('Synchronize mirrored ESPs'))

    def test_no_destructive_work_without_start(self):
        output = self.bash('''
wipe_disks() { echo ERASED; }
run_stage() { echo CALLED-STAGE; }
run_installation
''', expected=1)
        self.assertNotIn("ERASED", output)
        self.assertNotIn("CALLED-STAGE", output)
        self.bash('exec 3>&1; confirm_menu', "r\n", expected=10)
        self.bash('exec 3>&1; confirm_menu', "e\n", expected=20)
        self.bash('exec 3>&1; confirm_menu', "s\n")

    def test_full_configuration_encryption_optional(self):
        for encrypted in (True, False):
            output = self.bash(self.ui() + '''
reset_configuration
whole_disk() { return 0; }
validate_keymap() { return 0; }
apply_keymap() { :; }
get_inputs
print_preconf_header
printf 'RESULT:encryption=%s,pass=%s\\n' "$DEBIAN_ENCRYPTION" "${ZFS_PASSPHRASE:+set}"
''', "us\ny\n/dev/mock-a\nn\n\n0\n" + ("y" if encrypted else "n") +
                "\nfixture\nfixture\nEurope/Vienna\nn\naccount-secret\naccount-secret\n" +
                ("encryption-secret\nencryption-secret\n" if encrypted else ""))
            self.assertIn(f"RESULT:encryption={str(encrypted).lower()},pass={'set' if encrypted else ''}", output)
            self.assertNotIn("account-secret", output)
            self.assertNotIn("encryption-secret", output)

    def test_pool_encryption_and_mirror_arguments(self):
        for encrypted in ("true", "false"):
            for mirrored in ("true", "false"):
                output = self.bash(f'''
WORK_DIR="$TEST_ROOT"
DEBIAN_ENCRYPTION={encrypted}
DEBIAN_MIRROR_MODE={mirrored}
POOL_DEVICE_1=/dev/mock-a2
POOL_DEVICE_2=/dev/mock-b2
zpool() {{ printf 'zpool:%s\\n' "$*"; }}
blkid() {{ printf uuid; }}
create_zpool
[[ $POOL_OWNED == true ]]
''')
                self.assertEqual("encryption=aes-256-gcm" in output, encrypted == "true")
                self.assertEqual("zroot mirror" in output, mirrored == "true")

    def test_disk_validation_rejects_busy_small_duplicate_and_partition(self):
        fixture = '''
INSTALL_CONFIRMED=true BOOT_MODE=UEFI DEBIAN_MIRROR_MODE=false
DEBIAN_DISK1=/dev/mock-a DEBIAN_DISK2=/dev/mock-b
DEBIAN_SWAPSIZE=0 DEBIAN_DESKTOP=false TARGET="$TEST_ROOT/target"
whole_disk() { [[ ${BAD_TYPE:-false} != true ]]; }
lsblk() { case $1 in -dnro) echo 0 ;; *) echo '/dev/mock-a disk'; echo '/dev/mock-a1 part' ;; esac; }
blockdev() { echo "${BYTES:-40000000000}"; }
swapon() { echo "${SWAP:-}"; }
zpool() { :; }
findmnt() { [[ ${BUSY:-false} == true ]]; }
mountpoint() { return 1; }
find() { :; }
fuser() { [[ ${OPEN:-false} == true ]]; }
https_check() { :; }
'''
        self.bash(fixture + 'revalidate_disks')
        for bad in ("BUSY=true", "OPEN=true", "SWAP=/dev/mock-a1", "BYTES=4000", "BAD_TYPE=true",
                    "DEBIAN_MIRROR_MODE=true; DEBIAN_DISK2=/dev/mock-a", "INSTALL_CONFIRMED=false"):
            self.bash(fixture + bad + '\nrevalidate_disks', expected=1)

    def test_network_manager_and_dhcp(self):
        for desktop in ("true", "false"):
            for dhcp in ("true", "false"):
                directory = self.root / f"{desktop}-{dhcp}"
                self.bash(f'''
TARGET={directory}
mkdir -p "$TARGET/etc"
DEBIAN_DESKTOP={desktop} DEBIAN_ENABLE_DHCP={dhcp}
chroot_run() {{ printf '%s\\n' "$*" >> "$TARGET/commands"; }}
apt_install_target() {{ printf '%s\\n' "$*" >> "$TARGET/commands"; }}
configure_networking
''')
                commands = (directory / "commands").read_text()
                self.assertNotIn("systemctl enable", commands)
                if desktop == "true":
                    self.assertIn("mask systemd-networkd.service", commands)
                    config = directory / "etc/NetworkManager/system-connections/wired.nmconnection"
                    self.assertEqual(config.exists(), dhcp == "true")
                    if config.exists(): self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(os.readlink(directory / "etc/resolv.conf"), "/run/NetworkManager/resolv.conf")
                else:
                    self.assertIn("mask NetworkManager.service networking.service", commands)
                    self.assertEqual((directory / "etc/systemd/network/20-wired-ipv4-dhcp.network").exists(), dhcp == "true")

    def test_mirrored_esp_mounts_allow_a_missing_disk(self):
        self.bash('''
TARGET="$TEST_ROOT/target"
mkdir -p "$TARGET/etc"
DEBIAN_MIRROR_MODE=true
BOOT_DEVICE_1=/dev/mock-a1 BOOT_DEVICE_2=/dev/mock-b1
mkfs.vfat() { :; }
blkid() { echo fixture-uuid; }
chroot_run() { :; }
configure_efi_partitions
awk '$2=="/boot/efi" || $2=="/boot/efi2" { if ($4 !~ /nofail/) exit 1; count++ } END {if(count!=2) exit 1}' "$TARGET/etc/fstab"
''')

    def test_target_policy_restore_on_failure(self):
        target = self.root / "target"
        policy = target / "usr/sbin/policy-rc.d"
        policy.parent.mkdir(parents=True)
        policy.write_text("original policy\n")
        policy.chmod(0o711)
        self.bash(self.ui() + '''
TARGET="$TEST_ROOT/target"
install_target_policy
grep -q 'exit 101' "$TARGET/usr/sbin/policy-rc.d"
false
''', expected=1)
        self.assertEqual(policy.read_text(), "original policy\n")
        self.assertEqual(policy.stat().st_mode & 0o777, 0o711)

    def test_stage_preserves_state_and_full_log(self):
        self.bash(self.ui() + '''
one() { STATE=retained; for ((i=0;i<150;i++)); do echo "verbose-line-$i"; done; }
two() { [[ $STATE == retained ]]; echo next-stage; }
run_stage first one
run_stage second two
[[ $(cat "$STAGE_OUTPUT") == next-stage ]]
''')
        log = next((self.root / "logs").glob("*.log"))
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        text = log.read_text()
        self.assertIn("verbose-line-0", text)
        self.assertIn("verbose-line-149", text)
        self.assertIn("next-stage", text)

    def test_occupied_vt_falls_back_without_force_or_switch(self):
        output = self.bash('''
BOOT_MODE=UEFI LOG_DIR="$TEST_ROOT/logs"
fgconsole() { echo 1; }
openvt() { printf '%s\\n' "$*" > "$TEST_ROOT/vt-arguments"; return 1; }
ui_init
printf '%s\\n' "$VT_STATUS"
ui_restore
rm -rf -- "$WORK_DIR"
''')
        self.assertIn('no unused Linux VT', output)
        arguments = (self.root / 'vt-arguments').read_text().split(' -- ', 1)[0].split()
        self.assertNotIn('-f', arguments)
        self.assertNotIn('-s', arguments)
        self.assertNotIn('--force', arguments)
        self.assertNotIn('--switch', arguments)

    def test_nested_failure_and_pipeline_stop_later_stages(self):
        for command in ("false", "printf x | (exit 7)"):
            expected = 1 if command == "false" else 7
            out = self.bash(self.ui() + f'''
nested() {{ echo before-failure; {command}; echo HIDDEN-FAILURE; }}
run_stage broken nested
run_stage forbidden echo LATER-STAGE
''', expected=expected)
            self.assertIn("[failed] broken", out)
            self.assertNotIn("HIDDEN-FAILURE", out)
            self.assertNotIn("LATER-STAGE", out)

    def test_export_failure_cannot_be_reported_success(self):
        self.bash(self.ui() + '''
TARGET="$TEST_ROOT/target"
POOL_OWNED=true
mountpoint() { return 1; }
zpool() { echo export-failed; return 9; }
run_stage cleanup cleanup_target
echo FALSE-SUCCESS
''', expected=1)
        log = next((self.root / "logs").glob("*.log"))
        self.assertIn("export-failed", log.read_text())
        self.assertNotIn("FALSE-SUCCESS", log.read_text())

    def test_cleanup_retry_does_not_write_into_unmounted_target(self):
        self.bash('''
TARGET="$TEST_ROOT/target"
mkdir -p "$TARGET"
TARGET_MOUNTED=true
LOG_FILE="$TEST_ROOT/live.log"
echo retained-log > "$LOG_FILE"
mountpoint() { return 1; }
persist_target_log
[[ ! -e $TARGET/var ]]
''')

    def test_deployment_dry_runs_all_profiles(self):
        for profile in ("intel", "amd", "nvidia", "nouveau", "vm"):
            result = subprocess.run(["bash", str(REPO / "deploy/deploy.sh"), "--dry-run"],
                                    env=dict(os.environ, GPU_DRIVER=profile, VM_GUEST="qemu"),
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"graphics: {profile}", result.stdout)

    def test_pty_verbose_resize_transition_interrupt_and_no_vt(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
        env = dict(os.environ, TEST_ROOT=str(self.root), REPO=str(REPO), TERM="xterm")
        script = 'source "$REPO/install.sh"\n' + self.ui() + '''
verbose() { for ((i=0;i<100;i++)); do echo "output-$i"; done; printf '%0200d\\n' 0; sleep .8; }
run_stage first verbose
run_stage second sleep 20
'''
        proc = subprocess.Popen(["bash", "-c", script], stdin=slave, stdout=slave, stderr=slave,
                                env=env, start_new_session=True)
        self.addCleanup(lambda: proc.poll() is None and os.killpg(proc.pid, signal.SIGKILL))
        output = b""
        deadline = time.monotonic() + 15
        resized = False
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                output += os.read(master, 65536)
            if b"0" * 90 in output and not resized:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 65, 0, 0))
                os.killpg(proc.pid, signal.SIGWINCH)
                resized = True
            if b"[running] second" in output:
                os.killpg(proc.pid, signal.SIGINT)
                break
        self.assertTrue(resized, output.decode(errors="replace"))
        self.assertEqual(proc.wait(timeout=10), 130)
        while select.select([master], [], [], .2)[0]: output += os.read(master, 65536)
        text = output.decode(errors="replace")
        self.assertIn("no unused Linux VT", text)
        self.assertIn("[passed] first", text)
        self.assertIn("[running] second", text)
        self.assertIn("[failed] second", text)
        self.assertIn("\x1b[?25h", text)
        widths = {len(line) for line in text.replace('\r', '').splitlines() if re.fullmatch('0+', line)}
        self.assertIn(90, widths)
        self.assertIn(65, widths)
        log = next((self.root / "logs").glob("*.log"))
        self.assertIn("output-0", log.read_text())
        self.assertIn("output-99", log.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
