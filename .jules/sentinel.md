## 2024-07-07 - XML External Entity (XXE) Prevention
**Vulnerability:** Found missing `shouldResolveExternalEntities = false` protection on standard `XMLParser` use in `GPXImporter.swift` and `TCXImporter.swift`. This exposes the application to XXE attacks when processing externally-provided GPX and TCX files.
**Learning:** `XMLParser` in Foundation resolves external entities by default on some platforms or older OS versions, or at the very least it's an explicit setting that should be disabled when parsing untrusted user-supplied XML files like GPX/TCX.
**Prevention:** Always set `parser.shouldResolveExternalEntities = false` when initializing `XMLParser` for importing external/user-provided XML files.

## 2024-07-07 - SSRF/Remote File Inclusion Prevention
**Vulnerability:** Found missing `url.isFileURL` checks before calling `Data(contentsOf: url)` in workout importer classes (`FITImporter`, `GPXImporter`, `JSONWorkoutImporter`, `TCXImporter`). While `FileManager.default.fileExists(atPath: url.path)` provided partial mitigation, it does not prevent network requests if an attacker provided an `http://` URL where the `.path` component coincidentally matched an existing local file.
**Learning:** `Data(contentsOf:)` handles network protocols like HTTP/HTTPS in addition to local files. Relying solely on `FileManager.default.fileExists` is insufficient because it only validates the path component of the URL.
**Prevention:** Always validate that URLs intended for local file access are actually local files using `guard url.isFileURL else { ... }` before passing them to `Data(contentsOf:)` or similar APIs.

## 2024-07-09 - CSV Injection Prevention in Export Service
**Vulnerability:** Found missing mitigation for CSV Formula Injection in `ExportService.swift`. Unescaped spreadsheet formulas can be executed by applications like Microsoft Excel if user-supplied data (such as segment titles or string payloads starting with =, +, - or @) is directly appended to the output.
**Learning:** Spreadsheets treat fields starting with =, +, -, and @ as formulas and will evaluate them. In Swift, one must strip whitespace before detecting these, and allow real numbers while prepending a single quote to potential formula strings.
**Prevention:** In CSV-exporting mechanisms such as `CSVRow.escape`, check if the non-numeric field string starts with `=, +, -, @` and prepend a single quote (`'`) to ensure the field is interpreted as text rather than a potentially malicious formula.

## 2024-07-09 - CSV Formula Injection Mitigation Bypass Prevention

**Vulnerability:** Found an incomplete CSV Formula Injection mitigation in `ExportService.swift` where tab (`\t`) and carriage return (`\r`) prefixes were not considered dangerous. Attackers can bypass standard `=` prefix checks by starting a payload with a tab or carriage return, which some spreadsheet applications (like Excel) will still interpret as a formula.

**Learning:** Checking only for `=`, `+`, `-`, and `@` is insufficient because certain spreadsheet applications will trim specific leading whitespace characters or interpret them such that the remaining text is executed as a formula.

**Prevention:** Use the whitespace-trimming slow path in `CSVRow.escape` to handle fields starting with whitespace characters like `\t` and `\r`. The slow path trims leading whitespace, checks the first non-whitespace character against `dangerousPrefixes`, and prepends `'` only when a formula prefix is found after trimming. Do NOT add whitespace characters to `dangerousPrefixes` — doing so causes the fast path to incorrectly prepend `'` to legitimate non-formula fields starting with whitespace (e.g., `\tHello` would become `'\tHello`).

## 2026-07-16 - Corrected CSV Formula Injection Bypass Fix

**Issue:** The original fix (2024-07-09) added `\t` and `\r` directly to `dangerousPrefixes`, which caused a regression: legitimate non-formula fields starting with tabs or carriage returns were incorrectly escaped with a `'` prefix.

**Fix:** Removed `\t` and `\r` from `dangerousPrefixes`. The whitespace-trimming slow path already handles these characters correctly — it trims the whitespace, inspects the first non-whitespace character for dangerous prefixes, and only prepends `'` when a formula is detected. Added regression tests verifying that `\tHello` and `\rHello` are NOT incorrectly escaped.

**Verification:** All 39 ExportServiceTests pass, including the new regression tests for non-formula whitespace-prefixed fields.

## 2026-10-24 - SSRF/Remote File Inclusion Prevention with ZIPFoundation Archive
**Vulnerability:** Found missing `url.isFileURL` checks before calling `Archive(url: url, accessMode: .read)` in `WorkoutArchiveService.swift`. Like `Data(contentsOf:)`, passing an arbitrary or untrusted URL to ZIPFoundation's `Archive` initialization can result in Server-Side Request Forgery (SSRF) or remote file inclusion if network URLs are allowed.
**Learning:** Initializers that read from a `URL`, such as `Archive(url: accessMode:)` from the `ZIPFoundation` library, are vulnerable to SSRF just like `Data(contentsOf:)` if the URL is not verified to be a local file.
**Prevention:** Always validate that URLs intended for local file access are actually local files using `guard url.isFileURL else { ... }` before passing them to file-reading APIs, including third-party library initializers like `Archive(url:)`.
