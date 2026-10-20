#!/usr/bin/env bash
set -Eeuo pipefail
# Never enable xtrace: passwords must not enter logs.
set +x
umask 022
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TARGET=/mnt/debianzfs-install
DEBIAN_RELEASE=trixie
DEBIAN_MIRROR=https://deb.debian.org/debian
DEBIAN_COMPONENTS="main contrib non-free-firmware"
HOST_APT_SOURCE=/etc/apt/sources.list.d/debianzfs-install-host.list
source "$REPO_DIR/lib/ui.sh"
source "$REPO_DIR/lib/config.sh"
source "$REPO_DIR/lib/target.sh"

devpart() {
    local disk="$1" part="${2:-1}" sep=""
    [[ "$disk" =~ ^/dev/(nvme|mmcblk|nbd|loop) ]] && sep="p"
    printf "%s%s%s" "$disk" "$sep" "$part"
}

set_zfs_vars() {
    export BOOT_DISK_1="$DEBIAN_DISK1"
    export BOOT_PART_1=1
    BOOT_DEVICE_1="$(devpart "$DEBIAN_DISK1" 1)"
    export BOOT_DEVICE_1
    ok "BOOT_DEVICE_1 set to $BOOT_DEVICE_1"

    export POOL_DISK_1="$DEBIAN_DISK1"
    export POOL_PART_1
    if swap_enabled; then POOL_PART_1=3; else POOL_PART_1=2; fi
    POOL_DEVICE_1="$(devpart "$DEBIAN_DISK1" "$POOL_PART_1")"
    export POOL_DEVICE_1
    ok "POOL_DEVICE_1 set to $POOL_DEVICE_1"

    if [[ -n "${DEBIAN_DISK2:-}" && "$DEBIAN_DISK2" != "none" ]]; then
        export BOOT_DISK_2="$DEBIAN_DISK2"
        export BOOT_PART_2=1
        BOOT_DEVICE_2="$(devpart "$DEBIAN_DISK2" 1)"
        export BOOT_DEVICE_2
        ok "BOOT_DEVICE_2 set to $BOOT_DEVICE_2"

        export POOL_DISK_2="$DEBIAN_DISK2"
        export POOL_PART_2
        if swap_enabled; then POOL_PART_2=3; else POOL_PART_2=2; fi
        POOL_DEVICE_2="$(devpart "$DEBIAN_DISK2" "$POOL_PART_2")"
        export POOL_DEVICE_2
        ok "POOL_DEVICE_2 set to $POOL_DEVICE_2"
    fi
}

swap_enabled() {
    [[ "${DEBIAN_SWAPSIZE:-0}" =~ ^[0-9]+$ ]] && [ "$DEBIAN_SWAPSIZE" -gt 0 ]
}

wipe_disks() {
    local disks=("$DEBIAN_DISK1")
    [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]] && disks+=("$DEBIAN_DISK2")

    for d in "${disks[@]}"; do
        info "[Wiping $d]"
        wipefs -a "$d"
        sgdisk --zap-all "$d" >/dev/null || {
            failhard "Failed to zap partition table on $d"
            exit 1
        }
        partprobe "$d" >/dev/null 2>&1 || true
        ok "Wiped $d"
    done
}

partition_disks() {
    local disks=("$DEBIAN_DISK1")
    [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]] && disks+=("$DEBIAN_DISK2")

    for d in "${disks[@]}"; do
        info "[Partitioning $d]"
        sgdisk --zap-all "$d" >/dev/null
        sgdisk -n1:1MiB:+512MiB -t1:ef00 -c1:EFI "$d" >/dev/null
        ok "Created EFI partition on $d"
        if swap_enabled; then
            sgdisk -n2:0:+"${DEBIAN_SWAPSIZE}"GiB -t2:8200 -c2:swap "$d" >/dev/null
            ok "Created swap partition on $d"
            sgdisk -n3:0:-10MiB -t3:bf00 -c3:zfs "$d" >/dev/null
        else
            sgdisk -n2:0:-10MiB -t2:bf00 -c2:zfs "$d" >/dev/null
        fi
        ok "Created ZFS partition on $d"
        partprobe "$d" || { failhard "Could not reread the partition table on $d."; return 1; }
        udevadm settle --timeout=10 || { failhard "Partition events did not settle for $d."; return 1; }
    done
}

