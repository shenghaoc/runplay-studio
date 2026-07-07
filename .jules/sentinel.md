## 2024-07-07 - XML External Entity (XXE) Prevention
**Vulnerability:** Found missing `shouldResolveExternalEntities = false` protection on standard `XMLParser` use in `GPXImporter.swift` and `TCXImporter.swift`. This exposes the application to XXE attacks when processing externally-provided GPX and TCX files.
**Learning:** `XMLParser` in Foundation resolves external entities by default on some platforms or older OS versions, or at the very least it's an explicit setting that should be disabled when parsing untrusted user-supplied XML files like GPX/TCX.
**Prevention:** Always set `parser.shouldResolveExternalEntities = false` when initializing `XMLParser` for importing external/user-provided XML files.
