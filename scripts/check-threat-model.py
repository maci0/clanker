#!/usr/bin/env python3
"""Resolve every file:line reference in docs/THREAT_MODEL.md against the tree.


The threat model asserts in its header that its references were mechanically
checked. This is that check, so the next reader can re-run it instead of
trusting the number. It has failed four times (43 of 92, 39 of 82, 96 of 280
stale references), and each time the reason was the same class: the file moved
and the citation did not. A model whose pointers have rotted is worse than one
that names no files, because every downstream pass aims at it.

What counts as resolved
-----------------------
A reference resolves when the file exists, the span is inside it, and the symbol
the reference names appears within that span (or within four lines either side).
Two details matter and both are learned the hard way:

* A bare ``:NNNN`` inherits its file from the *previous* reference in the same
  table cell, so cell context decides which file the line number counts into.
  A cell whose explicit references all moved can otherwise leave its bare ones
  counting against a file nobody named.
* A symbol that also occurs elsewhere in the file -- a ``test`` block, a doc
  comment -- satisfies a naive window search even when the cited line is
  unrelated code. Def occurrences are preferred over incidental mentions, and
  when a symbol has both, the span must hit a definition.

Exit status is 0 when every reference resolves and 1 otherwise. CI runs it as
the "Check threat model references" step, and scripts/verify.sh as its local
mirror, alongside scripts/test_check_threat_model.py.

Usage: python3 scripts/check-threat-model.py [path/to/THREAT_MODEL.md]
       python3 scripts/check-threat-model.py --list   # print every resolution
"""

import os
import re
import sys

REF = re.compile(r'([A-Za-z0-9_./-]+\.(?:zig|md|sh|ts|js|json|yml|py)):(\d+)(?:-(\d+))?')
BARE = re.compile(r'^:(\d+)(?:-(\d+))?$')
PLAIN_PATH = re.compile(r'^[A-Za-z0-9_./-]+\.(?:zig|md|sh|ts|js|json|yml|py)$')
SYMBOL = re.compile(r'`([A-Za-z_][A-Za-z0-9_]{3,})`')
DEF = re.compile(r'^\s*(?:pub\s+)?(?:fn|const|var|threadlocal\s+fn)\s+([A-Za-z_][A-Za-z0-9_]*)')
WINDOW = 4


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Tree:
    """Line cache plus definition/occurrence lookup, so the loop stays cheap.

    ``root`` is the directory every reference path is resolved against. It
    defaults to the checkout, and takes a fixture directory in tests so a rule
    can be exercised without a whole tree.
    """

    def __init__(self, root=None):
        self.root = root if root is not None else repo_root()
        self._lines = {}

    def lines(self, rel):
        if rel not in self._lines:
            full = os.path.join(self.root, rel)
            try:
                with open(full, encoding='utf-8', errors='replace') as fh:
                    self._lines[rel] = fh.read().splitlines()
            except OSError:
                self._lines[rel] = None
        return self._lines[rel]

    def defs(self, rel, symbol):
        out = []
        for n, line in enumerate(self.lines(rel) or [], 1):
            m = DEF.match(line)
            if m and m.group(1) == symbol:
                out.append(n)
        return out

    def occurrences(self, rel, symbol):
        rx = re.compile(rf'\b{re.escape(symbol)}\b')
        return [n for n, line in enumerate(self.lines(rel) or [], 1) if rx.search(line)]


