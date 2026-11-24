# CI and release channels (plan)

Owner request (2026-11-24): once Preview 1 is ready for testing, replace
the single `ci.yml` with **PR builds, nightly builds, beta builds and
release builds**. The feature set should be similar to the Endfield FineWine
project's workflows (`~/Github/Endfield_FineWine/.github/`). One difference:
**nothing is announced outside GitHub.** No Discord, Bluesky, webhooks or
other outside notifications. The only signs of a new build are GitHub
Releases, tags, job summaries, and the app's own update check against
GitHub.

Roadmap item: Preview 1 P8 (`docs/09-roadmap.md`). The current CI is
`.github/workflows/ci.yml` (it runs `scripts/check.sh` on `macos-26`).

## Channels

| Workflow | Trigger | What it publishes | Modelled on |
|----------|---------|-------------------|-------------|
| `pr.yml` | Pull requests to `main`, with path filters | Nothing. It runs `scripts/check.sh` (Swift, Rust, proto `--check`), a build of the app and release bundle, and `audit-bundle.sh`; it uploads the app as a workflow artifact for reviewers, and writes a job summary | FineWine `build.yml` |
| `nightly.yml` | `schedule` (daily, UTC) + `workflow_dispatch` | A new GitHub **pre-release** per run, tagged `nightly_<version>.<YYYYMMDD>_<sha>`. A change gate skips the run when nothing it is built from changed since the newest `nightly_*` tag, and a failed build is retried the next night. Nothing is replaced or deleted | FineWine `nightly.yml` |
| `beta.yml` | Push to `beta/**` branches, or a manual run on one | A pre-release tagged `beta_<YYYYMMDD>.<n>`, numbered across all betas, with `--latest=false`. A commit that already has a beta isn't published twice. Its own concurrency group | FineWine `beta.yml` |
| `release.yml` | Push to `release/<version>` branches, or `workflow_dispatch` with a version | The full release: tag `<version>`, title "Seemless <version>", marked latest. It refuses a version that is already published (immutable releases on). Assets go up while the release is a draft. It checks that the app's `CFBundleShortVersionString` matches. It opens a PR that refreshes the issue-template version dropdowns | FineWine `release.yml` |
| `validate-issue-version.yml` | Issues opened or edited | Requires bug reports to name a full release version | FineWine, same name |

Shared pieces, as reusable workflows (`workflow_call`):
- **`build-stack.yml`:** `scripts/build-deps.sh all` into `build/prefix`,
  cached by a key from `scripts/versions.lock`, `patches/**` and the build
  scripts. The stack takes hours to build, so the cache is what makes
  nightlies cheap.
- **`build-app.yml`:** the agent, the app, `scripts/package-release.sh`,
  signing, notarization, the dmg and zip, `SHA256SUMS.txt`, and the GPL
  source archive (`scripts/release/source-archive.sh`). The source archive
  is attached to every published build, nightly and beta too, because
  copyleft source must go with each binary we ship.

## Release contents

Every published build carries: `Seemless-<version>.dmg`, `Seemless-<version>.zip`,
`SHA256SUMS.txt`, the source-offer archive and the release notes. It never
carries Windows media or Microsoft tools (CLAUDE.md).

## Release notes

They are generated from the commits since the previous tag of the same
channel, with the raw commit list as a collapsible fallback. FineWine
summarises with an LLM through OpenRouter. That sends commit text to an
outside service, so it's **off by default** here. It's an owner decision,
and needs a secret the owner adds.

## Updates in the app (ties to WP8.3)

The app's updater (WP8.3, Sparkle) offers channels **Release**, **Beta**
and **Nightly**. The feeds come only from GitHub: an appcast attached to
each release, or GitHub Pages in this repository. Sparkle's EdDSA signing
key is the owner's (a GitHub secret).

## Wiki (optional)

FineWine generates its wiki from the docs with `git-wiki-builder` and an AI
model. The wiki stays on GitHub, so it is allowed, but it needs the owner's
model secret. It is optional and off by default.

## Secrets and gates (all the owner's)

- **Signing certificate** (`.p12` and its export password) as GitHub
  secrets. Preview 1 uses the **self-signed** identity from
  `scripts/release/make-signing-cert.sh` (owner, 2026-11-24), exported as
  in `docs/release.md`. The job imports it into a temporary keychain and
  passes its name in `SEEMLESS_SIGN_IDENTITY`. Self-signed builds are not
  notarized: testers allow the app once in System Settings ▸ Privacy &
  Security, and the release notes say so. Without the secret, builds are
  ad-hoc signed and labelled so.
- **Later: Developer ID certificate and a notary API key**, which replace
  the self-signed identity and enable notarization
  (`SEEMLESS_NOTARY_PROFILE`).
- **Sparkle EdDSA private key** (WP8.3).
- **Microsoft CRT/SDK in CI:** building the Windows agent on a runner
  downloads them through cargo-xwin, which accepts Microsoft's licence
  (Q12). Until the owner decides, CI uses a prebuilt agent that the owner
  stages, or it skips the agent and labels the build.
- **Runner:** an Apple silicon `macos-26` image with Xcode 26+. The label
  is still unverified on GitHub; check it before relying on it.
- **Repository settings:** immutable releases, and tag protection for
  `nightly_*`, `beta_*` and version tags.
