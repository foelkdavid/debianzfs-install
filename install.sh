#!/usr/bin/env bash

# Safety guard: Debian live/rescue environments vary, but this avoids running
# from an ordinary installed workstation unless the operator opts out.
DEBIAN_CHECK_HOSTNAME=true

DEBIAN_RELEASE=trixie
DEBIAN_MIRROR=http://deb.debian.org/debian
DEBIAN_COMPONENTS="main contrib non-free-firmware"
DEBIAN_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
DEBIAN_ENABLE_DHCP=true
HOST_APT_SOURCE=/etc/apt/sources.list.d/debianzfs-install-host.list

set -Eeo pipefail

R="\033[0;31m"
G="\033[0;32m"
Y="\033[0;33m"
P="\033[0;35m"
LB="\033[1;34m"
NC="\033[0m"

ok() { printf "  %b %s\n" "${G}OK${NC}" "$1"; }
fail() { printf "  %b %s\n" "${R}FAIL${NC}" "$1"; }
failhard() { printf "  %b\n" "${R}FAIL $1${NC}"; }
info() { printf "%b%s%b\n" "$P" "$1" "$NC"; }
note() { printf "  %b%s%b\n" "$LB" "$1" "$NC"; }

check() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$desc"
	else
		fail "$desc"
		FAILED=1
	fi
}

tail_window() {
	local lines="$1" label="$2" log="/tmp/debianzfs-install-${label}.log" count_file="/tmp/debianzfs-install-${label}.count"
	shift 2

	rm -f "$count_file"
	set +e
	"$@" 2>&1 |
		tee "$log" |
		awk -v n="$lines" -v count_file="$count_file" '
			{
				shown = (count < n ? count : n)
				for (i = 0; i < shown; i++) {
					printf "\033[1A\033[2K"
				}
				buffer[count % n] = $0
				count++
				start = (count > n ? count - n : 0)
				for (j = start; j < count; j++) {
					print buffer[j % n]
				}
				fflush()
			}
			END {
				print count > count_file
			}
		'
	local rc=${PIPESTATUS[0]}
	set -e
	local count=0
	[ -s "$count_file" ] && read -r count <"$count_file"
	rm -f "$count_file"
	local shown="$count"
	[ "$shown" -gt "$lines" ] && shown="$lines"
	[ "$shown" -lt 1 ] && shown=1
	printf "\033[%dA\033[0J" "$shown"
	if [ "$rc" -ne 0 ]; then
		failhard "Command failed; see $log"
	fi
	return "$rc"
}

hostnamecheck() {
	[ "${DEBIAN_CHECK_HOSTNAME}" = true ] || return 0

	local hn
	hn="$(hostname || true)"
	case "$hn" in
	debian | debian-live | rescue | live | localhost) return 0 ;;
	esac

	failhard "Hostname '$hn' is not in the default live/rescue allowlist."
	failhard "Set DEBIAN_CHECK_HOSTNAME=false at the top of this script if this is intentional."
	return 1
}

zfscheck() {
	command -v zgenhostid >/dev/null 2>&1 || {
		failhard "Missing 'zgenhostid' from ZFS utilities."
		return 1
	}

	if ! modprobe -n zfs >/dev/null 2>&1; then
		failhard "Kernel module 'zfs' is not available on this system."
		return 1
	fi
}

servicecheck() {
	local files=(
		"services/efisync/efisync.sh"
		"services/efisync/efisync.service"
		"services/zfs-autosnap/zfs-autosnap.sh"
		"services/zfs-autosnap/zfs-autosnap-status.sh"
		"services/zfs-autosnap/zfs-autosnap.service"
		"services/zfs-autosnap/jobs.conf"
	)

	for f in "${files[@]}"; do
		[[ -e "$f" ]] || {
			failhard "Missing required file: $f"
			return 1
		}
	done
}