pool_partition_ready() {
    [[ -b $1 && $(lsblk -dnro TYPE "$1") == part ]]
}

resolve_pool_device() {
    local device=$1 uuid alias attempt
    # A fresh partition can appear after partprobe/udevadm return. Probe the
    # GPT metadata directly: normal blkid output can omit PARTUUID or be stale.
    for ((attempt = 0; attempt < 40; attempt++)); do
        if pool_partition_ready "$device"; then
            uuid=$(blkid --probe --match-tag PART_ENTRY_UUID --output value "$device" 2>/dev/null) || uuid=''
            if [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
                alias="/dev/disk/by-partuuid/${uuid,,}"
                if [[ -b $alias && $alias -ef $device ]]; then
                    printf '%s\n' "$alias"
                else
                    # ZFS also identifies vdevs by their on-disk GUIDs. A late
                    # udev alias must not prevent using the verified partition.
                    info "PARTUUID link is not ready; using verified partition $device." >&2
                    printf '%s\n' "$device"
                fi
                return 0
            fi
        fi
        sleep .25
    done
    failhard "No block partition with a readable GPT UUID appeared for $device within 10 seconds."
    return 1
}

create_zpool() {
    [[ -n "${POOL_DEVICE_1:-}" ]] || {
        failhard "POOL_DEVICE_1 not set"
        return 1
    }
    local first second
    local -a vdevs=()
    first=$(resolve_pool_device "$POOL_DEVICE_1") || return 1
    if [[ ${DEBIAN_MIRROR_MODE:-false} == true ]]; then
        [[ -n ${POOL_DEVICE_2:-} ]] || { failhard 'The second mirror partition is not set.'; return 1; }
        second=$(resolve_pool_device "$POOL_DEVICE_2") || return 1
        [[ $first != "$second" && ! $first -ef $second ]] || {
            failhard 'Mirror partitions refer to the same block device.'; return 1;
        }
        vdevs=(mirror "$first" "$second")
    else
        vdevs=("$first")
    fi

    local common_opts=(
        -f
        -o compatibility=openzfs-2.2-linux
        -o ashift=12
        -O compression=zstd
        -O acltype=posixacl
        -O xattr=sa
        -O relatime=on
        -O dnodesize=auto
        -O normalization=formD
        -O mountpoint=none
    )

    if [[ $DEBIAN_ENCRYPTION == true ]]; then
        common_opts+=(-O encryption=aes-256-gcm -O "keylocation=file://$WORK_DIR/zroot.key" -O keyformat=passphrase)
    fi
    info "[Creating ZFS pool 'zroot' on ${vdevs[*]}]"
    zpool create "${common_opts[@]}" zroot "${vdevs[@]}" || return
    POOL_OWNED=true
    ok "Created pool zroot"
    unset ZFS_PASSPHRASE
}

create_zfs_datasets() {
    info "[Creating ZFS datasets]"
    zfs create -o mountpoint=none zroot/ROOT
    zfs create -u -o mountpoint=/ -o canmount=noauto zroot/ROOT/debian
    zfs create -u -o mountpoint=/home zroot/home
    zpool set bootfs=zroot/ROOT/debian zroot
    ok "Created datasets with bootfs=zroot/ROOT/debian"
}

setup_zfs() {
    if [[ $DEBIAN_ENCRYPTION == true ]]; then
        printf '%s' "$ZFS_PASSPHRASE" > "$WORK_DIR/zroot.key"
        chmod 600 "$WORK_DIR/zroot.key"
    fi
    modprobe zfs
    create_zpool
    # Import with altroot before creating mountable datasets, so /home on the
    # live system can never be covered by an installer dataset.
    zpool export zroot
    POOL_OWNED=false
    zpool import -N -R "$TARGET" zroot
    POOL_OWNED=true
    if [[ $DEBIAN_ENCRYPTION == true ]]; then
        zfs load-key -L "file://$WORK_DIR/zroot.key" zroot
        zfs set keylocation=file:///etc/zfs/zroot.key zroot
    fi
    create_zfs_datasets
    zfs mount zroot/ROOT/debian
    TARGET_MOUNTED=true
    mkdir -p "$TARGET/home"
    zfs mount zroot/home
    udevadm trigger
}

mount_chroot_filesystems() {
    mkdir -p "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run"
    mount --rbind /dev "$TARGET/dev"
    mount --make-rslave "$TARGET/dev"
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sys "$TARGET/sys"
    mkdir -p "$TARGET/sys/firmware/efi/efivars"
    mount -t efivarfs efivarfs "$TARGET/sys/firmware/efi/efivars"
    # A private /run contains no live systemd/private or user bus sockets.
    mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$TARGET/run"
}

chroot_run() {
    chroot "$TARGET" /usr/bin/env -i \
        HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        "$@"
}

apt_install_target() {
    chroot_run apt-get install -y --no-install-recommends "$@"
}

install_base_system() {
    info "[Installing Debian base system]"
    # debootstrap's second stage and all APT operations inherit this policy.
    mkdir -p "$TARGET/usr/sbin"
    install_target_policy
    DEBIAN_ARCH="${DEBIAN_ARCH:-$(dpkg --print-architecture)}"
    local bootstrap_tarball=/opt/debianzfs-install/cache/debootstrap-trixie-amd64.tar
    if [[ -s $bootstrap_tarball ]]; then
        debootstrap --unpack-tarball="$bootstrap_tarball" --arch="$DEBIAN_ARCH" \
            --components="${DEBIAN_COMPONENTS// /,}" "$DEBIAN_RELEASE" "${TARGET}" "$DEBIAN_MIRROR"
    else
        debootstrap --arch="$DEBIAN_ARCH" --components="${DEBIAN_COMPONENTS// /,}" \
            "$DEBIAN_RELEASE" "${TARGET}" "$DEBIAN_MIRROR"
    fi
    ok "Installed Debian base system"

    mkdir -p "${TARGET}/etc/apt/sources.list.d" "${TARGET}/etc/zfs" "${TARGET}/etc/initramfs-tools/conf.d" "${TARGET}/etc/initramfs-tools/hooks"
    if [[ $DEBIAN_ENCRYPTION == true ]]; then
        install -m 000 "$WORK_DIR/zroot.key" "$TARGET/etc/zfs/zroot.key"
    fi

    cat >"${TARGET}/etc/apt/sources.list" <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} ${DEBIAN_COMPONENTS}
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates ${DEBIAN_COMPONENTS}
deb https://security.debian.org/debian-security ${DEBIAN_RELEASE}-security ${DEBIAN_COMPONENTS}
EOF

    mount_chroot_filesystems
    prepare_target_dns
    mount_bundled_apt_cache
    chroot_run apt-get update
    apt_install_target openssl mokutil
    apt_install_target linux-image-amd64 linux-headers-amd64 dkms zfs-dkms \
        zfsutils-linux zfs-initramfs zfs-zed \
        sudo locales console-setup keyboard-configuration efibootmgr dosfstools \
        rsync inotify-tools util-linux kmod systemd-sysv plymouth plymouth-themes
    chroot_run zgenhostid -f
    ok "Installed target packages"
}

