#!/usr/bin/env bash
set -Eeuo pipefail
set +x
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
die() { printf '%s\n' "$*" >&2; exit 1; }
DRY_RUN=false
CHROOT_MODE=false
LOGIN_USER=''
while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --chroot)
            (($# >= 2)) || die 'Usage: deploy.sh [--dry-run] [--chroot USER]'
            CHROOT_MODE=true; LOGIN_USER=$2; shift 2 ;;
        *) die 'Usage: deploy.sh [--dry-run] [--chroot USER]' ;;
    esac
done
if [[ $CHROOT_MODE == true ]]; then
    [[ $EUID == 0 ]] || die '--chroot USER is root-only.'
    [[ $LOGIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $LOGIN_USER != root ]] || die 'Invalid target user.'
    TARGET_HOME=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
    [[ $TARGET_HOME == /* && $(id -u "$LOGIN_USER") -ge 1000 ]] || die 'A normal target account is required.'
    CONFIG_DIR="$TARGET_HOME/.config"
    DATA_DIR="$TARGET_HOME/.local/share"
    CACHE_DIR="$TARGET_HOME/.cache"
    STATE_DIR="$TARGET_HOME/.local/state/debian-deploy"
else
    TARGET_HOME=$HOME
    CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}
    DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}
    CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}
    STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/debian-deploy
fi
# A root chroot invocation never sources user-writable shell code as root.
# Settings are read as data and validated below; environment overrides win.
if [[ -f $STATE_DIR/settings.sh ]]; then
    while IFS= read -r setting; do
        case $setting in
            GPU_DRIVER=*) [[ -n ${GPU_DRIVER:-} ]] || GPU_DRIVER=${setting#*=} ;;
            VM_GUEST=*) [[ -n ${VM_GUEST:-} ]] || VM_GUEST=${setting#*=} ;;
            VM_SOFTWARE_RENDERING=*) [[ -n ${VM_SOFTWARE_RENDERING:-} ]] || VM_SOFTWARE_RENDERING=${setting#*=} ;;
            USERSHELL=*) [[ -n ${USERSHELL:-} ]] || USERSHELL=${setting#*=} ;;
        esac
    done < "$STATE_DIR/settings.sh"
fi
# shellcheck source=deploy/vars.sh
source "$REPO_DIR/vars.sh"
# A dry run is also useful when reviewing the repository on a non-Debian host.
if command -v dpkg >/dev/null 2>&1; then
    ARCH=$(dpkg --print-architecture)
else
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) ARCH=unknown ;;
    esac
fi
case "$ARCH" in amd64|arm64) ;; *) die "Noctalia's APT repository requires amd64 or arm64." ;; esac
case "$VM_SOFTWARE_RENDERING" in true|false) ;; *) die "VM_SOFTWARE_RENDERING must be true or false." ;; esac
case "$VM_GUEST" in auto|qemu|vmware|none) ;; *) die "VM_GUEST must be auto, qemu, vmware or none." ;; esac

GPU_PACKAGES=()
GUEST_SERVICES=()
case "$GPU_DRIVER" in
    intel)
        [[ "$ARCH" == amd64 ]] || die "The Intel graphics profile requires amd64."
        GPU_PACKAGES=("${INTEL_PACKAGES[@]}") ;;
    amd) GPU_PACKAGES=("${AMD_PACKAGES[@]}") ;;
    nvidia)
        GPU_PACKAGES=("${NVIDIA_PACKAGES[@]}" "linux-image-$ARCH" "linux-headers-$ARCH") ;;
    nouveau) GPU_PACKAGES=("${NOUVEAU_PACKAGES[@]}") ;;
    vm)
        GPU_PACKAGES=("${VM_PACKAGES[@]}")
        if [[ $CHROOT_MODE == true && $VM_GUEST == auto ]]; then
            die '--chroot requires an explicit VM_GUEST (resolve auto before chroot).'
        fi
        if [[ "$VM_GUEST" == auto ]]; then
            VIRTUALIZATION=$(systemd-detect-virt --vm 2>/dev/null || true)
            case "$VIRTUALIZATION" in
                kvm|qemu) VM_GUEST=qemu ;;
                vmware) VM_GUEST=vmware ;;
                *) VM_GUEST=none ;;
            esac
        fi
        case "$VM_GUEST" in
            qemu) GPU_PACKAGES+=("${QEMU_PACKAGES[@]}") ;; # Static unit, started by its virtio device.
            vmware)
                GPU_PACKAGES+=("${VMWARE_PACKAGES[@]}")
                GUEST_SERVICES+=(open-vm-tools.service) ;;
        esac ;;
    *) die "GPU_DRIVER must be intel, amd, nvidia, nouveau or vm." ;;
esac

if "$DRY_RUN"; then
    printf 'Target: Debian 13 Trixie (%s), graphics: %s\n' "$ARCH" "$GPU_DRIVER"
    printf 'Packages: %s\nBackports: %s\nNoctalia: %s\n' "${PACKAGES[*]} ${GPU_PACKAGES[*]}" "${BACKPORTS_PACKAGES[*]}" "${NOCTALIA_PACKAGES[*]}"
    printf 'VM guest: %s; software rendering: %s\n' "$VM_GUEST" "$VM_SOFTWARE_RENDERING"
    printf 'Mode: chroot=%s; user=%s; HOME=%s; config=%s\n' "$CHROOT_MODE" "$LOGIN_USER" "$TARGET_HOME" "$CONFIG_DIR"
    exit 0
fi
source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || die 'This deployment targets Debian 13 Trixie.'
if [[ $CHROOT_MODE == true ]]; then
    as_root() { "$@"; }
else
    [[ $EUID != 0 ]] || die 'Run as your normal sudo-capable user, without sudo in front.'
    [[ -d /run/systemd/system ]] || die 'Standalone deployment requires booted systemd.'
    command -v sudo >/dev/null || die 'Install sudo first.'
    sudo -v
    as_root() { sudo "$@"; }
    LOGIN_USER=$(id -un)
fi
validate_nvidia_kernels() {
    [[ $GPU_DRIVER == nvidia ]] || return 0
    local kernel version found=false
    if [[ $CHROOT_MODE == true ]]; then
        for kernel in /boot/vmlinuz-*; do
            [[ -f $kernel ]] || continue
            found=true
            version=${kernel##*/vmlinuz-}
            dpkg --compare-versions "${version%%-*}" lt 6.16 || die "NVIDIA requires stock Trixie kernels (<6.16); target contains $version."
            [[ -d /usr/src/linux-headers-$version ]] || die "Missing target headers for $version."
        done
        "$found" || die 'No installed target kernel for NVIDIA.'
    else
        version=$(uname -r)
        dpkg --compare-versions "${version%%-*}" lt 6.16 || die 'Boot a stock Trixie kernel (<6.16) before NVIDIA deployment.'
    fi
}
validate_nvidia_kernels
WORK_DIR=$(mktemp -d)
# The installer owns the outer policy during --chroot; standalone deployment
# also suppresses package-triggered starts for the duration of this transaction.
POLICY_SAVED=false
POLICY_ACTIVE=false
restore_policy() {
    if [[ $POLICY_ACTIVE == true ]]; then
        as_root rm -f /usr/sbin/policy-rc.d || return
        if [[ $POLICY_SAVED == true ]]; then
            as_root cp -a "$WORK_DIR/policy.original" /usr/sbin/policy-rc.d || return
        fi
        POLICY_ACTIVE=false
    fi
}
deploy_exit() {
    local result=$?
    trap - EXIT
    set +e
    restore_policy || { ((result != 0)) || result=1; }
    rm -rf -- "$WORK_DIR"
    exit "$result"
}
trap deploy_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then
    as_root cp -a /usr/sbin/policy-rc.d "$WORK_DIR/policy.original"
    POLICY_SAVED=true
fi
POLICY_ACTIVE=true
printf '#!/bin/sh\nexit 101\n' > "$WORK_DIR/policy"
as_root rm -f /usr/sbin/policy-rc.d
as_root install -m 755 "$WORK_DIR/policy" /usr/sbin/policy-rc.d

printf 'Preparing Debian repositories...\n'
as_root apt-get update
as_root apt-get install -y --no-install-recommends ca-certificates curl python3
# Fill in missing official archive components without replacing existing sources.
python3 "$REPO_DIR/scripts/debian-sources.py" /etc/apt > "$WORK_DIR/debian-deploy.sources"
as_root install -m 644 "$WORK_DIR/debian-deploy.sources" /etc/apt/sources.list.d/debian-deploy.sources

printf 'Preparing the Noctalia repository...\n'
curl --fail --location --retry 3 --output "$WORK_DIR/nickh-archive-keyring.deb" \
    https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb
curl --fail --location --retry 3 --output "$WORK_DIR/noctalia-trixie.sources" \
    https://pkg.noctalia.dev/deb/noctalia-trixie.sources
[[ -s "$WORK_DIR/noctalia-trixie.sources" ]] || die "The Noctalia repository definition is empty."
as_root dpkg -i "$WORK_DIR/nickh-archive-keyring.deb"
as_root install -m 644 "$WORK_DIR/noctalia-trixie.sources" /etc/apt/sources.list.d/noctalia-trixie.sources
as_root apt-get update

# Keep applications on their normal candidates (including security updates).
# Graphics, PipeWire and WirePlumber use exact-version dependencies within their
# stacks, so let APT select matching versions with the backports libraries.
INSTALL_PACKAGES=()
for package in "${PACKAGES[@]}" "${GPU_PACKAGES[@]}" "${NOCTALIA_PACKAGES[@]}"; do
    case "$package" in
        libgl1-mesa-dri|libegl-mesa0|mesa-*|nvidia-*|libnvidia-*|pipewire-*|wireplumber|libspa-0.2-bluetooth)
            INSTALL_PACKAGES+=("$package")
            continue ;;
    esac
    candidate=$(LC_ALL=C apt-cache policy "$package" | awk '$1 == "Candidate:" { print $2; exit }')
    [[ -n "$candidate" && "$candidate" != '(none)' ]] || die "No APT candidate for $package. Check the configured repositories."
    INSTALL_PACKAGES+=("$package=$candidate")
