#!/bin/bash
# Destructive regression fixture: disposable UEFI QEMU guests only.
set -Eeuo pipefail
[[ $EUID == 0 && -d /run/live/medium && -d /sys/firmware/efi ]] || {
    echo 'Requires a disposable UEFI Debian live guest.' >&2; exit 1;
}
case $(systemd-detect-virt) in
    qemu|kvm) ;;
    *) echo 'Requires a disposable QEMU guest.' >&2; exit 1 ;;
esac
for pair in '/dev/nvme0n1 INSTALLER_TEST_A' '/dev/nvme1n1 INSTALLER_TEST_B'; do
    read -r disk serial <<< "$pair"
    [[ $(lsblk -dnro SERIAL "$disk") == "$serial" ]] || {
        echo "Refusing disk without fixture serial: $disk" >&2; exit 1;
    }
done
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$REPO_DIR/install.sh"
if zpool list zroot >/dev/null 2>&1; then
    echo 'Refusing to overwrite an existing zroot pool.' >&2; exit 1
fi
modprobe zfs
WORK_DIR=/tmp/nvme-fixture
TARGET=/mnt/nvme-fixture
mkdir -p "$WORK_DIR" "$TARGET"
truncate -s 64M "$WORK_DIR/fat.img"
mkfs.vfat "$WORK_DIR/fat.img"
for mirrored in false true; do
    for swap in 0 1; do
        for encrypted in false true; do
            DEBIAN_DISK1=/dev/nvme0n1 DEBIAN_DISK2=/dev/nvme1n1
            DEBIAN_MIRROR_MODE=$mirrored DEBIAN_SWAPSIZE=$swap DEBIAN_ENCRYPTION=$encrypted
            set_zfs_vars
            wipe_disks
            partition_disks
            devices=("$POOL_DEVICE_1")
            [[ $mirrored != true ]] || devices+=("$POOL_DEVICE_2")
            for device in "${devices[@]}"; do
                mkfs.ext4 -F -E nodiscard "$device" > "$WORK_DIR/mkfs.log" 2>&1
                dd if="$WORK_DIR/fat.img" of="$device" bs=512 count=1 conv=notrunc status=none
                # Assert that real, conflicting signatures break the old probe.
                if blkid --probe --match-tag PART_ENTRY_UUID --output value "$device"; then
                    echo 'FAIL: conflicting-signature reproduction stopped working'; exit 12
                fi
                wipefs "$device"
            done
            ZFS_PASSPHRASE='disposable fixture passphrase'
            setup_zfs
            [[ $(findmnt -nro SOURCE "$TARGET") == zroot/ROOT/debian ]]
            [[ $(findmnt -nro SOURCE "$TARGET/home") == zroot/home ]]
            [[ $(zpool list -H -o health zroot) == ONLINE ]]
            [[ $(zpool status -P zroot | grep -c '/dev/nvme[01]n1p') == "${#devices[@]}" ]]
            zfs unmount zroot/home
            zfs unmount zroot/ROOT/debian
            zpool export zroot
            zpool import -N -R "$TARGET" zroot
            [[ $encrypted != true ]] || zfs load-key -L "file://$WORK_DIR/zroot.key" zroot
            zfs mount zroot/ROOT/debian
            zfs mount zroot/home
            [[ $(findmnt -nro SOURCE "$TARGET") == zroot/ROOT/debian ]]
            zfs unmount zroot/home
            zfs unmount zroot/ROOT/debian
            zpool destroy zroot
            POOL_OWNED=false
            printf 'PASS mirror=%s swap=%s encryption=%s with real conflicting filesystem signatures\n' "$mirrored" "$swap" "$encrypted"
        done
    done
done
echo STORAGE_FIXTURE_DONE
