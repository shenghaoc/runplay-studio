---
inclusion: fileMatch
fileMatchPattern:
  - "Package.swift"
  - ".github/workflows/**/*"
  - "scripts/**/*"
---

# RunPlay Studio build and CI references

Use the shared verification interface and live repository sources rather than
copying toolchain versions, CI commands, or workflow behavior into steering.

Package definition: #[[file:Package.swift]]
Agent verification: #[[file:scripts/verify.sh]]
Continuous integration: #[[file:.github/workflows/ci.yml]]
