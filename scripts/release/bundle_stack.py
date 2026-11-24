#!/usr/bin/env python3
"""Copy the host stack from build/prefix into a Seemless.app (WP8.1).

    python3 -I scripts/release/bundle_stack.py <prefix> <Seemless.app> [--seemlessctl <path>]

Layout (HostStack.Layout.appBundle in kit/Sources/SeemlessKit/QEMUCommand.swift):

    Contents/Helpers/      qemu-system-aarch64 qemu-img swtpm virgl_render_server [seemlessctl]
    Contents/Frameworks/   every non-system dylib they load, plus the dlopened ones
    Contents/Resources/qemu/   firmware, option ROMs, keymaps (QEMU gets -L)

Every copied Mach-O is rewritten so it needs nothing outside the bundle:
install names become @rpath/<leaf>, executables get
LC_RPATH @executable_path/../Frameworks, dylibs get @loader_path, and any
rpath pointing at the build tree is removed. Leaf-name dlopen() (ANGLE's
libEGL from libepoxy, libdxmt-native from virglrenderer) searches the
caller's and the main executable's LC_RPATH, so no DYLD_* variable is needed
(entitled binaries ignore them anyway).

Homebrew libraries pulled in by the closure are recorded in
Contents/Resources/Licenses/homebrew-libraries.tsv (formula, version,
licence, source URL, sha256) for the notices file and the source archive.
Writes nothing outside the bundle. scripts/release/audit-bundle.sh checks the
result.
"""
import json
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")

# Executables copied into Contents/Helpers: (source relative to prefix, name).
HELPERS = [
    ("bin/qemu-system-aarch64", "qemu-system-aarch64"),
    ("bin/qemu-img", "qemu-img"),
    ("bin/swtpm", "swtpm"),
    ("libexec/virgl_render_server", "virgl_render_server"),
]

# Libraries loaded with dlopen (not in any load command), relative to prefix.
DLOPENED = [
    "ANGLE.xcarchive/Products/usr/local/lib/libEGL.dylib",     # libepoxy, by leaf name
    "ANGLE.xcarchive/Products/usr/local/lib/libGLESv2.dylib",  # libepoxy, by leaf name
    "lib/libdxmt-native.dylib",            # virglrenderer (Neptune DXMT backend), by leaf name
    "lib/libvkd3d-proton-d3d12.dylib",     # NPT_D3D12_LIBRARY_PATH (absolute)
    "lib/libvkd3d-proton-d3d12core.dylib", # vkd3d-proton d3d12 -> d3d12core
    "lib/libMoltenVK.dylib",               # vkd3d-proton, @loader_path/libMoltenVK.dylib; venus by leaf name
]

# Homebrew libraries loaded with dlopen under a fixed leaf name:
# (formula, file in its lib/, leaf name in Contents/Frameworks).
HOMEBREW_DLOPENED = [
    # sdl2-compat (QEMU links SDL2) dlopens @loader_path/libSDL3.dylib in its
    # initializer and shows a modal "Failed loading SDL3" alert, blocking
    # QEMU, when it is missing.
    ("sdl3", "libSDL3.0.dylib", "libSDL3.dylib"),
]

# QEMU data files needed by the aarch64 virt machine we run (docs/02).
QEMU_DATA = [
    "edk2-aarch64-code.fd",  # UEFI firmware (pflash unit 0)
    "efi-virtio.rom",        # virtio-net-pci option ROM
    "efi-e1000e.rom",
    "keymaps",               # -k / VNC keymaps; small, kept for parity with the prefix
    "firmware",              # firmware descriptor JSON
]


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")


def load_commands(path):
    """Return (install_id, [dependencies], [rpaths]) from otool -l."""
    out = run("otool", "-l", path)
    install_id, deps, rpaths = None, [], []
    cmd = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd "):
            cmd = s.split()[1]
        elif s.startswith("name ") and cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LAZY_LOAD_DYLIB"):
            deps.append(s[5:].rsplit(" (offset", 1)[0])
        elif s.startswith("name ") and cmd == "LC_ID_DYLIB":
            install_id = s[5:].rsplit(" (offset", 1)[0]
        elif s.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(s[5:].rsplit(" (offset", 1)[0])
    return install_id, deps, rpaths


def resolve(dep, source, source_rpaths, executable_dir):
    """Resolve a dependency path of `source` to a real file, or None if system."""
    if dep.startswith(SYSTEM_PREFIXES):
        return None
    loader_dir = os.path.dirname(source)
    candidates = []
    if dep.startswith("@loader_path/"):
        candidates.append(os.path.join(loader_dir, dep[len("@loader_path/"):]))
    elif dep.startswith("@executable_path/"):
        candidates.append(os.path.join(executable_dir, dep[len("@executable_path/"):]))
    elif dep.startswith("@rpath/"):
        leaf = dep[len("@rpath/"):]
        for rp in source_rpaths:
            rp = rp.replace("@loader_path", loader_dir).replace("@executable_path", executable_dir)
            candidates.append(os.path.join(rp, leaf))
        candidates.append(os.path.join(loader_dir, leaf))
    else:
        candidates.append(dep)
    for c in candidates:
        if os.path.exists(c):
            return os.path.realpath(c)
    raise SystemExit(f"bundle_stack: {source}: cannot resolve dependency {dep}")