done
BACKPORTS_REQUESTS=()
for package in "${BACKPORTS_PACKAGES[@]}"; do BACKPORTS_REQUESTS+=("$package/trixie-backports"); done
INSTALL_PACKAGES+=("${BACKPORTS_REQUESTS[@]}")
# Simulate the exact transaction before changing desktop packages or configs.
as_root apt-get --simulate -t trixie-backports install --no-install-recommends "${INSTALL_PACKAGES[@]}"
printf 'Installing the desktop and graphics packages...\n'
as_root apt-get install -y --no-install-recommends -t trixie-backports "${INSTALL_PACKAGES[@]}"

validate_nvidia_kernels

HYPRLAND_VERSION=$(dpkg-query -W -f='${Version}' hyprland)
dpkg --compare-versions "$HYPRLAND_VERSION" ge 0.55 || die "The Lua configuration requires Hyprland 0.55 or newer; installed: $HYPRLAND_VERSION"
for executable in Hyprland start-hyprland noctalia Thunar firefox-esr alacritty zsh nvim grim slurp wl-copy gio; do
    command -v "$executable" >/dev/null || die "The required program $executable is missing after package installation."
done


printf 'Configuring graphics and login shell...\n'
if [[ $GPU_DRIVER == nvidia ]]; then
    printf '%s\n' 'options nvidia_drm modeset=1 fbdev=1' > "$WORK_DIR/nvidia.conf"
    as_root install -D -m 644 "$WORK_DIR/nvidia.conf" /etc/modprobe.d/debian-deploy-nvidia.conf
