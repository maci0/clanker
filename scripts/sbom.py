#!/usr/bin/env python3
"""Generate a CycloneDX 1.5 software bill of materials for a clanker release.

Reads only in-tree manifests, so it runs offline and never sends the package
list anywhere:

- build.zig.zon            — the Zig release that builds the host binary, and
                             zwasm, vaxis (zig hash-pinned)
- vendor/toml/README.md    — vendored zig-toml (MIT)
- vendor/sqlite/README.md  — vendored SQLite amalgamation (Public Domain)
- package.json             — root devDependencies, paired with bun.lock
- tools/ts/package.json    — AssemblyScript devDependency
- bun.lock                 — oxlint, tailwindcss + transitive npm deps
- tools/ts/bun.lock        — assemblyscript + transitive npm deps
- ui/vendor/README.md      — vendored web UI JS/CSS
- scripts/setup-python-wasi.sh — optional kernel CPython interpreter
- grammars/build.sh        — optional ast-grep Zig grammar (commit-pinned)

Every component is tied back to the exact in-tree artifact that pins it (the
zig hash, the bun.lock registry digest, or the committed vendored file path), so
consumers and vulnerability scanners know precisely what shipped even for
files whose upstream version is not recorded in the file itself.

Output is deterministic (sorted components, stable serial number, timestamp
only when SOURCE_DATE_EPOCH is set), so the same tag always produces the same
document — same idea as the fixed SOURCE_DATE_EPOCH in CI.

Usage: scripts/sbom.py [-o out.cdx.json]   (default: stdout)
"""

import base64
import json
import os
import re
import sys
import uuid
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parent.parent

CDX_VERSION = "1.5"


def die(msg: str) -> NoReturn:
    print(f"sbom: {msg}", file=sys.stderr)
    sys.exit(1)


def read(path: str) -> str:
    full = REPO_ROOT / path
    try:
        return full.read_text(encoding="utf-8")
    except OSError as e:
        die(f"cannot read {full}: {e}")


def project_version() -> str:
    m = re.search(r'^\s*\.version\s*=\s*"([^"]+)"', read("build.zig.zon"), re.M)
    if not m:
        die("build.zig.zon has no .version")
    return m.group(1)


# --- zig dependencies (build.zig.zon) -------------------------------------

def zig_dependencies() -> list:
    """Parse `.dependencies = .{ .name = .{ .url, .hash }, ... }` blocks."""
    text = read("build.zig.zon")
    block = re.search(r"\.dependencies\s*=\s*\.\{", text)
    if not block:
        return []
    body = text[block.end():]
    depth = 0
    for i, ch in enumerate(body):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                body = body[:i]
                break
    deps = []
    for m in re.finditer(
        r"\.([A-Za-z0-9_]+)\s*=\s*\.\{\s*\.url\s*=\s*\"([^\"]+)\"\s*,\s*"
        r"\.hash\s*=\s*\"([^\"]+)\"",
        body,
    ):
        name, url, zhash = m.group(1), m.group(2), m.group(3)
        version = None
        tag = re.search(r"tags/v([0-9][0-9A-Za-z._-]*?)(?:\.tar\.gz|$)", url)
        if tag:
            version = tag.group(1)
        else:
            # zig hash format: <name>-<version>-<digest>; the digest may
            # itself contain '-'/'_', so the version is the first token.
            rest = zhash[len(name) + 1:]
            first = rest.split("-", 1)[0]
            if re.fullmatch(r"[0-9][0-9A-Za-z._]*", first):
                version = first
        deps.append({
            "name": name,
            "version": version or "unknown",
            "url": url,
            "hash": zhash,
        })
    return deps


# --- vendored zig-toml (vendor/toml/README.md) ------------------------------

def vendored_toml() -> dict | None:
    text = read("vendor/toml/README.md")
    m = re.search(
        r"Vendored from \[[^\]]+\]\([^)]*\) at commit\s*`([0-9a-f]+)`\s*"
        r"\(v([0-9][0-9A-Za-z._-]*)\)\s*,\s*([A-Za-z0-9 .-]+?)\s+licensed",
        text,
    )
    if not m:
        return None
    return {
        "name": "zig-toml",
        "version": "v" + m.group(2),
        "commit": m.group(1),
        "license": m.group(3).strip(),
    }


