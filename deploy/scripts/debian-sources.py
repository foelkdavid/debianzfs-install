#!/usr/bin/env python3
"""Print supplemental Debian sources; preserve existing .list and deb822 files.

The managed output is excluded from discovery so reruns retain its sources.
Accept an APT directory argument to allow inspection with temporary fixtures.
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


def render(apt_dir):
    suites = {
        "trixie": "https://deb.debian.org/debian",
        "trixie-updates": "https://deb.debian.org/debian",
        "trixie-security": "https://deb.debian.org/debian-security",
        "trixie-backports": "https://deb.debian.org/debian",
    }
    aliases = {"stable": "trixie", "stable-updates": "trixie-updates", "stable-security": "trixie-security", "stable-backports": "trixie-backports"}
    available = {suite: set() for suite in suites}
    archive_settings = {}
    sources = [apt_dir / "sources.list"]
    sources += sorted((apt_dir / "sources.list.d").glob("*.list"))
    sources += sorted((apt_dir / "sources.list.d").glob("*.sources"))
    for source_file in sources:
        if not source_file.is_file() or source_file.name == "debian-deploy.sources":
            continue
        for uris, source_suites, components, signed_by in entries(source_file):
            # Only count Debian archive paths; third-party suites can share names.
            archive_uris = [uri for uri in uris if urlparse(uri).path.rstrip("/").endswith(("/debian", "/debian-security"))]
            if not archive_uris:
                continue
            for source_suite in source_suites:
                suite = aliases.get(source_suite, source_suite)
                if suite in available:
                    available[suite].update(components)
                    archive_settings.setdefault(suite, (archive_uris[0], source_suite, signed_by))

    output = ["# Managed by debian-deploy; existing APT sources are preserved.\n"]
    for suite, uri in suites.items():
        missing = [component for component in ("main", "contrib", "non-free", "non-free-firmware") if component not in available[suite]]
        if not missing:
            continue
        # Reuse the mirror, suite spelling and signing settings. In particular,
        # adding a different Signed-By to an existing URI/suite breaks APT.
        source_uri, source_suite, signed_by = archive_settings.get(suite, (uri, suite, "/usr/share/keyrings/debian-archive-keyring.gpg"))
        stanza = f"Types: deb\nURIs: {source_uri}\nSuites: {source_suite}\nComponents: {' '.join(missing)}\n"
        if signed_by is not None:
            stanza += f"Signed-By: {signed_by}\n"
        output.append(stanza)
    return "\n".join(output)


if __name__ == "__main__":
    print(render(Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/etc/apt")), end="")
