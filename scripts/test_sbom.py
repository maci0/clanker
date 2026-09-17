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
        cls.components = {c["name"]: c for c in cls.document["components"]}

    def test_registry_hashes_preserve_lockfile_integrity(self) -> None:
        algorithms = {"sha256": ("SHA-256", 32), "sha384": ("SHA-384", 48), "sha512": ("SHA-512", 64)}
        packages = sbom.npm_components()
        self.assertTrue(packages)
        for package in packages:
            with self.subTest(package=package["name"]):
                algorithm, digest = package["integrity"].split("-", 1)
                expected_algorithm, expected_size = algorithms[algorithm]
                hashes = self.components[package["name"]]["hashes"]
                self.assertEqual(len(hashes), 1)
                self.assertEqual(hashes[0]["alg"], expected_algorithm)
                self.assertRegex(hashes[0]["content"], rf"^[0-9a-f]{{{expected_size * 2}}}$")
                self.assertEqual(
                    base64.b64encode(bytes.fromhex(hashes[0]["content"])).decode("ascii"),
                    digest,
                )

    def test_dependency_graph_uses_cyclonedx_field(self) -> None:
        dependencies = self.document["dependencies"]
        self.assertNotIn("relationships", self.document)
        assemblyscript = self.components["assemblyscript"]["bom-ref"]
        entry = next(d for d in dependencies if d["ref"] == assemblyscript)
        self.assertEqual(set(entry["dependsOn"]), {
            self.components["binaryen"]["bom-ref"],
            self.components["long"]["bom-ref"],
        })
        refs = {c["bom-ref"] for c in self.document["components"]}
        refs.add(self.document["metadata"]["component"]["bom-ref"])
        for dependency in dependencies:
            self.assertIn(dependency["ref"], refs)
            self.assertTrue(set(dependency["dependsOn"]).issubset(refs))


if __name__ == "__main__":
    unittest.main()
