#!/usr/bin/env python3
"""Subset the vendored PatternFly CSS to the components the UI actually uses.

The web UI references a handful of pf-v6-c-* components (see ui/PATTERNFLY.md);
the stock build ships every component. This script scans ui/app and ui/plugins
for pf-v6 class tokens, then keeps only:

  - style rules whose every pf-v6-{c,l,u}-* token is a used component,
  - rules with no pf-v6 component token at all (:root tokens, body, themes),
  - at-rules (@font-face, @charset, @property, @keyframes),
  - @media / @supports blocks, recursively filtered, kept when non-empty.

Regenerate after a PatternFly upgrade:

    python3 scripts/subset-patternfly.py \
        --css <fresh patternfly.min.css from the release> \
        --out ui/vendor/patternfly.min.css

Source: https://unpkg.com/@patternfly/patternfly@6/patternfly.min.css
"""

import argparse
import re
import sys
from pathlib import Path

COMPONENT_RE = re.compile(r"pf-v6-[clu]-[a-z0-9]+(?:-[a-z0-9]+)*")


def scan_used(src_dirs):
    """Collect every pf-v6 component token referenced by JS/HTML sources."""
    used = set()
    for d in src_dirs:
        for path in Path(d).rglob("*"):
            if path.suffix not in (".js", ".mjs", ".html"):
                continue
            used.update(COMPONENT_RE.findall(path.read_text(errors="replace")))
    return used


def split_rules(css):
    """Yield (prelude, body) for each top-level rule; body is None for
    statement at-rules (@charset ...;). Handles nested braces and strings."""
    i, n = 0, len(css)
    while i < n:
        while i < n and css[i] in " \t\r\n":
            i += 1
        if i >= n:
            return
        start = i
        depth = 0
        body_start = -1
        while i < n:
            c = css[i]
            if c in "\"'":
                q = c
                i += 1
                while i < n and css[i] != q:
                    i += 2 if css[i] == "\\" else 1
            elif c == "{":
                if depth == 0:
                    body_start = i
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    yield css[start:body_start], css[body_start + 1 : i]
                    i += 1
                    break
            elif c == ";" and depth == 0:
                yield css[start:i], None
                i += 1
                break
            i += 1
        else:
            return


def keep_selector(prelude, used):
    tokens = COMPONENT_RE.findall(prelude)
    return all(t in used for t in tokens)


def filter_css(css, used):
    out = []
    for prelude, body in split_rules(css):
        p = prelude.strip()
        if body is None:
            out.append(p + ";")
        elif p.startswith(("@media", "@supports", "@layer", "@container")):
            inner = filter_css(body, used)
            if inner:
                out.append(p + "{" + inner + "}")
        elif p.startswith("@"):
            # @font-face, @keyframes, @property: small, keep unconditionally.
            out.append(p + "{" + body + "}")
        elif keep_selector(p, used):
            out.append(p + "{" + body + "}")
    return "".join(out)


def self_test():
    used = {"pf-v6-c-button"}
    css = (
        "@charset \"UTF-8\";"
        ":root{--pf-t--x:1}"
        ".pf-v6-c-button{color:red}"
        ".pf-v6-c-card{color:blue}"
        ".pf-v6-c-card .pf-v6-c-button{color:green}"
        "@media (min-width:600px){.pf-v6-c-button{a:b}.pf-v6-c-card{c:d}}"
        "@media print{.pf-v6-c-card{c:d}}"
        "@keyframes spin{to{transform:rotate(1turn)}}"
        ".a{content:'}{'}"
    )
    got = filter_css(css, used)
    assert "@charset" in got
    assert ":root{--pf-t--x:1}" in got
    assert ".pf-v6-c-button{color:red}" in got
    assert ".pf-v6-c-card{color:blue}" not in got
    assert "color:green" not in got  # descendant of unused component
    assert "@media (min-width:600px){.pf-v6-c-button{a:b}}" in got
    assert "@media print" not in got  # emptied block dropped
    assert "@keyframes spin" in got
    assert ".a{content:'}{'}" in got  # brace inside string survives
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--css", default="ui/vendor/patternfly.min.css")
    ap.add_argument("--out", default="ui/vendor/patternfly.min.css")
    ap.add_argument("--src", nargs="*", default=["ui/app", "ui/plugins"])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return

    used = scan_used(args.src)
    if not used:
        sys.exit("no pf-v6 tokens found under " + ", ".join(args.src))
    css = Path(args.css).read_text()
    out = filter_css(css, used)
    for token in sorted(used):
        if token not in out:
            sys.exit(f"used component {token} missing from subset output")
    Path(args.out).write_text(out)
    print(
        f"{len(css)} -> {len(out)} bytes "
        f"({100 * len(out) // len(css)}%), {len(used)} components: "
        + " ".join(sorted(used))
    )


if __name__ == "__main__":
    main()
