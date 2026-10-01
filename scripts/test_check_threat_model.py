#!/usr/bin/env python3
"""Tests for scripts/check-threat-model.py.

The checker exists because a claim in a document went stale three reviews
running, and the fourth pass shipped the script that could have caught it. A
checker that silently stops detecting drift is the failure it was written to
prevent, so the tests here pin the part that is easy to break by accident: the
script lives beside this file rather than inside the package, so its module
path is set up explicitly rather than imported for free.
"""

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "check-threat-model.py"


def load_checker():
    """Import the checker by path: `scripts/` is not a package."""
    spec = importlib.util.spec_from_file_location("check_threat_model", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CheckerUnit(unittest.TestCase):
    """Direct tests of the resolution rules, on a fixture tree."""

    def setUp(self):
        self.mod = load_checker()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tree = self.mod.Tree(root=self.tmp.name)

    def write(self, rel, text):
        target = pathlib.Path(self.tmp.name) / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def test_resolve_matches_a_definition_in_the_span(self):
        self.write("src/a.zig", "pub fn one() void {}\npub fn two() void {}\n")
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 1, 1, ["one"])
        self.assertTrue(ok)

    def test_resolve_rejects_a_line_holding_another_symbol(self):
        # The fixture has to put the cited line far from `one`: the rule accepts
        # a definition within WINDOW lines, so an adjacent line is *meant* to
        # pass. Only a citation that points into unrelated code must fail.
        filler = "".join(f"// unrelated line {n}\n" for n in range(20))
        self.write("src/a.zig", "pub fn one() void {}\n" + filler + "pub fn two() void {}\n")
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 22, 22, ["one"])
        self.assertFalse(ok)

    def test_resolve_accepts_a_definition_a_few_lines_below(self):
        self.write("src/a.zig", "// a caller\n// calls this:\npub fn one() void {}\n")
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 1, 2, ["one"])
        self.assertTrue(ok)

    def test_resolve_rejects_a_missing_file(self):
        ok, detail = self.mod.resolve(self.tree, "src/gone.zig", 1, 1, ["one"])
        self.assertFalse(ok)
        self.assertIn("no such file", detail)

    def test_resolve_tolerates_a_span_past_the_end_as_a_port_number(self):
        self.write("src/a.zig", "pub fn one() void {}\n")
        ok, detail = self.mod.resolve(self.tree, "src/a.zig", 17921, 17921, ["one"])
        self.assertTrue(ok)
        self.assertIn("port number", detail)

    def test_assert_text_fails_when_the_line_moved_off_the_code(self):
        self.write("src/a.zig", "pub fn unrelated() void {}\n" * 40 + "const max_body_bytes = 1;\n")
        last = 41
        ok, _ = self.mod.assert_text(self.tree, "src/a.zig", last, last, ("max_body_bytes",))
        self.assertTrue(ok)
        ok, detail = self.mod.assert_text(self.tree, "src/a.zig", 1, 1, ("max_body_bytes",))
        self.assertFalse(ok)
        self.assertIn("max_body_bytes", detail)


class CheckerEndToEnd(unittest.TestCase):
    """Run the script as a process, which is how a reader will run it."""

    def run_script(self, doc_text):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        doc = pathlib.Path(tmp.name) / "TM.md"
        doc.write_text(doc_text, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(doc)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_clean_model_exits_zero(self):
        doc = "`src/config.zig:1`\n"
        # a bare line number cannot be verified, so it must still not fail
        result = self.run_script(doc)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 stale", result.stdout)

    def test_missing_file_exits_nonzero(self):
        result = self.run_script("`docs/nope.md:12`\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("stale", result.stdout)

    def test_the_shipped_model_is_clean(self):
        """The committed model must pass, or the header claim is false again."""
        model = SCRIPT.parent.parent / "docs" / "THREAT_MODEL.md"
        if not model.exists():
            self.skipTest("threat model not present")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(model)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
