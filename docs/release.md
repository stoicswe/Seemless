# Release packaging (WP8.1, WP8.2, WP8.5)

How a self-contained, signed `Seemless.app` is built, and what the owner sets
up once. Publishing (GitHub release, tags, uploads) is the owner's job; no
script here uploads anything.

## Commands

```bash
scripts/build-deps.sh all          # host stack in build/prefix (once)
scripts/package-release.sh         # → build/release/
scripts/release/source-archive.sh  # → build/release/Seemless-<version>-sources/
```

`scripts/package-release.sh` writes:

| File | What |
|------|------|
| `build/release/Seemless.app` | The release app (self-contained, signed) |
| `build/release/Seemless-<version>.dmg` | Signed dmg (app + Applications link); notarized and stapled when a notary profile is set |
| `build/release/Seemless-<version>.zip` | `ditto` zip of the (stapled) app |
| `build/release/SHA256SUMS` | Checksums of the dmg and zip |
| `build/release/audit.txt` | The otool audit (below) |
| `build/release/notarize.txt` | notarytool output, when notarized |

Options: `--skip-notarize`, and `--allow-newer-minos` (local testing only,
see "Blocker" below).

## Bundle layout (WP8.1)

```
Seemless.app/Contents/
├── MacOS/Seemless
├── Helpers/        qemu-system-aarch64  qemu-img  swtpm  virgl_render_server  seemlessctl
├── Frameworks/     every non-system dylib (ours, ANGLE, MoltenVK, vkd3d-proton, Homebrew's)
└── Resources/
    ├── qemu/       edk2-aarch64-code.fd, efi-virtio.rom, efi-e1000e.rom, keymaps/, firmware/
    ├── image/      answer files, WinPE and guest scripts, recipes (no inventory)
    └── Licenses/   THIRD-PARTY-NOTICES.md, each licence file, homebrew-libraries.tsv
```

- `scripts/release/bundle_stack.py` copies the helpers, walks their
  dependency closure with `otool`, adds the libraries that are only
  `dlopen`ed (ANGLE's libEGL/libGLESv2, libdxmt-native, vkd3d-proton,
  MoltenVK, and Homebrew's SDL3, which sdl2-compat loads in its initializer
  and shows a modal error without), and rewrites every install name to
  `@rpath/<leaf>`. Executables get `LC_RPATH @executable_path/../Frameworks`,
  dylibs `@loader_path`. Rpaths into the build tree are deleted.
- Leaf-name `dlopen()` searches the caller's and the main executable's
  `LC_RPATH` (`man dlopen`), so no `DYLD_*` variable is needed. Binaries with
  entitlements ignore `DYLD_*` anyway.
- `HostStack` (`kit/Sources/SeemlessKit/QEMUCommand.swift`) has two layouts.
  `locate()` checks `$SEEMLESS_PREFIX`, then the app bundle containing the
  running executable (the app in `Contents/MacOS` or `seemlessctl` in
  `Contents/Helpers`), then `build/prefix` (development). In the bundle
  layout QEMU gets `-L Contents/Resources/qemu` and
  `RENDER_SERVER_EXEC_PATH` (virglrenderer has the `build/prefix` path
  compiled in). `ImageAssets.locate()` prefers `Contents/Resources/image`
  the same way.
- `scripts/release/audit-bundle.sh` checks every Mach-O in the bundle and
  fails the build on: an architecture other than arm64; a load command that
  is not `/usr/lib`, `/System/Library` or `@rpath`/`@loader_path`/
  `@executable_path` resolving inside the bundle; an absolute rpath; a
  dylib id that is not `@rpath/<leaf>`; anything naming `build/prefix`, a
  home directory or Homebrew; a minimum macOS newer than
  `LSMinimumSystemVersion`.

## Signing and notarization (WP8.2)

`scripts/release/sign-app.sh` signs inside-out with the hardened runtime:
each dylib in `Frameworks/`, each helper, then the bundle.

| Binary | Entitlements |
|--------|--------------|
| `Helpers/qemu-system-aarch64` | `app/Entitlements/qemu.entitlements`: `com.apple.security.hypervisor` |
| Everything else | `app/Entitlements/app.entitlements`: none |

- **No JIT entitlement.** Seemless only runs `-accel hvf`, so TCG never
  maps its JIT buffer. Checked: firmware boots under the hardened runtime
  without `com.apple.security.cs.allow-jit`.
- **No library-validation or DYLD exceptions** with a Developer ID: all code
  carries the same Team ID.
- **Ad-hoc builds** (no identity) keep the hardened runtime, but an ad-hoc
  signature has no Team ID, so library validation refuses every bundled
  dylib ("different Team IDs"). For ad-hoc builds only, `sign-app.sh` adds
  `com.apple.security.cs.disable-library-validation` to temporary copies of
  the entitlements. Ad-hoc builds run on the Mac that built them; they are
  not for publishing.
- `com.apple.vm.networking` (vmnet) is not requested: the default network is
  user-mode (slirp). R11.
- Notarization submits the dmg. Notarizing the dmg also notarizes the app
  inside it (tickets are per code hash), so the script staples both.

### Owner's one-time setup

Nothing secret goes into the repository, the scripts or the environment
files. The scripts only take **names**.

1. Join the Apple Developer Program; in Xcode → Settings → Accounts, or on
   developer.apple.com, create a **Developer ID Application** certificate.
   It lands in the login keychain. Check:
   ```bash
   security find-identity -v -p codesigning
   ```