run_prechecks() {
	clear
	echo "------------------------"
	echo -e "${G}Debian-ZFS-Installer${NC}"
	echo "------------------------"
	FAILED=0
	check "Running as root" test "$EUID" -eq 0
	check "System booted in EFI mode" test -d /sys/firmware/efi
	check "Hostname safety check" hostnamecheck
	check "Required service files present" servicecheck
	check "apt package manager available" command -v apt-get
	check "Connectivity to 1.1.1.1 (ICMP)" ping -c2 -W2 1.1.1.1
	check "DNS resolution (debian.org)" ping -c2 -W2 debian.org

	if [ "$FAILED" -ne 0 ]; then
		echo
		failhard "Some pre-checks failed; exiting."
		exit 1
	fi

	install_host_requirements

	FAILED=0
	check "Required ZFS host support" zfscheck
	check "debootstrap available" command -v debootstrap
	check "sgdisk available" command -v sgdisk

	if [ "$FAILED" -ne 0 ]; then
		echo
		failhard "Host requirements could not be satisfied; exiting."
		exit 1
	fi
}

install_host_requirements() {
	info "[Installing host-side installer requirements]"
	note "This modifies only the live/rescue environment package state."

	cat >"$HOST_APT_SOURCE" <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} ${DEBIAN_COMPONENTS}
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates ${DEBIAN_COMPONENTS}
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security ${DEBIAN_COMPONENTS}
EOF

	tail_window 8 host-apt-update env DEBIAN_FRONTEND=noninteractive apt-get update
	tail_window 8 host-apt-install env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		ca-certificates debootstrap gdisk dosfstools rsync inotify-tools \
		util-linux kmod curl kbd console-setup keyboard-configuration \
		x11-xkb-utils openssl mokutil zfsutils-linux

	if ! modprobe zfs >/dev/null 2>&1; then
		note "ZFS module is not loaded; trying DKMS for the live kernel."
		tail_window 8 host-zfs-dkms env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
			openssl mokutil dkms "linux-headers-$(uname -r)" zfs-dkms zfsutils-linux
		modprobe zfs
	fi

	ok "Host-side requirements installed"
}

print_preconf_header() {
	clear
	echo "------------------------"
	echo -e "${G}Debian-ZFS-Installer${NC}"
	echo "------------------------"
	echo -e "${Y}[Configuration]${NC}"
	echo -e "  Release      -> [ ${Y}${DEBIAN_RELEASE}${NC} ]"
	echo -e "  Mirror       -> [ ${Y}${DEBIAN_MIRROR}${NC} ]"
	echo -e "  Components   -> [ ${Y}${DEBIAN_COMPONENTS}${NC} ]"
	echo -e "  IPv4 DHCP    -> [ ${Y}${DEBIAN_ENABLE_DHCP}${NC} ]"
	echo -e "  ZFS-Mirror?  -> [ ${Y}${DEBIAN_MIRROR_MODE:-}${NC} ]"
	echo -e "  Disk1        -> [ ${Y}${DEBIAN_DISK1:-}${NC} ] ${DEBIAN_DISK1_SIZE:-}"
	echo -e "  Disk2        -> [ ${Y}${DEBIAN_DISK2:-}${NC} ] ${DEBIAN_DISK2_SIZE:-}"
	echo -e "  Swap(GB)     -> [ ${Y}${DEBIAN_SWAPSIZE:-}${NC} ] ${DEBIAN_MIRROR_MODE:+(per disk; 0 disables swap)}"
	echo -e "  Hostname     -> [ ${Y}${DEBIAN_HOSTNAME:-}${NC} ]"
	echo -e "  Sudo User    -> [ ${Y}${DEBIAN_SUDOUSER:-}${NC} ]"
	echo -e "  Timezone     -> [ ${Y}${DEBIAN_TIMEZONE:-}${NC} ]"
	echo -e "  Keymap       -> [ ${Y}${DEBIAN_KEYMAP:-}${NC} ]"
	echo "------------------------"
}

print_postconf_header() {
	clear
	echo "------------------------"
	echo -e "${G}Debian-ZFS-Installer${NC}"
	echo "------------------------"
	echo -e "${Y}[Installing...]${NC}"
}

