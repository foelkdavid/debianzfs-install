#!/usr/bin/env python3
"""Validate the bundled Noctalia settings and wallpaper integration."""
from pathlib import Path
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
SETTINGS = REPO / "deploy/noctalia/settings.toml"
WALLPAPER = REPO / "deploy/wallpapers/debianzfs_1.png"
HELP_LAUNCHER = REPO / "deploy/desktop/debianzfs-help.desktop"


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

    def test_live_and_target_paths_install_assets_for_the_selected_user(self):
        user_setup = (REPO / "deploy/scripts/user-setup.sh").read_text()
        target_setup = (REPO / "lib/target.sh").read_text()
        image_build = (REPO / "image/build.sh").read_text()

        self.assertIn('"$REPO_DIR/noctalia/settings.toml"', user_setup)
        self.assertIn('"$REPO_DIR/desktop/debianzfs-help.desktop"', user_setup)
        self.assertIn('DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}', user_setup)
        self.assertIn('"$TARGET/opt/media/wall/debianzfs_1.png"', target_setup)
        self.assertIn('chroot_run chown -R "$DEBIAN_SUDOUSER:$DEBIAN_SUDOUSER" /opt/media/wall',
                      target_setup)
        self.assertIn('/opt/media/wall/debianzfs_1.png', image_build)
        self.assertIn('-o liveuser -g liveuser', image_build)
        self.assertIn('systemctl --root=/ --no-reload enable NetworkManager.service',
                      image_build)


if __name__ == "__main__":
    unittest.main()
