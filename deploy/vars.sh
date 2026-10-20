#!/bin/bash
# Package arrays are consumed by deploy.sh.
# shellcheck disable=SC2034

# intel, amd, nvidia, nouveau, vm
# These defaults can also be overridden for one run: GPU_DRIVER=vm ./deploy.sh
GPU_DRIVER=${GPU_DRIVER:-intel}
USERSHELL=${USERSHELL:-/usr/bin/zsh}

# VM guest integration: auto, qemu, vmware, none.
# auto uses systemd-detect-virt; graphics support does not require a guest agent.
VM_GUEST=${VM_GUEST:-auto}
# Leave false with accelerated Virtio/virgl. Set true for a software-rendered VM.
VM_SOFTWARE_RENDERING=${VM_SOFTWARE_RENDERING:-false}

# Packages normally selected from Debian Trixie. Graphics and audio stacks may use
# backports to match Hyprland's libraries. Recommends are disabled by the
# installer, so desktop integrations that we use are explicitly included here.
PACKAGES=(
    ca-certificates curl git unzip zip python3
    dbus dbus-user-session libpam-systemd polkitd
    zsh neovim alacritty firefox-esr
    thunar thunar-volman thunar-archive-plugin tumbler xarchiver
    gvfs gvfs-backends udisks2
    xdg-utils xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-gtk libglib2.0-bin
    xwayland xkb-data wl-clipboard grim slurp
    pipewire-audio pipewire-alsa pipewire-pulse wireplumber libspa-0.2-bluetooth
    network-manager wpasupplicant wireless-regdb bluez
    upower power-profiles-daemon brightnessctl
    fontconfig fonts-noto-core fonts-noto-color-emoji adwaita-icon-theme
    qt5-gtk-platformtheme qt6-gtk-platformtheme qt6-wayland
    libgl1-mesa-dri libegl-mesa0
)

# Explicit backports requests; graphics/audio companions can follow their libraries.
BACKPORTS_PACKAGES=(
    hyprland hyprland-guiutils xdg-desktop-portal-hyprland libxkbcommon0 libxkbcommon-x11-0
)

# Noctalia v5 is supplied by the Trixie APT repository in its installation docs.
NOCTALIA_PACKAGES=(noctalia)

# Graphics packages are selected by GPU_DRIVER. Kernels already contain the
# Intel, AMD, Nouveau and virtual GPU kernel drivers; no Xorg DDX is needed.
INTEL_PACKAGES=(
    firmware-intel-graphics intel-media-va-driver i965-va-driver
    mesa-vulkan-drivers mesa-va-drivers
)
AMD_PACKAGES=(firmware-amd-graphics mesa-vulkan-drivers mesa-va-drivers)
# Debian's proprietary driver; the installer also adds matching stock kernel
# and header metapackages for DKMS. See README for GPU/kernel limitations.
NVIDIA_PACKAGES=(
    nvidia-driver nvidia-kernel-dkms libnvidia-egl-wayland1 nvidia-vaapi-driver
)
NOUVEAU_PACKAGES=(firmware-misc-nonfree mesa-vulkan-drivers mesa-va-drivers)
VM_PACKAGES=(mesa-vulkan-drivers)
QEMU_PACKAGES=(qemu-guest-agent)
VMWARE_PACKAGES=(open-vm-tools)

# Enabled for the next boot. UPower, UDisks and desktop portals use D-Bus
# activation; PipeWire uses user units rather than system services.
SERVICES=(
    NetworkManager.service bluetooth.service power-profiles-daemon.service
)
