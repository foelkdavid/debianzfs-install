#!/usr/bin/env python3
"""Prepare native live-build overrides from the selected config wallpaper."""
from pathlib import Path
import argparse
import shutil

from PIL import Image, ImageEnhance, ImageOps


def prepare(wallpaper, destination):
    templates = Path(__file__).resolve().parent / "boot-menu"
    shutil.copytree(templates, destination, dirs_exist_ok=True)
    with Image.open(wallpaper) as source:
        for directory, size in [("grub-pc", (800, 600)),
                                ("syslinux_common", (640, 480))]:
            # Preserve proportions and leave high contrast behind the menu text.
            background = ImageOps.fit(source.convert("RGB"), size, Image.Resampling.LANCZOS)
            background = ImageEnhance.Brightness(background).enhance(0.55)
            background.save(destination / directory / "splash.png")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wallpaper", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    prepare(args.wallpaper, args.destination)
