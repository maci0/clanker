import base64
import hashlib
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

    def test_manifests_declare_only_pinned_dev_dependencies(self) -> None:
        # `tools-ts-toolchain` (src/gate/checks.zig) reads tools/ts/package.json
        # and nothing refuses the root manifest, so neither of the two facts
        # this repository states about the JS toolchain was enforced on half of
        # it: `bun install` runs a lifecycle script only for a package named in
        # trustedDependencies, and every component in the document is marked
        # dev-only because both manifests declare dev-only dependencies. A
        # range specifier is a third, quieter version of the same gap: the
        # lockfile pins what resolved, so an unlocked range only shows up at
        # the next `bun install`.
        managers: set = set()
        for path, lockfile, manifest in sbom.npm_manifests():
            with self.subTest(manifest=path):
                self.assertNotIn(
                    sbom.NPM_LIFECYCLE_KEY, manifest,
                    f"{path} grants install-time code execution to a package",
                )
                for key in sbom.NPM_PRODUCTION_KEYS:
                    self.assertNotIn(
                        key, manifest,
                        f"{path} declares {key}; the document marks every "
                        "component dev-only",
                    )
                dev = manifest.get("devDependencies")
                self.assertTrue(dev, f"{path} declares no devDependencies")
                for name, spec in dev.items():
                    self.assertTrue(
                        sbom.is_exact_version(spec),
                        f"{path} pins {name} as {spec!r}, which is not one "
                        "exact release",
                    )
                # A manifest edited without re-locking resolves a different
                # tree on the next install than the one this document and the
                # `bun install --frozen-lockfile` gate were built from.
                self.assertEqual(
                    dev, sbom.workspace_devdeps(lockfile),
                    f"{path} and {lockfile} disagree on the direct devDependencies",
                )
                # tools/ts/dist/ is committed, so `tools/ts/verify.sh` rebuilds
                # and diffs it with whatever bun the runner has. The root
                # manifest pinned the package manager; this one did not, so
                # the tree that produces a shipped artifact was the one
                # resolving against an unpinned bun.
                pinned = manifest.get("packageManager", "")
                self.assertTrue(
                    pinned.startswith("bun@"),
                    f"{path} pins no bun version as packageManager",
                )
                managers.add(pinned)
        # One toolchain builds both trees: the AssemblyScript guests and the
        # Tailwind sheet are produced by the same project release.
        self.assertEqual(len(managers), 1)

    def test_ast_grep_grammar_is_recorded_and_commit_pinned(self) -> None:
        # grammars/build.sh clones a third-party repository, checks out a
        # commit and compiles it into zig.so, and nothing named that component
        # in the document or the license inventory. A branch name or a short
        # SHA is not a fetchable ref, so the pin is a full commit id; this says
        # so rather than trusting the comment that says it.
        grammar = sbom.tree_sitter_grammar()
        self.assertIsNotNone(grammar)
        self.assertRegex(grammar["version"], sbom.GRAMMAR_COMMIT)
        purl = f'pkg:github/tree-sitter-grammars/tree-sitter-zig@{grammar["version"]}'
        component = self.components[purl]
        self.assertEqual(component["scope"], "optional")
        properties = {p["name"]: p["value"] for p in component["properties"]}
        self.assertEqual(
            properties["clanker:pin"], "grammars/build.sh:REF_ZIG"
        )
        self.assertEqual(
            component["externalReferences"],
            [{"type": "vcs", "url": grammar["url"]}],
        )

    def test_build_toolchain_is_recorded(self) -> None:
        # Every dependency the binary links was named and no compiler was, so
        # the document could not say what built the artifact it ships. The pin
        # lives in build.zig.zon alone, which is where CI reads the version it
        # installs from.
        toolchain = sbom.zig_toolchain()
        self.assertIsNotNone(toolchain)
        component = self.components[
            sbom.generic_purl(toolchain["name"], toolchain["version"])
        ]
        self.assertEqual(component["scope"], "required")
        properties = {p["name"]: p["value"] for p in component["properties"]}
        self.assertEqual(
            properties["clanker:pin"], "build.zig.zon:minimum_zig_version"
        )

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
        sqlite = sbom.vendored_sqlite()
        self.assertIsNotNone(sqlite)
        names += [sqlite["name"], sbom.vendored_toml()["name"]]
        grammar = sbom.tree_sitter_grammar()
        self.assertIsNotNone(grammar)
        names += [grammar["name"]]
        for name in names:
            with self.subTest(dependency=name):
                self.assertIn(name, inventory)

    def test_vendored_digests_match_the_committed_bytes(self) -> None:
        # ui/vendor/README.md calls its SHA-256 column "the integrity
        # reference for the committed bytes" and vendor/sqlite/README.md the
        # only integrity reference the amalgamation zip had. Nothing checked
        # either against the file, so a re-vendored, re-minified or edited
        # copy left a table asserting a digest the served bytes never had.
        digests = sbom.recorded_digests()
        self.assertTrue(digests)
        for path, recorded in digests:
            with self.subTest(path=path):
                full = sbom.REPO_ROOT / path
                self.assertTrue(full.is_file(), f"{path} is recorded but absent")
                self.assertEqual(
                    hashlib.sha256(full.read_bytes()).hexdigest(), recorded
                )

    def test_every_vendored_file_records_a_digest(self) -> None:
        recorded = {path for path, _ in sbom.recorded_digests()}
        present = {
            str(p.relative_to(sbom.REPO_ROOT))
            for p in sorted((sbom.REPO_ROOT / "ui/vendor").iterdir())
            if p.suffix == ".js"
        }
        self.assertTrue(present)
        self.assertEqual(present - recorded, set())

    def test_web_vendor_digests_reach_the_document(self) -> None:
        # A digest that stays in the README is a promise in prose; a consumer
        # or scanner reads the document, so the hash has to be in it.
        for w in sbom.vendored_web():
            component = next(
                c for c in self.components.values() if c["name"] == w["upstream"].strip()
            )
            with self.subTest(file=w["file"]):
                self.assertIn(
                    "ui/vendor/" + w["file"],
                    [p["value"] for p in component["properties"]
                     if p["name"] == "clanker:vendor-path"],
                )
                self.assertIn(
                    w["sha256"],
                    [p["value"] for p in component["properties"]
                     if p["name"].startswith("clanker:sha256-")],
                )


if __name__ == "__main__":
    unittest.main()