configure_initramfs() {
    printf 'UMASK=0077\n' > "$TARGET/etc/initramfs-tools/conf.d/umask"
    info "[Configuring initramfs-tools for ZFS]"
    cat >"${TARGET}/etc/initramfs-tools/conf.d/zfs" <<'EOF'
BOOT=zfs
EOF
    [[ $DEBIAN_ENCRYPTION == true ]] || return 0
    cat >"${TARGET}/etc/initramfs-tools/hooks/zroot-key" <<'EOF'
#!/bin/sh
set -e

PREREQ=""
prereqs() { echo "$PREREQ"; }

case "$1" in
prereqs) prereqs; exit 0 ;;
esac

mkdir -p "${DESTDIR}/etc/zfs"
cp -p /etc/zfs/zroot.key "${DESTDIR}/etc/zfs/zroot.key"
chmod 000 "${DESTDIR}/etc/zfs/zroot.key"
EOF
    chmod 755 "${TARGET}/etc/initramfs-tools/hooks/zroot-key"
    ok "Configured initramfs"
}

rebuild_initramfs() {
    info "[Rebuilding initramfs]"
    chroot_run update-initramfs -u -k all
    ok "Rebuilt initramfs"
}

configure_system() {
    info "[Configuring Debian system]"
    echo "$DEBIAN_HOSTNAME" >"${TARGET}/etc/hostname"
    cat >"${TARGET}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${DEBIAN_HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    ln -sf "/usr/share/zoneinfo/$DEBIAN_TIMEZONE" "${TARGET}/etc/localtime"
    echo "$DEBIAN_TIMEZONE" >"${TARGET}/etc/timezone"
    cat >"${TARGET}/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${DEBIAN_KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${TARGET}/etc/locale.gen"
    chroot_run locale-gen
    chroot_run update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en
    zfs set org.zfsbootmenu:commandline="quiet splash" zroot/ROOT
    if [[ $DEBIAN_ENCRYPTION == true ]]; then
        zfs set org.zfsbootmenu:keysource=zroot/ROOT/debian zroot
    fi
    ok "Configured hostname, timezone, keyboard, locale, and ZFSBootMenu property"
}

