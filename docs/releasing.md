# Releasing RunPlay Studio (macOS)

This document describes the **v0.1 release pipeline**: how versioning, packaging,
signing, notarization, and publication work. It does not authorize publishing a
release by itself.

**Status**

| Item | State |
|------|--------|
| Release pipeline tooling | Ready (this repository) |
| Official signed binary | Not yet published |
| Demo (unsigned) packaging | Available via `scripts/package-demo.sh` |

Until an owner creates a matching `vX.Y.Z` tag with release-environment secrets
configured, no official binary is produced.

---

## Prerequisites

- macOS 26.0+ host for local packaging
- Xcode 26.4+ / Swift 6.3
- Apple Silicon (`arm64`) only for this release train
- For production: Apple Developer Program membership, Developer ID Application
  certificate, App Store Connect API key with Notary access
- For production CI: GitHub environment `release` with secrets listed below.
  The repository has no environments yet. GitHub auto-creates an environment
  the first time a job references it, and an auto-created environment has **no**
  protection rules — an owner must create `release` deliberately and add the
  required reviewers / branch restrictions before the first tag push.

---

## Version ownership

Authoritative marketing version:

```text
VERSION
```

Rules:

- Exactly three nonnegative integer components (`x.y.z`)
- No leading `v`
- No prerelease label for the initial `0.1.0` line
- Packaging scripts, workflows, and release notes read this file
- Do not hardcode the marketing version in unrelated sources

Production Git tags **must** be annotated, point at the commit being packaged,
and reference a commit already reachable from `main`:

```text
v<contents of VERSION>
```

Example: `VERSION` is `0.1.0` → tag `v0.1.0`.

The release workflow fails before signing when:

- the tag is malformed;
- the tag does not match `VERSION`;
- the tag is lightweight rather than annotated;
- `HEAD` is not the tagged commit;
- the tagged commit is not reachable from `main`;
- the worktree is dirty;
- generated bundle metadata disagrees with `VERSION`.

Dry runs may run from a branch without a tag.

### Build number (`CFBundleVersion`)

- Positive integer, digits only, no leading zeros, practical length bound
- Local default: `1`
- GitHub Actions default: `GITHUB_RUN_NUMBER`
- Never a Git SHA, timestamp with punctuation, or arbitrary string

Marketing version (`CFBundleShortVersionString`) comes only from `VERSION`.

---

## Scripts

| Script | Role |
|--------|------|
| `scripts/lib/release-common.sh` | Shared validation, plist generation, checksums, signing helpers |
| `scripts/assemble-app-bundle.sh` | Staged, repeatable `.app` assembly (no sign / zip / publish) |
| `scripts/package-demo.sh` | Unsigned demo `.app` + `RunPlayStudio.app.zip` |
| `scripts/package-release.sh` | Versioned release packaging (unsigned / adhoc / developer-id) |
| `scripts/verify-app-bundle.sh` | Non-mutating structural + signing verification |
| `scripts/test-release-packaging.sh` | Credential-free packaging tests |

### Info.plist template

```text
Packaging/RunPlayStudio-Info.plist.in
```

Generated fields include bundle identity, versions, minimum OS, high-resolution
capability, and `LSApplicationCategoryType = public.app-category.healthcare-fitness`
(fitness/workout analysis product).

**Bundle identifier (distribution):** `com.shenghaoc.runplay-studio`
Preserved from the historical demo packager. Do not change casually — it affects
trust records and future upgrades. Application Support storage uses the fixed
folder name `RunPlayStudio`, not a reverse-DNS derivation from this ID.

The assembler is also reused by `script/build_and_run.sh`, with that launcher's
intentional development bundle identifier supplied explicitly. There is one
bundle-structure implementation, not separate release and development copies.
"Repeatable" here means one validated process and deterministic logical
metadata/naming; signed archives are not claimed to be byte-for-byte
reproducible because build timestamps and secure signing timestamps vary.

---

## Demo packaging (unsigned)

```bash
./scripts/package-demo.sh [output-dir]
```

Produces:

- `RunPlayStudio.app`
- `RunPlayStudio.app.zip`

Label: **Unsigned — demo/testing only**

- Never requires Apple credentials
- Never notarizes
- Never claims Gatekeeper acceptance
- Workflow: `.github/workflows/package-demo.yml` (`workflow_dispatch`)

On Apple Silicon, the Swift toolchain may attach a linker ad-hoc signature to
the executable. That is still **not** a public distribution signature.

---

## Local dry run (ad-hoc)

```bash
./scripts/package-release.sh \
  --signing-mode adhoc \
  --skip-notarization \
  --dry-run \
  --output-dir /private/tmp/runplay-v0.1-dry-run
```

