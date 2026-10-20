# Bundled Debian desktop deployment

Installs Debian 13 desktop packages and configures their services inside the
new target. User dotfiles, Noctalia settings, wallpaper, help/ticket shortcuts
and refreshable user scripts live in the pinned
[`debianzfs-config`](../debianzfs-config) repository. The installer places that
checkout at `~/.local/debianzfs-config`; temporary package deployment scripts
are removed before reboot.

Noctalia uses the bundled plugin-free v5 settings and Gruvbox theme. The
Debian wallpaper is installed at `/opt/media/wall/debianzfs_1.png`, which is
also the configured default. The installer assigns `/opt/media/wall` to the
configured sudo user. Existing `~/.local/state/noctalia/settings.toml` files
are preserved during configuration refreshes.
NetworkManager starts in the live image and installed desktop. The live image
uses wired DHCP by default; the installer carries the selected DHCP setting
into the installed system. Wi-Fi can be selected and configured from Noctalia's
network panel. **DebianZFS Help** opens `https://docs.debian.foelk.com` in
Firefox, and **DebianZFS Ticket** opens the pre-labeled GitHub issue form.
Both launchers are installed on the desktop and in the app launcher with their
bundled icons.

## Refreshing user configuration

After `git pull`, run `~/.local/debianzfs-config/deploy.sh` as the desktop user
to refresh dotfile links and shortcut entries. Existing symlinks are replaced;
regular files are backed up under `~/.local/state/debianzfs-config/backups/`.
Set `DEBIANZFS_SKIP_OPTIONAL_ASSETS=true` to refresh offline without downloading
fonts or cloning Zsh plugins.

## Graphics and VM options

`GPU_DRIVER` selects `intel`, `amd`, `nvidia`, `nouveau` or `vm`.

- NVIDIA uses Debian's proprietary driver and stock Trixie kernel/header
  metapackages, selected from their normal stable candidates. Standalone mode
  rejects a running kernel >=6.16. Chroot mode checks **installed target
  kernels** in `/boot` and matching `/usr/src/linux-headers-*`, rejecting any
  target kernel >=6.16. Physical NVIDIA hardware has not been validated here;
  consult [Debian's NVIDIA guide](https://wiki.debian.org/NvidiaGraphicsDrivers)
  for GPU support and Secure Boot setup.
- VM integration: `VM_GUEST=auto|qemu|vmware|none`. Automatic detection runs in
  the booted/live system. Chroot mode requires an explicit resolved value.
- `VM_SOFTWARE_RENDERING=true` enables software rendering; leave it false for
  accelerated Virtio/virgl. For GPU passthrough, select the actual GPU profile.
- Standalone supports amd64 and arm64; Intel requires amd64. The parent ZFS
  installer supports amd64 only.

## Explicit chroot mode

The parent installer creates the account, provides target DNS and a private
`/run`, stages this package deployment bundle temporarily in `/opt`, and invokes
it as target root. It clones the pinned config checkout into the selected
account's home:

```sh
GPU_DRIVER=vm VM_GUEST=qemu VM_SOFTWARE_RENDERING=false \
  bash /opt/debianzfs-deploy/deploy.sh --chroot USER
```

`--chroot USER` is root-only and requires an existing normal account, Debian
Trixie, installed target kernels/headers and working DNS. It does not require
booted systemd or a user bus. `--dry-run` can be combined with `--chroot USER`.

Privileged system operations are separate from user resources. `runuser` runs
fonts, plugins, config and symlinks with the account's correct HOME, USER,
LOGNAME and XDG directories/ownership. No passwordless sudo rule is added.
Services are enabled offline using `systemctl --root=/ --no-reload` and per-user
unit links. A temporary `policy-rc.d` suppresses package-triggered service starts
and is restored on success or failure, preserving the installer's outer policy.
NetworkManager is enabled and competing network services are disabled/masked.
The parent installer creates the chosen DHCP profile, performs the final
initramfs rebuild and mirrored ESP sync, and exports the pool before reporting
success. Its Void-style colored UI identifies UEFI/Legacy BIOS and shows the
current stage with up to five lines of output. Complete output stays in a
root-readable log file; no separate log VT is allocated. See the
[parent README](../README.md) for boot support, display and log retention.

## Configuration and keys

Packages and services are listed in `vars.sh`. Hardware settings are generated
in `~/.config/debian-deploy/graphics.lua`. The Hyprland Lua configuration
retains its German/Bone keyboard layout independently of the console keyboard
selection. Its monitor settings include the source repository's working-tree
changes captured when this bundle was merged.

- Super+Return: Alacritty
- Super+D: launcher
- Super+E: Thunar
- Super+L: lock
- Super+Shift+S: screenshot to clipboard
- Super+M: exit Hyprland and return to the login shell
