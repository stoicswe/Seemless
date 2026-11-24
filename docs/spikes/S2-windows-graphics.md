# S2 — Windows graphics bring-up with UTM's prebuilt drivers

Status: **partial / blocked** (2026-11-23). Driver signing answered (D12).
Fire Strike scores **not** obtained — blocked before the driver could load by
an account-privilege bug (below), and then by the session usage limit.

Media: `Windows11_Client_arm64_en-us_26300_9457.iso` (build 26300.9457, Pro).
Host: M3, macOS 27.3, host stack from S1 (`build/prefix`).
Storage: throwaway `--root build/s2-root`, VM `s2`.

## What was done

1. Downloaded UTM's driver release **v0.6** of `utmapp/viogpu-wddm` (its tag
   points at `d25bb08c`, exactly the `win-kmd` SHA pinned in
   `scripts/versions.lock`). Owner approved the download. Files and verified
   SHA-256 (match the GitHub release digests):
   - `viogpu3d-arm64x-signed.zip` `7231…425f`
   - `utm-guest-tools-0.1.276.iso` `3acf…c817` (146 MB; carries the viogpu3d
     3D driver plus NetKVM and the other virtio drivers).
   Kept under `build/s2-downloads/` (gitignored).
2. Installed Windows unattended (`image build --recipe stock`, FIRSTBOOT_OK,
   20 min). Owner accepted Microsoft's licence at OOBE in the VM window; the
   `Seemless` account auto-logged on (this also closes the S4 OOBE gap:
   account creation + auto-logon work on this media).
3. Inspected the driver signatures on the Mac (below).
4. Attempted to install the driver — **blocked**: see "Blocker".

## Driver signing (answers D12)

Read directly from the release binaries (`openssl`), so this holds regardless
of the blocker.

**Two independent signatures:**

| Artifact | Signature | Signer | Chain |
|----------|-----------|--------|-------|
| `viogpu3d.cat` (the catalog that makes the package trusted) | PKCS#7 **Microsoft attestation** signature | **Microsoft Windows Hardware Compatibility Publisher** | → Microsoft Windows Third Party Component CA 2014 → Microsoft Root Certificate Authority 2010 |
| `viogpu3d.sys`, `neptune_umd_arm64.dll`, `vgpusrv.exe`, … (embedded PE Authenticode) | **EV code-signing** signature | **TURING SOFTWARE LLC** (businessCategory = Private Organization — EV) | → TrustID EV Code Signing CA 4 → IdenTrust |

- The catalog's signing cert carries EKUs `1.3.6.1.4.1.311.10.3.5` and
  `…3.5.1` (Windows Hardware Driver Verification), validity 2026-05-13 →
  2027-05-11. This is the **Hardware Dev Center attestation-signing** pattern:
  UTM (Turing Software LLC) submits the package under its EV identity and
  Microsoft returns a Microsoft-signed catalog.
- INF: `Provider=%RHEL%`, `Class=Display`, `DriverVer=11/17/2026,100.6.101.58000`,
  HWID `pci\ven_1af4&dev_1050` (virtio-gpu). Catalog OSAttr lists ARM64 from
  RS3 through `26H1`, so build 26300 is covered.

**Consequences for D12:**

- The drivers are **attestation-signed, not test-signed.** On ARM64 Windows a
  kernel-mode driver must carry a Microsoft-trusted signature; the
  Microsoft-issued catalog satisfies standard code-integrity. So **test
  signing is NOT required** to install these prebuilt drivers, and
  `bcdedit /set testsigning on` is unnecessary for the UTM path.
- **Secure Boot** therefore does not have to be toggled for *signing* reasons
  (attestation-signed drivers load with Secure Boot on or off). Our firmware
  (`edk2-aarch64-code.fd`) runs **without** Secure Boot regardless, and UTM's
  Setup answer file sets `LabConfig\BypassSecureBootCheck` to get Setup past
  the hardware gate — unrelated to driver trust.
