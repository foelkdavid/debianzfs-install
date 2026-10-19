#!/usr/bin/env bash
# Shared globals are consumed by the installer/deployment.
# shellcheck disable=SC2034

detect_boot_mode() {
    BOOT_MODE='Legacy BIOS'
    [[ ! -d /sys/firmware/efi ]] || BOOT_MODE=UEFI
}

root_privileges_check() { [[ $EUID == 0 ]]; }

live_environment_check() {
    local ID='' VERSION_CODENAME=''
    source /etc/os-release
    [[ $ID == debian && $VERSION_CODENAME == trixie ]] || {
        failhard 'Use an official Debian 13 Trixie live image.'; return 1;
    }
    if [[ ! -d /run/live/rootfs ]] || ! mountpoint -q /run/live/medium; then
        failhard 'A booted Debian live environment is required.'; return 1
    fi
    [[ $(dpkg --print-architecture) == amd64 ]]
}

bundled_files_check() {
    local file
    for file in lib/{ui,config,target}.sh services/efisync/{efisync.sh,efisync.service} \
        services/zfs-autosnap/{zfs-autosnap.sh,zfs-autosnap-status.sh,zfs-autosnap.service,jobs.conf} \
        deploy/{deploy.sh,vars.sh,scripts/debian-sources.py,scripts/user-setup.sh} \
        deploy/dotfiles/{hypr/hyprland.lua,alacritty/alacritty.toml,gtk-3.0/settings.ini,nvim/init.lua,nvim/lua/options.lua,zsh/zshrc,zsh/aliases,zsh/getplugins.sh,fonts/getfonts.sh}; do
        [[ -s $REPO_DIR/$file ]] || { failhard "Missing bundled file: $file"; return 1; }
    done
}

https_check() {
    local url
    for url in "$@"; do
        if command -v curl >/dev/null; then
            curl --fail --location --silent --show-error --connect-timeout 15 --max-time 45 \
                --head --output /dev/null "$url" || return
        elif command -v wget >/dev/null; then
            wget --quiet --timeout=45 --tries=1 --spider "$url" || return
        else
            failhard 'Install curl or wget and ca-certificates in the live environment first.'
            return 1
        fi
    done
}

source_connectivity_check() {
    local host
    for host in deb.debian.org security.debian.org get.zfsbootmenu.org; do
        getent ahosts "$host" >/dev/null || return 1
    done
    https_check https://deb.debian.org/debian/dists/trixie/Release \
        https://security.debian.org/debian-security/dists/trixie-security/Release \
        https://get.zfsbootmenu.org/efi/release
}

run_prechecks() {
    local -a labels=('Root privileges' 'Detected boot mode' 'Debian 13 live / amd64' 'Required bundled files' 'DNS and HTTPS sources')
    local -a checks=('root' 'boot' 'live' 'files' 'network')
    local -a states=(pending pending pending pending pending)
    local i j result=0
    for i in "${!checks[@]}"; do
        CURRENT_STAGE="Preflight: ${labels[i]}"
        states[i]=running
        screen_header
        for j in "${!labels[@]}"; do printf '[%s] %s\n' "${states[j]}" "${labels[j]}" >&3; done
        # Functions in this conditional must explicitly propagate each error.
        case ${checks[i]} in
            root) root_privileges_check && result=0 || result=1 ;;
            boot) result=0 ;; # BIOS is a detected mode, not a detection failure.
            live) live_environment_check && result=0 || result=1 ;;
            files) bundled_files_check && result=0 || result=1 ;;
            network) source_connectivity_check && result=0 || result=1 ;;
        esac > "$WORK_DIR/preflight.log" 2>&1
        cat "$WORK_DIR/preflight.log" >&3
        cat "$WORK_DIR/preflight.log" >> "$LOG_FILE"
        if ((result)); then states[i]=failed; else states[i]=passed; fi
        printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "${states[i]}" "${labels[i]}" >> "$LOG_FILE"
        ((result == 0)) || { failhard "Preflight: ${labels[i]}"; return 1; }
        if [[ ${checks[i]} == boot && $BOOT_MODE == 'Legacy BIOS' ]]; then
            screen_header
            printf '[passed] Boot mode detected: Legacy BIOS\nBIOS installation support is pending another branch. No installation changes made.\n' >&3
            return 1
        fi
    done
    screen_header
    for j in "${!labels[@]}"; do printf '[%s] %s\n' "${states[j]}" "${labels[j]}" >&3; done
}

install_host_requirements() {
    printf 'Preparing packages in the live environment only.\n'
    cat > "$HOST_APT_SOURCE" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE $DEBIAN_COMPONENTS
deb $DEBIAN_MIRROR ${DEBIAN_RELEASE}-updates $DEBIAN_COMPONENTS
deb https://security.debian.org/debian-security ${DEBIAN_RELEASE}-security $DEBIAN_COMPONENTS
EOF
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates debootstrap gdisk dosfstools rsync inotify-tools parted \
        util-linux kmod curl kbd psmisc console-setup keyboard-configuration xkb-data \
        openssl mokutil zfsutils-linux procps
    if ! modprobe zfs; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            dkms "linux-headers-$(uname -r)" zfs-dkms
        modprobe zfs
    fi
}

