# Contributing

First off, thank you so much for considering a contribution to this project. We welcome contributions from everyone!

Everyone taking part is expected to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

<br/>

## Table of Contents

-   [1. How can I contribute?](#how-to-contribute)
-   [2. Guidelines](#guidelines)
    -   [2.1 Git commit messages](#commit-messages)
    -   [2.2 Coding style guide](#coding-style-guide)
    -   [2.3 Project rules](#project-rules)
-   [3. Code Review Process](#code-review)
-   [4. Community and Communication](#community-and-communication)
-   [5. Releasing](#releasing)

<br/>

[//]: # '## 1. How can I contribute?'

## How to Contribute?

Contributing is simple. Here's how you can do it:

1. **Identify an Issue**: Look for existing [Issues](https://github.com/stoicswe/Seemless/issues) or create your own explaining the feature or fix.
2. **Fork the Repository**: Click on the fork button in the top right corner.
3. **Clone the Repository**: After forking, clone the repo to your local machine to make changes.
4. **Set up Your Environment**: Run `scripts/bootstrap.sh` to check your tools, then build the host stack with `scripts/build-deps.sh fetch` and `scripts/build-deps.sh all` (see [CLAUDE.md](CLAUDE.md) "Commands" and the [docs](docs/)). You need an Apple silicon Mac with macOS 26 or later and Xcode 26 or later.
5. **Create a New Branch**: Before making any changes, switch to a new branch:
    ```bash
    # For bugs:
    git checkout -b bug/your-new-branch-name

    # For features:
    git checkout -b feature/your-new-branch-name
    ```
6. **Make Changes**: Implement your feature or fix.
7. **Run Tests**: Ensure your changes do not break any existing functionality. `scripts/check.sh` runs everything that works without a VM (it is also what CI runs).
8. **Write Commit Messages**: Please try to make your commit messages adequately descriptive.
9. **Push to GitHub**: After committing your changes, push them to GitHub:
    ```
    git push origin your-new-branch-name
    ```
10. **Submit a Pull Request**: Go to your repository on GitHub and click the 'Compare & pull request' button. Fill in the details and submit.

<br/>

[//]: # '## 2. Guidelines'

## Guidelines

[//]: # '### 2.1 Git commit messages'

### Commit Messages

While we do not have a distinct commit message style, it is best to ensure that your commit message contains enough description as to what the goal of the commit is.

[//]: # '### 2.2 Coding style guide'

### Coding Style Guide

We follow the standard practice for each language in the repository:

-   **Swift** (`app/`, `kit/`): the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/), Swift 6 strict concurrency.
-   **Rust** (`guest/agent/`): `rustfmt` and `clippy` clean, on the toolchain pinned in `guest/agent/rust-toolchain.toml`.

```swift
struct GuestRect {
    var width: Int
    var height: Int

    var isEmpty: Bool { width <= 0 || height <= 0 }
}
```

[//]: # '### 2.3 Project rules'

### Project Rules

-   **The guest is untrusted.** Validate everything the Windows guest sends ([docs/06](docs/06-guest-agent-protocol.md)).
-   **Never commit or bundle** Windows ISOs, images or keys, Microsoft tools, Apple's `D3DMetal.framework`, or Tiny11 Builder code or binaries. Users bring their own Windows media and licence.
-   **Licences:** Seemless's own code is MIT. Upstream projects keep their own licences. GPL code (QEMU) stays in `vendor/` and `patches/`; never copy it into `kit/`, `app/` or `guest/`.
-   **Dependencies:** pin every external source by commit SHA in `scripts/versions.lock`, and record its licence and URL in `THIRD_PARTY.md`.
-   **Tests first:** features land in `kit/` or the Rust agent with tests before any UI.
-   **Performance:** no performance change without before/after numbers from `seemlessctl bench`.
-   **Docs:** if your change proves a document in `docs/` wrong, fix the document in the same pull request.

<br/>

[//]: # '## 3. Code Review Process'

### Code Review

All submissions, including submissions by project maintainers, require review. We use GitHub pull requests for this process. If your pull request is particularly urgent, please mention this in the request.

<br/>

[//]: # '## 4. Community and Communication'

### Community and Communication

Follow discussions in the [GitHub Issues](https://github.com/stoicswe/Seemless/issues) section of our repository.

<br/>

[//]: # '## 5. Releasing'

## Releasing

> The release workflows are being set up. See [docs/ci-plan.md](docs/ci-plan.md) for the plan. This section describes how releasing will work once they exist.

Full releases are cut from a `release/<version>` branch. Pushing to one (for example
`release/0.1.0`) runs `.github/workflows/release.yml`, which builds the signed and notarized
`Seemless.app` and publishes a full GitHub Release:

-   **Tag:** `<version>` (bare, no `v` prefix).
-   **Title:** `Seemless <version>`.
-   **Assets:** `Seemless-<version>.dmg`, `Seemless-<version>.zip`, `SHA256SUMS.txt`, and the
    source archive for the GPL/LGPL components.
-   **Notes:** generated from the commits since the previous release.

The app's `CFBundleShortVersionString` is set from the branch version, so it reports the version
it was released as.

To cut a release:

```bash
git checkout main && git pull
git checkout -b release/0.1.0
git push origin release/0.1.0      # triggers the release workflow
```

Then watch the run under **Actions → release**; the published release appears at
`https://github.com/stoicswe/Seemless/releases/tag/0.1.0`.

Notes:

-   The version must be `x.y.z`. The previous release is detected from the numeric git tags, so
    always tag releases as bare versions (`0.1.0`, not `v0.1.0`).
-   A published release is immutable: to change it, bump the version.
-   To publish an explicit version without a branch, use **Actions → release → Run workflow** with
    the `version` input.
-   Nightly snapshots are separate: each nightly run publishes a new prerelease tagged
    `nightly_<version>.<UTC date>_<commit>`, and only when something changed since the last one.
-   Betas are separate again: a push to a `beta/<anything>` branch publishes a prerelease tagged
    `beta_<YYYYMMDD>.<number>`. Betas are never the latest release.
-   Pull requests are built and checked, but nothing is published.
-   New builds are announced only on GitHub (Releases and tags); there are no outside
    announcements.
