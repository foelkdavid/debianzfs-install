#!/usr/bin/env python3
"""Host-safe APT repository migration fixtures (never invoke host APT)."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sources", REPO / "deploy/scripts/debian-sources.py")
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


def expected(mirror):
    return "".join(
        f"deb [signed-by={sources.KEYRING}] {uri} {suite} main contrib non-free non-free-firmware\n"
        for uri, suite in ((mirror, "trixie"), (mirror, "trixie-updates"),
                           ("https://security.debian.org/debian-security", "trixie-security"),
                           ("https://deb.debian.org/debian", "trixie-backports")))


class SourcesTests(unittest.TestCase):
    def test_custom_default_and_missing_sources(self):
        for mirror in ("http://debian.lagis.at/debian", "https://deb.debian.org/debian", None):
            with self.subTest(mirror=mirror), tempfile.TemporaryDirectory() as tmp:
                apt = Path(tmp)
                directory = apt / "sources.list.d"
                directory.mkdir()
                if mirror:
                    (apt / "sources.list").write_text(f"deb {mirror} trixie main contrib non-free-firmware\n")
                # Migrate the previously generated supplement, including its backports.
                (directory / "debian-deploy.sources").write_text(
                    "Types: deb\nURIs: http://debian.lagis.at/debian\nSuites: trixie\nComponents: non-free\n")
                third_party = "Types: deb\nURIs: https://example.org/repo\nSuites: trixie\nComponents: main\n"
                (directory / "third-party.sources").write_text(third_party)
                cache = "deb [trusted=yes] file:/mnt/debianzfs-cache ./\n"
                (directory / "cache.list").write_text(cache)
                desired = expected(mirror or "https://deb.debian.org/debian")
                self.assertEqual(sources.render(apt), desired)
                self.assertTrue((directory / "debian-deploy.sources").exists())
                for _ in range(2):
                    self.assertEqual(sources.render(apt, write=True), desired)
                    self.assertEqual((apt / "sources.list").read_text(), desired)
                    self.assertFalse((directory / "debian-deploy.sources").exists())
                    self.assertEqual((directory / "third-party.sources").read_text(), third_party)
                    self.assertEqual((directory / "cache.list").read_text(), cache)

    def test_deb822_migration_and_mixed_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            apt = Path(tmp)
            directory = apt / "sources.list.d"
            directory.mkdir()
            (directory / "debian.sources").write_text(
                "Types: deb\nURIs: http://debian.lagis.at/debian\nSuites: trixie trixie-updates\n"
                "Components: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n")
            third_party = "deb https://example.org/repo trixie main\n"
            (directory / "mixed.list").write_text(
                "deb https://deb.debian.org/debian trixie-backports main\n" + third_party)
            sources.render(apt, write=True)
            self.assertEqual((apt / "sources.list").read_text(), expected("http://debian.lagis.at/debian"))
            self.assertFalse((directory / "debian.sources").exists())
            self.assertEqual((directory / "mixed.list").read_text(), third_party)


if __name__ == "__main__":
    unittest.main()