# --- vendored SQLite amalgamation (vendor/sqlite/README.md) ------------------

def vendored_sqlite() -> dict | None:
    text = read("vendor/sqlite/README.md")
    ver = re.search(r"SQLite ([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?) amalgamation", text)
    url = re.search(r"fetched from\s*<([^>]+)>", text)
    if not ver or not url:
        return None
    c_sha = re.search(r"`sqlite3\.c` sha256\s*`([0-9a-f]{64})`", text)
    h_sha = re.search(r"`sqlite3\.h` sha256\s*`([0-9a-f]{64})`", text)
    return {
        "name": "sqlite",
        "version": ver.group(1),
        "url": url.group(1),
        "c_sha256": c_sha.group(1) if c_sha else None,
        "h_sha256": h_sha.group(1) if h_sha else None,
    }


# --- npm toolchains (bun.lock, tools/ts/bun.lock) ---------------------------

# Both lockfiles are in tree and both resolve dev-only trees: the root one
# (oxlint, tailwindcss) and the AssemblyScript one. Neither reaches a shipped
# binary, so everything they resolve is dev-scope in the document.
NPM_LOCKFILES = ("bun.lock", "tools/ts/bun.lock")

# Each npm manifest with the lockfile that pins it, in the same order. The
# pairing is what lets a check say "this manifest's devDependencies" and
# "that lockfile's workspace block" are the same set, rather than comparing
# two unordered bags of names.
NPM_MANIFESTS = (
    ("package.json", "bun.lock"),
    ("tools/ts/package.json", "tools/ts/bun.lock"),
)

# The manifest keys that would give a package install-time code execution or a
# place in a shipped release. `trustedDependencies` is the one bun honours:
# lifecycle scripts run only for packages named there, so its absence is what
# keeps `bun install` inert. The others are scope, and every component below
# is marked dev-only on the strength of both manifests declaring dev-only
# dependencies.
NPM_LIFECYCLE_KEY = "trustedDependencies"
NPM_PRODUCTION_KEYS = ("dependencies", "optionalDependencies", "peerDependencies")

# A version specifier that resolves to exactly one release. Anything carrying
# a range operator, a comparator or a tag is excluded, so a caret that would
# admit the next minor without review is not an exact pin.
EXACT_VERSION = re.compile(r"[0-9][0-9A-Za-z.+-]*")


def is_exact_version(spec: str) -> bool:
    return bool(EXACT_VERSION.fullmatch(spec))


def _read_lock(lockfile: str) -> dict:
    # bun.lock is JSONC: valid JSON except for trailing commas, which bun emits
    # to keep diffs one-line-per-package. Strip them and parse as JSON.
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", read(lockfile)))


def npm_manifests() -> list:
    """(manifest path, lockfile path, parsed manifest) for every npm manifest.

    A manifest is plain JSON, unlike the JSONC lockfile beside it.
    """
    out = []
    for manifest_path, lockfile in NPM_MANIFESTS:
        try:
            parsed = json.loads(read(manifest_path))
        except json.JSONDecodeError as e:
            die(f"{manifest_path} is not valid JSON: {e}")
        if not isinstance(parsed, dict):
            die(f"{manifest_path} is not a JSON object")
        out.append((manifest_path, lockfile, parsed))
    return out


def workspace_devdeps(lockfile: str) -> dict:
    """The devDependencies each workspace block of `lockfile` declares."""
    workspaces = _read_lock(lockfile).get("workspaces", {})
    if not isinstance(workspaces, dict):
        die(f"{lockfile} has no workspaces object")
    merged: dict = {}
    for entry in workspaces.values():
        merged.update(entry.get("devDependencies", {}))
    return merged


