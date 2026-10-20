#!/usr/bin/env bash
set -Eeuo pipefail
set +x
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $EUID != 0 ]] || { echo 'User setup must run as the selected normal user.' >&2; exit 1; }
# shellcheck source=deploy/vars.sh
source "$REPO_DIR/vars.sh"
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/debian-deploy
printf 'Installing user configuration from debianzfs-config...\n'
CONFIG_REPO_DIR=${DEBIANZFS_CONFIG_DIR:-$HOME/.local/debianzfs-config}
[[ -x $CONFIG_REPO_DIR/deploy.sh ]] || {
    printf 'Missing config repository or deploy script: %s/deploy.sh\n' "$CONFIG_REPO_DIR" >&2
    exit 1
}
printf 'Selecting the Hyprland hardware profile...\n'
profile=$GPU_DRIVER
if [[ $profile == vm && $VM_SOFTWARE_RENDERING == true ]]; then profile=vm-software; fi
case $profile in intel|amd|nvidia|nouveau|vm|vm-software) ;;
    *) printf 'Unknown graphics profile: %s\n' "$profile" >&2; exit 1 ;;
esac
profile_path="$CONFIG_REPO_DIR/dotfiles/hypr/profiles/$profile.lua"
[[ -f $profile_path ]] || { printf 'Missing hardware profile: %s\n' "$profile_path" >&2; exit 1; }
mkdir -p -- "$CONFIG_DIR/debian-deploy"
# Replace the old generated file as well as a previous profile selection.
ln -sfnT -- "$profile_path" "$CONFIG_DIR/debian-deploy/graphics.lua"

"$CONFIG_REPO_DIR/deploy.sh"
# Persist settings while allowing explicit environment overrides on reruns.
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/settings.sh" <<EOF
GPU_DRIVER=$GPU_DRIVER
VM_GUEST=$VM_GUEST
VM_SOFTWARE_RENDERING=$VM_SOFTWARE_RENDERING
USERSHELL=$USERSHELL
EOF
chmod 600 "$STATE_DIR/settings.sh"
# A managed block in .zprofile runs only once per interactive login on TTY1.
# Do not exec: ending Hyprland returns to the same shell. No automatic login.
if ! grep -q '^# BEGIN debian-deploy TTY1$' "$HOME/.zprofile" 2>/dev/null; then
    cat >> "$HOME/.zprofile" <<'EOF'

# BEGIN debian-deploy TTY1
if [[ -o interactive && -o login && -z ${SSH_CONNECTION:-} && -z ${SSH_TTY:-} &&
      -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && -z ${HYPRLAND_INSTANCE_SIGNATURE:-} &&
      ${SHLVL:-1} -eq 1 && $(tty) == /dev/tty1 ]]; then
    start-hyprland
fi
# END debian-deploy TTY1
EOF
fi
printf 'User resources configured for %s in %s.\n' "$(id -un)" "$HOME"
