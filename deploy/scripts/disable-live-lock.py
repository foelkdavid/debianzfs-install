#!/usr/bin/env python3
"""Disable Noctalia idle locking for the autologin live user only."""
from pathlib import Path
import sys


def disable_lock(path: Path) -> None:
    lines = path.read_text().splitlines(keepends=True)
    section_start = next(
        (index for index, line in enumerate(lines)
         if line.strip() == "[idle.behavior.lock]"),
        None,
    )
    if section_start is None:
        raise SystemExit("Could not locate [idle.behavior.lock].")

    section_end = next(
        (index for index in range(section_start + 1, len(lines))
         if lines[index].lstrip().startswith("[")),
        len(lines),
    )
    for index in range(section_start + 1, section_end):
        if lines[index].strip() == "enabled = true":
            indent = lines[index][:len(lines[index]) - len(lines[index].lstrip())]
            ending = "\n" if lines[index].endswith("\n") else ""
            lines[index] = f"{indent}enabled = false{ending}"
            path.write_text("".join(lines))
            return
    raise SystemExit("Could not locate enabled setting in [idle.behavior.lock].")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: disable-live-lock.py SETTINGS.toml")
    disable_lock(Path(sys.argv[1]))
