#!/usr/bin/env bash
set -Eeuo pipefail

FONT_VERSION=v3.3.0
FONTS=(CodeNewRoman ComicShannsMono)
FONT_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/fonts/nerd-fonts
FONT_WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$FONT_WORK_DIR"' EXIT

for font in "${FONTS[@]}"; do
    destination="$FONT_DIR/$font"
    if [[ -f "$destination/.version" && "$(cat "$destination/.version")" == "$FONT_VERSION" ]]; then
        continue
    fi
    printf 'Installing %s Nerd Font (%s)...\n' "$font" "$FONT_VERSION"
    curl --fail --location --retry 3 --output "$FONT_WORK_DIR/$font.zip" \
        "https://github.com/ryanoasis/nerd-fonts/releases/download/$FONT_VERSION/$font.zip"
    unzip -q "$FONT_WORK_DIR/$font.zip" -d "$FONT_WORK_DIR/$font"
    font_count=0
    mkdir -p -- "$destination"
    while IFS= read -r -d '' font_file; do
        install -m 644 "$font_file" "$destination/"
        font_count=$((font_count + 1))
    done < <(find "$FONT_WORK_DIR/$font" -type f \( -iname '*.otf' -o -iname '*.ttf' \) -print0)
    (( font_count > 0 )) || { printf 'No font files in %s.zip\n' "$font" >&2; exit 1; }
    printf '%s\n' "$FONT_VERSION" > "$destination/.version"
done
fc-cache -f "$FONT_DIR"
