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


def frame_rows(frame):
    return [re.sub(r'\x1b\[[0-9;]*m', '', line)
            for line in re.split(r'\x1b\[\d+;1H\x1b\[2K', frame)[1:]]


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

    def test_bootstrap_cache_requires_matching_mirror(self):
        for mirror, cached in (("https://deb.debian.org/debian", True),
                               ("https://deb.debian.org/debian/", True),
                               ("https://ftp.de.debian.org/debian", False),
                               ("https://deb.debian.org/debian-other", False)):
            with self.subTest(mirror=mirror):
                output = self.bash('''
TARGET="$TEST_ROOT/target"
DEBIAN_ARCH=amd64
printf fixture > "$TEST_ROOT/bootstrap.tar"
debootstrap() { printf 'ARG:%s\\n' "$@"; }
''' + f'DEBIAN_MIRROR={mirror}\n' + '''
bootstrap_debian "$TEST_ROOT/bootstrap.tar"
''')
                self.assertEqual("ARG:--unpack-tarball=" in output, cached)
                self.assertIn("ARG:" + mirror, output)
        self.bash('''
DEBIAN_ARCH=amd64
DEBIAN_MIRROR=https://ftp.de.debian.org/debian
debootstrap() { return 2; }
bootstrap_debian "$TEST_ROOT/missing.tar"
echo MUST-NOT-RUN
''', expected=2)

    def test_bootstrap_failure_reports_detail_and_preserves_status(self):
        output = self.bash('''
TARGET="$TEST_ROOT/target"
DEBIAN_ARCH=amd64
mkdir -p "$TARGET/debootstrap"
printf 'fixture dpkg error\\n' > "$TARGET/debootstrap/debootstrap.log"
debootstrap() { return 2; }
bootstrap_debian "$TEST_ROOT/missing.tar"
echo MUST-NOT-RUN
''', expected=2)
        self.assertIn("fixture dpkg error", output)
        self.assertNotIn("MUST-NOT-RUN", output)

    def test_network_firmware_installed_for_clean_and_desktop(self):
        for desktop in ("false", "true"):
            with self.subTest(desktop=desktop):
                output = self.bash(f'DEBIAN_DESKTOP={desktop}\n' + '''
TARGET="$TEST_ROOT/target"
DEBIAN_ARCH=amd64
DEBIAN_ENCRYPTION=false
install_target_policy() { :; }
bootstrap_debian() { :; }
mount_chroot_filesystems() { :; }
prepare_target_dns() { :; }
mount_bundled_apt_cache() { :; }
chroot_run() { :; }
apt_install_target() { printf 'PACKAGE:%s\\n' "$@"; }
install_base_system
''')
                for package in ("firmware-iwlwifi", "firmware-realtek", "firmware-mediatek"):
                    self.assertIn("PACKAGE:" + package, output)
        packages = subprocess.check_output(
            ["bash", str(REPO / "image/package-manifest.sh"), "base"], text=True).splitlines()
        self.assertIn("firmware-iwlwifi", packages)
        self.assertIn("firmware-realtek", packages)
        self.assertIn("firmware-mediatek", packages)

    def test_target_sources_use_selected_mirror_and_keyring(self):
        for desktop in ("false", "true"):
            self.bash(f'DEBIAN_DESKTOP={desktop}\n' + '''
TARGET="$TEST_ROOT/target"
DEBIAN_ARCH=amd64 DEBIAN_ENCRYPTION=false
DEBIAN_MIRROR=http://debian.lagis.at/debian
install_target_policy() { :; }
bootstrap_debian() { :; }
mount_chroot_filesystems() { :; }
prepare_target_dns() { :; }
mount_bundled_apt_cache() { :; }
chroot_run() { :; }
apt_install_target() { :; }
install_base_system
''')
            lines = (self.root / "target/etc/apt/sources.list").read_text().splitlines()
            self.assertEqual(len(lines), 4)
            for line, uri, suite in zip(lines, (
                    "http://debian.lagis.at/debian", "http://debian.lagis.at/debian",
                    "https://security.debian.org/debian-security", "https://deb.debian.org/debian"),
                    ("trixie", "trixie-updates", "trixie-security", "trixie-backports")):
                self.assertEqual(line, f"deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] {uri} {suite} main contrib non-free non-free-firmware")
            self.assertFalse((self.root / "target/etc/apt/sources.list.d/debian-deploy.sources").exists())

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

    def test_desktop_deployment_gives_user_ownership_of_local_parent(self):
        target = self.root / "target"
        target.mkdir()
        output = self.bash(f'''
TARGET={target}
REPO_DIR="$REPO"
DEBIAN_DESKTOP=true DEBIAN_SUDOUSER=david
GPU_DRIVER=intel VM_GUEST=none VM_SOFTWARE_RENDERING=false
DEBIANZFS_CONFIG_SOURCE="$REPO/debianzfs-config"
chroot_run() {{ printf 'chroot:%s\\n' "$*" >> "$TEST_ROOT/commands"; }}
deploy_desktop
''')
        commands = (self.root / "commands").read_text().splitlines()
        self.assertIn("chroot:chown david:david /home/david/.local", commands)
        self.assertLess(commands.index("chroot:chown david:david /home/david/.local"),
                        next(index for index, line in enumerate(commands)
                             if line.startswith("chroot:env GPU_DRIVER=")))
        self.assertTrue((target / "home/david/.local/debianzfs-config/deploy.sh").is_file())

    def test_configuration_and_restart_precede_all_preparation(self):
        fixture = self.ui() + '''
root_privileges_check() { :; }
live_environment_check() { :; }
secure_boot_check() { :; }
get_inputs() {
    [[ ! -v USER_PASSWORD && ! -v GPU_DRIVER && ! -v INSTALL_CONFIRMED ]] || exit 12
    echo ANSWERS
    DEBIAN_DESKTOP=false DEBIAN_SUDOUSER=fixture
    USER_PASSWORD=private GPU_DRIVER=vm
}
source_connectivity_check() { echo NETWORK; }
install_host_requirements() { echo PACKAGES; }
validate_live_tools() { echo ZFS-VALIDATION; }
run_installation() { [[ $INSTALL_CONFIRMED == true ]]; echo INSTALLATION; }
cleanup_target() { echo CLEANUP; }
run_stage() { printf 'STAGE:%s\\n' "$1"; shift; "$@"; }
run_guided_installation
'''
        out = self.bash(fixture, 'r\ns\n')
        self.assertEqual(out.count('ANSWERS'), 2)
        markers = ('NETWORK', 'PACKAGES', 'ZFS-VALIDATION', 'INSTALLATION')
        for marker in markers:
            self.assertGreater(out.index(marker), out.rindex('ANSWERS'))
        self.assertEqual([out.index(x) for x in markers], sorted(out.index(x) for x in markers))
        out = self.bash(fixture, 'e\n')
        for marker in markers: self.assertNotIn(marker, out)
        self.assertEqual(out.count('[passed] Root privileges'), 1)
        self.assertNotIn('[pending]', out)
        self.assertNotIn('\x1b', out)

    def test_secure_boot_check_before_configuration_or_packages(self):
        directory = self.root / 'efi'
        directory.mkdir()
        variable = directory / 'SecureBoot-fixture'
        for enabled in (0, 1):
            variable.write_bytes(b'\x07\x00\x00\x00' + bytes([enabled]))
            self.bash('secure_boot_enabled "$TEST_ROOT/efi"', expected=0 if enabled else 1)
        out = self.bash(self.ui() + '''
root_privileges_check() { :; }
live_environment_check() { :; }
secure_boot_enabled() { return 0; }
get_inputs() { echo UNEXPECTED-QUESTIONS; }
install_host_requirements() { echo UNEXPECTED-PACKAGES; }
run_guided_installation
''', expected=1)
        self.assertIn('Disable Secure Boot in UEFI firmware', out)
        self.assertIn('No packages or disks have been changed', out)
        self.assertNotIn('UNEXPECTED-', out)

    def test_rejected_zfs_module_does_not_trigger_rebuild(self):
        out = self.bash(self.ui() + '''
HOST_APT_SOURCE="$TEST_ROOT/sources.list"
apt-get() { printf 'APT:%s\\n' "$*"; }
modprobe() { echo 'modprobe: Key was rejected by service' >&2; return 1; }
run_stage preparation install_host_requirements
echo UNEXPECTED-SUCCESS
''', expected=1)
        self.assertIn('Disable Secure Boot', out)
        self.assertNotIn('UNEXPECTED-SUCCESS', out)
        log = next((self.root / 'logs').glob('*.log')).read_text()
        self.assertNotIn('linux-headers-', log)
        self.assertNotIn('zfs-dkms', log)

    def test_keymap_validation_only_parses_and_missing_tools_are_deferred(self):
        out = self.bash('''
loadkeys() { echo "LOADKEYS:$*" >> "$TEST_ROOT/keymap-commands"; return 0; }
validate_keymap de-latin1
! validate_keymap 'invalid;key'
cat "$TEST_ROOT/keymap-commands"
''')
        self.assertEqual(out.strip(), 'LOADKEYS:-b de-latin1')
        self.bash('''
command() { [[ $* != '-v setupcon' ]]; }
loadkeys() { return 127; }
DEBIAN_KEYMAP=us
apply_keymap
''')

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
wipefs() {{ printf 'wipefs:%s\\n' "$*"; }}
resolve_pool_device() {{ printf '%s\\n' "$1"; }}
create_zpool
[[ $POOL_OWNED == true ]]
''')
                self.assertEqual("encryption=aes-256-gcm" in output, encrypted == "true")
                self.assertEqual("zroot mirror" in output, mirrored == "true")
                self.assertIn("wipefs:--all /dev/mock-a2", output)
                self.assertEqual("wipefs:--all /dev/mock-b2" in output, mirrored == "true")
                self.assertEqual(output.count("wipefs:"), 2 if mirrored == "true" else 1)
                self.assertLess(output.rindex("wipefs:"), output.index("zpool:"))

    def test_nvme_partition_names_with_and_without_swap(self):
        for swap, partition in (("0", "2"), ("2", "3")):
            output = self.bash(f'''
