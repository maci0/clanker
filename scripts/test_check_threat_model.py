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
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 1, 2, ["one"],
                                 primary="one")
        self.assertTrue(ok)

    def test_resolve_refuses_the_nearby_tolerance_for_a_neighbouring_symbol(self):
        """The chatroom row: five handlers named, three citations stale.

        `nearby` used to answer for any symbol in the cell, so a citation for
        `handleChatPin` passed because `handleChatSubscribe` happened to be
        four lines off. Only the symbol the clause named may use the window.
        """
        self.write(
            "src/a.zig",
            "pub fn one() void {}\n"
            + "".join(f"// filler {n}\n" for n in range(2))
            + "pub fn two() void {}\n"
            + "".join(f"// filler {n}\n" for n in range(20)),
        )
        # A citation naming `two`, sitting inside the trailing filler and so
        # far from both definitions that only `one` is within the window.
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 24, 24, ["one", "two"],
                                 primary="two")
        self.assertFalse(ok)

    def test_resolve_accepts_a_line_inside_the_body_it_names(self):
        """A clause citing a guard clause, not the `fn` line, is correct.

        The readiness report is cited at the line that builds the JSON
        envelope, several lines below `readinessBody`. The span test is what
        keeps that honest: it stops at the closing brace, so the next
        function's body does not satisfy it either.
        """
        self.write(
            "src/a.zig",
            "fn outer() void {\n"
            "    const s = \"{\";\n"
            "    _ = s;\n"
            "}\n"
            + "".join(f"// filler {n}\n" for n in range(20))
            + "fn inner() void {\n"
            "    _ = 1;\n"
            "}\n",
        )
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 2, 2, ["outer"],
                                 primary="outer")
        self.assertTrue(ok)
        # Line 25 is `inner`'s body; naming `outer` there is drift, and it is
        # far enough out that neither the span nor the window can excuse it.
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 26, 26, ["outer", "inner"],
                                 primary="outer")
        self.assertFalse(ok)

    def test_resolve_holds_a_clause_to_its_own_symbol_not_the_cell(self):
        """`readinessBody src/cli.zig:8138` must not pass on a neighbour.

        `max_connection_threads` is defined on that line and the risk row
        names it too, so an any-of match reports clean. The clause named
        `readinessBody`, so that is what the citation has to reach.
        """
        self.write(
            "src/a.zig",
            "const max_connection_threads: u16 = 64;\n"
            + "".join(f"// filler {n}\n" for n in range(20))
            + "fn readinessBody() void {}\n",
        )
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 1, 1,
                                 ["max_connection_threads", "readinessBody"],
                                 primary="readinessBody")
        self.assertFalse(ok)

    def test_defs_resolves_a_module_qualified_name_to_the_bare_symbol(self):
        """`cli_plugins.resolveTier2` is defined under the bare name."""
        self.write("src/cli/plugins.zig", "fn resolveTier2() bool {\n    return true;\n}\n")
        self.assertEqual(
            self.tree.defs("src/cli/plugins.zig", "cli_plugins.resolveTier2"), [1])

    def test_resolve_still_matches_an_exact_span_from_any_cell_symbol(self):
        """Splitting out `nearby` must not cost the any-of exact match.

        The DoS row cites a constant, the cap and the refusing thread from one
        cell; each reference answers a different symbol, all inside the span.
        """
        self.write("src/a.zig", "const cap: usize = 8;\nfn other() void {}\n")
        ok, _ = self.mod.resolve(self.tree, "src/a.zig", 1, 2, ["cap", "other"],
                                 primary="other")
        self.assertTrue(ok)

    def test_resolve_rejects_a_missing_file(self):
        ok, detail = self.mod.resolve(self.tree, "src/gone.zig", 1, 1, ["one"])
        self.assertFalse(ok)
        self.assertIn("no such file", detail)

    def test_resolve_tolerates_a_span_past_the_end_as_a_port_number(self):
        self.write("src/a.zig", "pub fn one() void {}\n")
        ok, detail = self.mod.resolve(self.tree, "src/a.zig", 17921, 17921, ["one"], bare=True)
        self.assertTrue(ok)
        self.assertIn("port number", detail)

    def test_resolve_rejects_a_span_past_the_end_that_names_its_file(self):
        """A `file:NNNN` citation past EOF is drift, not a port.

        The port waiver existed because prose writes bare `:17921` for a port.
        It applied to both forms, so rewiring a citation to any large number
        reported clean instead of stale -- a hole a moved symbol walked
        straight through, in the one check whose whole job is reporting those.
        """
        self.write("src/a.zig", "pub fn one() void {}\n")
        ok, detail = self.mod.resolve(self.tree, "src/a.zig", 17921, 17921, ["one"])
        self.assertFalse(ok)
        self.assertIn("out of range", detail)

    def test_a_citation_rewired_past_eof_is_reported_stale(self):
        """End to end, not just resolve(): the hole was in the report."""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        (root / "src").mkdir()
        (root / "src" / "a.zig").write_text("pub fn one() void {}\n", encoding="utf-8")
        doc = root / "TM.md"
        doc.write_text("Cited `src/a.zig:1` and `src/a.zig:99999`.\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(doc)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("stale", result.stdout)

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
