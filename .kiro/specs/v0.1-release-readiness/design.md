# Design: macOS v0.1 release readiness

## Context

RunPlay Studio already ships a mature macOS product and a completed portable
C++23 engine. Packaging was limited to an unsigned demo script and a manual
demo workflow. This phase adds a release-quality pipeline beside that path.

## Architecture

```text
VERSION ──► assemble-app-bundle.sh ──► RunPlayStudio.app (unsigned structure)
                    ▲
                    │
     Packaging/RunPlayStudio-Info.plist.in
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
 package-demo.sh          package-release.sh
 (unsigned zip)           unsigned | adhoc | developer-id
                                 │
                                 ├─ verify-app-bundle.sh
                                 ├─ optional notarytool + stapler
                                 ├─ versioned zip + SHA256SUMS
                                 └─ release manifest JSON
```

Shared logic lives in `scripts/lib/release-common.sh` so packagers stay focused.

## Key decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Version authority | Root `VERSION` file | Single durable source; scripts and CI validate |
| Bundle ID | `com.shenghaoc.runplay-studio` | Preserve demo packager identity; avoid breaking trust records |
| App Support path | Folder name `RunPlayStudio` (unchanged in app code) | Independent of reverse-DNS bundle id |
| Architecture | arm64 only | Matches current product; no Intel work this phase |
| Min OS | 26.0 | Matches existing demo packager and README |
| Category | `public.app-category.healthcare-fitness` | Truthful for workout analysis |
| Icon | Document missing; do not invent | No approved artwork |
| Entitlements | None | MapKit non-sandboxed needs no invented entitlements |
| Signing order | Nested Mach-O then outer bundle | Avoid `--deep` as implementation |
| Notarization | `notarytool` + staple then final zip | Current Apple tooling; pre-staple zip not published |
| Publication | `gh release create` after gates | Prefer official GitHub CLI over unreviewed marketplace actions |
| Dry run | adhoc + `dry_run: true` manifest | Credential-free CI validation |
| Demo path | Keep separate workflow/script | Do not silently promote demo to production |

## Artifact naming

- Outer publishable zip: `RunPlayStudio-<version>-macos-arm64.zip`
- Inner bundle: `RunPlayStudio.app` (Finder-standard)
- Manifest: `RunPlayStudio-<version>-release.json`
- Checksums: `SHA256SUMS`

## Workflow design

### Dry run (`workflow_dispatch`, default)

1. Checkout, Xcode 26.4, Swift 6.3  
2. Boundary validation + tests  
3. `package-release.sh --signing-mode adhoc --skip-notarization --dry-run`  
4. Upload versioned zip, manifest, SHA256SUMS  
5. Never create a GitHub Release  

### Production (`push` tags `v*`)

1. Validate tag ↔ VERSION ↔ HEAD; clean tree  
2. Same correctness suite  
3. Temporary keychain + import Developer ID  
4. `package-release.sh --signing-mode developer-id --notarize ...`  
5. Publish job checks manifest statuses then `gh release create`  

## Security

- Secrets only in `release` environment  
- No `set -x` around credentials  
- Keychain and `.p8` deleted in `always()` cleanup  
- Manifest never embeds secret material or local absolute user paths  

## Testing strategy

`scripts/test-release-packaging.sh` covers validators, CLI rejection cases, plist
generation, adhoc packaging, checksum validation, manifest truthfulness, and
privacy absence checks without Developer ID credentials.

## Risks

| Risk | Mitigation |
|------|------------|
| Tag without secrets | Production job fails closed; no partial official publish |
| Accidental publication from PR | No tag created; dry_run default; publish job gated |
| Bundle ID mismatch with local `build_and_run.sh` | Document packaging ID as distribution authority; local script is dev-only |
| Linker ad-hoc on “unsigned” demo | Document as allowed; still not public distribution |
