# Third-Party Notices

## ZIPFoundation

- **Version:** 0.9.20, exact-pinned (`.package(url:…, exact: "0.9.20")` in
  `Package.swift`); `Package.resolved` records resolved revision
  `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` for that tag.
- **Acquisition:** remote SwiftPM dependency of the root package — the
  package's only remote dependency. Dependency bumps are manual, reviewable
  edits to the pin in `Package.swift`.
- **Upstream:** https://github.com/weichsel/ZIPFoundation
- **License:** MIT (see the upstream repository's `LICENSE`).
- **Purpose:** ZIP container read access for local Strava bulk-export archive import in `RunPlayPlatform` only.
- **Security review notes:**
  - CVE-2023-39138 (Zip Slip / path traversal) affected ZIPFoundation
    **below 0.9.18** during *extraction to disk*; the fix landed in 0.9.18,
    so the pinned 0.9.20 includes it.
  - RunPlay Studio **never extracts the full archive to a temporary directory**.
  - Entry paths are validated with `WorkoutArchivePathValidator` before use.
  - Entry data is read into bounded memory with centralized size and ratio limits.
  - Non-file URLs are rejected by `StravaArchiveService` before any archive
    open; upstream 0.9.20 does not itself enforce a local-file-URL scheme
    in `Archive(url:)`.
