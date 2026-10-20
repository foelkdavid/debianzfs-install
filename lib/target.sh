#!/usr/bin/env bash

revalidate_disks() {
    [[ ${INSTALL_CONFIRMED:-false} == true ]] || { failhard 'Explicit start is required.'; return 1; }
    [[ $BOOT_MODE == UEFI ]] || return 1
    local -a disks=("$DEBIAN_DISK1")
    if [[ $DEBIAN_MIRROR_MODE == true ]]; then
        [[ $(readlink -f "$DEBIAN_DISK1") != "$(readlink -f "$DEBIAN_DISK2")" ]] || {
            failhard 'Mirror members refer to the same disk.'; return 1;
        }
        disks+=("$DEBIAN_DISK2")
    fi
    local disk node size minimum type swaps pools device_tree
    swaps=$(swapon --show --noheadings --raw --output NAME)
    pools=$(zpool status -LP 2>/dev/null || true)
    for disk in "${disks[@]}"; do
        whole_disk "$disk" || { failhard "Not a whole disk: $disk"; return 1; }
        [[ $(lsblk -dnro RO "$disk") == 0 ]] || { failhard "Read-only disk: $disk"; return 1; }
        size=$(blockdev --getsize64 "$disk")
        minimum=8
        [[ $DEBIAN_DESKTOP != true ]] || minimum=24
        minimum=$(((minimum + DEBIAN_SWAPSIZE) * 1024 * 1024 * 1024 + 536870912))
        ((size >= minimum)) || { failhard "Insufficient capacity: $disk (need $minimum bytes)"; return 1; }
        device_tree=$(lsblk -nrpo NAME,TYPE "$disk")
        [[ -n $device_tree ]] || return 1
        while read -r node type; do
            if findmnt -rn -S "$node" >/dev/null || [[ $type != disk && $type != part ]]; then
                failhard "Mounted or mapped/in-use device: $node"; return 1
            fi
            if [[ -n $(find "/sys/class/block/${node##*/}/holders" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
                failhard "Device has active holders: $node"; return 1
            fi
            if [[ $'\n'$swaps$'\n' == *$'\n'"$node"$'\n'* ]] || \
                awk -v device="$node" '$1 == device {found=1} END {exit !found}' <<< "$pools" || \
                fuser -s "$node"; then
                failhard "Swap, pool or open device in use: $node"; return 1
            fi
        done <<< "$device_tree"
    done
    if zpool list -H -o name | grep -qx zroot; then
        failhard 'A pool named zroot is already imported.'; return 1
    fi
    if mountpoint -q "$TARGET" || [[ -d $TARGET && -n $(ls -A "$TARGET") ]]; then
        failhard "Target must be empty and unmounted: $TARGET"; return 1
    fi
    https_check "${DEBIAN_MIRROR%/}/dists/$DEBIAN_RELEASE/Release"
    if [[ $DEBIAN_DESKTOP == true ]]; then
        getent ahosts github.com >/dev/null
        getent ahosts pkg.noctalia.dev >/dev/null
        https_check https://github.com https://pkg.noctalia.dev/deb/noctalia-trixie.sources
    fi
}

install_target_policy() {
    local policy="$TARGET/usr/sbin/policy-rc.d"
    if [[ -e $policy || -L $policy ]]; then
        cp -a -- "$policy" "$WORK_DIR/policy-rc.d.original"
        POLICY_EXISTED=true
    fi
    POLICY_ACTIVE=true
    rm -f -- "$policy"
    printf '#!/bin/sh\nexit 101\n' > "$policy"
    chmod 755 "$policy"
}

restore_target_policy() {
    [[ ${POLICY_ACTIVE:-false} == true ]] || return 0
    rm -f -- "$TARGET/usr/sbin/policy-rc.d" || return
    if [[ ${POLICY_EXISTED:-false} == true ]]; then
        cp -a -- "$WORK_DIR/policy-rc.d.original" "$TARGET/usr/sbin/policy-rc.d" || return
    fi
    POLICY_ACTIVE=false
}

prepare_target_dns() {
    # Dereference the live resolver, including systemd-resolved's stub symlink.
    # Its nameserver remains reachable over the shared network namespace.
    rm -f -- "$TARGET/etc/resolv.conf"
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
    chmod 644 "$TARGET/etc/resolv.conf"
}

mount_bundled_apt_cache() {
    # The purpose-built live ISO carries the package closure needed by the
    # installer and all deployment GPU profiles. Standard Debian live media
    # has no cache directory and continues using its configured mirrors.
    local source=${DEBIANZFS_IMAGE_CACHE:-/opt/debianzfs-install/cache}
    [[ -s $source/Packages && -s $source/debootstrap-trixie-amd64.tar ]] || return 0
    install -d -m 755 "$TARGET/mnt/debianzfs-cache"
    install -d -m 755 "$TARGET/etc/apt/preferences.d"
    mount --bind "$source" "$TARGET/mnt/debianzfs-cache"
    mount -o remount,bind,ro "$TARGET/mnt/debianzfs-cache"
    IMAGE_CACHE_MOUNTED=true
    cat > "$TARGET/etc/apt/sources.list.d/debianzfs-image-cache.list" <<'EOF'
deb [trusted=yes] file:/mnt/debianzfs-cache ./
EOF
    cat > "$TARGET/etc/apt/preferences.d/debianzfs-image-cache" <<'EOF'
Package: *
Pin: release o=DebianZFSInstaller
Pin-Priority: 1001
EOF
    printf 'Using the ISO package cache for Debian and desktop packages.\n'
}

remove_bundled_apt_cache_config() {
    [[ ${IMAGE_CACHE_MOUNTED:-false} == true ]] || return 0
    rm -f "$TARGET/etc/apt/sources.list.d/debianzfs-image-cache.list" \
        "$TARGET/etc/apt/preferences.d/debianzfs-image-cache"
}

configure_networking() {
    if [[ $DEBIAN_DESKTOP == true ]]; then
        chroot_run systemctl --root=/ --no-reload disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
        chroot_run systemctl --root=/ --no-reload mask systemd-networkd.service systemd-networkd.socket
        mkdir -p "$TARGET/etc/NetworkManager/system-connections" "$TARGET/etc/NetworkManager/conf.d"
        cat > "$TARGET/etc/NetworkManager/conf.d/20-installer.conf" <<'EOF'
[main]
no-auto-default=*
EOF
        if [[ $DEBIAN_ENABLE_DHCP == true ]]; then
            cat > "$TARGET/etc/NetworkManager/system-connections/wired.nmconnection" <<'EOF'
[connection]
id=Wired DHCP
type=ethernet
autoconnect=true
[ethernet]
[ipv4]
method=auto
[ipv6]
method=disabled
EOF
            chmod 600 "$TARGET/etc/NetworkManager/system-connections/wired.nmconnection"
        fi
        chroot_run systemctl --root=/ --no-reload enable NetworkManager.service
        rm -f -- "$TARGET/etc/resolv.conf"
        ln -s /run/NetworkManager/resolv.conf "$TARGET/etc/resolv.conf"
    else
        apt_install_target systemd-resolved
        chroot_run systemctl --root=/ --no-reload mask NetworkManager.service networking.service
        mkdir -p "$TARGET/etc/systemd/network"
        if [[ $DEBIAN_ENABLE_DHCP == true ]]; then
            cat > "$TARGET/etc/systemd/network/20-wired-ipv4-dhcp.network" <<'EOF'
[Match]
Type=ether
[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
[DHCPv4]
UseDNS=yes
EOF
        fi
        chroot_run systemctl --root=/ --no-reload enable systemd-networkd.service systemd-resolved.service
        rm -f -- "$TARGET/etc/resolv.conf"
        ln -s /run/systemd/resolve/resolv.conf "$TARGET/etc/resolv.conf"
    fi
}

deploy_desktop() {
    [[ $DEBIAN_DESKTOP == true ]] || return 0
    local home="/home/$DEBIAN_SUDOUSER"
    install -d -m 755 "$TARGET$home/.local/deploy"
    cp -a "$REPO_DIR/deploy/." "$TARGET$home/.local/deploy/"
    chroot_run chown -R "$DEBIAN_SUDOUSER:$DEBIAN_SUDOUSER" "$home/.local"
    # VM_GUEST is resolved by the live setup, never by chroot's systemd view.
    chroot_run env GPU_DRIVER="$GPU_DRIVER" VM_GUEST="$VM_GUEST" \
        VM_SOFTWARE_RENDERING="$VM_SOFTWARE_RENDERING" \
        DEBIANZFS_APT_CACHE="$( [[ ${IMAGE_CACHE_MOUNTED:-false} == true ]] && printf /mnt/debianzfs-cache )" \
        bash "$home/.local/deploy/deploy.sh" --chroot "$DEBIAN_SUDOUSER"
}

run_installation() {
    # All destructive entry points go through this guard.
    [[ ${INSTALL_CONFIRMED:-false} == true ]] || { failhard 'Explicit start is required.'; return 1; }
    run_stage 'Revalidate disks and chosen mirror' revalidate_disks
    run_stage 'Prepare disk variables' set_zfs_vars
    run_stage 'Erase selected disks' wipe_disks
    run_stage 'Partition selected disks' partition_disks
    run_stage 'Create ZFS pool and datasets' setup_zfs
    run_stage 'Install Debian base and kernel' install_base_system
    run_stage 'Prepare EFI partitions' configure_efi_partitions
    run_stage 'Configure base system' configure_system
    run_stage 'Create user account' setup_user
    if [[ $DEBIAN_DESKTOP == true ]]; then
        run_stage 'Deploy Hyprland desktop' deploy_desktop
    fi
    run_stage 'Configure networking' configure_networking
    run_stage 'Remove image cache configuration' remove_bundled_apt_cache_config
    run_stage 'Configure initramfs' configure_initramfs
    run_stage 'Configure swap' setup_swap
    run_stage 'Install snapshot service' install_zfs_autosnap
    run_stage 'Install mirrored EFI service' install_efisync
    run_stage 'Rebuild final initramfs' rebuild_initramfs
    run_stage 'Install ZFSBootMenu' setup_zfsbootmenu
    run_stage 'Synchronize mirrored ESPs' sync_esps
}

persist_target_log() {
    [[ ${TARGET_MOUNTED:-false} == true ]] || return 0
    # A failed export may be retried after the target was already unmounted.
    # Never create log files in the underlying live mountpoint on that retry.
    mountpoint -q "$TARGET" || return 0
    install -d -m 700 "$TARGET/var/log/debianzfs-install" || return
    install -m 600 "$LOG_FILE" "$TARGET/var/log/debianzfs-install/" || return
}

cleanup_target() {
    # Explicit return handling: this function is also called with errexit off
    # in EXIT and must preserve failures without abandoning safe cleanup.
    local failed=0 path
    restore_target_policy || failed=1
    remove_bundled_apt_cache_config || failed=1
    unset USER_PASSWORD ZFS_PASSPHRASE
    if [[ -n ${WORK_DIR:-} && -f $WORK_DIR/zroot.key ]]; then
        rm -f -- "$WORK_DIR/zroot.key" || failed=1
    fi
    if [[ ${POOL_OWNED:-false} == true ]]; then
        for path in mnt/debianzfs-cache run sys proc dev boot/efi2 boot/efi; do
            if mountpoint -q "$TARGET/$path"; then
                umount -R "$TARGET/$path" || failed=1
            fi
        done
        # Keep target logs through the policy restore and child unmounts. The
        # live log remains authoritative for final unmount/export outcomes.
        persist_target_log || failed=1
        if ((failed == 0)); then
            if mountpoint -q "$TARGET/home"; then zfs unmount zroot/home || failed=1; fi
            if mountpoint -q "$TARGET"; then
                if zfs unmount zroot/ROOT/debian; then TARGET_MOUNTED=false; else failed=1; fi
            fi
            if zpool export zroot; then
                POOL_OWNED=false
                TARGET_MOUNTED=false
                printf 'Pool exported successfully.\n'
            else
                failed=1
            fi
        fi
    fi
    return "$failed"
}

installer_exit() {
    local result=$1 cleanup_result=0
    trap - EXIT ERR INT TERM
    set +e
    # EXIT may run inside a failed function while its FIFO redirection is
    # still active. Close both writer descriptors before waiting for EOF.
    exec 1>&3 2>&3
    drain_stage
    ui_restore
    if ((result)); then
        printf '\n' >&3
        failhard "$CURRENT_STAGE (exit $result)" 2>&3
        stage_preview >&3
        printf '[%s] [failed] %s (exit %s)\n' "$(date -u +%FT%TZ)" "$CURRENT_STAGE" "$result" >> "$LOG_FILE"
    fi
    if [[ ${CLEANED:-false} != true ]]; then
        cleanup_target >> "$LOG_FILE" 2>&1
        cleanup_result=$?
    fi
    ((result != 0 || cleanup_result == 0)) || result=$cleanup_result
    printf 'Live log retained: %s\n' "$LOG_FILE" >&3
    if ((cleanup_result)); then
        printf 'Cleanup incomplete; inspect the log and remaining target mounts/pool before rebooting.\n' >&3
    fi
    if ((cleanup_result == 0)); then
        [[ -z ${WORK_DIR:-} ]] || rm -rf -- "$WORK_DIR"
    else
        printf 'Cleanup backups retained in: %s\n' "$WORK_DIR" >&3
    fi
    exit "$result"
}
