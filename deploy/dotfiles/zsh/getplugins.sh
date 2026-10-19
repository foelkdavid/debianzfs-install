#!/usr/bin/env bash
set -Eeuo pipefail

PLUGIN_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins
PLUGIN_WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$PLUGIN_WORK_DIR"' EXIT
mkdir -p -- "$PLUGIN_DIR"

for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
    if [[ ! -d "$PLUGIN_DIR/$plugin" ]]; then
        git clone --depth 1 "https://github.com/zsh-users/$plugin.git" "$PLUGIN_WORK_DIR/$plugin"
        mv -- "$PLUGIN_WORK_DIR/$plugin" "$PLUGIN_DIR/$plugin"
    fi
done

if [[ ! -d "$PLUGIN_DIR/gitfast" ]]; then
    git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$PLUGIN_WORK_DIR/ohmyzsh"
    cp -R -- "$PLUGIN_WORK_DIR/ohmyzsh/plugins/gitfast" "$PLUGIN_DIR/gitfast"
fi
