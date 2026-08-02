# Requirements: macOS v0.1 release readiness

## Objective

Prepare a reproducible macOS v0.1 release pipeline for RunPlay Studio without
publishing a release from this change. Production signing, notarization, tagging,
and publication remain credential-gated owner actions.

## In scope

1. Authoritative `VERSION` file (`0.1.0`) and validated build numbers
2. Shared staged app-bundle assembly with deterministic logical metadata
3. Preserved unsigned demo packaging path
4. Separate release packager with unsigned / adhoc / developer-id modes
5. Ad-hoc dry runs without Apple credentials
6. Developer ID signing + notarytool notarization + stapling when credentials exist
7. Versioned ZIP, SHA-256 checksums, machine-readable release manifest
8. Safe GitHub Actions release workflow (dry-run default; tag production path)
9. Bundle verification and credential-free packaging tests
10. Truthful release, privacy, README, and phase-plan documentation
11. Kiro specification under `.kiro/specs/v0.1-release-readiness/`

## Out of scope

- Creating a Git tag or GitHub Release from this PR
- Using Apple credentials without a configured environment
- iOS / UIKit / HealthKit / companion apps
- Intel or universal binaries
- DMG, Sparkle, Mac App Store, TestFlight, sandbox migration
- Icon redesign, UI redesign, new analysis features, schema migrations
- Reopening the completed C++23 engine migration
- Product algorithm, import, export, comparison, or UI feature changes

## Functional requirements

### Versioning

- FR-V1: `VERSION` is the sole marketing-version authority (`x.y.z`).
- FR-V2: Reject blank, whitespace, `v` prefix, prerelease, and non-semver-three-part values.
- FR-V3: `CFBundleShortVersionString` comes from `VERSION`; `CFBundleVersion` is a positive integer.
- FR-V4: Production tags must be annotated, equal `v` + `VERSION`, point to
  `HEAD`, and reference a commit reachable from `main`; mismatch fails before
  signing.
- FR-V5: Dry runs may run without a tag.

### Assembly

- FR-A1: Shared assembler builds or consumes SwiftPM release output and produces `.app`.
- FR-A2: Assembler installs executable, resource bundle, and generated Info.plist.
- FR-A3: Assembler never signs, zips, notarizes, or publishes.
- FR-A4: Missing binary or resource bundle fails clearly.

### Demo packaging

- FR-D1: `package-demo.sh` remains an unsigned demo path using the shared assembler.
- FR-D2: Demo never requires secrets or notarization.
- FR-D3: Demo never claims Gatekeeper acceptance.

### Release packaging

- FR-R1: Explicit CLI with help, validation, safe product-bundle paths, staged
  assembly, and publish-on-success artifact replacement.
- FR-R2: Unsupported option combinations fail (e.g. notarize + adhoc).
- FR-R3: Deterministic versioned artifact names; no generic official `RunPlayStudio.app.zip`.
- FR-R4: Exact verified app is what gets zipped (optional staple first).
- FR-R5: Manifest statuses reflect measured results, not intentions; unsigned,
  ad-hoc, and non-notarized output cannot claim `dry_run: false`.

### Signing and notarization

- FR-S1: Three modes — unsigned, adhoc, developer-id.
- FR-S2: Developer ID uses hardened runtime, timestamp, inside-out signing (no `--deep` as signer).
- FR-S3: No custom entitlements unless proven necessary (none for v0.1); bundle
  verification fails if any are present on the app or nested code.
- FR-S4: Notarization via `notarytool` only; staple; Gatekeeper assess; then final zip.
- FR-S5: Temporary CI keychain with cleanup that also runs after partial
  credential setup failures.
- FR-S6: Secrets never printed or uploaded.

### CI / workflow

- FR-C1: Manual dry-run workflow path without credentials or GitHub Release.
- FR-C2: Tag `v*` production path uses `release` environment and secrets.
- FR-C3: Least-privilege permissions; separate concurrency groups.
- FR-C4: PR CI runs credential-free packaging smoke tests.
- FR-C5: Existing Core / sanitizer / full-stack CI remains intact.
- FR-C6: Publication revalidates downloaded checksums and exact manifest facts
  before `gh release create --verify-tag`.

### Privacy

- FR-P1: Bundles must not contain user libraries, session files, or secrets.
- FR-P2: Documentation states notarization uploads app archives only.

## Non-functional requirements

- NFR-1: Scripts use `set -euo pipefail` and are `bash -n` clean.
- NFR-2: arm64-only artifacts; never labeled universal.
- NFR-3: Minimum macOS 26.0 consistent across plist, docs, and binary expectations.
- NFR-4: No new third-party packaging dependencies.