def npm_components() -> list:
    out: dict[tuple[str, str], dict] = {}
    for lockfile in NPM_LOCKFILES:
        lock = _read_lock(lockfile)
        # Each entry is [spec, registry, metadata, integrity]; spec is
        # "name@version" and integrity is the registry digest ("sha512-..."),
        # absent for workspaces.
        for key, entry in lock.get("packages", {}).items():
            if not isinstance(entry, list) or not entry:
                continue
            spec = entry[0]
            name, _, version = spec.rpartition("@")
            name, version = name or key, version or "unknown"
            integrity = next(
                (f for f in entry[1:] if isinstance(f, str) and f.startswith("sha")),
                None,
            )
            # Two lockfiles can name the same package at the same version; the
            # digest is then the same one and the first lockfile read names it.
            out.setdefault((name, version), {
                "name": name,
                "version": version,
                "integrity": integrity,
                # bun.lock records no license field; both manifests declare
                # only devDependencies, so everything resolved is dev-only.
                "license": None,
                "dev": True,
                "lockfile": lockfile,
            })
    return list(out.values())


def npm_direct_devdeps() -> list:
    """Names each lockfile's own workspace declares, in lockfile order."""
    names = []
    for lockfile in NPM_LOCKFILES:
        names.extend(workspace_devdeps(lockfile))
    return names


# --- vendored web UI (ui/vendor/README.md) ----------------------------------

def vendored_web() -> list:
    text = read("ui/vendor/README.md")
    rows = re.findall(
        r"\| `([^`]+)` \| \[([^\]]+)\]\(([^)]*)\)[^|]*\| ([^|`]+) \| ([A-Za-z0-9 .-]+) \|"
        r" `([0-9a-f]{64})` \|",
        text,
    )
    return [
        {
            "file": f, "upstream": u, "url": url,
            "version": v.strip(), "license": lic.strip(), "sha256": sha,
        }
        for f, u, url, v, lic, sha in rows
    ]


# --- recorded digests of the vendored trees ---------------------------------

def recorded_digests() -> list:
    """(in-tree path, recorded sha256) for every vendored file that records one.

    ui/vendor/README.md carries a digest per file, vendor/sqlite/README.md one
    per amalgamation file, and vendor/toml/ records only a source commit (its
    files are patched, so a digest would pin clanker's patch rather than
    upstream and tell a reader nothing). scripts/test_sbom.py checks each
    recorded digest against the committed bytes, so a re-vendored file that
    skipped the table is drift this repository refuses to ship.
    """
    digests = [("ui/vendor/" + w["file"], w["sha256"]) for w in vendored_web()]
    sq = vendored_sqlite()
    if sq:
        if sq["c_sha256"]:
            digests.append(("vendor/sqlite/sqlite3.c", sq["c_sha256"]))
        if sq["h_sha256"]:
            digests.append(("vendor/sqlite/sqlite3.h", sq["h_sha256"]))
    return digests


# --- build toolchain (build.zig.zon) ---------------------------------------

def zig_toolchain() -> dict | None:
    """The compiler release the shipped binary was built with.

    `build.zig.zon` names it once and three readers take it from there: CI
    installs exactly this version, build.zig refuses to configure against any
    other 0.16.x, and scripts/setup.sh warns when the one on PATH disagrees.
    The document named every dependency the binary links and no toolchain at
    all, so the compiler that produced the artifact a consumer downloads was
    the one part of the build nothing recorded.
    """
    m = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', read("build.zig.zon"))
    if not m:
        return None
    return {"name": "zig", "version": m.group(1)}


# --- optional kernel interpreter (scripts/setup-python-wasi.sh) --------------

def python_wasi() -> dict | None:
    text = read("scripts/setup-python-wasi.sh")
    tag = re.search(r"release_tag='([^']+)'", text)
    sha = re.search(r"sha256='([0-9a-f]{64})'", text)
    if not tag or not sha:
        return None
    ver = re.search(r"python/([0-9]+\.[0-9]+\.[0-9]+)", tag.group(1))
    return {
        "name": "python-wasi",
        "version": ver.group(1) if ver else tag.group(1),
        "release_tag": tag.group(1),
        "sha256": sha.group(1),
        "url": "https://github.com/vmware-labs/webassembly-language-runtimes"
               "/releases/download/" + tag.group(1).replace("+", "%2B"),
    }


