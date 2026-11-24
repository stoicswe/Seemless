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

Options: `--skip-notarize`, and `--allow-newer-minos` (local testing only:
turns a too-new minimum macOS into a warning and marks the build NOT
RELEASABLE).

## Bundle layout (WP8.1)

```
Seemless.app/Contents/
├── MacOS/Seemless
├── Helpers/        qemu-system-aarch64  qemu-img  swtpm  virgl_render_server  seemlessctl
├── Frameworks/     every non-system dylib, all built from pinned source (build-deps.sh)
└── Resources/
    ├── qemu/       edk2-aarch64-code.fd, efi-virtio.rom, keymaps/, firmware/
    ├── image/      answer files, WinPE and guest scripts, recipes (no inventory)
    └── Licenses/   THIRD-PARTY-NOTICES.md, Seemless-LICENSE.txt, each licence file
```

- `scripts/release/bundle_stack.py` copies the helpers, walks their
  dependency closure with `otool`, adds the libraries that are only
  `dlopen`ed (ANGLE's libEGL/libGLESv2, libdxmt-native, vkd3d-proton,
  MoltenVK), and rewrites every install name to
  `@rpath/<leaf>`. Executables get `LC_RPATH @executable_path/../Frameworks`,
  dylibs `@loader_path`. Rpaths into the build tree are deleted. A library that resolves into
  Homebrew stops the build: the app ships only libraries built from pinned
  source by `scripts/build-deps.sh` (P1, owner 2026-11-24).
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

**Preview 1 is signed with a self-signed certificate and is not notarized**
(owner, 2026-11-24: "We will use a self-sign cert for now"). Developer ID
signing and notarization stay in the scripts for later.

`scripts/release/sign-app.sh` signs inside-out with the hardened runtime:
each dylib in `Frameworks/`, each helper, then the bundle. It works out the
kind of signature from the identity in `SEEMLESS_SIGN_IDENTITY`:

| Kind | Identity | Team ID | Library validation | Notarized | Who can open it |
|------|----------|---------|--------------------|-----------|-----------------|
| ad-hoc | none | none | off (`disable-library-validation`) | no | The Mac that built it |
| **self-signed** (Preview 1) | from `make-signing-cert.sh` | none | off (`disable-library-validation`) | no (Apple notarizes only Developer ID code) | Anyone, after allowing it once (below) |
| Developer ID | "Developer ID Application: …" | yes | on | yes, with `SEEMLESS_NOTARY_PROFILE` | Anyone, no warning |

| Binary | Entitlements |
|--------|--------------|
| `Helpers/qemu-system-aarch64` | `app/Entitlements/qemu.entitlements`: `com.apple.security.hypervisor` |
| Everything else | `app/Entitlements/app.entitlements`: none |

- **The hypervisor entitlement works with every kind.** It is not a
  restricted entitlement. Checked 2026-11-24: an app signed with a
  self-signed test identity booted the firmware VM from a copied location.
- **`disable-library-validation` is still needed for self-signed builds.**
  A self-signed certificate has no Apple Team ID, so with library validation
  on, QEMU refuses its own bundled dylibs ("mapping process and mapped file
  (non-platform) have different Team IDs"; checked by re-signing QEMU
  without it). `sign-app.sh` adds it to temporary copies of the entitlements
  for ad-hoc and self-signed builds only. Developer ID builds use the files
  unchanged.
- **No JIT entitlement.** Seemless only runs `-accel hvf`, so TCG never
  maps its JIT buffer. Checked: firmware boots under the hardened runtime
  without `com.apple.security.cs.allow-jit`.
- Self-signed and ad-hoc builds are not timestamped; Developer ID builds are.
- `package-release.sh` notarizes only Developer ID builds with
  `SEEMLESS_NOTARY_PROFILE` set. For a self-signed build it says why it
  skipped notarization and carries on.
- `com.apple.vm.networking` (vmnet) is not requested: the default network is
  user-mode (slirp). R11.

### Owner's one-time setup (self-signed, Preview 1)

Nothing secret goes into the repository, the scripts or the environment
files. The scripts only take **names**.