get_disks() {
	info "[Select Disk $([[ -n ${DEBIAN_DISK1:-} ]] && echo 2 || echo 1)]"
	disklist="$(lsblk -ndo NAME,SIZE,TYPE -dp | awk '$3=="disk"{printf "  %-20s %s\n", $1, $2}')"
	echo -e "${LB}${disklist}${NC}"
	echo "------------------------"

	while true; do
		read -rp "Enter the full path of the disk you want to use: " chosen_disk
		if ! lsblk -dno NAME -p | grep -qx "$chosen_disk"; then
			failhard "Invalid disk path: ${chosen_disk}"
		elif [[ $chosen_disk == "${DEBIAN_DISK1:-}" ]]; then
			failhard "You already selected this disk: ${chosen_disk}"
		else
			local disk_var="DEBIAN_DISK1" size_var="DEBIAN_DISK1_SIZE"
			[[ -n "${DEBIAN_DISK1:-}" ]] && disk_var="DEBIAN_DISK2" && size_var="DEBIAN_DISK2_SIZE"
			printf -v "$disk_var" "%s" "$chosen_disk"
			read -r disk_size < <(lsblk -dnpo SIZE "$chosen_disk")
			printf -v "$size_var" "(%s)" "$disk_size"
			break
		fi
		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

mirror_decision() {
	while :; do
		read -rp "Do you want to create a ZFS mirror? (y/n) " yn
		[[ -z $yn ]] && echo -ne "\033[1A\033[0J" && continue
		case "${yn,,}" in
		y | yes) DEBIAN_MIRROR_MODE=true && print_preconf_header && get_disks && break ;;
		n | no) DEBIAN_MIRROR_MODE=false && DEBIAN_DISK2=none && echo && break ;;
		*) echo "Please answer y or n." ;;
		esac
	done
}