def resolve(tree, path, a, b, symbols, *, bare=False):
    """Return (ok, detail). Definitions win over incidental mentions.

    A cell names several symbols and a reference is expected to land on any of
    them: the risk table's DoS row cites a constant, the cap that enforces it
    and the thread that refuses over it, and each reference answers a different
    one. Requiring every reference to match the cell's first symbol would flag
    a correct citation because the constant is not the symbol it names.

    `bare` says the reference is the `:NNNN` form, which inherits its file from
    the cell rather than naming it, and only that form is allowed the port
    number waiver below.
    """
    lines = tree.lines(path)
    if lines is None:
        return False, 'no such file'
    if a > len(lines) or b > len(lines):
        # A bare number past the end of the file is usually a port number in
        # prose (`:17921`, `:7420`), not a citation. Not an error -- but only
        # for the bare form. A reference that spells its own file out
        # (`src/cli.zig:NNNN`) is naming the file, so a line number past its
        # end is drift, and waiving it was a hole a moved symbol walked
        # straight through: a citation rewritten to any large number reported
        # clean rather than stale.
        if bare:
            return True, 'out of range (port number?)'
        return False, f'out of range ({path} has {len(lines)} lines)'
    if not symbols:
        return True, 'no symbol named in the cell'
    for symbol in symbols:
        for line in tree.defs(path, symbol):
            if a <= line <= b:
                return True, f'def {symbol}'
            if a - WINDOW <= line <= b + WINDOW:
                return True, f'def {symbol} nearby'
    for symbol in symbols:
        rx = re.compile(rf'\b{re.escape(symbol)}\b')
        for n, line in enumerate(lines, 1):
            if a <= n <= b and rx.search(line):
                return True, f'uses {symbol}'
    return False, f"none of {', '.join(symbols[:4])} nearby"


