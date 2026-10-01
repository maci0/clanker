"""Tests for scripts/release-checksum.sh.

The script's exit code is the last thing between a broken release and a
published one: `release-publish` runs `verify` on the merged artifact
directory before it creates anything. A sidecar proves the bytes it names are
intact, and a binary with no sidecar is refused, but neither answers "did
every target the release matrix builds actually arrive?" — so a dist holding
two of the four shipped targets verified clean and published as a healthy
release. These drive the shipped script against a real directory and assert
both answers.
"""

import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("release-checksum.sh")
REPO = SCRIPT.parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "ci.yml"
# The tag the fixtures below stand in for. It only ever appears in file names
# inside a temp dir, so any vX.Y.Z works.
TAG = "v9.9.9"


def shipped_targets() -> list[str]:
    """Target names the release-build matrix declares, in matrix order.

    Read from the workflow the matrix lives in rather than restated, so a
    target added to the matrix is required by the shipped script and by this
    test without either being edited. The extraction is the same range and
    the same substitution scripts/release-checksum.sh uses, so the test
    cannot pass against a list the script does not read.
    """
    text = WORKFLOW.read_text(encoding="utf-8")
    in_job = False
    targets: list[str] = []
    for line in text.splitlines():
        if line.startswith("  release-build:"):
            in_job = True
            continue
        # The next 2-space job key ends this one.
        if in_job and re.match(r"^  [a-z][a-z-]*:$", line):
            break
        # A matrix entry spells its target on a `target:` key of its own line
        # (`- os:` and `target:` are separate lines), not `- target:`.
        if in_job and re.match(r"^\s*target: ", line):
            targets.append(line.split(":", 1)[1].strip())
    if not targets:
        raise AssertionError(f"{WORKFLOW} declares no release-build matrix targets")
    return targets


class ReleaseChecksumTest(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dist = Path(self._tmp.name) / "dist"
        self.dist.mkdir()
        self.targets = shipped_targets()

    def stage(self, target: str) -> Path:
        """One release binary with the sidecar the matrix job writes for it."""
        path = self.dist / f"clanker-{TAG}-{target}"
        path.write_text(f"bytes for {target}\n", encoding="utf-8")
        self.write_sidecar(path)
        return path

    @staticmethod
    def write_sidecar(binary: Path) -> None:
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        # The basename, not the path it was written from: a sidecar carrying a
        # build path is useless to a consumer who unpacks the release anywhere.
        (binary.parent / f"{binary.name}.sha256").write_text(
            f"{digest}  {binary.name}\n", encoding="utf-8"
        )

    def run_verify(self) -> subprocess.CompletedProcess:
        # check=False because the return code IS the answer under test.
        return subprocess.run(
            [str(SCRIPT), "verify", str(self.dist)],
            cwd=REPO,
            env=dict(os.environ),
            capture_output=True,
            text=True,
            check=False,
        )

    def run_create(self, *files: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(SCRIPT), "create", *(str(f) for f in files)],
            cwd=REPO,
            env=dict(os.environ),
            capture_output=True,
            text=True,
            check=False,
        )

    def test_complete_dist_passes(self) -> None:
        for target in self.targets:
            self.stage(target)
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_shipped_target_is_refused(self) -> None:
        # Every target but one, each with a sidecar that verifies: the only
        # thing wrong is that a matrix leg's binary never arrived.
        missing = self.targets[-1]
        for target in self.targets[:-1]:
            self.stage(target)
        result = self.run_verify()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(missing, result.stderr)

    def test_binary_without_a_sidecar_is_refused(self) -> None:
        for target in self.targets:
            self.stage(target)
        unpaired = self.dist / f"clanker-{TAG}-extra-target"
        unpaired.write_text("no sidecar\n", encoding="utf-8")
        result = self.run_verify()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("extra-target", result.stderr)

    def test_tampered_binary_is_refused(self) -> None:
        binary = self.stage(self.targets[0])
        binary.write_text("bytes that are not what the sidecar recorded\n", encoding="utf-8")
        result = self.run_verify()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_create_writes_the_basename_not_the_build_path(self) -> None:
        binary = self.stage(self.targets[0])
        sidecar = Path(f"{binary}.sha256")
        sidecar.unlink()
        result = self.run_create(binary)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        recorded = sidecar.read_text(encoding="utf-8").strip()
        self.assertTrue(recorded.endswith(f"  {binary.name}"), recorded)
        self.assertNotIn(str(self._tmp.name), recorded)

    def test_dir_with_no_sidecars_at_all_is_refused(self) -> None:
        (self.dist / f"clanker-{TAG}-{self.targets[0]}").write_text("bare\n", encoding="utf-8")
        result = self.run_verify()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
