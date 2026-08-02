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
The existing debug launcher also delegates bundle construction to the assembler,
while retaining its intentional development bundle identifier.

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
| Artifact replacement | Build and verify in an output-local staging directory | A failed run cannot publish a partial new artifact set |
| Workflow output location | `release-artifacts/` inside the checkout, git-ignored | Keeps upload paths simple while preventing accidental commits and self-inflicted dirty-worktree failures in production packaging |
| Non-production state | Require `--dry-run` for unsigned, ad-hoc, or non-notarized output | Prevent official-looking false manifest state |

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

1. Validate annotated tag ↔ VERSION ↔ HEAD and `main` ancestry; clean tree
2. Same correctness suite
3. Temporary keychain + import Developer ID
4. `package-release.sh --signing-mode developer-id --notarize ...`
5. Download and validate checksums plus exact manifest facts
6. `gh release create --verify-tag` after all gates pass

## Security

- Secrets only in `release` environment; non-production triggers resolve the
  job `environment` expression to the empty string, which GitHub treats as no
  environment (probe-verified) and therefore grants no environment secrets
- No `set -x` around credentials
- Keychain, decoded `.p12`, and `.p8` deleted in `always()` cleanup, including
  partial setup failures
- Manifest never embeds secret material or local absolute user paths
- Unexpected entitlements fail bundle verification

## Testing strategy

`scripts/test-release-packaging.sh` covers validators, CLI rejection cases,
safe/staged assembly and failed-run artifact preservation, development-identity
reuse, ad-hoc packaging, deployment target and entitlement enforcement,
checksum validation, manifest truthfulness, and privacy absence checks without
Developer ID credentials.

PR CI additionally executes the packaging path rather than only asserting its
contracts: the `Release Packaging (macOS)` job builds the unsigned demo bundle
and the ad-hoc dry-run release set, verifies checksums, and asserts packaging
leaves the checkout clean. Both invocations share one `swift build -c release`.
The job is separate from `macOS (Full Stack)` so the two run concurrently.

## Risks

| Risk | Mitigation |
|------|------------|
| Tag without secrets | Production job fails closed; no partial official publish |
| Accidental publication from PR | No tag created; dry_run default; publish job gated |
| Development and distribution bundle IDs intentionally differ | Pass the development ID explicitly through the shared assembler and test both identities |
| Linker ad-hoc on “unsigned” demo | Document as allowed; still not public distribution |
| Conditional job `environment` never executed | Probe branch ran the empty-string branch of the same expression: job succeeded and no environment was created |
| Packaging regression reaching the release path unnoticed | PR CI runs the release workflow's own dry-run invocation end to end |
| Auto-created `release` environment has no protection rules | `docs/releasing.md` requires the owner to create it deliberately before the first tag push |
