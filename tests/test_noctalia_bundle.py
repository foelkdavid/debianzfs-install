#!/usr/bin/env python3
"""Validate the bundled Noctalia settings and wallpaper integration."""
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
CONFIG = REPO / "debianzfs-config"
SETTINGS = CONFIG / "noctalia/settings.toml"
WALLPAPER = CONFIG / "wallpapers/debianzfs_1.png"
HELP_LAUNCHER = CONFIG / "scripts/help-shortcuts/desktop-files/debianzfs-help.desktop"
TICKET_LAUNCHER = CONFIG / "scripts/help-shortcuts/desktop-files/debianzfs-ticket.desktop"
HELP_ICON = CONFIG / "scripts/help-shortcuts/pngs/debianzfs-help.png"
TICKET_ICON = CONFIG / "scripts/help-shortcuts/pngs/debianzfs-ticket.png"


class NoctaliaBundleTests(unittest.TestCase):
    def test_settings_are_plugin_free_and_use_the_bundled_wallpaper(self):
        text = SETTINGS.read_text()
        settings = tomllib.loads(text)
        wallpaper = settings["wallpaper"]

        self.assertNotIn("plugin", text.lower())
        self.assertNotIn("secondary-screen", text)
        self.assertEqual(settings["theme"]["builtin"], "Gruvbox")
        self.assertEqual(wallpaper["directory"], "/opt/media/wall")
        self.assertEqual(wallpaper["default"]["path"],
                         "/opt/media/wall/debianzfs_1.png")
        self.assertEqual(wallpaper["last"]["path"],
                         "/opt/media/wall/debianzfs_1.png")
        self.assertTrue(WALLPAPER.is_file())
        self.assertGreater(WALLPAPER.stat().st_size, 0)
        self.assertTrue(HELP_LAUNCHER.is_file())
        launcher = HELP_LAUNCHER.read_text()
        self.assertIn("Name=DebianZFS Help", launcher)
        self.assertIn("firefox-esr --new-window https://docs.debian.foelk.com", launcher)
        self.assertIn("Icon=debianzfs-help", launcher)
        self.assertTrue(HELP_ICON.is_file())
        self.assertGreater(HELP_ICON.stat().st_size, 0)
        self.assertTrue(TICKET_ICON.is_file())
        self.assertGreater(TICKET_ICON.stat().st_size, 0)
        ticket = TICKET_LAUNCHER.read_text()
        self.assertIn("Name=DebianZFS Ticket", ticket)
        self.assertIn("https://github.com/foelkdavid/debian-docs/issues/new?labels=Liveticket",
                      ticket)
        self.assertIn("Icon=debianzfs-ticket", ticket)

    def test_live_and_target_paths_install_assets_for_the_selected_user(self):
        user_setup = (REPO / "deploy/scripts/user-setup.sh").read_text()
        target_setup = (REPO / "lib/target.sh").read_text()
        image_build = (REPO / "image/build.sh").read_text()
        config_installer = (CONFIG / "scripts/noctalia/deploy.sh").read_text()
        dotfiles_deployer = (CONFIG / "scripts/dotfiles/deploy.sh").read_text()

        self.assertIn('"$CONFIG_REPO_DIR/deploy.sh"', user_setup)
        self.assertIn('"$REPO_DIR/noctalia/settings.toml"', config_installer)
        self.assertIn('"$HOME/.zprofile"', dotfiles_deployer)
        self.assertIn('dotfiles/zsh/zprofile', dotfiles_deployer)
        self.assertIn('"$TARGET$home/.local/debianzfs-config"', target_setup)
        self.assertNotIn('.local/deploy', target_setup)
        self.assertIn('branch.main.merge refs/heads/main', target_setup)
        self.assertIn('branch.main.merge refs/heads/main', image_build)
        self.assertIn('"$TARGET/opt/media/wall/debianzfs_1.png"', target_setup)
        self.assertIn('chroot_run chown -R "$DEBIAN_SUDOUSER:$DEBIAN_SUDOUSER" /opt/media/wall',
                      target_setup)
        self.assertIn('/opt/media/wall/debianzfs_1.png', image_build)
        self.assertIn('-o liveuser -g liveuser', image_build)
        self.assertIn('systemctl --root=/ --no-reload enable NetworkManager.service',
                      image_build)
        self.assertIn("L+ /etc/resolv.conf - - - - /run/NetworkManager/resolv.conf",
                      image_build)
        self.assertIn('/home/liveuser/.local/debianzfs-config', image_build)
        self.assertIn("disable-live-lock.py", image_build)
        self.assertIn("enabled = false", (REPO / "deploy/scripts/disable-live-lock.py").read_text())

    def test_standalone_linker_replaces_symlinks_and_owns_zprofile(self):
        script = CONFIG / "deploy.sh"
        self.assertTrue(script.stat().st_mode & 0o111)
        zprofile = CONFIG / "dotfiles/zsh/zprofile"
        self.assertTrue(zprofile.is_file())
        text = zprofile.read_text()
        self.assertIn('$(tty) == /dev/tty1', text)
        self.assertIn('${SSH_CONNECTION:-}', text)
        self.assertIn('link_config "$REPO_DIR/dotfiles/zsh/zprofile" "$HOME/.zprofile"',
                      (CONFIG / "scripts/dotfiles/deploy.sh").read_text())
        self.assertTrue((CONFIG / "scripts/help-shortcuts/deploy.sh").is_file())

    def test_live_lock_override_changes_only_the_lock_setting(self):
        original = '''[idle.behavior.lock]
action = "lock"
enabled = true
timeout = 600.0

[idle.behavior.lock-and-suspend]
action = "lock_and_suspend"
enabled = false
timeout = 900.0

[idle.behavior.screen-off]
action = "screen_off"
enabled = true
timeout = 660.0
'''
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "settings.toml"
            settings.write_text(original)
            subprocess.run(
                [sys.executable, str(REPO / "deploy/scripts/disable-live-lock.py"),
                 str(settings)],
                check=True,
            )
            updated = tomllib.loads(settings.read_text())

        self.assertFalse(updated["idle"]["behavior"]["lock"]["enabled"])
        self.assertFalse(updated["idle"]["behavior"]["lock-and-suspend"]["enabled"])
        self.assertTrue(updated["idle"]["behavior"]["screen-off"]["enabled"])


if __name__ == "__main__":
    unittest.main()
