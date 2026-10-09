# debianzfs-install

Interactive Debian on ZFS installer (optional with zfs-mirror)

Ported from my [voidzfs-install](https://github.com/foelkdavid/voidzfs-install), using Debian 13 "Trixie" and systemd.

## Howto:

1. Boot an official Debian 13 live image. The amd64 standard ISO works; a desktop live image works too. Use the live image, not the installer rescue shell.
2. Connect to the internet and clone this repo.
3. Run the script from the repo directory:

```sh
sudo ./install.sh
```

The script installs the tools it needs first. This can take a while if it has to build the ZFS module. Then follow the prompts for disks, swap, hostname, user, timezone, keyboard layout and passwords. Reboot once it's done.

## Features:

- Boots from ZFSBootMenu
- Encrypts the ZFS filesystem
- Optional ZFS-Mirror setup
    - Two EFI partitions for redundancy
        - Synced once after installation, then continuously by a custom service
    - ZFS-mirrored system partitions
- Customizable swap partition (use `0` or `none` to skip it)
- Creates an additional dataset for `/home`
- Provides systemd services for automatic snapshots + continuous EFI syncing
    - `efisync.service` is only installed for mirrored setups
    - Snapshot jobs can be changed in `/etc/zfs-autosnap/jobs.conf`

**This requires UEFI to boot. The selected disks will be wiped.**

## Rough FS diagram:

```text
Each disk:
  EFI (512 MiB)
  Swap (optional)
  ZFS (remaining space, mirrored if using two disks)

zroot
├── ROOT
│   └── debian  → /
└── home        → /home
```