- Test-signing + Secure-Boot-off only becomes relevant for **our own**
  future driver builds (WP4.6) before they are attestation-signed, which still
  needs an EV certificate + Hardware Dev Center account (budget item,
  unchanged).

Caveat: the above is read from the signatures; it is **not yet empirically
confirmed by loading the driver in the guest** (blocked below). The empirical
check (pnputil succeeds without test-signing; dxdiag shows the virtio adapter)
is the first step when S2 resumes.

## Blocker (now fixed): the auto-created account was not an administrator

The `s2` VM (built 2026-11-23 18:53) had its `Seemless` account **not** in the
local Administrators group, and the built-in `Administrator` disabled, so
nothing in the guest could elevate — blocking `pnputil /add-driver /install`
and any 3DMark installer. Confirmed in-guest: `net localgroup Administrators`
listed only `Administrator`.

Root cause: on build 26300, OOBE created the `<LocalAccount>` but **ignored
`<Group>Administrators</Group>`**, leaving the account in no local group.
(An offline retry of `net localgroup Administrators Seemless /add` at a
`SetupType=2` boot failed with error 1317 "account does not exist" — the SAM
does not resolve the name that early in a setup boot, so that path is a dead
end anyway.)

**Fix (already in the working tree, added 2026-11-23 ~20:50; my `s2` VM
predates it, which is why it still showed the bug):**

- `image/unattend/unattend.xml` no longer uses `<LocalAccounts>`; it only hides
  OOBE's account pages and sets auto-logon.
- `image/guest/setup-account.ps1`, run as SYSTEM by `firstboot.cmd`
  (SetupComplete, before OOBE), creates the account from the AutoLogon values
  in the **payload disk's** answer file (Setup rewrites the passwords in the
  cached `Panther` copy, so that one does not decode) and adds it to
  Administrators + Users **by SID**
  (`S-1-5-32-544`/`-545`, language-independent). It then **verifies** the
  membership and throws if absent.
- `firstboot.cmd` gates the build result on it: `FIRSTBOOT_OK` is written only
  when `setup-account.ps1` succeeded, else `ERROR account …`.
- Covered by `LocalAccountTests` / `ImagePipelineTests` (17 tests pass).

Because `FIRSTBOOT_OK` is now gated on `setup-account.ps1`'s own membership
check, **a fresh build reaching `FIRSTBOOT_OK` is itself proof the account is a
verified administrator** — no licence acceptance or desktop login needed to
confirm it.

Verification (main session, 2026-11-23): a fresh Lean `image build --root
/tmp/slb --name admfix` reached `FIRSTBOOT_OK` in 6 min 39 s. Its
`firstboot.log` says "account Seemless ready (Administrators, Users)". The two
builds before it failed with `ERROR account` and found the two issues fixed
above: the Panther password rewrite, and `New-LocalUser`'s 48-character
description limit. The `s2b` build mentioned earlier was never run. Still
unseen until someone accepts the licence: OOBE with no account page,
auto-logon, and the answer file deleted at first logon.

## Runtime bring-up (VM `admfix`, driver installed, 2026-11-23)

Started the verified `admfix` VM (`--root /tmp/slb`, Lean, licence handled at
build). In-guest verification of the account fix (elevated UAC was a **consent**
prompt, not a credential prompt — definitive admin proof): `Seemless` in
`BUILTIN\Administrators`, auto-logon, no account page, `Panther\unattend.xml`
deleted by the `\Seemless\RemoveAnswerFile` task. Snapshot `clean-install` taken.

Installed the driver from the guest-tools ISO (`D:\Drivers\viogpu3d\w11\ARM64\
viogpu3d.inf`):

```
pnputil /add-driver D:\Drivers\viogpu3d\w11\ARM64\viogpu3d.inf /install
```

**The renderer ran for the first time** (closes the S1 open item). From the
render-server log (`/tmp/slb/vms/admfix/logs/qemu-*.log`):

