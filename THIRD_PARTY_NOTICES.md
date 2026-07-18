# Third-Party Notices

## ZIPFoundation

- **Version:** 0.9.20 (vendored sources under `ThirdParty/ZIPFoundation/`)
- **Upstream:** https://github.com/weichsel/ZIPFoundation
- **License:** MIT (see `ThirdParty/ZIPFoundation/LICENSE`)
- **Purpose:** ZIP container read access for local Strava bulk-export archive import in `RunPlayPlatform` only.
- **Security review notes:**
  - CVE-2023-39138 (Zip Slip / path traversal) affected ZIPFoundation **&lt; 0.9.18** during *extraction to disk*.
  - RunPlay Studio **never extracts the full archive to a temporary directory**.
  - Entry paths are validated with `WorkoutArchivePathValidator` before use.
  - Entry data is read into bounded memory with centralized size and ratio limits.
  - Sources are vendored as a first-party package target so warning-clean CI
    (`-warnings-as-errors`) does not conflict with SPM’s dependency
    `-suppress-warnings` flag.
- **Swift compatibility:** Compiled under Swift 5 language mode inside the Swift 6.3 package graph (macOS only).
