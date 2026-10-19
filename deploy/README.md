# Bundled Debian desktop deployment

Sets up Debian 13 Trixie with Hyprland, Noctalia, Alacritty, Thunar, Firefox ESR,
Zsh, audio, networking, Bluetooth, fonts, plugins and linked dotfiles.
Hyprland comes from Trixie backports; Noctalia uses its official APT repository.
The parent ZFS installer offers this deployment by default and copies this
bundled directory into the configured account's permanent `~/.local/deploy`.
It does not clone a fresh deployment repository.

## Standalone usage

On booted Debian Trixie with a sudo-capable normal user and internet access:

1. Copy this `deploy/` directory to `~/.local/deploy`, or keep it at another
   permanent location. Dotfiles link into it, so do not remove or move it later.
2. Choose settings in `vars.sh` or environment variables.
3. Run `./deploy.sh --dry-run` to inspect packages and profile choices.
4. Run `./deploy.sh` as your normal user, without `sudo` in front.
5. Reboot and log in normally on **TTY1**. Hyprland starts after login, with no
   automatic login. Exiting Hyprland returns to the shell. SSH, nested shells
   and existing graphical sessions do not launch another compositor.

Settings persist as data in `~/.local/state/debian-deploy/settings.sh` for
reruns. Explicit environment variables override saved settings. For example:

```sh
GPU_DRIVER=vm VM_GUEST=qemu VM_SOFTWARE_RENDERING=true ./deploy.sh --dry-run
```

Existing configs are backed up under `~/.local/state/debian-deploy/backups/`.
To refresh the deployment, copy the newer bundled files into the same permanent
location and rerun the script. Retain any custom changes when refreshing.

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
`/run`, copies this bundle and invokes it as target root:

```sh
GPU_DRIVER=vm VM_GUEST=qemu VM_SOFTWARE_RENDERING=false \
  bash /home/USER/.local/deploy/deploy.sh --chroot USER
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
in `~/.config/debian-deploy/graphics.lua`. The bundled Hyprland Lua configuration
retains its German/Bone keyboard layout independently of the console keyboard
selection. Its monitor settings include the source repository's working-tree
changes captured when this bundle was merged.

- Super+Return: Alacritty
- Super+D: launcher
- Super+E: Thunar
- Super+L: lock
- Super+Shift+S: screenshot to clipboard
- Super+M: exit Hyprland and return to the login shell