- `npt: Neptune renderer initialized`; `dwm.exe` gets a Neptune context →
  **DWM is GPU-accelerated**. Per-process contexts for dwm, dxgiadaptercache,
  msedgewebview2, etc.
- Backend: `npt: loaded D3D11 library: libdxmt-native.dylib` → **DXMT D3D11**
  (the pinned default `NPT_BACKEND=dxmt`). `backend library: directx-native ABI 1`.
- **D3D11 feature level 11_1** (`Using feature level D3D_FEATURE_LEVEL_11_1`,
  Shader Model 5.0-class). DXMT warns `D3DKMTOpenAdapterFromLuid not
  implemented` (non-fatal).
- **D3D12 unavailable** on this backend: `npt: failed to load
  D3D12CreateDevice … symbol not found`. Expected — D3D12 is the future
  vkd3d-proton/MoltenVK path (D3a/S8), not DXMT. So Fire Strike (D3D11) is in
  scope; Time Spy (D3D12) is not.
- Scanout sharing works: `npt: shared: exported blob_id=… 1024x768 fmt=87
  (BGRA) pitch=4096` — the desktop composited to shared textures.

**Driver signing confirmed empirically:** the WDDM KMD loaded and the display
switched (800×600 → 1024×768) with **no test-signing enabled and Secure Boot
absent**. On ARM64 a KMD needs a Microsoft-trusted signature to load, so the
load proves the attestation catalog is accepted on its own. **D12 confirmed.**

### Instability (deterministic): QEMU aborted on virtio-gpu reset — now fixed

With the driver installed, QEMU **`abort()`ed (SIGABRT)** whenever the virtio-gpu
device was **reset** (guest reboot, and early in a cold boot while the KMD
initialises). Creation of EGLImage-backed scanouts worked; only teardown
crashed. Fixed by the virglrenderer patch below. Backtrace (from the owner's
crash report, thread 21):

```
abort ← libepoxy egl_provider_resolver: eglDestroyImageKHR has NO provider
      (needs EGL_KHR_image / EGL_KHR_image_base / EGL 1.5)
   ← vrend_renderer_resource_destroy            (virglrenderer)
   ← virtio_gpu_virgl_resource_destroy          (virtio-gpu-virgl.c:404)
   ← virtio_gpu_reset_bh ← virtio_gpu_reset     (virtio-gpu.c:1616/1705)
   ← virtio_gpu_gl_reset ← virtio_reset ← qemu_system_reset
```

**Root cause (precise):** libepoxy resolves each EGL entrypoint lazily, and its
provider check queries the **current** display via `eglGetCurrentDisplay()`
(`libepoxy/src/dispatch_egl.c`: `epoxy_conservative_egl_version`,
`epoxy_conservative_has_egl_extension`). The destroy runs from
`virtio_gpu_reset` on QEMU's main thread with **no EGL context current**, so the
current display is `EGL_NO_DISPLAY`: the version reads 0 and
`EGL_KHR_image_base` is not in `eglQueryString(NO_DISPLAY, EGL_EXTENSIONS)`, so
no provider is found for `eglDestroyImageKHR` and libepoxy's generated resolver
calls `abort()`. ANGLE *does* expose the extension on the display (creation,
which ran with a context current, proved it) — the defect is the absent current
display at reset, not a missing ANGLE entrypoint. The scanout EGL images live
the whole session and are only destroyed at reset, so `eglDestroyImageKHR`'s
first-ever call lands here, with nothing current. Crash site:
`virglrenderer/src/vrend/vrend_renderer.c:9153` → `virgl_egl_image_destroy`.

### Fix (revised 2026-11-23, main session)

