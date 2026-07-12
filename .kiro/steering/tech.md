---
inclusion: fileMatch
fileMatchPattern:
  - "Package.swift"
  - ".github/workflows/**/*"
  - "scripts/**/*"
  - "**/*.swift"
---

# RunPlay Studio build and CI references

This is a **Swift Package** — there is no `.xcodeproj`. Xcode opens it via
`open Package.swift`. Schemes live in
`.swiftpm/xcode/xcshareddata/xcschemes/`. Do not create or reference an
`.xcodeproj` file.

Use the shared verification interface and live repository sources rather than
copying toolchain versions, CI commands, or workflow behavior into steering.

Package definition: #[[file:Package.swift]]
Agent verification: #[[file:scripts/verify.sh]]
Continuous integration: #[[file:.github/workflows/ci.yml]]