# --- optional ast-grep grammar (grammars/build.sh) ---------------------------

# ast-grep ships no Zig parser, so structural search over this project's own
# source needs tree-sitter-zig compiled into grammars/zig.so. It is a developer
# tool rather than part of a release, like the kernel interpreter above, but it
# is third-party source this repository fetches, patches and compiles, so the
# document and the license inventory name it like any other fetched component.
GRAMMAR_COMMIT = re.compile(r"^[0-9a-f]{40}$")


def tree_sitter_grammar() -> dict | None:
    text = read("grammars/build.sh")
    url = re.search(r'^REPO_ZIG="([^"]+)"', text, re.M)
    ref = re.search(r'^REF_ZIG="([0-9a-f]+)"', text, re.M)
    if not url or not ref:
        return None
    return {
        "name": "tree-sitter-zig",
        "version": ref.group(1),
        "url": url.group(1),
        "license": "MIT",
    }


# --- CycloneDX assembly ------------------------------------------------------

def purl(name: str, version: str) -> str:
    n = name.replace("@", "%40")
    return f"pkg:npm/{n}@{version}"


def generic_purl(name: str, version: str) -> str:
    """purl for something with no registry of its own (a compiler, an interpreter)."""
    return f"pkg:generic/{name}@{version}"


def license_obj(license_id: str) -> dict:
    # Keep identifiers as names; SPDX id when it matches a known id.
    spdx = {"MIT", "ISC", "Apache-2.0", "BSD-3-Clause"}
    if license_id in spdx:
        return {"license": {"id": license_id}}
    return {"license": {"name": license_id}}


def component(comp: dict) -> dict:
    c = {
        "type": "library",
        "bom-ref": comp["purl"],
        "name": comp["name"],
        "version": comp["version"],
        "purl": comp["purl"],
        "licenses": [license_obj(comp["license"])] if comp.get("license") else [],
        "properties": comp.get("properties", []),
    }
    if comp.get("scope"):
        c["scope"] = comp["scope"]
    if comp.get("hashes"):
        c["hashes"] = comp["hashes"]
    if comp.get("externalReferences"):
        c["externalReferences"] = comp["externalReferences"]
    return c