get_swapsize() {
	info "[Swap Configuration]"
	note "Enter 0 or none to skip swap entirely."
	note "In mirror mode, swap is created on both disks when enabled."
	echo "------------------------"
	while true; do
		read -rp "Enter swap size in GB: " DEBIAN_SWAPSIZE || true
		if [[ "${DEBIAN_SWAPSIZE:-}" =~ ^[0-9]+$ ]]; then
			break
		elif [[ "${DEBIAN_SWAPSIZE,,}" == none ]]; then
			DEBIAN_SWAPSIZE=0
			break
		fi
		failhard "Invalid input. Please enter a non-negative integer or none."
		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

validate_hostname() {
	local h="$1"
	[[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

get_hostname() {
	info "[Set Hostname]"
	echo "------------------------"
	while true; do
		read -rp "Enter hostname for new system: " DEBIAN_HOSTNAME || true
		validate_hostname "$DEBIAN_HOSTNAME" && break
		failhard "Invalid hostname: $DEBIAN_HOSTNAME"
		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

validate_username() {
	local u="$1"
	[[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
	[[ "$u" != "root" ]]
}

get_sudouser() {
	info "[Configure sudo user]"
	echo "------------------------"
	while true; do
		read -rp "Enter username for new system: " DEBIAN_SUDOUSER || true
		validate_username "$DEBIAN_SUDOUSER" && break
		failhard "Invalid username: $DEBIAN_SUDOUSER"
		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

validate_timezone() {
	[ -f "/usr/share/zoneinfo/$1" ]
}

get_timezone() {
	info "[Configure timezone]"
	note "Example: Europe/Vienna"
	echo "------------------------"
	while true; do
		read -rp "Enter timezone: " DEBIAN_TIMEZONE || true
		validate_timezone "$DEBIAN_TIMEZONE" && break
		failhard "Invalid timezone: $DEBIAN_TIMEZONE"
		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

validate_keymap() {
	[[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 1
	loadkeys -q "$1" >/dev/null 2>&1 && return 0
	find /usr/share/keymaps /usr/share/kbd/keymaps -type f \( -name "$1.map.gz" -o -name "$1.map" \) 2>/dev/null | grep -q . && return 0
	local xkb_rules="/usr/share/X11/xkb/rules/base.lst"
	[ -f "$xkb_rules" ] && awk '$1 == "!" && $2 == "layout" { in_layout=1; next } $1 == "!" { in_layout=0 } in_layout && $1 == key { found=1 } END { exit !found }' key="$1" "$xkb_rules"
}

get_keymap() {
	info "[Configure keymap]"
	note "Examples: de, de-latin1, us"
	echo "------------------------"
	while true; do
		read -rp "Enter keymap: " DEBIAN_KEYMAP || true
		if validate_keymap "$DEBIAN_KEYMAP"; then
			apply_keymap "$DEBIAN_KEYMAP"
			break
		fi
		failhard "Invalid keymap: $DEBIAN_KEYMAP"
		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

apply_keymap() {
	local keymap="$1"

	if command -v loadkeys >/dev/null 2>&1 && loadkeys "$keymap" >/dev/null 2>&1; then
		ok "Applied console keymap '$keymap' with loadkeys"
		return 0
	fi

	if command -v setupcon >/dev/null 2>&1; then
		cat >/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${keymap}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
		if setupcon -k --force >/dev/null 2>&1; then
			ok "Applied console keymap '$keymap' with setupcon"
			return 0
		fi
	fi

	if command -v localectl >/dev/null 2>&1 && localectl set-keymap "$keymap" >/dev/null 2>&1; then
		ok "Applied console keymap '$keymap' with localectl"
		return 0
	fi

	if [ -n "${DISPLAY:-}" ] && command -v setxkbmap >/dev/null 2>&1 && setxkbmap "$keymap" >/dev/null 2>&1; then
		ok "Applied X11 keymap '$keymap' with setxkbmap"
		return 0
	fi

	if [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
		note "This appears to be an SSH session; keymap changes must be made on the client side."
	else
		note "Could not apply '$keymap' in this live environment."
	fi
	note "It will still be configured for the installed Debian system."
}

get_dhcp_config() {
	info "[Configure networking]"
	note "Enable simple IPv4 DHCP on Ethernet interfaces in the installed system?"
	echo "------------------------"
	while true; do
		read -rp "Enable IPv4 DHCP? (Y/n) " yn
		yn="${yn:-y}"
		case "${yn,,}" in
		y | yes) DEBIAN_ENABLE_DHCP=true && break ;;
		n | no) DEBIAN_ENABLE_DHCP=false && break ;;
		*) echo "Please answer y or n." ;;
		esac
	done
}

confirm_menu() {
	info "[Configuration finished]"
	note "What do you want to do?"
	echo -e "    [${G}c${NC}] Continue with destructive partitioning"
	echo -e "    [${Y}r${NC}] Restart configuration"
	echo -e "    [${R}e${NC}] Exit without changes"
	while true; do
		read -rp "Choose [c/r/e]: " ans || true
		case "${ans,,}" in
		c) return 0 ;;
		r) return 10 ;;
		e) return 20 ;;
		esac
	done
}

get_inputs() {
	clear
	run_prechecks
	sleep 1
	print_preconf_header
	get_keymap
	print_preconf_header
	get_dhcp_config
	print_preconf_header
	get_disks
	print_preconf_header
	mirror_decision
	print_preconf_header
	get_swapsize
	print_preconf_header
	get_hostname
	print_preconf_header
	get_sudouser
	print_preconf_header
	get_timezone
	print_preconf_header
}

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
		zpool labelclear -f "$d" >/dev/null 2>&1 || true
		wipefs -a "$d" >/dev/null 2>&1 || true
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
		partprobe "$d" >/dev/null 2>&1 || true
		udevadm settle >/dev/null 2>&1 || true
	done
}

get_zfs_passphrase() {
	info "[Make sure your ZFS passphrase works with a US keyboard layout]"
	while true; do
		read -rsp "Enter ZFS passphrase: " p1
		echo
		read -rsp "Confirm ZFS passphrase: " p2
		echo
		[[ -n "$p1" && "$p1" == "$p2" ]] && ZFS_PASSPHRASE="$p1" && return 0
		echo "Passphrases did not match or were empty; try again."
	done
}

get_user_password() {
	while true; do
		read -rsp "Enter user password: " p1
		echo
		read -rsp "Confirm user password: " p2
		echo
		[[ -n "$p1" && "$p1" == "$p2" ]] && USER_PASSWORD="$p1" && return 0
		echo "Passwords did not match or were empty; try again."
	done
}

create_zpool() {
	[[ -n "${POOL_DEVICE_1:-}" ]] || {
		failhard "POOL_DEVICE_1 not set"
		exit 1
	}

	local common_opts=(
		-f
		-o ashift=12
		-O compression=zstd
		-O acltype=posixacl
		-O xattr=sa
		-O relatime=on
		-O dnodesize=auto
		-O normalization=formD
		-O mountpoint=none
		-O encryption=aes-256-gcm
		-O keylocation=file:///etc/zfs/zroot.key
		-O keyformat=passphrase
	)

	if [[ "${DEBIAN_MIRROR_MODE:-false}" == true && -n "${POOL_DEVICE_2:-}" ]]; then
		info "[Creating encrypted ZFS pool 'zroot' as mirror]"
		zpool create "${common_opts[@]}" zroot mirror \
			"/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_1")" \
			"/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_2")"
		ok "Created mirrored pool zroot"
	else
		info "[Creating encrypted ZFS pool 'zroot']"
		zpool create "${common_opts[@]}" zroot \
			"/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_1")"
		ok "Created pool zroot"
	fi
	unset ZFS_PASSPHRASE
}

create_zfs_datasets() {
	info "[Creating ZFS datasets]"
	zfs create -o mountpoint=none zroot/ROOT
	zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/debian
	zfs create -o mountpoint=/home zroot/home
	zpool set bootfs=zroot/ROOT/debian zroot
	ok "Created datasets with bootfs=zroot/ROOT/debian"
}

setup_zfs() {
	mkdir -p /etc/zfs
	printf "%s" "$ZFS_PASSPHRASE" >/etc/zfs/zroot.key
	chmod 000 /etc/zfs/zroot.key
	zgenhostid -f
	modprobe zfs
	create_zpool
	create_zfs_datasets
	zpool export zroot
	zpool import -N -R /mnt zroot
	zfs load-key -L file:///etc/zfs/zroot.key zroot
	zfs mount zroot/ROOT/debian
	mkdir -p /mnt/home
	zfs mount zroot/home
	udevadm trigger
}

mount_chroot_filesystems() {
	mkdir -p /mnt/dev /mnt/proc /mnt/sys/firmware/efi/efivars /mnt/run
	mount --rbind /dev /mnt/dev
	mount --make-rslave /mnt/dev
	mount -t proc proc /mnt/proc
	mount -t sysfs sys /mnt/sys
	mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true
	mount --rbind /run /mnt/run
	mount --make-rslave /mnt/run
}

chroot_run() {
	chroot /mnt /usr/bin/env \
		DEBIAN_FRONTEND=noninteractive \
		LANG=C.UTF-8 \
		LC_ALL=C.UTF-8 \
		"$@"
}

apt_install_target() {
	tail_window 8 target-apt-install chroot_run apt-get install -y --no-install-recommends "$@"
}

install_base_system() {
	info "[Installing Debian base system]"
	DEBIAN_ARCH="${DEBIAN_ARCH:-$(dpkg --print-architecture)}"
	tail_window 10 debootstrap debootstrap --arch="$DEBIAN_ARCH" --components="${DEBIAN_COMPONENTS// /,}" "$DEBIAN_RELEASE" /mnt "$DEBIAN_MIRROR"
	ok "Installed Debian base system"

	mkdir -p /mnt/etc/apt/sources.list.d /mnt/etc/zfs /mnt/etc/initramfs-tools/conf.d /mnt/etc/initramfs-tools/hooks
	cp /etc/hostid /mnt/etc/hostid
	cp /etc/zfs/zroot.key /mnt/etc/zfs/zroot.key
	chmod 000 /mnt/etc/zfs/zroot.key

	cat >/mnt/etc/apt/sources.list <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} ${DEBIAN_COMPONENTS}
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates ${DEBIAN_COMPONENTS}
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security ${DEBIAN_COMPONENTS}
EOF

	mount_chroot_filesystems
	tail_window 8 target-apt-update chroot_run apt-get update
	apt_install_target openssl mokutil
	apt_install_target linux-image-amd64 linux-headers-amd64 dkms zfs-dkms \
		zfsutils-linux zfs-initramfs zfs-zed \
		sudo locales console-setup keyboard-configuration efibootmgr dosfstools \
		rsync inotify-tools util-linux kmod systemd-sysv
	ok "Installed target packages"
}

configure_initramfs() {
	info "[Configuring initramfs-tools for ZFS]"
	cat >/mnt/etc/initramfs-tools/conf.d/zfs <<'EOF'
BOOT=zfs
EOF
	cat >/mnt/etc/initramfs-tools/hooks/zroot-key <<'EOF'
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
	chmod 755 /mnt/etc/initramfs-tools/hooks/zroot-key
	ok "Configured initramfs"
}

rebuild_initramfs() {
	info "[Rebuilding initramfs]"
	tail_window 8 initramfs chroot_run update-initramfs -u -k all
	ok "Rebuilt initramfs"
}

configure_system() {
	info "[Configuring Debian system]"
	echo "$DEBIAN_HOSTNAME" >/mnt/etc/hostname
	cat >/mnt/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 ${DEBIAN_HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
	ln -sf "/usr/share/zoneinfo/$DEBIAN_TIMEZONE" /mnt/etc/localtime
	echo "$DEBIAN_TIMEZONE" >/mnt/etc/timezone
	cat >/mnt/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${DEBIAN_KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
	sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
	tail_window 5 locale-gen chroot_run locale-gen
	tail_window 5 update-locale chroot_run update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en
	chroot_run zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT
	ok "Configured hostname, timezone, keyboard, locale, and ZFSBootMenu property"
}

configure_networking() {
	if [[ "${DEBIAN_ENABLE_DHCP:-false}" != true ]]; then
		info "[Skipping network autoconfiguration]"
		ok "No DHCP network configuration written"
		return 0
	fi

	info "[Configuring IPv4 DHCP networking]"
	mkdir -p /mnt/etc/systemd/network
	cat >/mnt/etc/systemd/network/20-wired-ipv4-dhcp.network <<'EOF'
[Match]
Type=ether

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no

[DHCPv4]
UseDNS=yes
EOF
	chroot_run systemctl enable systemd-networkd.service
	ok "Enabled IPv4 DHCP via systemd-networkd"
}

configure_efi_partitions() {
	info "[Formatting and mounting EFI partitions]"
	mkfs.vfat -F32 "$BOOT_DEVICE_1" >/dev/null
	mkdir -p /mnt/boot/efi
	local efi1_uuid
	efi1_uuid="$(blkid -s UUID -o value "$BOOT_DEVICE_1")"
	echo "UUID=$efi1_uuid /boot/efi vfat defaults 0 1" >>/mnt/etc/fstab
	chroot_run mount /boot/efi
	ok "Mounted primary ESP"

	if [[ "${DEBIAN_MIRROR_MODE:-false}" == true ]]; then
		mkfs.vfat -F32 "$BOOT_DEVICE_2" >/dev/null
		mkdir -p /mnt/boot/efi2
		local efi2_uuid
		efi2_uuid="$(blkid -s UUID -o value "$BOOT_DEVICE_2")"
		echo "UUID=$efi2_uuid /boot/efi2 vfat defaults,nofail 0 1" >>/mnt/etc/fstab
		chroot_run mount /boot/efi2
		ok "Mounted secondary ESP"
	fi
}

setup_zfsbootmenu() {
	info "[Configuring ZFSBootMenu]"
	mkdir -p /mnt/etc/zfsbootmenu /mnt/boot/efi/EFI/zbm /mnt/boot/efi/EFI/BOOT
	tail_window 5 zfsbootmenu-download curl -fsSL https://get.zfsbootmenu.org/efi/release -o /mnt/boot/efi/EFI/zbm/vmlinuz.EFI
	cp -f /mnt/boot/efi/EFI/zbm/vmlinuz.EFI /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI
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
		echo "UUID=$swap_uuid none swap defaults,nofail 0 0" >>/mnt/etc/fstab
		ok "Configured swap on disk $i"
		((i++))
	done
}

setup_user() {
	info "[Creating sudo user: $DEBIAN_SUDOUSER]"
	chroot_run useradd -m -G sudo -s /bin/bash "$DEBIAN_SUDOUSER"
	printf "%s:%s\n" "$DEBIAN_SUDOUSER" "$USER_PASSWORD" | chroot_run chpasswd
	echo "%sudo ALL=(ALL:ALL) ALL" >/mnt/etc/sudoers.d/sudo
	chmod 440 /mnt/etc/sudoers.d/sudo
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
	install -D -m 755 "$PWD/services/efisync/efisync.sh" /mnt/usr/local/bin/efisync.sh
	install -D -m 644 "$PWD/services/efisync/efisync.service" /mnt/etc/systemd/system/efisync.service
	chroot_run systemctl enable efisync.service
	ok "Installed efisync.service"
}

install_zfs_autosnap() {
	info "[Installing zfs-autosnap systemd service]"
	install -D -m 755 "$PWD/services/zfs-autosnap/zfs-autosnap.sh" /mnt/usr/local/bin/zfs-autosnap.sh
	install -D -m 755 "$PWD/services/zfs-autosnap/zfs-autosnap-status.sh" /mnt/usr/local/bin/zfs-autosnap-status.sh
	install -D -m 644 "$PWD/services/zfs-autosnap/jobs.conf" /mnt/etc/zfs-autosnap/jobs.conf
	install -D -m 644 "$PWD/services/zfs-autosnap/zfs-autosnap.service" /mnt/etc/systemd/system/zfs-autosnap.service
	chroot_run systemctl enable zfs-autosnap.service
	ok "Installed zfs-autosnap.service"
}

cleanup_mounts() {
	set +e
	umount -n -R /mnt/run 2>/dev/null
	umount -n -R /mnt/sys 2>/dev/null
	umount -n -R /mnt/proc 2>/dev/null
	umount -n -R /mnt/dev 2>/dev/null
	umount -n -R /mnt 2>/dev/null
	zpool export zroot 2>/dev/null
}

while true; do
	get_inputs
	if confirm_menu; then rc=0; else rc=$?; fi
	case "$rc" in
	10)
		info "[Restarting configuration]"
		unset DEBIAN_MIRROR_MODE DEBIAN_DISK1 DEBIAN_DISK1_SIZE DEBIAN_DISK2 DEBIAN_DISK2_SIZE DEBIAN_SWAPSIZE DEBIAN_HOSTNAME DEBIAN_SUDOUSER DEBIAN_TIMEZONE DEBIAN_KEYMAP
		continue
		;;
	20) exit 0 ;;
	0) break ;;
	esac
done

print_postconf_header
get_user_password
get_zfs_passphrase
print_postconf_header
trap cleanup_mounts EXIT
set_zfs_vars
wipe_disks
partition_disks
setup_zfs
install_base_system
configure_efi_partitions
configure_system
configure_networking
configure_initramfs
rebuild_initramfs
setup_zfsbootmenu
setup_swap
setup_user
sync_esps
install_efisync
install_zfs_autosnap
cleanup_mounts
trap - EXIT

echo
echo "------------------------"
echo -e "${G}Install finished!${NC}"
echo "------------------------"
info "Enabled services in the new system:"
[[ "${DEBIAN_MIRROR_MODE:-false}" == true ]] && ok "efisync.service"
ok "zfs-autosnap.service"
