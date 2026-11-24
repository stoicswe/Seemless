#!/usr/bin/env python3
"""Write the third-party notices and licence texts into a Seemless.app (WP8.5).

    python3 -I scripts/release/gen_notices.py <repo> <Seemless.app> <version>
    python3 -I scripts/release/gen_notices.py --check <repo>

Reads THIRD_PARTY.md's "Shipped in Seemless.app" table, then writes into
Contents/Resources/Licenses/:

    THIRD-PARTY-NOTICES.md   component list, source offer, every licence text
    <component>/<file>       each licence file, as shipped by its project

Fails when a listed licence file is missing, so the notices never silently
drop a component.
"""
import os
import re
import shutil
import sys



def slug(name, used):
    """'SPIRV-Cross (MoltenVK's)' -> 'spirv-cross', or 'spirv-cross-moltenvk' if taken."""
    clean = lambda t: re.sub(r"[^A-Za-z0-9.+-]+", "-", t.replace("'s", "").replace("`", "")).strip("-").lower()
    base, _, rest = name.partition(" (")
    s = clean(base)
    if s in used:
        s = clean(base + " " + rest.split(",")[0].split(" ")[0])
    used.add(s)
    return s


def shipped_rows(third_party_md):
    text = open(third_party_md, encoding="utf-8").read()
    m = re.search(r"^## Shipped in Seemless\.app.*?$(.*?)^## ", text, re.S | re.M)
    if not m:
        raise SystemExit("gen_notices: THIRD_PARTY.md has no 'Shipped in Seemless.app' section")
    rows = []
    for line in m.group(1).splitlines():
        if not line.startswith("|") or line.startswith("|--") or line.startswith("| Component"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 6:
            raise SystemExit(f"gen_notices: bad row (want 6 cells): {line}")
        rows.append(dict(zip(["component", "version", "licence", "source", "files", "as"], cells)))
    return rows


def main(argv):
    if len(argv) == 3 and argv[1] == "--check":
        # scripts/check.sh: the table parses (no build/src needed).
        rows = shipped_rows(os.path.join(argv[2], "THIRD_PARTY.md"))
        print(f"notices: THIRD_PARTY.md lists {len(rows)} shipped components")
        return 0
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    repo, app, version = os.path.realpath(argv[1]), os.path.realpath(argv[2]), argv[3]
    lic = os.path.join(app, "Contents", "Resources", "Licenses")
    os.makedirs(lic, exist_ok=True)

    texts = []  # (heading, path inside Licenses, text)
    out = []
    out.append(f"# Seemless {version}: licences\n")
    # Our own code: MIT (owner, 2026-11-24, docs/10 Q10).
    own = os.path.join(repo, "LICENSE")
    if not os.path.isfile(own):
        raise SystemExit("gen_notices: repository LICENSE missing")
    shutil.copyfile(own, os.path.join(lic, "Seemless-LICENSE.txt"))
    out.append("Seemless's own code (the app, SeemlessKit, seemlessctl, the guest scripts and "
               "image recipes) is released under the **MIT licence** (`Seemless-LICENSE.txt`). "
               "Every third-party component below keeps its own licence.\n")
    texts.append(("Seemless (MIT)", "Seemless-LICENSE.txt", open(own, encoding="utf-8").read()))
    out.append("## Third-party software\n")
    out.append(
        "Seemless.app contains the open-source components below. Each keeps its own "
        "licence; the full texts follow the tables and are also in this folder "
        "(`Contents/Resources/Licenses/`).\n\n"
        "**Source code.** The complete corresponding source for this release of the "
        "GPL and LGPL components (QEMU, iPXE, DXMT, vkd3d-proton, GLib, JSON-GLib and "
        "proxy-libintl), and the source of every other component listed here, is "
        "published as `Seemless-" + version + "-sources` next to this release, built "
        "by `scripts/release/source-archive.sh` from the exact revisions below plus "
        "Seemless's patches (`patches/`).\n\n"
        "**Replacing libraries.** The LGPL libraries are separate dynamic libraries "
        "in `Contents/Frameworks/`. You may replace them with your own builds; macOS "
        "then requires the app to be re-signed (for example `codesign --force --deep "
        "--sign - Seemless.app`).\n\n"
        "Not included, and never distributed by Seemless in any form: Windows (no ISOs, "
        "disk images or product keys), other Microsoft software, and Apple's "
        "D3DMetal.framework. You supply your own Windows 11 ARM installation media "
        "and licence.\n")

    out.append("## Components built by Seemless\n")
    out.append("| Component | Version | Licence | Source | In the app as |")
    out.append("|---|---|---|---|---|")
    used = set()
    for r in shipped_rows(os.path.join(repo, "THIRD_PARTY.md")):
        out.append(f"| {r['component']} | {r['version']} | {r['licence']} | {r['source']} | {r['as']} |")
        dest_dir = os.path.join(lic, slug(r["component"], used))
        os.makedirs(dest_dir, exist_ok=True)
        for rel in [p.strip() for p in r["files"].split(",") if p.strip()]:
            src = os.path.join(repo, rel)
            if not os.path.isfile(src):
                raise SystemExit(f"gen_notices: {r['component']}: licence file missing: {rel}")
            dest = os.path.join(dest_dir, os.path.basename(rel))
            shutil.copyfile(src, dest)
            texts.append((f"{r['component']}: {os.path.basename(rel)}", os.path.relpath(dest, lic),
                          open(src, encoding="utf-8", errors="replace").read()))

    out.append("\n## Licence texts\n")
    for heading, path, text in texts:
        out.append(f"### {heading}\n\n`{path}`\n\n```text\n{text.rstrip()}\n```\n")

    with open(os.path.join(lic, "THIRD-PARTY-NOTICES.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print(f"notices: {len(texts)} licence files -> {lic}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