def build() -> dict:
    comps = []

    # The compiler that builds the host binary. First because it is what every
    # other entry below was compiled by: a dependency pin says what went in,
    # this says what put it there.
    zig = zig_toolchain()
    if zig:
        comps.append(component({
            "name": zig["name"],
            "version": zig["version"],
            "license": "MIT",
            "purl": generic_purl(zig["name"], zig["version"]),
            "scope": "required",
            "properties": [
                {"name": "clanker:build-toolchain", "value": "zig"},
                {"name": "clanker:pin", "value": "build.zig.zon:minimum_zig_version"},
            ],
        }))

    # Zig host dependencies
    for z in zig_dependencies():
        refs = [{
            "type": "distribution",
            "url": z["url"],
        }]
        props = [{"name": "clanker:zig-hash", "value": z["hash"]}]
        github = re.search(r"github\.com/([^/#]+)/([^/#]+)", z["url"])
        p = ""
        if github:
            p = f"pkg:github/{github.group(1)}/{github.group(2)}@{z['version']}"
        else:
            p = f"pkg:generic/{z['name']}@{z['version']}"
        comps.append(component({
            "name": z["name"],
            "version": z["version"],
            "license": "Apache-2.0" if z["name"] == "zwasm" else "MIT",
            "purl": p,
            "externalReferences": refs,
            "properties": props,
        }))

    # Vendored zig-toml
    t = vendored_toml()
    if t:
        comps.append(component({
            "name": t["name"],
            "version": t["version"],
            "license": t["license"],
            "purl": f"pkg:github/sam701/zig-toml@{t['version']}",
            "properties": [
                {"name": "clanker:vendor-path", "value": "vendor/toml"},
                {"name": "clanker:upstream-commit", "value": t["commit"]},
            ],
        }))

    # Vendored SQLite amalgamation (compiled into the host and test binaries)
    sq = vendored_sqlite()
    if sq:
        props = [{"name": "clanker:vendor-path", "value": "vendor/sqlite"}]
        if sq["c_sha256"]:
            props.append({"name": "clanker:sha256-sqlite3-c", "value": sq["c_sha256"]})
        if sq["h_sha256"]:
            props.append({"name": "clanker:sha256-sqlite3-h", "value": sq["h_sha256"]})
        comps.append(component({
            "name": sq["name"],
            "version": sq["version"],
            "license": "Public Domain",
            "purl": f"pkg:generic/{sq['name']}@{sq['version']}",
            "scope": "required",
            "externalReferences": [{"type": "distribution", "url": sq["url"]}],
            "properties": props,
        }))

    # npm toolchains (dev-scope; neither tree ships in the binary)
    npm = npm_components()
    for n in npm:
        if n.get("integrity"):
            alg, _, digest = n["integrity"].partition("-")
            hashes = [{
                "alg": {
                    "sha1": "SHA-1",
                    "sha256": "SHA-256",
                    "sha384": "SHA-384",
                    "sha512": "SHA-512",
                }[alg],
                "content": base64.b64decode(digest, validate=True).hex(),
            }]
        else:
            hashes = []
        comps.append(component({
            "name": n["name"],
            "version": n["version"],
            "license": n["license"],
            "purl": purl(n["name"], n["version"]),
            "scope": "optional" if n["dev"] else "required",
            "hashes": hashes,
            "properties": [{"name": "clanker:lockfile", "value": n["lockfile"]}],
        }))

    # Vendored web UI files; several rows share one upstream package (the two
    # the three.js split, the highlight.js and mermaid builds), so group rows per package and
    # carry each committed file path as a property.
    web = {}
    for w in vendored_web():
        name = w["upstream"].strip()
        version_cell = w["version"].strip()
        sha_prop = "clanker:sha256-" + re.sub(r"[^A-Za-z0-9]+", "-", w["file"]).strip("-")
        # Sanitize version cells like "r180 module" / "10.x ESM" into a
        # version plus a kind note; keep the committed file as the real pin.
        kind = ""
        m = re.fullmatch(r"r(\d+)\s*(.*)", version_cell)
        if m:
            version, kind = m.group(1), m.group(2).strip()
            # three.js releases are named r180 but npm versions are 0.180.0;
            # a purl like pkg:npm/three@180 resolves to nothing on the registry.
            if name == "three":
                version = f"0.{version}.0"
        else:
            m = re.fullmatch(r"([0-9]+\.x|[0-9][0-9A-Za-z._]*)\s*(.*)", version_cell)
            if m:
                version, kind = m.group(1), m.group(2).strip()
            else:
                version = version_cell
        key = (name, version)
        entry = web.setdefault(key, {
            "name": name,
            "version": version,
            "license": w["license"].strip(),
            "files": [],
            "urls": [],
            "kinds": [],
            "digests": [],
        })
        entry["files"].append("ui/vendor/" + w["file"])
        entry["urls"].append(w["url"])
        entry["digests"].append({"name": sha_prop, "value": w["sha256"]})
        if kind:
            entry["kinds"].append(kind)

    # web is keyed by (name, version); sort on the same pair so the order is
    # the one the key tuple already implied.
    for e in sorted(web.values(), key=lambda v: (v["name"], v["version"])):
        props = []
        for f in sorted(set(e["files"])):
            props.append({"name": "clanker:vendor-path", "value": f})
        for u in sorted(set(e["urls"])):
            props.append({"name": "clanker:upstream-url", "value": u})
        for k in sorted(set(e["kinds"])):
            props.append({"name": "clanker:vendor-kind", "value": k})
        for d in sorted(e["digests"], key=lambda v: v["name"]):
            props.append(d)
        name = e["name"]
        purl_name = name.replace("@", "%40")
        comps.append(component({
            "name": name,
            "version": e["version"],
            "license": e["license"],
            "purl": f"pkg:npm/{purl_name}@{e['version']}",
            "properties": props,
        }))

    # Optional ast-grep grammar (not shipped; fetched + commit-pinned)
    grammar = tree_sitter_grammar()
    if grammar:
        comps.append(component({
            "name": grammar["name"],
            "version": grammar["version"],
            "license": grammar["license"],
            "purl": f"pkg:github/tree-sitter-grammars/tree-sitter-zig@{grammar['version']}",
            "scope": "optional",
            "externalReferences": [{"type": "vcs", "url": grammar["url"]}],
            "properties": [{"name": "clanker:pin", "value": "grammars/build.sh:REF_ZIG"}],
        }))

    # Optional kernel interpreter (not shipped; fetched + sha256-verified)
    pw = python_wasi()
    if pw:
        comps.append(component({
            "name": pw["name"],
            "version": pw["version"],
            "purl": f"pkg:generic/python-wasi@{pw['version']}",
            "scope": "optional",
            "externalReferences": [{"type": "distribution", "url": pw["url"]}],
            "properties": [
                {"name": "clanker:sha256", "value": pw["sha256"]},
                {"name": "clanker:release-tag", "value": pw["release_tag"]},
            ],
        }))

    comps.sort(key=lambda c: c["purl"])
    for c in comps:
        c["properties"].sort(key=lambda p: p["name"])

    # npm edges, as recorded in the lockfiles: the project's own devDeps hang
    # off the root component, AssemblyScript's transitive deps off AssemblyScript.
    by_name = {}
    for c in comps:
        by_name.setdefault(c["name"], c["purl"])
    rels = []
    direct = [by_name[n] for n in npm_direct_devdeps() if n in by_name]
    if direct:
        rels.append({"ref": "clanker", "dependsOn": direct})
    for n in npm:
        if n["name"] != "assemblyscript":
            continue
        deps = [by_name[d] for d in ("binaryen", "long") if d in by_name]
        if deps:
            rels.append({
                "ref": by_name["assemblyscript"],
                "dependsOn": deps,
            })

    # Project component
    proj = {
        "type": "application",
        "bom-ref": "clanker",
        "name": "clanker",
        "version": project_version(),
        "purl": f"pkg:github/maci0/clanker@{project_version()}",
    }

    metadata = {
        "component": proj,
        "tools": [{
            "vendor": "clanker",
            "name": "clanker-sbom",
            "version": "1",
        }],
    }
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch and epoch.isdigit():
        metadata["timestamp"] = (
            __import__("datetime").datetime
            .fromtimestamp(int(epoch), __import__("datetime").timezone.utc)
            .isoformat().replace("+00:00", "Z")
        )

    # Deterministic serial number: uuid5 over sorted purls.
    seed = "\n".join(c["purl"] for c in comps)
    serial = "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, "clanker-sbom\n" + seed))

    return {
        "bomFormat": "CycloneDX",
        "specVersion": CDX_VERSION,
        "serialNumber": serial,
        "version": 1,
        "metadata": metadata,
        "components": comps,
        "dependencies": rels,
    }


def main(argv: list) -> int:
    out = None
    if len(argv) == 2 and argv[0] == "-o":
        out = argv[1]
    elif len(argv) != 0:
        print("usage: scripts/sbom.py [-o out.cdx.json]", file=sys.stderr)
        return 2

    doc = build()
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"

    # Self-check: must round-trip as valid JSON with the required fields.
    parsed = json.loads(text)
    for key in ("bomFormat", "specVersion", "serialNumber", "components"):
        if key not in parsed:
            die(f"internal error: generated document missing {key}")

    if out:
        Path(out).write_text(text, encoding="utf-8")
        print(f"wrote {out} ({len(parsed['components'])} components)")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