def homebrew_formula(path):
    """'/opt/homebrew/Cellar/glib/2.86.1/lib/x.dylib' -> ('glib', '2.86.1')."""
    parts = os.path.realpath(path).split(os.sep)
    if "Cellar" in parts:
        i = parts.index("Cellar")
        return parts[i + 1], parts[i + 2]
    return None


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    prefix = os.path.realpath(argv[1])
    app = os.path.realpath(argv[2])
    extra_helpers = []
    if "--seemlessctl" in argv:
        extra_helpers.append((os.path.realpath(argv[argv.index("--seemlessctl") + 1]), "seemlessctl"))

    contents = os.path.join(app, "Contents")
    helpers_dir = os.path.join(contents, "Helpers")
    fw_dir = os.path.join(contents, "Frameworks")
    data_dir = os.path.join(contents, "Resources", "qemu")
    lic_dir = os.path.join(contents, "Resources", "Licenses")
    for d in (helpers_dir, fw_dir, data_dir):
        shutil.rmtree(d, ignore_errors=True)
    for d in (helpers_dir, fw_dir, data_dir, lic_dir):
        os.makedirs(d, exist_ok=True)

    # (source real path, destination) for every Mach-O we copy.
    copied = {}      # source realpath -> dest path
    leaf_of = {}     # dest leaf -> source realpath (detect clashes)
    queue = []

    def add_lib(src, leaf=None):
        src = os.path.realpath(src)
        if src in copied:
            return copied[src]
        # The leaf name a dependent refers to is the file's install id leaf
        # when it has one (libepoxy.0.dylib), else its file name.
        if leaf is None:
            install_id, _, _ = load_commands(src)
            leaf = os.path.basename(install_id) if install_id else os.path.basename(src)
        if leaf in leaf_of and leaf_of[leaf] != src:
            raise SystemExit(f"bundle_stack: two different libraries named {leaf}: {leaf_of[leaf]} and {src}")
        leaf_of[leaf] = src
        dest = os.path.join(fw_dir, leaf)
        copied[src] = dest
        queue.append(src)
        return dest

    executables = []
    for rel, name in HELPERS:
        src = os.path.realpath(os.path.join(prefix, rel))
        executables.append((src, os.path.join(helpers_dir, name)))
    for src, name in extra_helpers:
        executables.append((src, os.path.join(helpers_dir, name)))
    for rel in DLOPENED:
        add_lib(os.path.join(prefix, rel))
    for formula, file, leaf in HOMEBREW_DLOPENED:
        brew_prefix = run("brew", "--prefix", formula).strip()
        add_lib(os.path.join(brew_prefix, "lib", file), leaf)

    # Walk the dependency closure. Map each Mach-O to its rewrites.
    rewrites = {}  # dest -> list of (old, new)
    for src, dest in executables:
        copied[src] = dest
        queue.append(src)
    while queue:
        src = queue.pop()
        _, deps, rpaths = load_commands(src)
        exe_dir = os.path.dirname(src)
        changes = []
        for dep in deps:
            real = resolve(dep, src, rpaths, exe_dir)
            if real is None:
                continue
            dest = add_lib(real)
            changes.append((dep, "@rpath/" + os.path.basename(dest)))
        rewrites[copied[src]] = (src, changes, rpaths)

    exe_dests = {d for _, d in executables}
    homebrew = {}
    for dest, (src, changes, rpaths) in sorted(rewrites.items()):
        shutil.copyfile(src, dest)
        os.chmod(dest, 0o755)
        args = []
        if dest not in exe_dests:
            args += ["-id", "@rpath/" + os.path.basename(dest)]
        for old, new in changes:
            if old != new:
                args += ["-change", old, new]
        for rp in rpaths:
            args += ["-delete_rpath", rp]
        args += ["-add_rpath", "@executable_path/../Frameworks" if dest in exe_dests else "@loader_path"]
        # Homebrew bottles and our build carry signatures; install_name_tool
        # invalidates them. sign-app.sh re-signs everything afterwards.
        run("install_name_tool", *args, dest)
        run("codesign", "--remove-signature", dest, check=False)
        hb = homebrew_formula(src)
        if hb:
            homebrew.setdefault(hb, []).append(os.path.basename(dest))

    # QEMU data.
    share = os.path.join(prefix, "share", "qemu")
    for name in QEMU_DATA:
        s = os.path.join(share, name)
        d = os.path.join(data_dir, name)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copyfile(s, d)

    # Homebrew manifest, with each formula's licence and exact source.
    rows = []
    for (formula, version), libs in sorted(homebrew.items()):
        info = {}
        try:
            info = json.loads(run("brew", "info", "--json=v2", formula))["formulae"][0]
        except Exception as e:  # brew missing: still record what we know
            print(f"bundle_stack: warning: brew info {formula}: {e}", file=sys.stderr)
        stable = info.get("urls", {}).get("stable", {})
        url, sha = stable.get("url", ""), stable.get("checksum", "")
        current = info.get("versions", {}).get("stable", "")
        # Bottle versions carry a _N rebuild suffix (3.8.13_2); the formula's
        # source URL is only right when the upstream version matches.
        if not current or version.split("_")[0] != current:
            print(f"bundle_stack: warning: {formula} installed {version}, formula source is {current or '?'}: "
                  "source marked STALE (run `brew upgrade` and package again)", file=sys.stderr)
            url, sha = "STALE", ""
        rows.append("\t".join([
            formula, version, info.get("license") or "UNKNOWN",
            url, sha, info.get("homepage", ""),
            " ".join(sorted(libs)),
        ]))
    with open(os.path.join(lic_dir, "homebrew-libraries.tsv"), "w") as f:
        f.write("# formula\tversion\tlicence\tsource_url\tsha256\thomepage\tbundled_files\n")
        f.write("\n".join(rows) + "\n")

    print(f"bundled {len(exe_dests)} helpers, {len(copied) - len(exe_dests)} libraries "
          f"({len(homebrew)} Homebrew formulae) into {contents}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
