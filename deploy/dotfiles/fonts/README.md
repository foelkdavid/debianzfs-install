# Fonts

`getfonts.sh` downloads CodeNewRoman and ComicShannsMono Nerd Fonts into
`~/.local/share/fonts/nerd-fonts` (or `$XDG_DATA_HOME/fonts/nerd-fonts`).
It installs both `.ttf` and `.otf` files, refreshes Fontconfig, and skips downloads
when the selected version is already installed. Downloaded fonts stay outside
the repository. Alacritty uses CodeNewRoman Nerd Font.