validate_live_tools() {
    local tool
    for tool in zgenhostid zpool zfs debootstrap sgdisk wipefs partprobe udevadm \
        mkfs.vfat rsync chroot runuser blkid findmnt lsblk blockdev flock curl fuser swapon mountpoint; do
        command -v "$tool" >/dev/null || { failhard "Missing tool: $tool"; return 1; }
    done
    modprobe zfs
    [[ -d /sys/module/zfs ]]
}

reset_configuration() {
    unset DEBIAN_DISK1 DEBIAN_DISK2 DEBIAN_MIRROR_MODE DEBIAN_SWAPSIZE \
        DEBIAN_HOSTNAME DEBIAN_SUDOUSER DEBIAN_TIMEZONE DEBIAN_KEYMAP \
        DEBIAN_DESKTOP GPU_DRIVER VM_GUEST VM_SOFTWARE_RENDERING DEBIAN_ENCRYPTION \
        USER_PASSWORD ZFS_PASSPHRASE INSTALL_CONFIRMED
    DEBIAN_ENABLE_DHCP=true
    DEBIAN_MIRROR=https://deb.debian.org/debian
}

print_preconf_header() {
    screen_header
    printf 'Configuration — Debian %s / amd64\n' "$DEBIAN_RELEASE" >&3
    printf '  Console keyboard: %-12s IPv4 DHCP: %s\n' "${DEBIAN_KEYMAP:-unset}" "${DEBIAN_ENABLE_DHCP:-unset}" >&3
    printf '  ERASE disk 1: %s\n  ERASE disk 2: %s\n' "${DEBIAN_DISK1:-unset}" "${DEBIAN_DISK2:-unset}" >&3
    printf '  ZFS mirror: %-18s Swap GiB per disk: %s\n' "${DEBIAN_MIRROR_MODE:-unset}" "${DEBIAN_SWAPSIZE:-unset}" >&3
    printf '  Debian mirror: %s\n' "${DEBIAN_MIRROR:-unset}" >&3
    printf '  ZFS encryption: %s\n' "${DEBIAN_ENCRYPTION:-unset}" >&3
    printf '  Hostname: %-20s Username: %s\n' "${DEBIAN_HOSTNAME:-unset}" "${DEBIAN_SUDOUSER:-unset}" >&3
    printf '  Timezone: %s\n' "${DEBIAN_TIMEZONE:-unset}" >&3
    printf '  Desktop deployment: %-10s GPU profile: %s\n' "${DEBIAN_DESKTOP:-unset}" "${GPU_DRIVER:-unset}" >&3
    printf '  VM integration: %-14s Software rendering: %s\n' "${VM_GUEST:-unset}" "${VM_SOFTWARE_RENDERING:-unset}" >&3
    printf '  Account password: %-12s ZFS passphrase: %s\n' \
        "$([[ -n ${USER_PASSWORD:-} ]] && echo set || echo unset)" \
        "$([[ -n ${ZFS_PASSPHRASE:-} ]] && echo set || echo unset)" >&3
    printf '  Network manager: %s\n\n' "$([[ ${DEBIAN_DESKTOP:-false} == true ]] && echo NetworkManager || echo systemd-networkd)" >&3
}

ask() {
    local variable=$1 prompt=$2 default=${3:-} response
    print_preconf_header
    if [[ $variable == DEBIAN_DISK1 || $variable == DEBIAN_DISK2 ]]; then
        lsblk -dpno NAME,SIZE,MODEL,TYPE >&3
    fi
    read -r -p "$prompt " response || return 1
    printf -v "$variable" '%s' "${response:-$default}"
}

ask_bool() {
    local variable=$1 prompt=$2 default=$3 answer
    while :; do
        ask answer "$prompt" "$default"
        case ${answer,,} in
            y|yes) printf -v "$variable" true; break ;;
            n|no) printf -v "$variable" false; break ;;
            *) printf 'Answer y or n.\n' >&3 ;;
        esac
    done
}

