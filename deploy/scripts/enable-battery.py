#!/usr/bin/env python3
"""Add Noctalia's battery widget before session, without rewriting other settings."""
import json
from pathlib import Path
import re
import sys
import tomllib


def enable_battery(path: Path) -> None:
    text = path.read_text()
    settings = tomllib.loads(text)
    widgets = settings["bar"]["Topbar"]["end"]
    if "battery" in widgets:
        return
    widgets.insert(widgets.index("session") if "session" in widgets else len(widgets), "battery")
    section = re.search(r"(?m)^[ \t]*\[bar\.Topbar\][ \t]*\n", text)
    if section is None:
        raise ValueError("Missing [bar.Topbar] section")
    start = section.end()
    following = re.search(r"(?m)^[ \t]*\[", text[start:])
    end = start + following.start() if following else len(text)
    body, count = re.subn(r"(?m)^([ \t]*)end\s*=\s*\[[^\]]*\]",
                          lambda match: match[1] + "end = " + json.dumps(widgets),
                          text[start:end], count=1)
    if count != 1:
        raise ValueError("Missing Topbar end widget array")
    updated = text[:start] + body + text[end:]
    tomllib.loads(updated)
    path.write_text(updated)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: enable-battery.py SETTINGS.toml")
    enable_battery(Path(sys.argv[1]))