2. Store notarization credentials in the keychain once, under a profile
   name (`notarytool` prompts for the app-specific password or API key
   itself; type it there, not into a script):
   ```bash
   xcrun notarytool store-credentials seemless-notary --apple-id <your Apple ID> --team-id <TEAMID>
   ```
3. For each release:
   ```bash
   SEEMLESS_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" SEEMLESS_NOTARY_PROFILE=seemless-notary scripts/package-release.sh
   ```
   then `scripts/release/source-archive.sh`, and upload the dmg/zip,
   `SHA256SUMS` and the `Seemless-<version>-sources/` folder to the GitHub
   release.
4. Check on a second Mac (or a fresh user account): open the dmg, drag the
   app to Applications, open it. Gatekeeper must not warn.

## Licence compliance (WP8.5)

Seemless's own code is MIT (repo `LICENSE`; owner, 2026-11-24, docs/10 Q10),
shipped as `Resources/Licenses/Seemless-LICENSE.txt` and named first in the
notices. Each upstream keeps its own licence. No Windows ISOs, images or keys
are distributed in any form.

- `THIRD_PARTY.md` → "Shipped in Seemless.app" is the source of truth for
  components we build. `scripts/release/gen_notices.py` turns it into
  `Resources/Licenses/THIRD-PARTY-NOTICES.md` (component tables, the source
  offer and replacement note, every licence text) and copies each licence
  file. A listed file that is missing fails the build.
- Homebrew libraries are recorded per build in
  `Resources/Licenses/homebrew-libraries.tsv` (formula, version, licence,
  source URL, sha256, files), from `brew info`. Their licence files come
  from each keg.
- `scripts/release/source-archive.sh` writes the source offer: a
  `git archive` of each pinned SHA (checked against `versions.lock`), each
  submodule the build uses at its recorded commit (QEMU's `roms/edk2` and
  `roms/ipxe`, because we ship their firmware binaries), QEMU's downloaded
  meson subprojects, each Homebrew library's upstream tarball (sha256
  checked), and `seemless-build-<version>.tar.gz` (`patches/`,
  `build-deps.sh`, `versions.lock`, `scripts/release/`, `THIRD_PARTY.md`).
  `SOURCES.txt` lists every file with its sha256 and origin.

## Blocker and open items (owner decisions)

These are recorded in docs/10 ("Release packaging findings"). The scripts
flag them but do not decide them.

1. **Homebrew libraries need macOS 27.** This Mac runs macOS 27, so 14 of
   the bundled Homebrew dylibs are built with `minos 27.0` (glib, gio,
   gobject, gmodule, pcre2, json-glib, libcrypto, libslirp, libpng, libjpeg,
   p11-kit, libunistring, SDL2, SDL3; list in `build/release/audit.txt`). The
   app says `LSMinimumSystemVersion 26.0` (D10) and our own builds (QEMU,
   virglrenderer, …) target 26.0. The audit fails such a bundle, so release
   packaging fails on this Mac today. Trimming QEMU's optional features
   (`--disable-gnutls --disable-sdl --disable-libusb --disable-zstd`) removes
   11 of the 20 formulae but not glib, pcre2, libslirp, json-glib or
   OpenSSL, which QEMU and swtpm need. So the choices are: build the
   remaining libraries from pinned source with `MACOSX_DEPLOYMENT_TARGET=26.0`
   in `build-deps.sh` (this also pins them by SHA, as CLAUDE.md asks, and
   makes the source offer exact), or raise the minimum to macOS 27.
2. **Homebrew versions are not pinned** in `versions.lock`. They are
   recorded per release in `homebrew-libraries.tsv`. When the installed
   bottle is older than the formula (seen: gnutls 3.8.13 vs 3.8.14, p11-kit
   0.26.5 vs 0.26.6), the exact source tarball is unknown. The row is marked
   STALE and the source archive refuses to complete until
   `brew upgrade` and a repackage. Building these from source (item 1)
   removes the problem.
3. **LGPL-3.0 / GPL-3.0 parts.** gmp, nettle, libunistring and libidn2 are
   dual-licensed (GPL-2.0+ or LGPL-3.0+); gnutls's metadata adds
   GPL-3.0-only (its command-line tools, which we do not ship); gettext's
   libintl is LGPL-2.1+. LGPL-3.0 asks that users can run modified
   libraries; in a signed app that means re-signing (stated in the notices).
   Needs the owner's (or a lawyer's) review. Dropping gnutls (item 1)
   removes most of these.
4. **libtpms TPM 2.0 code** is under the TCG's BSD-style licence, which
   says it grants no patent licence. Redistribution with notice is allowed.
5. **virglrenderer Neptune files**: per-file headers not yet read (the
   repository licence is MIT).
6. **UTM's logo in the firmware** (docs/10 rule 6): `edk2-aarch64-code.fd`
   is still QEMU/UTM's build.
7. **Guest drivers and guest tools** are not in the app yet (Q1, Q13; the
   agent waits for WP4.2/Q12). If Q13 says to bundle drivers, they go in
   `Contents/Resources/guest-drivers/<driver>/` (P2's
   `GuestDrivers.locate()` looks there), and `package-release.sh` plus
   `THIRD_PARTY.md` need a copy step and notices rows.
