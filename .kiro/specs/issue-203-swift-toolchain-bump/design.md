# Design

Pin the Linux image to `swift:6.4.2-resolute` by digest. Its libdispatch has the EPOLLHUP change (`423a7567`, the 6.4.x cherry-pick of `279fa89b`); the swift-6.4.2-RELEASE tag is ahead of it and 6.4.1 is behind. 6.4.2 matches Xcode 27.2's Swift, so macOS/Linux parity holds; 6.4.3 exists but would break parity. The retry wrapper, its fixtures, and every step that used it are removed in the same change.