**First attempt — insufficient.** `0001-egl-image-destroy-make-current-at-reset`
made virgl's `egl_ctx` current before the destroy when nothing was current.
Three hard resets survived, but a **cold start at 23:05 aborted again** with the
same "No provider of eglDestroyImageKHR" (owner's crash report, patched library
built 22:16). Reason: QEMU uses `virgl_egl_init_external()`, where virgl owns no
context (`egl_ctx` is NULL), so that `eglMakeCurrent` only *released* the current
context. Runs survived only when some other context happened to be current on
QEMU's main thread at reset time; the first device reset of a cold boot has none.

**Fix now in place:** `patches/virglrenderer/0001-egl-resolve-destroy-image-at-init.patch`
(replaces the first attempt). Both init paths resolve `eglDestroyImageKHR` once
with `eglGetProcAddress` (core EGL 1.0, which libepoxy resolves without a display
check; falls back to core `eglDestroyImage`), and `virgl_egl_image_destroy` calls
through that pointer. No dependence on which thread has which context current.
Small, outside virtio-gpu/Neptune code, upstream-ready (MIT). Applied by
`build-deps.sh` (`apply_patches`); virglrenderer rebuilt with `--force virgl`.

**UTM-repro step skipped by the owner's choice (2026-11-23):** CLAUDE.md asks to
reproduce in UTM with the pinned versions first, but UTM is not installed
(~200 MB download) and the root cause is unambiguous in the pinned sources, so
the owner chose to fix on our stack directly. The pinned QEMU `8ab298bc` was
checked and **already carries the utmapp/qemu#6 hvf reset fix** (no `assert(isv)`;
`!isv` handled gracefully), so no QEMU patch was needed.

**Verification (main session, 23:13–23:24):** library rebuilt 23:13:29 from the
revised patch. On `admfix`, 4 cold boots with up to 3 hard resets each (10
resets in total): no abort, no "No provider of eglDestroyImageKHR" line, no
crash report. Two runs ended at their second reset with a clean guest
power-off and no crash. The old build did the same once; it looks like
Windows reacting to back-to-back hard resets and is not investigated.

### Display capture gap (relevant to S3)

`seemlessctl vm screendump` (QMP, reads the legacy framebuffer) returns **black**
once the WDDM driver takes over — the composited output lives in the
Neptune/DWM GPU-texture scanout, which QMP cannot read. Only the GL window
(`vm run`) shows it. The planned `seemlessctl screenshot --scanout N` IOSurface
dump (docs/04) does not exist yet (S3). Agents are effectively blind to the 3D
desktop until S3 lands it; the owner confirmed the desktop via the GL window.

## Result

- **Signing: answered + confirmed.** Attestation catalog (Microsoft HWCC) +
  embedded EV (Turing Software LLC); the KMD loads with **no test-signing** and
  **no Secure Boot**. D12 updated and confirmed.
- **Renderer: exercised (first time).** Neptune + DXMT D3D11, feature level
  11_1, DWM accelerated, scanouts exported. D3D12 not available on DXMT.
- **Reset-abort crash: fixed** (virglrenderer patch; verified with 3 resets +
  a clean shutdown, no abort). Reboots are safe now.
- **Fire Strike score: not obtained.** Remaining blocker is only that 3DMark is
  not installed (owner provides/approves). With the reset crash fixed, a run is
  now viable.

## Next

1. Owner provides/approves 3DMark; run **Fire Strike** on `NPT_BACKEND=dxmt`,
   capture the score + render-server log. (Reset crash no longer in the way.)
2. S3 needs the IOSurface scanout capture so agents can see the 3D desktop
   (QMP screendump is black once the 3D driver loads).
3. Upstream the virglrenderer patch to utmapp/virglrenderer.

## Artifacts

- Downloads + SHA log: `build/s2-downloads/` (gitignored).
- `admfix` VM: `/tmp/slb/vms/admfix/`, snapshot `clean-install` (driver not yet
  installed), driver installed on the live overlay. Render-server + crash logs
  in its `logs/`.
- Crash report: QEMU SIGABRT, thread 21, `epoxy_eglDestroyImageKHR_resolver`.