DEBIAN_DISK1=/dev/nvme0n1 DEBIAN_DISK2=/dev/nvme1n1
DEBIAN_SWAPSIZE={swap}
set_zfs_vars
printf 'DEVICES:%s,%s,%s,%s\\n' "$BOOT_DEVICE_1" "$POOL_DEVICE_1" "$BOOT_DEVICE_2" "$POOL_DEVICE_2"
''')
            self.assertIn(f"DEVICES:/dev/nvme0n1p1,/dev/nvme0n1p{partition},/dev/nvme1n1p1,/dev/nvme1n1p{partition}", output)

    def test_fresh_partition_waits_for_block_node_and_handles_missing_alias(self):
        output = self.bash('''
WORK_DIR="$TEST_ROOT"
DEBIAN_ENCRYPTION=false DEBIAN_MIRROR_MODE=false
POOL_DEVICE_1="$TEST_ROOT/nvme0n1p2"
touch "$POOL_DEVICE_1"
pool_partition_ready() {
    local n=0
    [[ ! -f $TEST_ROOT/ready-count ]] || read -r n < "$TEST_ROOT/ready-count"
    printf '%s\\n' "$((n+1))" > "$TEST_ROOT/ready-count"
    ((n >= 2))
}
blkid() {
    [[ $* == "--probe --match-tag PART_ENTRY_UUID --output value $POOL_DEVICE_1" ]] || return 99
    local n=0
    [[ ! -f $TEST_ROOT/probe-count ]] || read -r n < "$TEST_ROOT/probe-count"
    printf '%s\\n' "$((n+1))" > "$TEST_ROOT/probe-count"
    echo 12345678-1234-1234-1234-123456789abc
}
sleep() { :; }
wipefs() { [[ $* == "--all $POOL_DEVICE_1" ]]; }
zpool() { printf 'ZPOOL:%s\\n' "$*"; [[ ${!#} == "$POOL_DEVICE_1" ]]; }
create_zpool
[[ $POOL_OWNED == true ]]
[[ $(cat "$TEST_ROOT/ready-count") == 3 && $(cat "$TEST_ROOT/probe-count") == 1 ]]
''')
        self.assertIn("using verified partition", output)
        self.assertIn("ZPOOL:create", output)
        self.assertNotIn("zroot /dev/disk/by-partuuid/", output)

    def test_failed_or_invalid_uuid_probe_uses_partition_and_clears_signatures(self):
        for result in ("return 2", "printf ''", "echo not-a-uuid", "echo 12345678-1234-1234-1234-123456789abc; return 8"):
            with self.subTest(result=result):
                output = self.bash('''
DEBIAN_ENCRYPTION=false DEBIAN_MIRROR_MODE=false
POOL_DEVICE_1=/dev/nvme0n1p2
pool_partition_ready() { return 0; }
sleep() { echo UNEXPECTED-WAIT; }
wipefs() { [[ $* == "--all $POOL_DEVICE_1" ]] || return 99; echo CLEARED; }
zpool() { [[ ${!#} == "$POOL_DEVICE_1" ]] || return 99; echo CREATED; }
blkid() { ''' + result + '''; }
create_zpool
[[ $POOL_OWNED == true ]]
''')
                self.assertNotIn("UNEXPECTED-WAIT", output)
                self.assertIn("PARTUUID probe unavailable", output)
                self.assertLess(output.index("CLEARED"), output.index("CREATED"))
                self.assertNotIn("zroot /dev/disk/by-partuuid/", output)

    def test_missing_block_partition_never_calls_wipefs_or_zpool(self):
        output = self.bash('''
DEBIAN_ENCRYPTION=false DEBIAN_MIRROR_MODE=false
POOL_DEVICE_1="$TEST_ROOT/missing-nvme0n1p2"
sleep() { :; }
blkid() { echo UNEXPECTED-PROBE; }
wipefs() { echo UNEXPECTED-WIPE; }
zpool() { echo UNEXPECTED-POOL-CREATE; }
create_zpool
''', expected=1)
        self.assertNotIn("UNEXPECTED", output)
        self.assertIn("No block partition appeared", output)

    def test_mirror_requires_both_resolved_and_distinct_partitions(self):
        fixture = '''
DEBIAN_ENCRYPTION=false DEBIAN_MIRROR_MODE=true
POOL_DEVICE_1="$TEST_ROOT/a" POOL_DEVICE_2="$TEST_ROOT/b"
touch "$POOL_DEVICE_1" "$POOL_DEVICE_2"
zpool() { echo UNEXPECTED-POOL-CREATE; }
wipefs() { echo UNEXPECTED-WIPE; }
'''
        for code in (
            'unset POOL_DEVICE_2; resolve_pool_device() { echo "$1"; }',
            'resolve_pool_device() { [[ $1 == "$POOL_DEVICE_1" ]] || return 2; echo "$1"; }',
            'resolve_pool_device() { echo "$POOL_DEVICE_1"; }',
            'rm "$POOL_DEVICE_2"; ln -s "$POOL_DEVICE_1" "$POOL_DEVICE_2"; resolve_pool_device() { echo "$1"; }',
        ):
            with self.subTest(code=code):
                output = self.bash(fixture + code + '\ncreate_zpool', expected=1)
                self.assertNotIn("UNEXPECTED", output)

    def test_signature_cleanup_failure_stops_before_zpool(self):
        for mirrored, failed_device in (("false", "/dev/mock-a2"),
                                        ("true", "/dev/mock-b2")):
            output = self.bash(f'''
DEBIAN_ENCRYPTION=false DEBIAN_MIRROR_MODE={mirrored} POOL_OWNED=false
POOL_DEVICE_1=/dev/mock-a2 POOL_DEVICE_2=/dev/mock-b2
resolve_pool_device() {{ echo "$1"; }}
wipefs() {{ echo "WIPE:$*"; [[ $2 != {failed_device} ]] || return 19; }}
zpool() {{ echo UNEXPECTED-POOL-CREATE; }}
if create_zpool; then exit 99; else status=$?; fi
[[ $status == 19 && $POOL_OWNED == false ]]
''')
            self.assertNotIn("UNEXPECTED-POOL-CREATE", output)

    def test_zpool_failure_preserves_status_and_does_not_claim_ownership(self):
        self.bash('''
DEBIAN_ENCRYPTION=false DEBIAN_MIRROR_MODE=false POOL_OWNED=false
POOL_DEVICE_1=/dev/nvme0n1p2
resolve_pool_device() { echo "$1"; }
wipefs() { :; }
zpool() { return 17; }
if create_zpool; then exit 99; else status=$?; fi
[[ $status == 17 && $POOL_OWNED == false ]]
''')

    def test_partition_reread_and_udev_errors_stop_partitioning(self):
        fixture = '''
DEBIAN_DISK1=/dev/nvme0n1 DEBIAN_DISK2=/dev/nvme1n1
DEBIAN_MIRROR_MODE=true DEBIAN_SWAPSIZE=0
sgdisk() { echo "PARTITION:$*"; }
'''
        output = self.bash(fixture + '''
partprobe() { return 17; }
udevadm() { echo UNEXPECTED-UDEV; }
partition_disks
''', expected=1)
        self.assertIn("Could not reread the partition table on /dev/nvme0n1", output)
        self.assertNotIn("UNEXPECTED-UDEV", output)
        self.assertNotIn("/dev/nvme1n1", output)
        output = self.bash(fixture + '''
partprobe() { :; }
udevadm() { [[ $* == 'settle --timeout=10' ]]; return 17; }
partition_disks
''', expected=1)
        self.assertIn("Partition events did not settle for /dev/nvme0n1", output)
        self.assertNotIn("/dev/nvme1n1", output)

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
                self.assertIn("network-manager wpasupplicant", commands)
                self.assertIn("mask systemd-networkd.service", commands)
                self.assertIn("systemd-resolved.service networking.service", commands)
                self.assertIn("systemd-resolved.service networking.service", commands)
                self.assertIn("enable NetworkManager.service", commands)
                config = directory / "etc/NetworkManager/system-connections/wired.nmconnection"
                self.assertEqual(config.exists(), dhcp == "true")
                if config.exists(): self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                self.assertEqual(os.readlink(directory / "etc/resolv.conf"), "/run/NetworkManager/resolv.conf")

    def test_iso_cache_mounting_and_standard_media_fallback(self):
        target = self.root / "target"
        cache = self.root / "cache"
        (target / "etc/apt/sources.list.d").mkdir(parents=True)
        cache.mkdir()
        (cache / "Packages").write_text("Package: fixture\n")
        (cache / "debootstrap-trixie-amd64.tar").write_text("fixture\n")
        self.bash(f'''
TARGET={target}
DEBIANZFS_IMAGE_CACHE={cache}
mount() {{ printf '%s\\n' "$*" >> "$TEST_ROOT/mounts"; }}
mount_bundled_apt_cache
[[ $IMAGE_CACHE_MOUNTED == true ]]
''')
        self.assertEqual((self.root / "mounts").read_text().count("--bind"), 1)
        self.assertIn("file:/mnt/debianzfs-cache ./", (target / "etc/apt/sources.list.d/debianzfs-image-cache.list").read_text())
        self.assertIn("Pin-Priority: 1001", (target / "etc/apt/preferences.d/debianzfs-image-cache").read_text())
        self.bash(f'''
TARGET={target}
IMAGE_CACHE_MOUNTED=true
remove_bundled_apt_cache_config
''')
        self.assertFalse((target / "etc/apt/sources.list.d/debianzfs-image-cache.list").exists())
        self.assertFalse((target / "etc/apt/preferences.d/debianzfs-image-cache").exists())

    def test_image_package_manifest_tracks_gpu_profiles(self):
        def manifest(*args):
            return set(subprocess.check_output(
                ["bash", str(REPO / "image/package-manifest.sh"), *args], text=True
            ).splitlines())

        for profile, array in (("intel", "INTEL_PACKAGES"), ("amd", "AMD_PACKAGES"),
                               ("nvidia", "NVIDIA_PACKAGES"), ("nouveau", "NOUVEAU_PACKAGES"),
                               ("vm", "VM_PACKAGES")):
            expected = subprocess.check_output(
                ["bash", "-c", f'source "$1/deploy/vars.sh"; printf "%s\\n" "${{{array}[@]}}"', "test", str(REPO)],
                text=True,
            ).splitlines()
            selected = manifest("cache", profile)
            for package in expected:
                self.assertIn(package, selected)
        self.assertNotIn("linux-image-amd64", manifest("cache", "nvidia"))
        self.assertIn("hyprland/trixie-backports", manifest("live"))
        self.assertIn("libxkbcommon-x11-0/trixie-backports", manifest("live"))
        self.assertNotIn("libxkbcommon0", manifest("base"))

    def test_image_installer_launcher_is_live_only_and_keeps_terminal_open(self):
        shortcut = REPO / "image/live-assets/debianzfs-install.desktop"
        icon = REPO / "image/live-assets/debianzfs_install.png"
        build = (REPO / "image/build.sh").read_text()
        desktop = shortcut.read_text()
        self.assertTrue(icon.is_file())
        self.assertIn("Exec=alacritty --hold -e debianzfs-install", desktop)
        self.assertIn("Icon=debianzfs_install", desktop)
        self.assertIn('"$IMAGE_ROOT/live-assets/debianzfs_install.png"', build)
        self.assertIn('"$IMAGE_ROOT/live-assets/debianzfs-install.desktop"', build)
        self.assertIn("/home/liveuser/.local/share/applications/debianzfs-install.desktop", build)
        self.assertNotIn("/home/liveuser/Desktop", build)
        self.assertFalse((REPO / "debianzfs-config/scripts/installer-shortcut").exists())

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
        output = self.bash(self.ui() + '''
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
        self.assertNotIn('verbose-line-0\n', output)
        self.assertIn('verbose-line-149', output)
        self.assertIn('next-stage', output)
        self.assertLessEqual(output.count('verbose-line-'), 5)

    def test_logging_never_allocates_or_switches_virtual_terminals(self):
        output = self.bash('''
openvt() { echo UNEXPECTED-VT; return 1; }
fgconsole() { echo UNEXPECTED-VT; return 1; }
''' + self.ui() + '''
reset_configuration
print_preconf_header
run_stage fixture echo logged-output
''')
        self.assertNotIn('UNEXPECTED-VT', output)
        self.assertNotIn('Ctrl+Alt', output)
        self.assertNotIn('VT', output)

    def test_small_stage_frame_removes_controls_and_never_scrolls(self):
        out = self.bash(self.ui() + r'''
terminal_size() { UI_ROWS=10 UI_COLS=40; }
COMPLETED=()
for ((i=0;i<40;i++)); do COMPLETED+=("Earlier step $i"); done
CURRENT_STAGE='Install packages with a long description'
printf '\033]0;untrusted title\007\033[31mprogress\ttext\r\033[0m\n' > "$STAGE_OUTPUT"
LC_ALL=C render_stage
''')
        frame = '\n'.join(frame_rows(re.search(r'\x1b\[H(.*?)\x1b\[J', out, re.S).group(1)))
        self.assertIn('[Install packages', frame)
        self.assertNotIn('Earlier step', frame)
        self.assertIn('progress    text', frame)
        self.assertNotIn('untrusted title', frame)
        self.assertEqual(frame.splitlines()[0], '─' * 39)
        self.assertNotRegex(frame, r'[\x00-\x09\x0b-\x1f\x7f]')
        self.assertLessEqual(len(frame.splitlines()), 9)
        self.assertLessEqual(max(map(len, frame.splitlines())), 39)

    def test_final_summary_and_start_prompt_fit_standard_console(self):
        out = self.bash(self.ui() + '''
reset_configuration
DEBIAN_DISK1=/dev/nvme0n1 DEBIAN_DISK2=/dev/nvme1n1
DEBIAN_HOSTNAME=debian DEBIAN_SUDOUSER=fixture
DEBIAN_KEYMAP=de-latin1 DEBIAN_TIMEZONE=Europe/Vienna
DEBIAN_DESKTOP=true GPU_DRIVER=vm VM_GUEST=qemu VM_SOFTWARE_RENDERING=true
USER_PASSWORD=private ZFS_PASSPHRASE=private
print_preconf_header
confirm_menu
''', 's\n')
        summary = out.split('Live log retained:')[0]
        # read -p only emits its prompt with a terminal; account for it here.
        lines = summary.splitlines() + ['[s] Start installation  [r] Restart configuration  [e] Exit: ']
        self.assertLessEqual(sum(max(1, (len(line) + 79) // 80) for line in lines), 23)
        self.assertNotIn('private', summary)

    def test_renderer_finishes_inflight_frame_before_stage_returns(self):
        out = self.bash(self.ui() + '''
UI_TTY=true
render_stage() {
    [[ $BASHPID != $$ ]] || return 0
    { touch "$WORK_DIR/frame-started"; sleep .2; echo FINISHED-FRAME; } | cat >&3
}
wait_for_frame() { while [[ ! -e $WORK_DIR/frame-started ]]; do sleep .01; done; }
run_stage first wait_for_frame
echo STAGE-RETURNED
sleep .3
''')
        self.assertIn('FINISHED-FRAME', out)
        self.assertLess(out.rindex('FINISHED-FRAME'), out.index('STAGE-RETURNED'))

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

    def test_pty_void_configuration_palette_and_no_color(self):
        for colored in (True, False):
            with self.subTest(colored=colored):
                master, slave = pty.openpty()
                self.addCleanup(os.close, master)
                self.addCleanup(os.close, slave)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                env = dict(os.environ, TEST_ROOT=str(self.root), REPO=str(REPO), TERM="linux")
                env.pop("NO_COLOR", None)
                if not colored: env["NO_COLOR"] = "1"
                code = 'source "$REPO/install.sh"\n' + self.ui() + '''
reset_configuration
DEBIAN_KEYMAP=de-latin1
DEBIAN_SUDOUSER=fixture
USER_PASSWORD=hidden-password
print_preconf_header
run_stage preparation info '[Install live packages]'
'''
                proc = subprocess.Popen(["bash", "-c", code], stdin=slave, stdout=slave, stderr=slave,
                                        env=env, start_new_session=True)
                self.addCleanup(lambda p=proc: p.poll() is None and os.killpg(p.pid, signal.SIGKILL))
                output = b""
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if select.select([master], [], [], .05)[0]: output += os.read(master, 65536)
                    elif proc.poll() is not None: break
                self.assertEqual(proc.wait(timeout=2), 0)
                text = output.decode()
                self.assertIn('Console keymap -> [ ', text)
                self.assertNotIn('hidden-password', text)
                if colored:
                    self.assertIn('\x1b[0;32mDebian-ZFS-Installer', text)
                    self.assertIn('\x1b[0;33m[Configuration]', text)
                    self.assertIn('[ \x1b[0;33mde-latin1\x1b[0m ]', text)
                    self.assertIn('\x1b[0;35m[preparation]', text)
                else:
                    self.assertNotRegex(text, r'\x1b\[[0-9;]*m')
                for log in (self.root / 'logs').glob('*.log'):
                    self.assertNotIn('\x1b', log.read_text())
                    self.assertNotIn('hidden-password', log.read_text())

    def test_pty_colors_verbose_resize_transition_and_interrupt(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
        env = dict(os.environ, TEST_ROOT=str(self.root), REPO=str(REPO), TERM="xterm")
        env.pop('NO_COLOR', None)
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
            if b"0" * 89 in output and not resized:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 65, 0, 0))
                os.killpg(proc.pid, signal.SIGWINCH)
                resized = True
            if b"[second]" in output:
                os.killpg(proc.pid, signal.SIGINT)
                break
        self.assertTrue(resized, output.decode(errors="replace"))
        self.assertEqual(proc.wait(timeout=10), 130)
        while select.select([master], [], [], .2)[0]: output += os.read(master, 65536)
        text = output.decode(errors="replace")
        self.assertIn("[first]", text)
        self.assertIn("[second]", text)
        self.assertIn("✘ second", text)
        self.assertIn("\x1b[0;31m✘ second", text)
        self.assertIn("\x1b[0;32mDebian-ZFS-Installer", text)
        self.assertIn("\x1b[0;35m[second]", text)
        self.assertIn("\x1b[1;34mLog:", text)
        self.assertNotIn("[passed] first", text)
        self.assertNotIn("Ctrl+Alt", text)
        self.assertIn("\x1b[?25h", text)
        frames = [frame_rows(frame) for frame in re.findall(r'\x1b\[H(.*?)\x1b\[J', text, flags=re.S)]
        widths = {len(line) for rows in frames for line in rows if re.fullmatch('0+', line)}
        self.assertIn(89, widths)
        self.assertIn(64, widths)
        for lines in frames:
            limit = 64 if '0' * 64 in lines else 89
            height = 17 if limit == 64 else 23
            self.assertLessEqual(len(lines), height)
            self.assertLessEqual(max(map(len, lines), default=0), limit)
        log = next((self.root / "logs").glob("*.log"))
        self.assertIn("output-0", log.read_text())
        self.assertIn("output-99", log.read_text())
        self.assertNotIn("\x1b", log.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
