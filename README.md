# debianzfs-install

Interactive Debian on ZFS installer with optional ZFS mirror support.

## What it does

- Installs Debian 13 "Trixie" onto an encrypted ZFS root pool.
- Boots through the upstream ZFSBootMenu EFI binary.
- Supports single-disk and mirrored ZFS layouts.
- Creates one EFI system partition per disk in mirror mode and keeps the secondary ESP synced.
- Optionally creates swap partitions on the selected disk or disks.
- Creates separate datasets for `/` and `/home`.
- Installs native systemd services for ESP sync and automatic ZFS snapshots.

This requires UEFI boot. The installer partitions and wipes the selected disks.

## Expected live environment

Run this from an official Debian live image, not the debian-installer rescue
shell. The live image boots a normal Debian userspace with `apt`; the installer
rescue shell is intentionally smaller and may not have enough tooling for DKMS,
ZFS, or debootstrap work.

The easiest VM choice is the Debian amd64 live standard ISO. A desktop live ISO
such as Xfce also works, but is larger.

The live environment must have:

- UEFI boot with `/sys/firmware/efi` present.
- Network connectivity.
- `apt-get`.

The installer enables the target Debian apt components in the live environment
and installs its host-side requirements itself, including `debootstrap`, `gdisk`,
`dosfstools`, `curl`, `zfsutils-linux`, and a DKMS fallback for the ZFS kernel
module.

## Usage

```sh
sudo ./install.sh
```

The installer prompts for:

- Console keymap, applied immediately in the live environment when supported.
- Target disk.
- Optional mirror disk.
- Swap size in GB, or `0`/`none` to skip swap.
- Hostname.
- Sudo user.
- Timezone.
- User password.
- ZFS encryption passphrase.

## Filesystem layout

Each selected disk is partitioned as:

1. 512 MiB EFI system partition.
2. Swap partition with the selected size, unless swap is disabled.
3. Remaining space for ZFS. If swap is disabled, ZFS uses partition 2.

The pool and datasets are:

```text
zroot
zroot/ROOT
zroot/ROOT/debian  mounted at /
zroot/home         mounted at /home
```

## Services

`efisync.service` is installed only for mirrored systems. It watches `/boot/efi` and syncs changes to `/boot/efi2`.

`zfs-autosnap.service` is always installed. Jobs are configured in `/etc/zfs-autosnap/jobs.conf` using:

```text
name|dataset|label|schedule|keep|slack|flags
```

The bundled scheduler supports the default daily, hourly, 15-minute, and minute-style schedules.
