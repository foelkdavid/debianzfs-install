#!/usr/bin/env python3
"""Host-safe Hyprland callbacks, static profiles, and user setup integration."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
CONFIG = REPO / "debianzfs-config"
PROFILES = CONFIG / "dotfiles/hypr/profiles"
LUA = shutil.which("lua5.4") or shutil.which("lua")


class HyprlandTests(unittest.TestCase):
    @unittest.skipUnless(LUA, "Lua interpreter required")
    def test_callbacks(self):
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run([LUA, str(CONFIG / "tests/hyprland.lua"),
                            str(CONFIG / "dotfiles/hypr/hyprland.lua")],
                           env=dict(os.environ, XDG_CONFIG_HOME=temporary), check=True)

    @unittest.skipIf(os.geteuid() == 0, "User setup intentionally rejects root")
    def test_profile_selection_switching_and_legacy_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            checkout = home / "config-repo"
            shutil.copytree(PROFILES, checkout / "dotfiles/hypr/profiles")
            deploy = checkout / "deploy.sh"
            deploy.write_text('#!/bin/sh\ntest "$(id -u)" != 0\n')
            deploy.chmod(0o755)
            selection = home / ".config/debian-deploy/graphics.lua"
            selection.parent.mkdir(parents=True)
            selection.write_text("old generated configuration\n")
            for gpu, software, expected in [
                ("intel", False, "intel"), ("amd", False, "amd"),
                ("nvidia", False, "nvidia"), ("nouveau", False, "nouveau"),
                ("vm", False, "vm"), ("vm", True, "vm-software"),
                ("intel", False, "intel"),
            ]:
                with self.subTest(profile=expected):
                    env = dict(os.environ, HOME=str(home),
                               XDG_CONFIG_HOME=str(home / ".config"),
                               XDG_STATE_HOME=str(home / ".local/state"),
                               DEBIANZFS_CONFIG_DIR=str(checkout), GPU_DRIVER=gpu,
                               VM_GUEST="none", VM_SOFTWARE_RENDERING=str(software).lower())
                    subprocess.run(["bash", str(REPO / "deploy/scripts/user-setup.sh")],
                                   env=env, check=True, capture_output=True, text=True)
                    self.assertTrue(selection.is_symlink())
                    self.assertEqual(selection.resolve(), checkout / "dotfiles/hypr/profiles" / f"{expected}.lua")
                    self.assertEqual(selection.lstat().st_uid, os.getuid())
                    self.assertEqual(selection.stat().st_uid, os.getuid())
                    state = home / ".local/state/debian-deploy/settings.sh"
                    self.assertIn(f"GPU_DRIVER={gpu}\n", state.read_text())
                    self.assertEqual(state.stat().st_mode & 0o777, 0o600)
            self.assertEqual((home / ".zprofile").read_text().count("# BEGIN debian-deploy TTY1"), 1)
            selection.unlink()
            (checkout / "dotfiles/hypr/profiles/intel.lua").unlink()
            result = subprocess.run(["bash", str(REPO / "deploy/scripts/user-setup.sh")],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Missing hardware profile", result.stderr)
            self.assertFalse(selection.exists())

    @unittest.skipUnless(LUA, "Lua interpreter required")
    def test_profile_effects_and_missing_selection_defaults(self):
        for profile in [None, "intel", "amd", "nvidia", "nouveau", "vm", "vm-software"]:
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as temporary:
                config_home = Path(temporary)
                if profile:
                    selection = config_home / "debian-deploy/graphics.lua"
                    selection.parent.mkdir()
                    selection.symlink_to(PROFILES / f"{profile}.lua")
                # Execute real profile code, asserting its merged settings/environment.
                code = '''
local settings, environment = {}, {}
local function merge(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" then target[k] = target[k] or {}; merge(target[k], v)
        else target[k] = v end
    end
end
hl = setmetatable({
    config = function(t) merge(settings, t) end,
    env = function(k, v) environment[k] = v end,
    get_monitors = function() return {} end,
    get_workspaces = function() return {} end,
    dsp = { window = {} },
}, { __index = function() return function() end end })
setmetatable(hl.dsp, { __index = function() return function() end end })
setmetatable(hl.dsp.window, { __index = function() return function() end end })
dofile(arg[1])
local vm = arg[2] == "vm" or arg[2] == "vm-software"
assert(settings.decoration.shadow.enabled == not vm)
assert(settings.decoration.blur.enabled == not vm)
assert(settings.animations.enabled == not vm)
assert(settings.cursor.no_hardware_cursors == (vm and 1 or 2))
assert(environment.LIBGL_ALWAYS_SOFTWARE == (arg[2] == "vm-software" and "true" or nil))
assert(environment.LIBVA_DRIVER_NAME == (arg[2] == "nvidia" and "nvidia" or nil))
assert(environment.__GLX_VENDOR_LIBRARY_NAME == (arg[2] == "nvidia" and "nvidia" or nil))
assert(environment.NVD_BACKEND == (arg[2] == "nvidia" and "direct" or nil))
'''
                fixture = config_home / "check.lua"
                fixture.write_text(code)
                subprocess.run([LUA, str(fixture), str(CONFIG / "dotfiles/hypr/hyprland.lua"),
                                profile or "default"],
                               env=dict(os.environ, XDG_CONFIG_HOME=temporary), check=True)


if __name__ == "__main__":
    unittest.main()