elif [[ -e /etc/modprobe.d/debian-deploy-nvidia.conf ]]; then
    as_root rm /etc/modprobe.d/debian-deploy-nvidia.conf
fi
if [[ $CHROOT_MODE != true ]]; then as_root update-initramfs -u -k all; fi
[[ $USERSHELL == /* && -x $USERSHELL ]] || die "Invalid shell: $USERSHELL"
as_root chsh -s "$USERSHELL" "$LOGIN_USER"
# Every user-created file, download, font cache and symlink belongs to the user.
user_environment=(env -i HOME="$TARGET_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER"
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 SHELL="$USERSHELL"
    XDG_CONFIG_HOME="$CONFIG_DIR" XDG_DATA_HOME="$DATA_DIR"
    XDG_STATE_HOME="${STATE_DIR%/debian-deploy}" XDG_CACHE_HOME="$CACHE_DIR"
    GPU_DRIVER="$GPU_DRIVER" VM_GUEST="$VM_GUEST" VM_SOFTWARE_RENDERING="$VM_SOFTWARE_RENDERING" USERSHELL="$USERSHELL")
if [[ $CHROOT_MODE == true ]]; then
    runuser -u "$LOGIN_USER" -- "${user_environment[@]}" bash "$REPO_DIR/scripts/user-setup.sh"
else
    "${user_environment[@]}" bash "$REPO_DIR/scripts/user-setup.sh"
fi
printf 'Enabling services offline...\n'
as_root systemctl --root=/ --no-reload disable networking.service systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
as_root systemctl --root=/ --no-reload mask networking.service systemd-networkd.service systemd-networkd.socket
as_root systemctl --root=/ --no-reload enable "${SERVICES[@]}" "${GUEST_SERVICES[@]}"
printf '\nDeployment complete. Reboot and log in on TTY1 to start Hyprland.\n'
