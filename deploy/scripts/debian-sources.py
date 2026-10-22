#!/usr/bin/env python3
"""Consolidate Debian binary repositories in sources.list, retaining custom mirrors.

Print the proposed sources.list by default; --write also migrates existing Debian
entries out of sources.list.d. Unrelated repositories are preserved.
"""

import re
import shlex
import sys
from pathlib import Path
from urllib.parse import urlparse


def stanzas(text):
    for block in re.split(r"\n\s*\n", text):
        fields = {}
        key = None
        for line in block.splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line[0].isspace() and key:
                fields[key] += "\n" + line
            elif ":" in line:
                key, value = line.split(":", 1)
                key = key.lower()
                fields[key] = value.strip()
        if fields.get("enabled", "yes").lower() != "no" and "deb" in fields.get("types", "").split():
            yield fields.get("uris", "").split(), fields.get("suites", "").split(), fields.get("components", "").split(), fields.get("signed-by")


def entries(source_file):
    text = source_file.read_text()
    if source_file.suffix == ".sources":
        yield from stanzas(text)
    else:
        for line in text.splitlines():
            match = re.match(r"^\s*deb\s+(?:\[([^]]*)\]\s+)?(\S+)\s+(\S+)\s+(.+)", line)
            if match:
                options, uri, suite, components = match.groups()
                signed_by = next((option.split("=", 1)[1] for option in shlex.split(options or "") if option.startswith("signed-by=")), None)
                yield [uri], [suite], components.split("#", 1)[0].split(), signed_by


ALIASES = {"stable": "trixie", "stable-updates": "trixie-updates",
           "stable-security": "trixie-security", "stable-backports": "trixie-backports"}
SUITES = tuple(ALIASES.values())
KEYRING = "/usr/share/keyrings/debian-archive-keyring.gpg"


def is_debian(uris, suites):
    return (bool(uris) and bool(suites)
            and all(urlparse(uri).path.rstrip("/").endswith(("/debian", "/debian-security")) for uri in uris)
            and all(ALIASES.get(suite, suite) in SUITES for suite in suites))


def retained_text(source_file):
    text = source_file.read_text()
    if source_file.suffix == ".sources":
        blocks = re.split(r"\n\s*\n", text)
        retained = [block for block in blocks
                    if not any(is_debian(uris, suites) for uris, suites, _, _ in stanzas(block))]
        return text if retained == blocks else "\n\n".join(retained).rstrip() + "\n"
    lines = []
    for line in text.splitlines(keepends=True):
        match = re.match(r"^\s*deb\s+(?:\[[^]]*\]\s+)?(\S+)\s+(\S+)\s+", line)
        if not match or not is_debian([match[1]], [match[2]]):
            lines.append(line)
    return "".join(lines)


def render(apt_dir, write=False):
    suites = {
        "trixie": "https://deb.debian.org/debian",
        "trixie-updates": "https://deb.debian.org/debian",
        "trixie-security": "https://security.debian.org/debian-security",
        "trixie-backports": "https://deb.debian.org/debian",
    }
    archive_settings = {}
    sources = [apt_dir / "sources.list"]
    sources += sorted((apt_dir / "sources.list.d").glob("*.list"))
    sources += sorted((apt_dir / "sources.list.d").glob("*.sources"))
    for source_file in sources:
        if not source_file.is_file() or source_file.name == "debian-deploy.sources":
            continue
        for uris, source_suites, _, _ in entries(source_file):
            if is_debian(uris, source_suites):
                for source_suite in source_suites:
                    archive_settings.setdefault(ALIASES.get(source_suite, source_suite), uris[0])

    # The selected main mirror also supplies updates. Security and backports
    # deliberately use the official endpoints, independently of that mirror.
    mirror = archive_settings.get("trixie", suites["trixie"])
    suites["trixie"] = suites["trixie-updates"] = mirror
    main = apt_dir / "sources.list"
    retained = retained_text(main) if main.is_file() else ""
    output = retained.rstrip() + "\n\n" if retained.strip() else ""
    output += "".join(
        f"deb [signed-by={KEYRING}] {uri} {suite} main contrib non-free non-free-firmware\n"
        for suite, uri in suites.items())
    if write:
        # Calculate all edits before modifying files. Never touch third-party
        # definitions (including the installer's temporary offline repository).
        changes = {source: retained_text(source) for source in sources
                   if source.is_file() and source != main
                   and source.name != "debian-deploy.sources"}
        main.write_text(output)
        main.chmod(0o644)
        for source, text in changes.items():
            if text != source.read_text():
                if text.strip():
                    source.write_text(text)
                else:
                    source.unlink()
        (apt_dir / "sources.list.d/debian-deploy.sources").unlink(missing_ok=True)
    return output


if __name__ == "__main__":
    args = [arg for arg in sys.argv[1:] if arg != "--write"]
    print(render(Path(args[0]) if args else Path("/etc/apt"), write="--write" in sys.argv), end="")