configure_efi_partitions() {
    info "[Formatting and mounting EFI partitions]"
    mkfs.vfat -F32 "$BOOT_DEVICE_1" >/dev/null
    mkdir -p "${TARGET}/boot/efi"
    local efi1_uuid efi_options=defaults
    efi1_uuid="$(blkid -s UUID -o value "$BOOT_DEVICE_1")"
    if [[ ${DEBIAN_MIRROR_MODE:-false} == true ]]; then
        efi_options=defaults,nofail,x-systemd.device-timeout=10s
    fi
    echo "UUID=$efi1_uuid /boot/efi vfat $efi_options 0 1" >>"${TARGET}/etc/fstab"
    chroot_run mount /boot/efi
    ok "Mounted primary ESP"

    if [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]]; then
        mkfs.vfat -F32 "$BOOT_DEVICE_2" >/dev/null
        mkdir -p "${TARGET}/boot/efi2"
        local efi2_uuid
        efi2_uuid="$(blkid -s UUID -o value "$BOOT_DEVICE_2")"
        echo "UUID=$efi2_uuid /boot/efi2 vfat defaults,nofail,x-systemd.device-timeout=10s 0 1" >>"${TARGET}/etc/fstab"
        chroot_run mount /boot/efi2
        ok "Mounted secondary ESP"
    fi
}

setup_zfsbootmenu() {
    info "[Configuring ZFSBootMenu]"
    mkdir -p "${TARGET}/etc/zfsbootmenu" "${TARGET}/boot/efi/EFI/zbm" "${TARGET}/boot/efi/EFI/BOOT"
    curl -fsSL https://get.zfsbootmenu.org/efi/release -o "${TARGET}/boot/efi/EFI/zbm/vmlinuz.EFI"
    cp -f "${TARGET}/boot/efi/EFI/zbm/vmlinuz.EFI" "${TARGET}/boot/efi/EFI/BOOT/BOOTX64.EFI"
    ok "Installed upstream ZFSBootMenu EFI binary"

    if [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]]; then
        for disk in "$DEBIAN_DISK1" "$DEBIAN_DISK2"; do
            chroot_run efibootmgr -c -d "$disk" -p 1 -L "ZFSBootMenu ($disk)" -l '\EFI\zbm\vmlinuz.EFI'
            ok "Added EFI boot entry for $disk"
        done
    else
        chroot_run efibootmgr -c -d "$DEBIAN_DISK1" -p 1 -L "ZFSBootMenu ($DEBIAN_DISK1)" -l '\EFI\zbm\vmlinuz.EFI'
        ok "Added EFI boot entry for $DEBIAN_DISK1"
    fi
}

setup_swap() {
    if ! swap_enabled; then
        info "[Skipping swap]"
        ok "No swap configured"
        return 0
    fi

    info "[Setting up swap]"
    local disks=("$DEBIAN_DISK1")
    [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]] && disks+=("$DEBIAN_DISK2")

    local i=1
    for disk in "${disks[@]}"; do
        local swappart swap_uuid
        swappart="$(devpart "$disk" 2)"
        mkswap "$swappart" >/dev/null
        swap_uuid="$(blkid -s UUID -o value "$swappart")"
        echo "UUID=$swap_uuid none swap defaults,nofail 0 0" >>"${TARGET}/etc/fstab"
        ok "Configured swap on disk $i"
        ((i++))
    done
}