Label: **Ad hoc signed — not trusted for public distribution**

Unsigned, ad-hoc, and deliberately non-notarized output must pass `--dry-run`.
The CLI refuses to emit an official-looking `"dry_run": false` manifest for
those modes. A non-dry production invocation additionally requires Developer ID
signing, notarization, an annotated tag at `HEAD`, and a clean worktree.

Produces versioned artifacts:

```text
RunPlayStudio.app                                 # internal bundle name
RunPlayStudio-0.1.0-macos-arm64.zip               # publishable archive name
RunPlayStudio-0.1.0-release.json                  # machine-readable manifest
SHA256SUMS
```

The zip always contains `RunPlayStudio.app` (standard macOS presentation). Outer
artifact names are versioned so generic `RunPlayStudio.app.zip` is not the
release publication name.

---

## Signing modes

### `unsigned`

Demo / structural diagnostics only.

### `adhoc`

```bash
codesign --force --sign - <code-object>
```

Used for CI dry runs and signing-order checks. Not notarization-eligible.

### `developer-id`

Requires `--signing-identity` matching a **Developer ID Application** identity.

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"
```

Requirements:

- Hardened runtime
- Secure timestamp
- Explicit identity (never `-`)
- Inside-out signing of nested Mach-O objects, then outer bundle
- Immediate `codesign --verify` (including `--deep` as a **check**, not as the
  signing strategy)

Custom entitlements: **none** for v0.1. MapKit in a non-sandboxed Developer ID
app does not require invented entitlements. Sign without an entitlements file
unless a future feature proves a narrow need.

---

## Notarization

Use **`xcrun notarytool`** only (no altool).

Preferred CI authentication: App Store Connect API key (`.p8` + key id + issuer).

Sequence:

1. Assemble app
2. Developer ID sign nested code, then outer bundle
3. Verify signatures
4. Create a **temporary** notarization zip with `ditto`
5. `xcrun notarytool submit --wait`
6. Require accepted status
7. Staple ticket; `stapler validate`
8. `spctl --assess --type execute`
9. Create **final** distribution zip from the stapled app
10. Generate `SHA256SUMS` and release manifest

Never distribute the pre-stapling zip as the final artifact.
On failure: fail the job, do not publish, do not mark the manifest notarized.
The app, zip, manifest, and checksum set are staged inside the output directory
and replace the public output paths only after verification and ZIP extraction
checks pass; `SHA256SUMS` moves last as the completion marker.

---

## Temporary keychain (CI)

Production jobs:

1. Create a temporary keychain under `$RUNNER_TEMP`
2. Import the Developer ID `.p12`
3. Configure key partition list for `codesign`
4. Prefer that keychain for the job
5. Sign / notarize
6. **Always** delete the decoded certificate, keychain, and API key file in
   cleanup, including when setup failed partway through

Do not import release certificates into the permanent login keychain.

---

## GitHub Actions

### `.github/workflows/release.yml`

| Trigger | Behavior |
|---------|----------|
| `workflow_dispatch` with `dry_run=true` (default) | Tests + ad-hoc package + artifact upload; **no** GitHub Release; **no** Apple credentials |
| `push` of annotated tag `v*` | Production path: validate tag↔VERSION↔HEAD and `main` ancestry, Developer ID, notarize, staple, Gatekeeper, then `gh release create --verify-tag` |

Permissions:

- Default `contents: read`
- `contents: write` only on the production publish job

Concurrency:

- Production: `release-prod-<ref>` (do not cancel in progress)
- Dry run: `release-dryrun-<ref>`

Both paths package into `release-artifacts/` inside the checkout. That directory
is git-ignored, so packaging output cannot be committed by accident and cannot
dirty the worktree that production packaging requires to be clean.

### Environment `release`

Configure GitHub Environment protections (recommended):

- Required reviewers
- Restricted to release tags / protected refs
- Environment secrets only
- Optional wait timer

### Secrets (names)

```text
DEVELOPER_ID_CERT_P12_BASE64
DEVELOPER_ID_CERT_PASSWORD
DEVELOPER_ID_APPLICATION_IDENTITY
APP_STORE_CONNECT_API_KEY_P8_BASE64
APP_STORE_CONNECT_KEY_ID
APP_STORE_CONNECT_ISSUER_ID
RELEASE_KEYCHAIN_PASSWORD          # optional; random if unset
```

Never commit `.p12` / `.p8` files. Never print decoded keys or passwords.

### PR CI packaging coverage

The `Release Packaging (macOS)` job in
[.github/workflows/ci.yml](../.github/workflows/ci.yml) runs on every pull
request and every push to `main`, entirely credential-free:

1. `bash -n` over every packaging script.
2. `scripts/test-release-packaging.sh` — the packaging contract suite.
3. `scripts/package-demo.sh` — builds a real unsigned `.app` plus its zip.
4. `scripts/package-release.sh --signing-mode adhoc --skip-notarization
   --dry-run` — the same invocation the Release workflow runs on its
   non-production path.
5. Artifact presence, `shasum -a 256 -c SHA256SUMS`, and a check that packaging
   left the checkout clean.

Steps 3 and 4 share one `swift build -c release`, so the second is cache-warm
and near-free. The job runs concurrently with `macOS (Full Stack)` rather than
extending it.

It never signs with a Developer ID, never notarizes, never uploads app
artifacts, and never creates a GitHub Release. The Developer ID → notarize →
staple → Gatekeeper path has no PR coverage by construction: it needs `release`
environment secrets and runs only on a `vX.Y.Z` tag push.

---

## Artifact naming

| Artifact | Purpose |
|----------|---------|
| `RunPlayStudio-<ver>-macos-arm64.zip` | Official downloadable app archive |
| `RunPlayStudio-<ver>-release.json` | Machine-readable release record |
| `SHA256SUMS` | Checksums for published files |

Architecture is **arm64 only** — not universal. Do not label otherwise.

---

## Release manifest

`RunPlayStudio-<ver>-release.json` records product metadata, commit SHA, tag (or
null), toolchain versions, artifact hash/size, signing mode, hardened-runtime
flag, and notarization / stapling / Gatekeeper statuses.

Statuses are written from **actual command results**. Requesting notarization
does not set `"notarization_status": "accepted"`.

Dry runs set `"dry_run": true`. Production publish refuses a dry-run manifest.
The publish job downloads the artifact set and revalidates `SHA256SUMS`, version,
tag, commit, artifact hash and size, architecture, signing mode, hardened
runtime, and notarization/stapling/Gatekeeper states before release creation.

---

## Privacy

Release and demo bundles contain only:

- application code;
- approved synthetic demo resources from the SwiftPM resource bundle.

They must not contain:

- user `manifest.json` / `session.json` libraries;
- imported workout snapshots;
- exports;
- certificates, API keys, or keychains.

Notarization uploads the **app archive** to Apple for malware scanning. No user
workout library is packaged or uploaded. Signing and notarization are not
product telemetry.

See also [privacy.md](privacy.md) and [private-data.md](private-data.md).

---

## Icon

No approved custom `.icns` is checked in for v0.1. The pipeline does not invent
a low-quality icon or pull artwork from the internet. Finder/Dock use the
default executable icon until a designed asset is added deliberately.

---

## Third-party licenses

Binary distribution includes vendored **ZIPFoundation 0.9.20** (MIT). See
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and
`ThirdParty/ZIPFoundation/LICENSE`.

---

## Verification after download

```bash
shasum -a 256 -c SHA256SUMS
ditto -x -k RunPlayStudio-0.1.0-macos-arm64.zip ./extracted
codesign --verify --deep --strict --verbose=2 ./extracted/RunPlayStudio.app
codesign -dvvv ./extracted/RunPlayStudio.app
xcrun stapler validate ./extracted/RunPlayStudio.app   # official only
spctl --assess --type execute --verbose=4 ./extracted/RunPlayStudio.app
```

Ad-hoc dry-run artifacts are **not** expected to pass Gatekeeper.

---

## Rollback

- Do not delete Git tags casually; if a tag must be retracted, remove the GitHub
  Release assets and publish a higher build number or patch version after fix.
- Yanked releases should be marked on the GitHub Release notes.
- Rotate Developer ID certificates and App Store Connect API keys if leaked;
  update environment secrets; re-run production packaging only after rotation.

---

## Troubleshooting notarization

- Confirm Developer ID Application (not Mac Development) identity
- Confirm hardened runtime and secure timestamp
- Inspect the notarytool log for the failing submission id (sanitized; no secrets):

  ```bash
  xcrun notarytool log <submission-id> \
    --key "$NOTARY_KEY" --key-id "$KEY_ID" --issuer "$ISSUER_ID"
  ```
- Ensure no unexpected nested unsigned Mach-O code
- Retry only after fixing the root cause — do not publish failed notarization

---

## Out of scope for this pipeline

- Mac App Store / TestFlight / Sparkle auto-update
- DMG installer
- Intel / universal binaries
- iOS / HealthKit
- Sandbox migration
- Telemetry, accounts, cloud backends
