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
**Learning:** Checking only for `=`, `+`, `-`, and `@` is insufficient because certain spreadsheet applications will trim specific leading whitespace characters or interpret them such that the remaining text is executed as a formula. The set of dangerous characters must include standard formula prefixes as well as whitespace characters commonly used for bypasses, specifically `\t` and `\r`.
**Prevention:** When mitigating CSV Formula Injection, ensure the list of dangerous characters checked at the beginning of fields includes both standard formula prefixes (`=`, `+`, `-`, `@`) and bypass characters (`\t`, `\r`). Always add these to the `dangerousPrefixes` list in escaping functions.
