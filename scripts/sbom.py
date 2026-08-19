#!/usr/bin/env python3
"""Generate a CycloneDX 1.5 software bill of materials for a clanker release.

Reads only in-tree manifests, so it runs offline and never sends the package
list anywhere:

- build.zig.zon            — zwasm, vaxis (zig hash-pinned)
- vendor/toml/README.md    — vendored zig-toml (MIT)
- tools/ts/package-lock.json — assemblyscript + transitive npm deps
- ui/vendor/README.md      — vendored web UI JS/CSS
- scripts/setup-python-wasi.sh — optional kernel CPython interpreter

Every component is tied back to the exact in-tree artifact that pins it (the
zig hash, the npm `integrity` digest, or the committed vendored file path), so
consumers and vulnerability scanners know precisely what shipped even for
files whose upstream version is not recorded in the file itself.

Output is deterministic (sorted components, stable serial number, timestamp
only when SOURCE_DATE_EPOCH is set), so the same tag always produces the same
document — same idea as the fixed SOURCE_DATE_EPOCH in CI.

Usage: scripts/sbom.py [-o out.cdx.json]   (default: stdout)
"""

import json
import os
import re
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

CDX_VERSION = "1.5"


def die(msg: str) -> "NoReturn":
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


# --- npm toolchain (tools/ts/package-lock.json) -----------------------------

def npm_components() -> list:
    lock = json.loads(read("tools/ts/package-lock.json"))
    packages = lock.get("packages", {})
    out = []
    for path, info in packages.items():
        if path == "":
            continue  # the project root
        out.append({
            "name": info.get("name", path.rsplit("/", 1)[-1]),
            "version": info.get("version", "unknown"),
            "integrity": info.get("integrity"),
            "license": info.get("license"),
            "dev": bool(info.get("dev")),
        })
    return out


# --- vendored web UI (ui/vendor/README.md) ----------------------------------

def vendored_web() -> list:
    text = read("ui/vendor/README.md")
    rows = re.findall(
        r"\| `([^`]+)` \| \[([^\]]+)\]\(([^)]*)\)[^|]*\| ([^|`]+) \| ([A-Za-z0-9 .-]+) \|",
        text,
    )
    return [
        {
            "file": f, "upstream": u, "url": url,
            "version": v.strip(), "license": lic.strip(),
        }
        for f, u, url, v, lic in rows
    ]


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


# --- CycloneDX assembly ------------------------------------------------------

def purl(name: str, version: str) -> str:
    n = name.replace("@", "%40")
    return f"pkg:npm/{n}@{version}"


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

    # AssemblyScript toolchain (dev-scope; not shipped in the binary)
    npm = npm_components()
    as_index = next((i for i, c in enumerate(npm) if c["name"] == "assemblyscript"), None)
    for i, n in enumerate(npm):
        if n.get("integrity"):
            alg, _, digest = n["integrity"].partition("-")
            hashes = [{"alg": alg, "content": digest}]
        else:
            hashes = []
        comps.append(component({
            "name": n["name"],
            "version": n["version"],
            "license": n["license"],
            "purl": purl(n["name"], n["version"]),
            "scope": "optional" if n["dev"] else "required",
            "hashes": hashes,
        }))
        if as_index is not None and i != as_index:
            pass  # relationship recorded below

    # Vendored web UI files; several rows share one upstream package (the two
    # patternfly files, the two three.js files), so group rows per package and
    # carry each committed file path as a property.
    web = {}
    for w in vendored_web():
        name = w["upstream"].strip()
        version_cell = w["version"].strip()
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
        })
        entry["files"].append("ui/vendor/" + w["file"])
        entry["urls"].append(w["url"])
        if kind:
            entry["kinds"].append(kind)

    for key, e in sorted(web.items()):
        props = []
        for f in sorted(set(e["files"])):
            props.append({"name": "clanker:vendor-path", "value": f})
        for u in sorted(set(e["urls"])):
            props.append({"name": "clanker:upstream-url", "value": u})
        for k in sorted(set(e["kinds"])):
            props.append({"name": "clanker:vendor-kind", "value": k})
        name = e["name"]
        purl_name = name.replace("@", "%40")
        comps.append(component({
            "name": name,
            "version": e["version"],
            "license": e["license"],
            "purl": f"pkg:npm/{purl_name}@{e['version']}",
            "properties": props,
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

    # AssemblyScript's transitive npm deps, as recorded in the lockfile.
    by_name = {}
    for c in comps:
        by_name.setdefault(c["name"], c["purl"])
    rels = []
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
        "relationships": rels,
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
