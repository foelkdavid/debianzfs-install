#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 022

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=deploy/vars.sh
source "$ROOT/deploy/vars.sh"
IMAGE_ROOT="$ROOT/image"
BUILD_ROOT=${DEBIANZFS_BUILD_DIR:-/tmp/debianzfs-live-build}
APT_CACHE="$BUILD_ROOT/apt-cache"
REPO_ROOT="$BUILD_ROOT/cache-repo"
CONFIG_ROOT="$BUILD_ROOT/live-config"
CONFIG_SOURCE_DIR="$BUILD_ROOT/debianzfs-config-source"
DEBIAN_MIRROR=https://deb.debian.org/debian
RELEASE=trixie

[[ $EUID == 0 ]] || { echo 'Run image/build.sh as root inside Debian Trixie.' >&2; exit 1; }
[[ $(dpkg --print-architecture) == amd64 ]] || { echo 'The live image currently supports amd64 only.' >&2; exit 1; }
source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || {
    echo 'Build in a Debian 13 Trixie environment.' >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git

# Pin each generated image to the newest published config version tag. This
# makes image builds reproducible while letting them consume a config release
# newer than the installer submodule's fallback pin.
config_tag=$(git ls-remote --tags --refs --sort=-version:refname \
    https://github.com/foelkdavid/debianzfs-config.git 'v*' |
    sed -n '1s|.*refs/tags/||p')
[[ -n $config_tag ]] || { echo 'No debianzfs-config version tag is available.' >&2; exit 1; }
rm -rf -- "$CONFIG_SOURCE_DIR"
git clone --branch "$config_tag" \
    https://github.com/foelkdavid/debianzfs-config.git "$CONFIG_SOURCE_DIR"
printf 'Using debianzfs-config tag %s in this image.\n' "$config_tag"

rm -rf -- "$CONFIG_ROOT"
install -d "$APT_CACHE/partial" "$REPO_ROOT/pool" "$CONFIG_ROOT/config/package-lists" \
    "$CONFIG_ROOT/config/archives" "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-install" \
    "$CONFIG_ROOT/config/hooks/normal"
{
    printf 'deb %s %s main contrib non-free non-free-firmware\n' "$DEBIAN_MIRROR" "$RELEASE"
    printf 'deb http://deb.debian.org/debian %s-backports main contrib non-free non-free-firmware\n' "$RELEASE"
    printf 'deb %s %s-updates main contrib non-free non-free-firmware\n' "$DEBIAN_MIRROR" "$RELEASE"
    printf 'deb https://security.debian.org/debian-security %s-security main contrib non-free non-free-firmware\n' "$RELEASE"
} > /etc/apt/sources.list.d/debianzfs-image-build.list
rm -f /etc/apt/sources.list.d/debian.sources
curl --fail --location --retry 3 --output "$BUILD_ROOT/nickh-archive-keyring.deb" \
    https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb
curl --fail --location --retry 3 --output /etc/apt/sources.list.d/noctalia-trixie.sources \
    https://pkg.noctalia.dev/deb/noctalia-trixie.sources
dpkg -i "$BUILD_ROOT/nickh-archive-keyring.deb"
apt-get update

backports_packages=("${BACKPORTS_PACKAGES[@]/%//trixie-backports}")
mapfile -t base_packages < <(bash "$IMAGE_ROOT/package-manifest.sh" base)
apt-get --download-only --reinstall -o "Dir::Cache::archives=$APT_CACHE" \
    -o APT::Get::Assume-Yes=true install "${base_packages[@]}"

for profile in intel amd nvidia nouveau vm; do
    printf 'Caching Debian and desktop packages for %s...\n' "$profile"
    GPU_DRIVER=$profile VM_GUEST=qemu VM_SOFTWARE_RENDERING=false \
        bash "$ROOT/deploy/deploy.sh" --dry-run > "$BUILD_ROOT/deploy-$profile.txt"
    mapfile -t cache_packages < <(bash "$IMAGE_ROOT/package-manifest.sh" cache "$profile")
    cache_packages+=("${backports_packages[@]}")
    apt-get --download-only --reinstall \
        -o "Dir::Cache::archives=$APT_CACHE" \
        -o APT::Get::Assume-Yes=true \
        -t trixie-backports install "${cache_packages[@]}"
done
# Keep both VM guest integrations because the profile is selected at install time.
for guest_package in qemu-guest-agent open-vm-tools; do
    apt-get --download-only --reinstall -o "Dir::Cache::archives=$APT_CACHE" \
        -o APT::Get::Assume-Yes=true install "$guest_package"
done
# Keep the NVIDIA profile on the supported stock Trixie kernel track.
apt-get --download-only --reinstall -o "Dir::Cache::archives=$APT_CACHE" \
    -o APT::Get::Assume-Yes=true install linux-image-amd64 linux-headers-amd64

# Resolve the target package sets in a minimal Trixie environment. Installing
# live-build helpers first can make their installed library versions constrain
# the target dependency solver, even though the installer target is fresh.
apt-get install -y --no-install-recommends \
    live-build debootstrap xorriso squashfs-tools syslinux-common isolinux \
    grub-pc-bin grub-efi-amd64-bin dpkg-dev apt-utils git rsync python3

find "$APT_CACHE" -maxdepth 1 -type f -name '*.deb' -exec cp -n -t "$REPO_ROOT/pool" -- {} +
[[ -n $(find "$REPO_ROOT/pool" -maxdepth 1 -type f -name '*.deb' -print -quit) ]] || {
    echo 'APT did not create any cached package files.' >&2; exit 1;
}
(
    cd "$REPO_ROOT"
    dpkg-scanpackages pool /dev/null > Packages
)
gzip -9 -c "$REPO_ROOT/Packages" > "$REPO_ROOT/Packages.gz"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=DebianZFSInstaller \
    -o APT::FTPArchive::Release::Label=DebianZFSInstaller \
    -o APT::FTPArchive::Release::Suite=trixie \
    -o APT::FTPArchive::Release::Codename=trixie \
    -o APT::FTPArchive::Release::Components=main \
    release "$REPO_ROOT" > "$REPO_ROOT/Release"

if [[ ! -s $REPO_ROOT/debootstrap-trixie-amd64.tar ]]; then
    debootstrap --make-tarball="$REPO_ROOT/debootstrap-trixie-amd64.tar" \
        --arch=amd64 --components=main,contrib,non-free,non-free-firmware \
        "$RELEASE" "$BUILD_ROOT/debootstrap-base" "$DEBIAN_MIRROR"
fi

mapfile -t live_packages < <(bash "$IMAGE_ROOT/package-manifest.sh" live)
printf '%s\n' "${live_packages[@]}" > "$CONFIG_ROOT/config/package-lists/debianzfs.list.chroot"
printf 'deb http://deb.debian.org/debian %s-backports main contrib non-free non-free-firmware\n' \
    "$RELEASE" > "$CONFIG_ROOT/config/archives/debian-backports.list.chroot"
rsync -a --exclude='/.git/' --exclude='/AGENTS.md' --exclude='/dist/' \
    --exclude='/tests/' --exclude='/image/' --exclude='__pycache__/' --exclude='*.pyc' \
    --exclude='/.image-build-work/' \
    --exclude='/.agents/' --exclude='/.aws/' --exclude='/.codex/' \
    "$ROOT/" "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-install/"
rm -rf "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-install/debianzfs-config"
git clone --local --no-hardlinks "$CONFIG_SOURCE_DIR" \
    "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-install/debianzfs-config"
git clone --local --no-hardlinks "$CONFIG_SOURCE_DIR" \
    "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-config"
install -d "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-install/cache"
cp -a "$REPO_ROOT/." "$CONFIG_ROOT/config/includes.chroot/opt/debianzfs-install/cache/"
cat > "$CONFIG_ROOT/config/hooks/normal/0100-debianzfs-live.hook.chroot" <<'HOOK'
#!/bin/bash
set -Eeuo pipefail
set +x
getent group sudo >/dev/null || groupadd sudo
id liveuser >/dev/null 2>&1 || useradd --create-home --groups sudo --shell /bin/bash liveuser
systemctl --root=/ --no-reload enable NetworkManager.service
systemctl --root=/ --no-reload disable \
    systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service systemd-resolved.service networking.service
systemctl --root=/ --no-reload mask \
    systemd-networkd.service systemd-networkd.socket systemd-resolved.service \
    networking.service
install -d -m 755 /etc/tmpfiles.d
printf '%s\n' 'L+ /etc/resolv.conf - - - - /run/NetworkManager/resolv.conf' \
    > /etc/tmpfiles.d/debianzfs-network.conf
install -d -o liveuser -g liveuser -m 755 /opt/media/wall
install -o liveuser -g liveuser -m 644 \
    /opt/debianzfs-install/debianzfs-config/wallpapers/debianzfs_1.png \
    /opt/media/wall/debianzfs_1.png
install -d -m 755 /etc/sudoers.d
printf 'liveuser ALL=(root) NOPASSWD: /opt/debianzfs-install/install.sh\n' \
    > /etc/sudoers.d/debianzfs-live-installer
chmod 440 /etc/sudoers.d/debianzfs-live-installer
cat > /usr/local/bin/debianzfs-install <<'EOF'
#!/bin/sh
exec sudo /opt/debianzfs-install/install.sh "$@"
EOF
chmod 755 /usr/local/bin/debianzfs-install
install -d -m 755 /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I $TERM
EOF
install -d -o liveuser -g liveuser -m 755 /home/liveuser/.local
git clone --local --no-hardlinks /opt/debianzfs-config \
    /home/liveuser/.local/debianzfs-config
git -C /home/liveuser/.local/debianzfs-config remote set-url origin \
    https://github.com/foelkdavid/debianzfs-config.git
git -C /home/liveuser/.local/debianzfs-config checkout -B main HEAD
git -C /home/liveuser/.local/debianzfs-config config branch.main.remote origin
git -C /home/liveuser/.local/debianzfs-config config branch.main.merge refs/heads/main
chown -R liveuser:liveuser /home/liveuser/.local/debianzfs-config
GPU_DRIVER=intel VM_GUEST=none VM_SOFTWARE_RENDERING=false \
    DEBIANZFS_CONFIG_DIR=/home/liveuser/.local/debianzfs-config \
    bash /opt/debianzfs-install/deploy/deploy.sh --chroot liveuser
python3 /opt/debianzfs-install/deploy/scripts/disable-live-lock.py \
    /home/liveuser/.local/state/noctalia/settings.toml
chown liveuser:liveuser /home/liveuser/.local/state/noctalia/settings.toml
HOOK
chmod 755 "$CONFIG_ROOT/config/hooks/normal/0100-debianzfs-live.hook.chroot"

cd "$CONFIG_ROOT"
lb config \
    --distribution "$RELEASE" \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --bootappend-live 'boot=live components quiet hostname=debianzfs username=liveuser' \
    --archive-areas 'main contrib non-free non-free-firmware' \
    --apt-recommends false \
    --apt-indices false \
    --debian-installer false \
    --memtest none \
    --iso-application 'Debian ZFS Installer' \
    --iso-publisher 'Debian ZFS Installer' \
    --iso-volume 'DEBIANZFS'
lb build

install -d "$ROOT/dist"
find "$CONFIG_ROOT" -maxdepth 1 -type f -name '*.iso' -exec install -m 644 {} "$ROOT/dist/debianzfs-live-amd64.iso" \;
[[ -s "$ROOT/dist/debianzfs-live-amd64.iso" ]] || { echo 'live-build produced no ISO.' >&2; exit 1; }
(
    cd "$ROOT/dist"
    sha256sum debianzfs-live-amd64.iso > SHA256SUMS
)
printf 'Built %s (%s bytes).\n' "$ROOT/dist/debianzfs-live-amd64.iso" \
    "$(stat -c %s "$ROOT/dist/debianzfs-live-amd64.iso")"