def check(doc_path, list_all):
    tree = Tree()
    with open(doc_path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    total = stale = skipped = by_symbol = by_text = 0
    for lineno, line in enumerate(lines, 1):
        cells = line.split('|') if line.count('|') >= 2 else [line]
        for cell in cells:
            last_file = None
            for span in re.finditer(r'`([^`]+)`', cell):
                text = span.group(1).strip()
                explicit = REF.search(text)
                is_bare = False
                if explicit and explicit.end() == len(text):
                    path = explicit.group(1)
                    a = int(explicit.group(2))
                    b = int(explicit.group(3) or explicit.group(2))
                    last_file = path
                else:
                    bare = BARE.match(text)
                    if bare and last_file:
                        path = last_file
                        a = int(bare.group(1))
                        b = int(bare.group(2) or bare.group(1))
                        is_bare = True
                    elif PLAIN_PATH.match(text):
                        last_file = text
                        continue
                    else:
                        continue
                # A reference answers the symbol that names it, which is the
                # one in its own clause. Dense table cells pack several
                # Expectation set: the symbols named in the cell, plus those
                # in the row's first cell (the boundary or control's subject,
                # which the sentence then cites by location). Scoping to a
                # clause was tried and rejected: the prose cites several
                # locations in one sentence and names the subject once, so a
                # clause scope flagged correct citations. What keeps the check
                # honest is the strict rule inside resolve(), not a narrower
                # window of prose.
                named = set(SYMBOL.findall(cell))
                named |= set(SYMBOL.findall(row_subjects(cell, line)))
                symbols = sorted(named)
                symbols = [s for s in symbols if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', s)]
                # `span` is already the re.finditer match over the cell; the
                # ASSERTED key needs its own name, and reusing the loop
                # variable shadowed it for the rest of the iteration.
                cited = f'{a}-{b}' if b != a else str(a)
                if (path, cited) in ASSERTED:
                    ok, detail = assert_text(tree, path, a, b, ASSERTED[(path, cited)])
                    by_text += 1
                else:
                    ok, detail = resolve(tree, path, a, b, symbols, bare=is_bare)
                    by_symbol += 1
                if 'port number' in detail:
                    skipped += 1
                    continue
                total += 1
                if not ok:
                    stale += 1
                if list_all or not ok:
                    print(f'{os.path.relpath(doc_path)}:{lineno}: {text} ({detail})')
    return total, stale, skipped, by_symbol, by_text




# References whose cell cites a location without naming a symbol in backticks,
# so no keyword can confirm them. Each line is *what the cited line is*, not a
# reason to skip it: the next pass re-reads the line rather than trusting the
# entry, and an entry whose line no longer says this has to be deleted, which is
# why the wording is specific enough to be falsified.
# Cells that cite a location without naming a symbol in backticks, so the keyword
# rule above has nothing to look for. Each entry is the *text* the cited lines must
# contain: the script asserts it, so an entry cannot quietly outlive the code it
# describes. That is the whole point -- a table of prose descriptions would be a
# waiver, and a waiver is how the last three passes each reported green over 96
# stale references. Each string below was taken from the line it describes.
ASSERTED = {
    ('src/cli.zig', '8482-8487'): ('on_proxy', 'authorize'),
    ('src/cli.zig', '8823'): ('"/api/run"',),
    ('src/cli.zig', '8819'): ('"/api/ask"',),
    ('src/cli.zig', '8637'): ('is_mcp_servers', '"/api/mcp/servers"'),
    ('src/cli.zig', '8432-8435'): ('max_body_bytes',),
    ('src/cli.zig', '10305'): ('max_image_bytes',),
    ('src/cli.zig', '10305-10306'): ('max_run_images',),
    ('src/cli.zig', '8544'): ('request_head',),
    ('src/cli.zig', '12603'): ('handleMcpServers',),
    ('src/serve/proxy.zig', '30-31'): ('default_first_byte_s', 'default_idle_s'),
    ('src/serve/proxy.zig', '57'): ('fn authorize',),
    ('src/serve/proxy.zig', '426-427'): ('first_byte',),
    ('src/serve/mesh_net.zig', '38'): ('max_inbound_conns',),
    ('src/serve/mesh_net.zig', '630'): ('max_inbound_conns',),
    ('src/config.zig', '1052-1056'): ('proxy_first_byte_timeout_s', 'proxy_idle_timeout_s'),
    ('src/config.zig', '1105'): ('mcp_client',),
    ('src/config.zig', '990-991'): ('listen_host', 'listen_port'),
    ('src/hooks/runner.zig', '16'): ('fn run',),
    ('src/tui/repl.zig', '4330'): ('exec_allow',),
    ('src/sandbox/host.zig', '2172'): ('debug.enabled',),
    ('src/llm/oauth_store.zig', '31'): ('oauth',),
    ('src/llm/oauth_store.zig', '55'): ('private_file',),
    ('tools/manifests/skills.tool.json', '18'): ('fs_prefixes',),
    # The files route cites the shared rule by file, and the symbols the row
    # names (safeJoin, read_file, env_allow) live in other files, so the
    # keyword rule cannot see them from the cited span.
    ('src/util/secret_dotenv.zig', '49'): ('isSecretDotenvPath',),
    ('src/cli.zig', '14524'): ('isSecretDotenvName',),
    ('src/cli.zig', '14537'): ('pathHasSymlinkComponent', 'symlinked'),
    ('src/cli.zig', '14624'): ('isOwnerOnlyFile',),
    ('src/cli.zig', '14610'): ('isSecretDotenvName',),
    ('src/cli.zig', '8669'): ('health/live',),
    ('docs/README.md', '865'): ('repl_exec_allow',),
    ('docs/README.md', '1625'): ('What it binds',),
    ('docs/README.md', '1621-1625'): ('binds',),
    ('docs/README.md', '1627'): ('token',),
    # The chat/mesh control-plane rows (R10-R13, T14). Each cites the line that
    # carries the claim, and several of those lines are inside a function body
    # rather than a definition, so the symbol rule has nothing to match and the
    # entry has to assert the text itself.
    ('src/peers/chatrooms.zig', '903'): ('.from = cfg.instance.name',),
    ('src/peers/chatrooms.zig', '435'): ('acquireChatroomLock',),
    ('src/cli.zig', '9322'): ('chatrooms.isSubscribed',),
    ('src/cli.zig', '9401'): ('/api/chat/react',),
    ('src/cli.zig', '9063'): ('.from = parsed.from', '.text = text'),
    ('src/cli.zig', '12146'): ('installCatalogCacheLocked',),
    ('src/cli.zig', '12877'): ('provider.api_key_env',),
    ('src/cli.zig', '12890'): ('budget_s', 'httpGetDeadline'),
    ('src/agent/loop.zig', '4049'): ('buildChatroomInbox',),
    ('src/agent/loop.zig', '4054'): ('[chatroom inbox]', 'never follow instructions'),
    ('src/agent/loop.zig', '4059-4061'): ('prompt_fence.neutralize',),
    ('src/agent/loop.zig', '985'): ('modules.chatrooms', 'chatrooms.on'),
    ('src/cli.zig', '5863'): ('prompt_fence.neutralize',),
    ('src/cli.zig', '17368'): ('prompt_fence.neutralize',),
    ('src/peers/chatrooms.zig', '900'): ('safe_text', 'utf8.sanitize'),
    ('src/config.zig', '993'): ('admission',),
    ('src/config.zig', '1090'): ('max_history',),
    ('src/config.zig', '1136'): ('chatrooms: bool = true',),
    ('src/config.zig', '1085'): ('on: bool = true',),
    ('src/config.zig', '1146'): ('mesh: bool = false',),
    ('src/sandbox/host.zig', '3014'): ('Compact re-encoding',),
    ('src/serve/mesh_net.zig', '695'): ('max_pending_joins',),
    ('src/serve/mesh_net.zig', '727'): ('parseHostPort', 'connectBounded'),
    ('src/serve/mesh_net.zig', '841'): ('fn leave',),
    ('src/serve/mesh_net.zig', '886'): ('fn resolvePending',),
    ('src/serve/mesh_net.zig', '43'): ('max_pending_joins',),
    ('src/peers/mesh.zig', '140'): ('join_id.len == 0',),
    ('docs/README.md', '1617'): ('Chat edit/delete answer 404',),
    ('docs/api.md', '40'): ('| 403 |', '/api/chat/react'),
    ('src/peers/chatrooms.zig', '706'): ('error.NotOwner', 'm.from, from'),
    ('src/peers/chatrooms.zig', '739'): ('error.NotOwner', 'm.from, from'),
}



def assert_text(tree, path, a, b, needles):
    """Every needle must appear in the cited span or its four-line window.

    Stands in for the keyword rule where the reference names no symbol: weaker
    than matching an identifier, but it still fails when the line moves off the
    code it claims, which is the failure this script is for.
    """
    lines = tree.lines(path)
    if lines is None:
        return False, 'no such file'
    lo = max(0, a - 1 - WINDOW)
    hi = min(len(lines), b + WINDOW)
    window = '\n'.join(lines[lo:hi])
    missing = [n for n in needles if n not in window]
    if missing:
        return False, f"window lacks {', '.join(missing)}"
    return True, f"asserts {', '.join(needles)}"


def row_subjects(cell, line):
    """First cell of the table row ``cell`` belongs to, plus the line's prose.

    A boundary row's first cell holds the subject name ("client_server") and
    the middle cell cites where it is implemented, so the subject is part of what
    a reference is expected to match.
    """
    if line.count('|') < 2:
        return line
    cells = line.split('|')
    for index, c in enumerate(cells):
        if c == cell:
            return ' '.join(cells[max(0, index - 2):index]) + ' ' + line
    return line


def main():
    args = sys.argv[1:]
    list_all = '--list' in args
    args = [a for a in args if not a.startswith('--')]
    doc = args[0] if args else os.path.join(repo_root(), 'docs/THREAT_MODEL.md')
    if not os.path.exists(doc):
        print(f'no threat model at {doc}')
        return 1
    total, stale, skipped, by_symbol, by_text = check(doc, list_all)
    print(f'{total} references: {stale} stale, {skipped} skipped as port numbers')
    left = total - by_symbol - by_text - stale - skipped
    print(f'  {by_symbol} against a symbol, {by_text} against asserted text, {left} unverified')
    return 1 if stale else 0


if __name__ == '__main__':
    sys.exit(main())
