#!/usr/bin/env bash
# Run only in a disposable Debian container. Installs fixtures under /tmp and
# uses mock package/service commands; never touches a developer account.
set -Eeuo pipefail
umask 022
[[ -f /.dockerenv && $EUID == 0 ]] || { echo 'Disposable root Docker container required.' >&2; exit 1; }
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST=$(mktemp -d)
chmod 755 "$TEST"
rm -f /boot/vmlinuz-6.17.1-fixture
trap 'rm -rf -- "$TEST"' EXIT
id -u fixture >/dev/null 2>&1 || useradd -m -s /bin/bash fixture
if [[ -e /usr/sbin/policy-rc.d ]]; then cp -a /usr/sbin/policy-rc.d "$TEST/baseline-policy"; fi
mkdir -p "$TEST/bin"
cat > "$TEST/bin/mock" <<'EOF'
#!/bin/bash
set -eu
name=${0##*/}
case $name in
    apt-cache)
        if [[ ${1:-} == madison ]]; then
            printf ' %s | 0.55.2 | http://deb.debian.org/debian trixie-backports/main amd64 Packages\n' "$2"
        else
            printf '  Candidate: 1.0\n'
        fi ;;
    apt-get) [[ $EUID == 0 ]] || exit 90 ;;
    dpkg-query) printf '0.55.0\n' ;;
    dpkg)
        if [[ ${1:-} == -i ]]; then exit 0; fi
        exec /usr/bin/dpkg "$@" ;;
    curl)
        while (($#)); do
            if [[ $1 == --output ]]; then printf fixture > "$2"; break; fi
            shift
        done ;;
    systemctl)
        [[ $* == *--root=/* && $* == *--no-reload* && $* != *'--user'* ]] || exit 91
        printf '%s\n' "$*" >> /tmp/debianzfs-mock-systemctl ;;
    update-initramfs) [[ $EUID == 0 ]] || exit 92 ;;
    *) : ;;
esac
EOF
chmod 755 "$TEST/bin/mock"
for command in apt-get apt-cache curl dpkg dpkg-query systemctl update-initramfs Hyprland start-hyprland noctalia Thunar firefox-esr alacritty nvim grim slurp wl-copy gio; do
    ln -s mock "$TEST/bin/$command"
done
# Optional fonts/plugins are skipped. Verify their user-facing outputs and
# ownership without downloads from the disposable container.
for profile in intel amd nvidia nouveau vm vm-software; do
    gpu=$profile
    software=false
    if [[ $profile == vm-software ]]; then gpu=vm; software=true; fi
    destination=/home/fixture/.local/debianzfs-config
    mkdir -p "$destination"
    cp -a "$REPO/debianzfs-config/." "$destination/"
    chown -R fixture:fixture /home/fixture
    # NVIDIA must inspect these target kernels, not the container host kernel.
    mkdir -p /usr/src/linux-headers-6.12.99-fixture
    touch /boot/vmlinuz-6.12.99-fixture
    PATH="$TEST/bin:$PATH" GPU_DRIVER=$gpu VM_GUEST=qemu VM_SOFTWARE_RENDERING=$software \
        DEBIANZFS_CONFIG_DIR="$destination" DEBIANZFS_SKIP_OPTIONAL_ASSETS=true \
        bash "$REPO/deploy/deploy.sh" --chroot fixture
    [[ $(getent passwd fixture | cut -d: -f7) == /usr/bin/zsh ]]
    [[ $(stat -c %U /home/fixture/.config/debian-deploy/graphics.lua) == fixture ]]
    [[ $(readlink /home/fixture/.config/debian-deploy/graphics.lua) == "$destination/dotfiles/hypr/profiles/$profile.lua" ]]
    [[ $(stat -Lc %U /home/fixture/.config/debian-deploy/graphics.lua) == fixture ]]
    [[ $(stat -c %U /home/fixture/.local/state/noctalia/settings.toml) == fixture ]]
    [[ $(readlink /home/fixture/.config/hypr) == "$destination/dotfiles/hypr" ]]
    [[ $(readlink /home/fixture/.zprofile) == "$destination/dotfiles/zsh/zprofile" ]]
    [[ ! -e /home/fixture/Desktop ]]
    [[ $(readlink /home/fixture/.config/systemd/user/sockets.target.wants/pipewire.socket) == /usr/lib/systemd/user/pipewire.socket ]]
    grep -qx "GPU_DRIVER=$gpu" /home/fixture/.local/state/debian-deploy/settings.sh
    grep -qx "VM_SOFTWARE_RENDERING=$software" /home/fixture/.local/state/debian-deploy/settings.sh
    if [[ -f $TEST/baseline-policy ]]; then
        cmp "$TEST/baseline-policy" /usr/sbin/policy-rc.d
    else
        [[ ! -e /usr/sbin/policy-rc.d ]]
    fi
    echo "PASS: chroot user ownership/environment and offline services ($profile)"
done
# A failed package transaction restores a pre-existing service-start policy.
printf '#!/bin/sh\nexit 42\n' > /usr/sbin/policy-rc.d
chmod 711 /usr/sbin/policy-rc.d
cp -a /usr/sbin/policy-rc.d "$TEST/original"
rm -- "$TEST/bin/apt-get"
cat > "$TEST/bin/apt-get" <<'EOF'
#!/bin/bash
exit 17
EOF
chmod 755 "$TEST/bin/apt-get"
if PATH="$TEST/bin:$PATH" GPU_DRIVER=vm VM_GUEST=none \
    DEBIANZFS_CONFIG_DIR="$destination" DEBIANZFS_SKIP_OPTIONAL_ASSETS=true \
    bash "$REPO/deploy/deploy.sh" --chroot fixture; then
    echo 'Expected package failure' >&2; exit 1
else
    [[ $? == 17 ]]
fi
cmp "$TEST/original" /usr/sbin/policy-rc.d
[[ $(stat -c %a /usr/sbin/policy-rc.d) == 711 ]]
touch /boot/vmlinuz-6.17.1-fixture
if PATH="$TEST/bin:$PATH" GPU_DRIVER=nvidia bash "$REPO/deploy/deploy.sh" --chroot fixture > "$TEST/nvidia.log" 2>&1; then
    echo 'Expected incompatible target kernel rejection' >&2; exit 1
fi
grep -q 'target contains 6.17.1-fixture' "$TEST/nvidia.log"
echo 'PASS: package failure restores policy and NVIDIA checks target kernels'
# Exercise the actual Zsh login guard with mocked terminal/session commands.
for guard in clean ssh nested wayland display signature noninteractive; do
    zsh_mode=-filc
    [[ $guard != noninteractive ]] || zsh_mode=-flc
    # Expansion belongs to the fixture Zsh process.
    # shellcheck disable=SC2016
    result=$(runuser -u fixture -- env -i HOME=/home/fixture PATH=/usr/bin:/bin GUARD="$guard" zsh "$zsh_mode" '
        tty() { print /dev/tty1; }
        start-hyprland() { print STARTED; }
        SHLVL=1
        case $GUARD in
            ssh) SSH_CONNECTION=fixture ;;
            nested) SHLVL=2 ;;
            wayland) WAYLAND_DISPLAY=wayland-1 ;;
            display) DISPLAY=:0 ;;
            signature) HYPRLAND_INSTANCE_SIGNATURE=fixture ;;
            noninteractive) : ;;
        esac
        source "$HOME/.zprofile"
        print RETURNED-TO-SHELL
    ')
    [[ $result == *RETURNED-TO-SHELL* ]]
    if [[ $guard == clean ]]; then [[ $result == *STARTED* ]]; else [[ $result != *STARTED* ]]; fi
done
echo 'PASS: actual Zsh TTY1 guard, session exclusions, and compositor return'
# Offline enablement against fixture units uses real systemctl, no system bus.
mkdir -p "$TEST/offline/etc/systemd/system" "$TEST/offline/usr/lib/systemd/system"
cat > "$TEST/offline/usr/lib/systemd/system/fixture.service" <<'EOF'
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
EOF
/usr/bin/systemctl --root="$TEST/offline" --no-reload enable fixture.service
[[ -L $TEST/offline/etc/systemd/system/multi-user.target.wants/fixture.service ]]
echo 'PASS: real systemctl offline enablement'
# A missing mirror ESP must never cause rsync --delete on the remaining ESP.
mkdir -p "$TEST/esp1" "$TEST/esp2"
cat > "$TEST/bin/rsync" <<'EOF'
#!/bin/bash
echo UNEXPECTED-SYNC
exit 98
EOF
chmod 755 "$TEST/bin/rsync"
ln -s mock "$TEST/bin/inotifywait"
if PATH="$TEST/bin:$PATH" SRC="$TEST/esp1" DST="$TEST/esp2" \
    bash "$REPO/services/efisync/efisync.sh" > "$TEST/efisync.log" 2>&1; then
    echo 'Expected unmounted-ESP rejection' >&2; exit 1
fi
grep -q 'Both ESPs must be mounted' "$TEST/efisync.log"
if grep -q UNEXPECTED-SYNC "$TEST/efisync.log"; then exit 1; fi
echo 'PASS: EFI synchronization refuses unmounted partitions'