validate_hostname() {
    ((${#1} <= 253)) && [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}
validate_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
validate_timezone() { [[ $1 != /* && $1 != *..* && -f /usr/share/zoneinfo/$1 ]]; }
validate_keymap() {
    [[ $1 =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 1
    loadkeys -q "$1" >/dev/null 2>&1 && return 0
    [[ -f /usr/share/X11/xkb/rules/base.lst ]] || return 1
    awk '$1=="!" { layout=($2=="layout"); next } layout && $1==key { found=1 } END {exit !found}' \
        key="$1" /usr/share/X11/xkb/rules/base.lst
}

apply_keymap() {
    if loadkeys "$DEBIAN_KEYMAP" >/dev/null 2>&1; then return 0; fi
    cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$DEBIAN_KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    if ! setupcon -k --force >/dev/null 2>&1; then
        printf 'Console keymap could not be applied here; it will be configured in the target.\n' >&3
    fi
}

ask_validated() {
    local variable=$1 prompt=$2 validator=$3 default=${4:-}
    while :; do
        ask "$variable" "$prompt" "$default"
        "$validator" "${!variable}" && break
        printf 'Invalid value; try again.\n' >&3
    done
}

get_secret() {
    local variable=$1 label=$2 first second
    while :; do
        print_preconf_header
        if [[ $variable == ZFS_PASSPHRASE ]]; then
            printf 'ZFSBootMenu uses a US keyboard for unlock.\n' >&3
        fi
        read -r -s -p "$label: " first || return 1; printf '\n' >&3
        read -r -s -p "Confirm $label: " second || return 1; printf '\n' >&3
        if [[ -n $first && $first == "$second" ]]; then
            if [[ $variable != ZFS_PASSPHRASE || (${#first} -ge 8 && ${#first} -le 512) ]]; then
                printf -v "$variable" '%s' "$first"
                unset first second
                return 0
            fi
        fi
        printf 'Values must match and be nonempty (ZFS: 8–512 characters).\n' >&3
    done
}

resolve_vm_guest() {
    case $(systemd-detect-virt --vm 2>/dev/null || true) in
        kvm|qemu) printf qemu ;;
        vmware) printf vmware ;;
        *) printf none ;;
    esac
}

get_desktop_inputs() {
    ask_bool DEBIAN_DESKTOP 'Run desktop deployment too? (y/n) [Y]' y
    [[ $DEBIAN_DESKTOP == true ]] || return 0
    while :; do
        ask GPU_DRIVER 'GPU profile (intel/amd/nvidia/nouveau/vm) [intel]:' intel
        case $GPU_DRIVER in intel|amd|nvidia|nouveau|vm) break ;; esac
    done
    VM_GUEST=none
    VM_SOFTWARE_RENDERING=false
    if [[ $GPU_DRIVER == vm ]]; then
        local guest
        while :; do
            ask guest 'VM integration (auto/qemu/vmware/none) [auto]:' auto
            case $guest in
                auto) VM_GUEST=$(resolve_vm_guest); break ;;
                qemu|vmware|none) VM_GUEST=$guest; break ;;
            esac
        done
        ask_bool VM_SOFTWARE_RENDERING 'Use software rendering? (y/n) [N]' n
    fi
}

whole_disk() { [[ -b $1 && $(lsblk -dnro TYPE "$1") == disk ]]; }
valid_swap() { [[ $1 =~ ^[0-9]{1,4}$ || ${1,,} == none ]]; }
valid_mirror() { [[ $1 =~ ^https?://[A-Za-z0-9./:_-]+$ ]]; }

get_inputs() {
    ask_validated DEBIAN_KEYMAP 'Console keyboard (e.g. de, de-latin1, us) [de]:' validate_keymap de
    apply_keymap
    ask_bool DEBIAN_ENABLE_DHCP 'Enable IPv4 DHCP on Ethernet? (y/n) [Y]' y
    ask_validated DEBIAN_DISK1 'Whole disk to ERASE (full /dev/path):' whole_disk
    DEBIAN_DISK1=$(readlink -f "$DEBIAN_DISK1")
    ask_bool DEBIAN_MIRROR_MODE 'Create a ZFS mirror? (y/n) [N]' n
    if [[ $DEBIAN_MIRROR_MODE == true ]]; then
        while :; do
            ask_validated DEBIAN_DISK2 'Second whole disk to ERASE:' whole_disk
            DEBIAN_DISK2=$(readlink -f "$DEBIAN_DISK2")
            [[ $DEBIAN_DISK2 != "$DEBIAN_DISK1" ]] && break
            printf 'Mirror members must be different disks.\n' >&3
        done
    fi
    ask_validated DEBIAN_MIRROR 'Debian mirror [https://deb.debian.org/debian]:' valid_mirror "$DEBIAN_MIRROR"
    ask_validated DEBIAN_SWAPSIZE 'Swap GiB per disk (0 disables) [0]:' valid_swap 0
    if [[ ${DEBIAN_SWAPSIZE,,} == none ]]; then DEBIAN_SWAPSIZE=0; else DEBIAN_SWAPSIZE=$((10#$DEBIAN_SWAPSIZE)); fi
    ask_bool DEBIAN_ENCRYPTION 'Encrypt ZFS? (y/n) [Y]' y
    ask_validated DEBIAN_HOSTNAME 'Hostname:' validate_hostname
    ask_validated DEBIAN_SUDOUSER 'Username:' validate_username
    ask_validated DEBIAN_TIMEZONE 'Timezone [Europe/Vienna]:' validate_timezone Europe/Vienna
    get_desktop_inputs
    get_secret USER_PASSWORD 'Account password'
    if [[ $DEBIAN_ENCRYPTION == true ]]; then
        get_secret ZFS_PASSPHRASE 'ZFS passphrase (8–512 characters)'
    fi
}

confirm_menu() {
    local answer
    printf 'The ERASE disks above will be completely wiped.\n' >&3
    while :; do
        read -r -p '[s] Start installation  [r] Restart configuration  [e] Exit: ' answer || return 20
        case ${answer,,} in s|start) return 0 ;; r) return 10 ;; e) return 20 ;; esac
    done
}
