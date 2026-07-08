## 2024-07-07 - XML External Entity (XXE) Prevention
**Vulnerability:** Found missing `shouldResolveExternalEntities = false` protection on standard `XMLParser` use in `GPXImporter.swift` and `TCXImporter.swift`. This exposes the application to XXE attacks when processing externally-provided GPX and TCX files.
**Learning:** `XMLParser` in Foundation resolves external entities by default on some platforms or older OS versions, or at the very least it's an explicit setting that should be disabled when parsing untrusted user-supplied XML files like GPX/TCX.
**Prevention:** Always set `parser.shouldResolveExternalEntities = false` when initializing `XMLParser` for importing external/user-provided XML files.

## 2024-07-07 - SSRF/Remote File Inclusion Prevention
**Vulnerability:** Found missing `url.isFileURL` checks before calling `Data(contentsOf: url)` in workout importer classes (`FITImporter`, `GPXImporter`, `JSONWorkoutImporter`, `TCXImporter`). While `FileManager.default.fileExists(atPath: url.path)` provided partial mitigation, it does not prevent network requests if an attacker provided an `http://` URL where the `.path` component coincidentally matched an existing local file.
**Learning:** `Data(contentsOf:)` handles network protocols like HTTP/HTTPS in addition to local files. Relying solely on `FileManager.default.fileExists` is insufficient because it only validates the path component of the URL.
**Prevention:** Always validate that URLs intended for local file access are actually local files using `guard url.isFileURL else { ... }` before passing them to `Data(contentsOf:)` or similar APIs.
