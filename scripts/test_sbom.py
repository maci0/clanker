import base64
import json
import subprocess
import sys
import unittest
from pathlib import Path

from scripts import sbom


class SbomTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        result = subprocess.run(
            [sys.executable, "-B", str(Path(__file__).with_name("sbom.py"))],
            check=True, capture_output=True, text=True,
        )
        cls.document = json.loads(result.stdout)
        # Keyed by purl, not name: two lockfiles can resolve the same package
        # at different versions (detect-libc 1.x and 2.x here), and the purl is
        # the document's own bom-ref.
        cls.components = {c["purl"]: c for c in cls.document["components"]}

    def test_registry_hashes_preserve_lockfile_integrity(self) -> None:
        algorithms = {
            "sha256": ("SHA-256", 32),
            "sha384": ("SHA-384", 48),
            "sha512": ("SHA-512", 64),
        }
        packages = sbom.npm_components()
        self.assertTrue(packages)
        for package in packages:
            with self.subTest(package=f'{package["name"]}@{package["version"]}'):
                algorithm, digest = package["integrity"].split("-", 1)
                expected_algorithm, expected_size = algorithms[algorithm]
                hashes = self.components[
                    sbom.purl(package["name"], package["version"])
                ]["hashes"]
                self.assertEqual(len(hashes), 1)
                self.assertEqual(hashes[0]["alg"], expected_algorithm)
                self.assertRegex(hashes[0]["content"], rf"^[0-9a-f]{{{expected_size * 2}}}$")
                self.assertEqual(
                    base64.b64encode(bytes.fromhex(hashes[0]["content"])).decode("ascii"),
                    digest,
                )

    def test_both_lockfiles_are_covered(self) -> None:
        lockfiles = set(sbom.NPM_LOCKFILES)
        self.assertEqual({p["lockfile"] for p in sbom.npm_components()}, lockfiles)
        for name in ("oxlint", "tailwindcss", "@tailwindcss/cli", "assemblyscript"):
            with self.subTest(package=name):
                self.assertTrue(
                    any(c["name"] == name for c in self.components.values())
                )
        for c in self.components.values():
            for prop in c["properties"]:
                if prop["name"] == "clanker:lockfile":
                    self.assertIn(prop["value"], lockfiles)

    def test_project_component_depends_on_every_declared_devdep(self) -> None:
        root = self.document["metadata"]["component"]["bom-ref"]
        entry = next(d for d in self.document["dependencies"] if d["ref"] == root)
        self.assertEqual(set(entry["dependsOn"]), {
            c["bom-ref"] for c in self.components.values()
            if c["name"] in sbom.npm_direct_devdeps()
        })

    def test_dependency_graph_uses_cyclonedx_field(self) -> None:
        dependencies = self.document["dependencies"]
        self.assertNotIn("relationships", self.document)
        by_name = {c["name"]: c for c in self.components.values()}
        assemblyscript = by_name["assemblyscript"]["bom-ref"]
        entry = next(d for d in dependencies if d["ref"] == assemblyscript)
        self.assertEqual(set(entry["dependsOn"]), {
            by_name["binaryen"]["bom-ref"],
            by_name["long"]["bom-ref"],
        })
        refs = {c["bom-ref"] for c in self.document["components"]}
        refs.add(self.document["metadata"]["component"]["bom-ref"])
        for dependency in dependencies:
            self.assertIn(dependency["ref"], refs)
            self.assertTrue(set(dependency["dependsOn"]).issubset(refs))

    def test_every_manifest_dependency_is_named_in_the_license_inventory(self) -> None:
        # THIRD_PARTY_LICENSES.md claims "adding a dependency means adding a
        # row in the same change"; nothing enforced that, and the Tailwind
        # devDeps shipped unmentioned. The claim needs a test to hold.
        inventory = (sbom.REPO_ROOT / "THIRD_PARTY_LICENSES.md").read_text(
            encoding="utf-8"
        )
        names = [d["name"] for d in sbom.zig_dependencies()]
        names += sbom.npm_direct_devdeps()
        names += [w["upstream"].strip() for w in sbom.vendored_web()]
        for name in names:
            with self.subTest(dependency=name):
                self.assertIn(name, inventory)


if __name__ == "__main__":
    unittest.main()
