# Debian ZFS installer

An interactive, all-in-one Debian 13 Trixie installer for amd64 UEFI systems,
with optional Hyprland and Noctalia deployment. Based on
[voidzfs-install](https://github.com/foelkdavid/voidzfs-install). Run it from an official Debian
13 **live** image, with internet access:

```sh
sudo apt-get update
sudo apt-get install git ca-certificates curl
git clone --branch v1.0.0 https://github.com/foelkdavid/debianzfs-install
cd debianzfs-install
sudo ./install.sh
```

The selected disks are erased only after you explicitly choose **Start
installation** at the final review. Never run this on an installed workstation.
Legacy BIOS is detected and displayed normally, but installation stops before
package preparation or disk changes: BIOS support is pending another branch.

The visible preflight checklist checks root, boot mode, Debian live/amd64,
bundled files, DNS and HTTPS. A logged preparation stage installs live tools and
builds the live ZFS module if necessary. HTTPS connectivity does not depend on
ping. Secure Boot must permit the ZFS module and upstream ZFSBootMenu EFI image;
this installer does not enroll signing keys.

Configuration asks each setting separately and redraws the complete summary:
console keyboard, Ethernet IPv4 DHCP, disk(s), mirror, Debian archive mirror,
swap, **ZFS encryption**, hostname, username, timezone and optional desktop.
Encryption defaults to yes. The account password and, when encrypted, the ZFS
passphrase are confirmed before final review; only set/unset is displayed.
ZFSBootMenu uses a US keyboard for unlocking. Restart clears all answers and
secrets while keeping successfully installed live prerequisites.

Choose **Run desktop deployment too? (y/n)** (default yes):

- **No:** clean Debian ZFS, Bash login, systemd-networkd and systemd-resolved.
  No desktop files, packages or login customization are installed.
- **Yes:** the bundled [`deploy/`](deploy/README.md) is copied permanently to
  `~/.local/deploy` and run inside the target chroot before final initramfs and
  mirrored ESP synchronization. Choose `intel`, `amd`, `nvidia`, `nouveau` or
  `vm`; VM mode also asks about guest tools and software rendering. Desktop
  systems use NetworkManager. Turning DHCP off leaves Ethernet configuration
  to you; NetworkManager will not create an automatic default connection.

Log in normally on **TTY1** using your configured account. Desktop installations
start Hyprland after that login, with no automatic login. SSH, nested shells
and existing graphical sessions do not start another compositor. Exiting
Hyprland returns to the shell. The bundled German/Bone Hyprland keyboard layout
is independent of the console keyboard choice and is preserved.

The deployment uses the merged files in this checkout, including the source
repository's working-tree Hyprland configuration; it does not clone a second
deployment repository. Dotfiles link into `~/.local/deploy`, so keep it there.
Profile choices persist in `~/.local/state/debian-deploy/settings.sh` for later
reruns. System operations run as root; user configuration, fonts and plugins
run as your account with its HOME and XDG paths. There is no temporary sudo
exception. Services are enabled offline; package-triggered starts are blocked
with a temporary policy, restored on success and failure. The target has a
private `/run` and copied live DNS during package setup. The installer owns a
private mount namespace so live service namespaces cannot retain target mounts.

The stage display shows completed steps, the running step and a rolling window
of recent output. Small terminals show a count of earlier completed stages;
the full history remains in the log. Resizing is handled on the next redraw.
Unsuitable terminals use plain output. Untruncated, timestamped logs are kept
with mode 0600 under `/var/log/debianzfs-install/` in the live environment. If an
unused Linux virtual terminal can be allocated safely, its number and switching
instructions appear above the UI. Switch with **Ctrl+Alt+Fn**; return to your
original installer TTY. Allocation never switches focus or overwrites an
occupied VT. Without a spare VT, file logging continues.

Before unmounting, the log is also copied under `/var/log/debianzfs-install/` in
the target. The complete live log additionally includes final unmount/export
results and any failure cleanup. Failures stop later stages, restore terminal
state and service policies, and preserve logs. Success is reported only after
cleanup and pool export succeed. Then reboot and log in as the account shown.

Storage retains ZFSBootMenu, optional two-disk ZFS mirroring, one `/home`
dataset, optional swap, automatic snapshots, and mirrored EFI synchronization.
Each disk has a 512 MiB ESP, optional swap and the remaining space for ZFS:

```text
zroot                 encryption optional (default yes)
├── ROOT
│   └── debian        /
└── home              /home
```

Swap partitions are separate from ZFS encryption. `0` or `none` disables swap;
in mirror mode the chosen size is allocated on each disk. Minimum disk space
is 8 GiB for clean or 24 GiB for desktop, plus ESP and swap. Immediately before
erasing, whole disks, capacity, distinct members, mounts, active swap, imported
pools, holders and open devices are revalidated. Live media cannot be selected.
Snapshot jobs live in `/etc/zfs-autosnap/jobs.conf`; `efisync.service` is installed
only for mirrors. See [services](services/README.md).

Validation commands and actual results/limitations are in
[`tests/README.md`](tests/README.md). In particular, mock tests and dry runs do
not establish physical NVIDIA support.

The boot/key handling follows the upstream
[ZFSBootMenu Debian UEFI guide](https://www.zfsbootmenu.org/en/latest/guides/debian/uefi.html),
and offline service links use
[systemctl's documented `--root` behavior](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html).
