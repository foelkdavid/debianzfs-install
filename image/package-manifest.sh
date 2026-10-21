#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=deploy/vars.sh
# shellcheck disable=SC2153 # Package arrays are populated by vars.sh.
source "$ROOT/deploy/vars.sh"

BASE_PACKAGES=(
    debootstrap gdisk dosfstools rsync inotify-tools parted util-linux kmod
    curl kbd psmisc console-setup keyboard-configuration xkb-data openssl mokutil
    procps zfsutils-linux zfs-dkms zfs-initramfs zfs-zed dkms
    firmware-iwlwifi firmware-realtek
    sudo locales efibootmgr systemd-sysv systemd-resolved plymouth plymouth-themes
)
LIVE_PACKAGES=(
    live-boot live-config live-config-systemd systemd-sysv sudo zsh dbus-user-session
    network-manager wpasupplicant wireless-regdb bluez pipewire-audio wireplumber
    desktop-base xwayland xkb-data plymouth plymouth-themes
    debootstrap gdisk dosfstools rsync inotify-tools parted util-linux kmod curl kbd
    psmisc console-setup keyboard-configuration xkb-data openssl mokutil procps
    zfsutils-linux zfs-dkms zfs-initramfs zfs-zed dkms linux-image-amd64
    linux-headers-amd64 efibootmgr systemd-resolved
)

declare -a packages=()
case "${1:-}" in
    base)
        packages=("${BASE_PACKAGES[@]}")
        ;;
    live)
        # Package arrays are populated by vars.sh.
        # shellcheck disable=SC2153
        packages=("${LIVE_PACKAGES[@]}" "${PACKAGES[@]}" "${INTEL_PACKAGES[@]}")
        ;;
    cache)
        packages=("${PACKAGES[@]}" "${NOCTALIA_PACKAGES[@]}")
        case "${2:-all}" in
            all)
                packages+=("${INTEL_PACKAGES[@]}" "${AMD_PACKAGES[@]}" "${NVIDIA_PACKAGES[@]}"
                    "${NOUVEAU_PACKAGES[@]}" "${VM_PACKAGES[@]}" "${QEMU_PACKAGES[@]}" "${VMWARE_PACKAGES[@]}")
                ;;
            intel) packages+=("${INTEL_PACKAGES[@]}") ;;
            amd) packages+=("${AMD_PACKAGES[@]}") ;;
            nvidia) packages+=("${NVIDIA_PACKAGES[@]}") ;;
            nouveau) packages+=("${NOUVEAU_PACKAGES[@]}") ;;
            vm) packages+=("${VM_PACKAGES[@]}") ;;
            *) printf 'Unknown GPU profile: %s\n' "$2" >&2; exit 2 ;;
        esac
        ;;
    *) printf 'Usage: %s base|live|cache\n' "$0" >&2; exit 2 ;;
esac

declare -A seen=()
backports=()
if [[ ${1:-} == live ]]; then
    for package in "${BACKPORTS_PACKAGES[@]}"; do
        backports+=("$package/trixie-backports")
    done
fi
for package in "${packages[@]}" "${backports[@]}"; do
    [[ -n ${seen[$package]:-} ]] && continue
    seen[$package]=1
    printf '%s\n' "$package"
done
