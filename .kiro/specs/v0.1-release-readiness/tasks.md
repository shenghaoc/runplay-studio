# Tasks: macOS v0.1 release readiness

Checked boxes mean the implementation was added in this branch. CI and
credential-gated production steps prove runtime success; a checked box alone is
not publication evidence.

## Specification

- [x] Author requirements.md
- [x] Author design.md
- [x] Author tasks.md

## Versioning and templates

- [x] Add authoritative `VERSION` (`0.1.0`)
- [x] Add `Packaging/RunPlayStudio-Info.plist.in`
- [x] Add shared `scripts/lib/release-common.sh` validators

## Scripts

- [x] `scripts/assemble-app-bundle.sh`
- [x] Update `scripts/package-demo.sh` to use assembler
- [x] Reuse the assembler from `script/build_and_run.sh` while preserving its
  development bundle identifier
- [x] `scripts/package-release.sh` (unsigned / adhoc / developer-id / notarize)
- [x] `scripts/verify-app-bundle.sh`
- [x] `scripts/test-release-packaging.sh`
- [x] Enforce staged output, truthful dry-run state, deployment target, and no
  unexpected entitlements

## CI / workflows

- [x] `.github/workflows/release.yml` (dry-run dispatch + tag production)
- [x] Require annotated tag at `HEAD` on `main`; validate downloaded release set
- [x] Dedicated `Release Packaging (macOS)` CI job: script syntax,
  `test-release-packaging.sh`, end-to-end `package-demo.sh`, end-to-end ad-hoc
  dry run, artifact/checksum assertions, clean-checkout assertion
- [x] Git-ignore in-checkout workflow packaging output (`release-artifacts/`)
- [x] Preserve existing demo workflow behavior

## Documentation

- [x] `docs/releasing.md`
- [x] `docs/release-notes/v0.1.0.md`
- [x] README distribution distinction
- [x] Privacy notes for release bundles / notarization
- [x] Phase plan entry for release readiness

## Audits (recorded in PR / releasing docs)

- [x] Icon audit — no approved custom icon
- [x] Entitlement audit — none required
- [x] Dependency / license — ZIPFoundation MIT notices already present
- [x] Bundle ID preserved from demo packager

## Validation (local / CI)

- [x] `bash -n` on all new scripts
- [x] `./scripts/test-release-packaging.sh` (71 pass / 0 fail)
- [x] Ad-hoc dry run to `/private/tmp/runplay-v0.1-dry-run`
- [x] `./scripts/package-demo.sh`
- [x] Warning-clean AGENTS.md baseline suite (local exact worktree)
- [x] Inspect dry-run app (`plutil`, `file`, `lipo`, `otool`, `codesign`)
- [x] ZIP extract + isolated fresh-home launch smoke
- [ ] Production Developer ID + notarization (owner credentials only — not this PR)
- [x] Probe branch executing the empty-string `environment` expression
  (job succeeded; repository environment count stayed 0; branch deleted)
- [x] Local end-to-end run of the exact new CI packaging commands
- [x] Final exact-head CI on the opened PR

## Explicitly not done in this PR

- [ ] Create `v0.1.0` tag
- [ ] Create GitHub Release
- [ ] Publish official notarized binary
- [ ] Configure `release` environment secrets on GitHub