setup_user() {
    info "[Creating sudo user: $DEBIAN_SUDOUSER]"
    chroot_run useradd -m -G sudo -s /bin/bash "$DEBIAN_SUDOUSER"
    printf "%s:%s\n" "$DEBIAN_SUDOUSER" "$USER_PASSWORD" | chroot_run chpasswd
    unset USER_PASSWORD
    echo "%sudo ALL=(ALL:ALL) ALL" >"${TARGET}/etc/sudoers.d/sudo"
    chmod 440 "${TARGET}/etc/sudoers.d/sudo"
    ok "Created user and sudoers configuration"
}

sync_esps() {
    [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]] || return 0
    info "[One-time ESP sync]"
    chroot_run rsync -a --delete /boot/efi/ /boot/efi2/
    ok "Synced secondary ESP"
}

install_efisync() {
    [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]] || return 0
    info "[Installing efisync systemd service]"
    install -D -m 755 "$REPO_DIR/services/efisync/efisync.sh" "${TARGET}/usr/local/bin/efisync.sh"
    install -D -m 644 "$REPO_DIR/services/efisync/efisync.service" "${TARGET}/etc/systemd/system/efisync.service"
    chroot_run systemctl --root=/ --no-reload enable efisync.service
    ok "Installed efisync.service"
}

install_zfs_autosnap() {
    info "[Installing zfs-autosnap systemd service]"
    install -D -m 755 "$REPO_DIR/services/zfs-autosnap/zfs-autosnap.sh" "${TARGET}/usr/local/bin/zfs-autosnap.sh"
    install -D -m 755 "$REPO_DIR/services/zfs-autosnap/zfs-autosnap-status.sh" "${TARGET}/usr/local/bin/zfs-autosnap-status.sh"
    install -D -m 644 "$REPO_DIR/services/zfs-autosnap/jobs.conf" "${TARGET}/etc/zfs-autosnap/jobs.conf"
    install -D -m 644 "$REPO_DIR/services/zfs-autosnap/zfs-autosnap.service" "${TARGET}/etc/systemd/system/zfs-autosnap.service"
    chroot_run systemctl --root=/ --no-reload enable zfs-autosnap.service
    ok "Installed zfs-autosnap.service"
}


run_guided_installation() {
    local rc
    run_prechecks
    while :; do
        reset_configuration
        get_inputs
        print_preconf_header
        if confirm_menu; then rc=0; else rc=$?; fi
        case $rc in
            10) continue ;;
            20) return 0 ;;
            0) INSTALL_CONFIRMED=true; break ;;
        esac
    done
    run_stage 'Check DNS and HTTPS sources' source_connectivity_check
    run_stage 'Prepare live dependencies' install_host_requirements
    run_stage 'Validate ZFS and installation tools' validate_live_tools
    run_installation
    # EXIT also handles failures, but success is only printed after export.
    run_stage 'Restore policies and clean up / export pool' cleanup_target
    CLEANED=true
    printf '\n' >&3
    ok "Installation finished. Reboot and log in as $DEBIAN_SUDOUSER." >&3
    if [[ $DEBIAN_DESKTOP == true ]]; then
        note 'Hyprland starts after interactive TTY1 login; exiting it returns to your shell.' >&3
    fi
    note "Complete live log: $LOG_FILE" >&3
}

main() {
    # Refuse before logging/apt/mounts on a normal developer workstation.
    [[ $EUID == 0 ]] || { failhard 'Run as root from Debian 13 live media.'; return 1; }
    # Live udev/logind use slave mount namespaces. If target mounts propagate
    # into them, they can retain invisible references after our unmounts and
    # prevent pool export. Own a recursively private namespace from the start.
    if [[ ${DEBIANZFS_PRIVATE_MOUNTS:-false} != true ]]; then
        exec unshare --mount --propagation private \
            env DEBIANZFS_PRIVATE_MOUNTS=true bash "$REPO_DIR/install.sh" "$@"
    fi
    detect_boot_mode
    ui_init
    trap 'installer_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit "$?"' ERR
    exec 9>/run/debianzfs-install.lock
    flock -n 9 || { failhard 'Another installer is running.'; return 1; }
    run_guided_installation
}

# Sourceable for fixtures; executing this file always performs the live checks.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
    exit 0
fi
