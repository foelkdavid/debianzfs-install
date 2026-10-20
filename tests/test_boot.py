#!/usr/bin/env python3
"""Host-safe boot branding checks; no mounts, devices, or host service changes."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

try:
    from PIL import Image
except ImportError:
    Image = None

REPO = Path(__file__).resolve().parents[1]


class BootTests(unittest.TestCase):
    def test_packages_cached_for_clean_and_live_systems(self):
        for kind in ["base", "live"]:
            packages = subprocess.check_output(["bash", str(REPO / "image/package-manifest.sh"), kind],
                                               text=True).splitlines()
            self.assertTrue({"plymouth", "plymouth-themes"}.issubset(packages))

    def test_theme_selected_in_target_and_before_final_initramfs(self):
        for desktop in ["true", "false"]:
            with self.subTest(desktop=desktop), tempfile.TemporaryDirectory() as temporary:
                code = '''source "$REPO/install.sh"
TARGET=$TEST_ROOT
chroot_run() { printf 'TARGET-COMMAND:%s\\n' "$*"; }
configure_plymouth
INSTALL_CONFIRMED=true
DEBIAN_DESKTOP=$DESKTOP
run_stage() { printf 'STAGE:%s\\n' "$1"; }
run_installation
'''
                result = subprocess.run(["bash", "-c", code], check=True, capture_output=True,
                                        text=True, env=dict(os.environ, REPO=str(REPO),
                                                           TEST_ROOT=temporary, DESKTOP=desktop))
                self.assertIn("TARGET-COMMAND:plymouth-set-default-theme spinner", result.stdout)
                self.assertLess(result.stdout.index("STAGE:Configure Plymouth boot splash"),
                                result.stdout.index("STAGE:Rebuild final initramfs"))
                self.assertEqual((Path(temporary) / "etc/initramfs-tools/conf.d/plymouth").read_text(),
                                 "FRAMEBUFFER=y\n")

    def test_installed_kernel_gets_splash_without_changing_unlock_properties(self):
        for encryption in ["true", "false"]:
            with self.subTest(encryption=encryption), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "etc/default").mkdir(parents=True)
                (root / "etc/locale.gen").write_text("# en_US.UTF-8 UTF-8\n")
                code = '''source "$REPO/install.sh"
TARGET=$TEST_ROOT
DEBIAN_HOSTNAME=fixture
DEBIAN_TIMEZONE=Etc/UTC
DEBIAN_KEYMAP=us
DEBIAN_ENCRYPTION=$ENCRYPTION
chroot_run() { :; }
zfs() { printf 'ZFS:%s\\n' "$*"; }
configure_system
'''
                result = subprocess.run(["bash", "-c", code], check=True, capture_output=True,
                                        text=True, env=dict(os.environ, REPO=str(REPO),
                                                           TEST_ROOT=temporary, ENCRYPTION=encryption))
                self.assertIn("ZFS:set org.zfsbootmenu:commandline=quiet splash zroot/ROOT", result.stdout)
                self.assertEqual("ZFS:set org.zfsbootmenu:keysource=" in result.stdout,
                                 encryption == "true")

    @unittest.skipUnless(Image, "Pillow required for menu image generation")
    def test_native_menu_overrides_have_valid_backgrounds(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "bootloaders"
            subprocess.run([sys.executable, str(REPO / "image/prepare-boot-menu.py"),
                            str(REPO / "debianzfs-config/wallpapers/debianzfs_1.png"),
                            str(destination)], check=True)
            for bootloader, size in [("grub-pc", (800, 600)), ("syslinux_common", (640, 480))]:
                with Image.open(destination / bootloader / "splash.png") as image:
                    self.assertEqual(image.size, size)
                    self.assertEqual(image.mode, "RGB")
            self.assertIn('desktop-image: "../splash.png"',
                          (destination / "grub-pc/live-theme/theme.txt").read_text())
            self.assertIn("menu background splash.png",
                          (destination / "syslinux_common/stdmenu.cfg").read_text())
            self.assertIn("DebianZFS Live", (destination / "syslinux_common/menu.cfg").read_text())


if __name__ == "__main__":
    unittest.main()
