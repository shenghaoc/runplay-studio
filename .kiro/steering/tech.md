# RunPlay Studio — Tech Stack

## Language & Toolchain

- **Swift 6** (language mode `.v6`) — strict concurrency enforced
- **Swift Package Manager** — no `.xcodeproj`; open `Package.swift` in Xcode
- **Swift tools version**: 6.3
- **Minimum deployment**: macOS 26

## Frameworks

| Layer | Frameworks |
|-------|-----------|
| RunPlayCore | Foundation, FoundationXML (conditional, Linux) |
| RunPlayPlatform | MapKit, SceneKit, AppKit value types, Combine (non-UI) |
| RunPlayStudio | SwiftUI, Swift Charts, UniformTypeIdentifiers, AppKit (NSHostingView for PNG export) |

**No third-party dependencies.** All code uses Apple-native frameworks only. Do not add external packages without an explicit product decision.

## Build & Test Commands

```bash
# Build everything (macOS)
swift build -Xswiftc -warnings-as-errors

# Run all tests
swift test -Xswiftc -warnings-as-errors

# Core-only (also works on Linux)
swift build --target RunPlayCore
swift test --filter RunPlayCoreTests

# Platform layer only
swift build --target RunPlayPlatform
swift test --filter RunPlayPlatformTests

# Check for whitespace issues before committing
git diff --check

# Build unsigned demo .app bundle
./scripts/package-demo.sh
# Output: .build/artifacts/RunPlayStudio.app
```

CI treats warnings as errors. Use the same standard locally — always pass `-Xswiftc -warnings-as-errors`.

## CI

GitHub Actions runs on every push to `main` and every PR:
- **macOS**: full `swift build` + `swift test`
- **Linux**: `RunPlayCore` target only (platform-neutral)

Workflows: `.github/workflows/ci.yml`, `.github/workflows/package-demo.yml`

## Swift 6 Concurrency Notes

- All UI state lives on `@MainActor` in `RunPlayStudio`
- `RunPlayCore` types are value types (`struct`, `enum`) — safe to cross actor boundaries
- `WorkoutLibraryStoreActor` is an `actor` for safe concurrent library access
- Avoid `@unchecked Sendable` workarounds; fix the underlying concurrency issue instead