1. Create the identity in your login keychain (run it yourself, once):
   ```bash
   scripts/release/make-signing-cert.sh
   ```
   It makes "Seemless Self-Signed" (a 10-year RSA code-signing certificate),
   imports it so that only `codesign` may use the key, and asks macOS to
   trust it for code signing (macOS asks for your password; you can skip
   that step). The first signing may show a keychain prompt for
   `codesign`: choose **Always Allow**.
2. For each release:
   ```bash
   SEEMLESS_SIGN_IDENTITY="Seemless Self-Signed" scripts/package-release.sh
   ```
   then `scripts/release/source-archive.sh`, and upload the dmg/zip,
   `SHA256SUMS` and the `Seemless-<version>-sources/` folder to the GitHub
   release.
3. For CI later (`docs/ci-plan.md`), export the identity as a `.p12`.
   macOS asks for an export password, which becomes a CI secret:
   ```bash
   security export -k login.keychain-db -t identities -f pkcs12 -o ~/Desktop/seemless-signing.p12
   ```
   This exports every identity in the keychain. To export only Seemless's,
   use Keychain Access ▸ My Certificates ▸ "Seemless Self-Signed" ▸
   right-click ▸ Export. Keep the `.p12` out of the repository.

Later, with a Developer ID: create the certificate in Xcode ▸ Settings ▸
Accounts, store notary credentials once with
`xcrun notarytool store-credentials seemless-notary --apple-id <Apple ID> --team-id <TEAMID>`
(it prompts for the secret itself), then package with
`SEEMLESS_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" SEEMLESS_NOTARY_PROFILE=seemless-notary`.

### First launch for testers (self-signed builds)

Gatekeeper blocks an app that is not notarized (`spctl` says "rejected" for
the self-signed build). Each tester allows it once:

1. Open the dmg and drag Seemless to Applications.
2. Open Seemless. macOS says it cannot verify the app; click **Done** (not
   Move to Trash).
3. Open **System Settings ▸ Privacy & Security**, scroll to Security, and
   click **Open Anyway** next to the Seemless message. Confirm with your
   password or Touch ID, then **Open**.

From then on it opens normally, until the next version replaces it.
Control-click ▸ Open no longer skips this check on macOS 15 and later, so
it does not help on macOS 26. Alternative for people comfortable with
Terminal: `xattr -dr com.apple.quarantine /Applications/Seemless.app`.

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
- `scripts/release/source-archive.sh` writes the source offer: a
  `git archive` of each pinned SHA (checked against `versions.lock`), each
  submodule the build uses at its recorded commit (QEMU's `roms/edk2` and
  `roms/ipxe`, because we ship their firmware binaries), QEMU's downloaded
  meson subprojects, and `seemless-build-<version>.tar.gz` (`patches/`,
  `build-deps.sh`, `versions.lock`, `scripts/release/`, `THIRD_PARTY.md`).
  `SOURCES.txt` lists every file with its sha256 and origin.

## Open items (owner decisions)

These are recorded in docs/10 ("Release packaging findings"). The scripts
flag them but do not decide them. L1–L3 (Homebrew libraries needing macOS
27, unpinned versions, LGPL-3 parts) are resolved: the libraries are built
from pinned source for macOS 26 and QEMU drops gnutls, SDL, libusb and zstd
(docs/02 "Building the host stack").

1. **libtpms TPM 2.0 code** is under the TCG's BSD-style licence, which
   says it grants no patent licence. Redistribution with notice is allowed.
2. **virglrenderer Neptune files**: per-file headers not yet read (the
   repository licence is MIT).
3. **UTM's logo in the firmware** (docs/10 rule 6): `edk2-aarch64-code.fd`
   is still QEMU/UTM's build.
4. **Guest drivers and guest tools** are not in the app yet (Q1, Q13; the
   agent waits for WP4.2/Q12). If Q13 says to bundle drivers, they go in
   `Contents/Resources/guest-drivers/<driver>/` (P2's
   `GuestDrivers.locate()` looks there), and `package-release.sh` plus
   `THIRD_PARTY.md` need a copy step and notices rows.
5. QEMU logs `rom: file vgabios-ramfb.bin … No such file` at start: the
   ramfb device looks for SeaBIOS's legacy VGA ROM, which UEFI on aarch64
   does not use. Not bundled on purpose (SeaBIOS is LGPL-3.0); harmless.
