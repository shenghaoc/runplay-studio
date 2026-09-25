import Foundation
// `XMLParser` lives in a separate module on corelibs; this guard matches the one
// every XML importer opens with (GPXImporter.swift:2, TCXImporter.swift:2).
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import RunPlayCore

/// Hardening tests for `DTDStrippingInputStream`.
///
/// This type exists because Foundation's `XMLParser` segfaults on Linux when a
/// document carries an inline DTD with an `ATTLIST` declaration, and Apple
/// Health's `export.xml` carries exactly that. See the type's doc comment for
/// the upstream defect.
///
/// Two properties are asserted here, and neither is incidental:
///
/// 1. **Boundary safety.** The DTD terminator can land on any byte, so every
///    case is re-run across a spread of upstream chunk sizes down to one byte.
///    A previous bug in this area came from `Data` slices retaining their
///    original indices, so chunk-size sweeps are the point rather than a formality.
/// 2. **The lossless guard fires.** Eliding a DTD is only safe when it supplies
///    no value. A DTD that could supply one must fail loudly, never import.
final class DTDStrippingInputStreamTests: XCTestCase {

    // MARK: - Harness

    /// An `InputStream` that yields at most `chunk` bytes per read, so a single
    /// fixture exercises every terminator split across a buffer boundary.
    private final class ChunkedStream: InputStream {
        private let inner: InputStream
        private let chunk: Int

        init(_ inner: InputStream, chunk: Int) {
            self.inner = inner
            self.chunk = chunk
            super.init(data: Data())
        }

        override func open() { inner.open() }
        override func close() { inner.close() }
        override var streamStatus: Stream.Status { inner.streamStatus }
        override var hasBytesAvailable: Bool { inner.hasBytesAvailable }
        override var streamError: Error? { inner.streamError }

        override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
            inner.read(buffer, maxLength: min(len, chunk))
        }
    }

    private final class CountingDelegate: NSObject, XMLParserDelegate {
        var elements = 0
        var attributes = 0
        var elementNames: [String] = []

        func parser(
            _ parser: XMLParser,
            didStartElement name: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            elements += 1
            self.attributes += attributes.count
            elementNames.append(name)
        }
    }

    /// Chunk sizes swept for every fixture: 1–3 byte reads split the DOCTYPE
    /// token itself, the sizes around 8–13 straddle `<!DOCTYPE`, and 4096 covers
    /// the normal bulk path.
    private let chunkSizes = [1, 2, 3, 5, 7, 8, 9, 10, 13, 64, 4096]

    /// What one elided parse produced. Named to avoid shadowing `Swift.Result`.
    private struct ParseOutcome {
        var parseOK: Bool
        var elements: Int
        var attributes: Int
        var violation: DTDPolicyViolation?
        var elidedBytes: Int
    }

    /// Parses `xml` with the elider in the chain, at a fixed upstream chunk size.
    private func parse(
        _ xml: String,
        chunk: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ParseOutcome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dtd-elide-\(UUID().uuidString).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let inner = InputStream(url: url) else {
            XCTFail("could not open fixture stream", file: file, line: line)
            return ParseOutcome(parseOK: false, elements: 0, attributes: 0,
                                violation: nil, elidedBytes: 0)
        }
        let elider = DTDStrippingInputStream(upstream: ChunkedStream(inner, chunk: chunk))
        let delegate = CountingDelegate()
        let parser = XMLParser(stream: elider)
        parser.delegate = delegate
        // Matches GPXImporter.swift:206 and TCXImporter.swift:446.
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        return ParseOutcome(
            parseOK: ok,
            elements: delegate.elements,
            attributes: delegate.attributes,
            violation: elider.policyViolation,
            elidedBytes: elider.elidedByteCount
        )
    }

    /// Runs one assertion across every chunk size in the sweep.
    private func acrossChunks(
        _ xml: String,
        chunks: [Int]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (ParseOutcome, Int, StaticString, UInt) -> Void
    ) {
        for chunk in chunks ?? chunkSizes {
            let result: ParseOutcome
            do {
                result = try parse(xml, chunk: chunk)
            } catch {
                XCTFail("fixture write failed: \(error)", file: file, line: line)
                return
            }
            body(result, chunk, file, line)
        }
    }

    // MARK: - Documents that must parse

    private let docNoDTD = #"<?xml version="1.0"?><Root><A v="1"/><A v="2"/></Root>"#

    private func docWithDTD(_ subset: String) -> String {
        "<?xml version=\"1.0\"?><!DOCTYPE Root [\(subset)]><Root><A v=\"1\"/><A v=\"2\"/></Root>"
    }

    /// The minimal document that reproduces the upstream defect.
    ///
    /// Handed to `XMLParser` directly this **segfaults** on Linux (Swift 6.4,
    /// `swift:6.4.0-resolute`, Ubuntu 26.04.1, arm64) inside
    /// `libxml2.so.16.1.2` beneath `XMLParser.parseData`, and parses fine on
    /// macOS (`ok=true elements=3`). The faulting element name is visible in the
    /// crash registers. This is the reproducer attached to
    /// <https://github.com/swiftlang/swift-corelibs-foundation/issues/5573>.
    ///
    /// The crash is deliberately *not* re-triggered here: a segfault would take
    /// down the whole test process, so what this file asserts is the other half
    /// of the story — that eliding the DTD makes the same bytes parse on both
    /// platforms.
    static let minimalDTDReproducer = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE HealthData [
        <!ELEMENT HealthData (Rec*)>
        <!ELEMENT Rec EMPTY>
        <!ATTLIST Rec
          type CDATA #REQUIRED
          value CDATA #IMPLIED
        >
        ]>
        <HealthData>
        <Rec type="HKQuantityTypeIdentifierHeartRate" value="150"/>
        <Rec type="HKQuantityTypeIdentifierHeartRate" value="151"/>
        </HealthData>

        """

    /// The reproducer's size is pinned so the claim in the upstream issue and the
    /// bytes in this file cannot silently drift apart.
    func testMinimalDTDReproducerIsTheDocumentedSize() {
        XCTAssertEqual(
            Self.minimalDTDReproducer.utf8.count, 324,
            "the issue cites a 324-byte reproducer; if this changed, update the issue"
        )
    }

    /// The reproducer parses through the elider on **both** platforms, which is
    /// the workaround proving itself on exactly the input that crashes without it.
    func testMinimalDTDReproducerParsesThroughTheEliderOnBothPlatforms() {
        acrossChunks(Self.minimalDTDReproducer) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk) reproducer should parse once elided",
                          file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk) #REQUIRED/#IMPLIED supply no value",
                         file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk) HealthData + 2 Rec",
                           file: file, line: line)
            XCTAssertEqual(result.attributes, 4, "chunk=\(chunk) both Rec attributes survive",
                           file: file, line: line)
        }
    }

    /// Value-free DTD: the shape Apple Health writes, with `#REQUIRED` and
    /// `#IMPLIED` only. Must parse, with every attribute delivered.
    func testValueFreeDTDParsesAcrossChunkBoundaries() {
        let xml = docWithDTD(
            "<!ELEMENT Root (A*)><!ELEMENT A EMPTY>"
                + "<!ATTLIST A v CDATA #REQUIRED><!ATTLIST A w CDATA #IMPLIED>"
        )
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk) should parse", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk) value-free DTD must not violate", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk) Root + 2 A", file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk) both v attributes survive", file: file, line: line)
            XCTAssertGreaterThan(result.elidedBytes, 0, "chunk=\(chunk) should elide something", file: file, line: line)
        }
    }

    /// A document with no DOCTYPE at all must pass through untouched.
    func testDocumentWithoutDTDPassesThroughUnchanged() {
        acrossChunks(docNoDTD) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elidedBytes, 0, "chunk=\(chunk) nothing to elide", file: file, line: line)
        }
    }

    /// An empty internal subset supplies no value.
    func testEmptyInternalSubsetParses() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root []><Root><A v=\"1\"/><A v=\"2\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// `ELEMENT`-only DTD: validity constraints contribute no value.
    func testElementOnlyDTDParses() {
        let xml = docWithDTD("<!ELEMENT Root (A*)><!ELEMENT A EMPTY>")
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A DOCTYPE with only an external ID and **no** internal subset must be
    /// accepted. The external subset is never fetched — callers set
    /// `shouldResolveExternalEntities = false` — so it supplies nothing, and
    /// refusing such a document would reject valid exports.
    func testExternalIDOnlyDOCTYPEParses() {
        for xml in [
            "<?xml version=\"1.0\"?><!DOCTYPE Root SYSTEM \"file:///nonexistent.dtd\"><Root><A v=\"1\"/><A v=\"2\"/></Root>",
            "<?xml version=\"1.0\"?><!DOCTYPE Root PUBLIC \"-//X//Y//EN\" \"http://example.invalid/x.dtd\"><Root><A v=\"1\"/><A v=\"2\"/></Root>",
        ] {
            acrossChunks(xml) { result, chunk, file, line in
                XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
                XCTAssertNil(result.violation, "chunk=\(chunk) external ID supplies no value", file: file, line: line)
                XCTAssertEqual(result.elements, 3, "chunk=\(chunk)", file: file, line: line)
                XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
            }
        }
    }

    /// The external ID's quoted literal must not be mistaken for a DOCTYPE
    /// internal subset opener, and the `]` inside it must not end anything.
    func testQuotedLiteralInsideExternalIDIsNotSubset() {
        let xml = "<?xml version=\"1.0\"?>"
            + "<!DOCTYPE Root PUBLIC \"-//A//B ]> tricky//EN\" \"x.dtd\"><Root><A v=\"1\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 2, "chunk=\(chunk) Root + A", file: file, line: line)
        }
    }

    // MARK: - The lossless guard (condition 1)

    /// A quoted attribute default is the case the user called out by name: a
    /// future iOS release could add one, and eliding would then silently drop an
    /// attribute from every record lacking it. This must fail loudly.
    func testQuotedAttributeDefaultFailsLoudlyInsteadOfImporting() {
        let xml = docWithDTD("<!ELEMENT Root (A*)><!ELEMENT A EMPTY><!ATTLIST A v CDATA \"supplied\">")
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertFalse(result.parseOK, "chunk=\(chunk) must not report success", file: file, line: line)
            XCTAssertEqual(
                result.violation, .quotedAttributeDefault,
                "chunk=\(chunk) must name the reason", file: file, line: line
            )
            XCTAssertEqual(result.elements, 0, "chunk=\(chunk) must not import", file: file, line: line)
        }
    }

    /// A single-quoted default must be caught too.
    func testSingleQuotedAttributeDefaultFailsLoudly() {
        let xml = docWithDTD("<!ATTLIST A v CDATA 'supplied'>")
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertFalse(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.violation, .quotedAttributeDefault, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// `#FIXED` pins a value, so eliding would drop it.
    func testFixedAttributeDefaultFailsLoudly() {
        let xml = docWithDTD("<!ATTLIST A v CDATA #FIXED \"pinned\">")
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertFalse(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.violation, .fixedAttributeDefault, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// An entity could expand into content.
    func testEntityDeclarationFailsLoudly() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root [<!ENTITY e \"boom\">]><Root>&e;</Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertFalse(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.violation, .entityDeclaration, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A notation could carry an unparsed-entity default.
    func testNotationDeclarationFailsLoudly() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root [<!NOTATION n SYSTEM \"x\">]><Root/>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertFalse(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.violation, .notationDeclaration, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A subset too large to inspect cannot be proven value-free.
    func testOversizedInternalSubsetFailsLoudly() {
        // The guard is bounded by bytes appended, so one chunk size suffices; a
        // single-byte sweep over a multi-megabyte subset would be slow for no
        // additional coverage of the boundary logic.
        let padding = String(repeating: "<!ELEMENT A EMPTY>", count: 60_000)
        XCTAssertGreaterThan(padding.utf8.count, DTDStrippingInputStream.maxInspectedDTDBytes,
                             "fixture must exceed the inspection limit to test the guard")
        let xml = docWithDTD(padding)
        acrossChunks(xml, chunks: [4096]) { result, _, file, line in
            XCTAssertFalse(result.parseOK, "must not parse an uninspectable DTD", file: file, line: line)
            if case .internalSubsetTooLarge = result.violation {
                // expected
            } else {
                XCTFail("expected .internalSubsetTooLarge, got \(String(describing: result.violation))",
                        file: file, line: line)
            }
        }
    }

    /// Every violation carries a user-facing message, since this surfaces as an
    /// import failure rather than a crash.
    func testViolationMessagesArePresent() {
        let violations: [DTDPolicyViolation] = [
            .entityDeclaration,
            .notationDeclaration,
            .fixedAttributeDefault,
            .quotedAttributeDefault,
            .internalSubsetTooLarge(observedBytes: 10, limit: 1),
        ]
        for violation in violations {
            XCTAssertFalse(violation.description.isEmpty, "\(violation) needs a message")
        }
    }

    // MARK: - Comment and PI boundaries (condition 2)

    /// A `]` or `>` inside a comment ahead of the DOCTYPE is prose, not a
    /// terminator. Getting this wrong would truncate the document.
    func testCommentBeforeDoctypeWithTerminatorLookalikes() {
        let xml = "<?xml version=\"1.0\"?>\n<!-- ]> not a terminator, and ] neither -->\n"
            + "<!DOCTYPE Root [<!ELEMENT Root (A*)>]><Root><A v=\"1\"/><A v=\"2\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk) whole document must survive", file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A processing instruction ahead of the DOCTYPE, including one ending in
    /// `?>` adjacent to a `]`.
    func testProcessingInstructionBeforeDoctype() {
        let xml = "<?xml version=\"1.0\"?><?style ]> ?><?other more?>\n"
            + "<!DOCTYPE Root [<!ELEMENT Root (A*)>]><Root><A v=\"1\"/><A v=\"2\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A comment **inside** the internal subset whose text contains `]>`. This is
    /// the sharpest case: a naive depth counter would close the subset early and
    /// leave the real `]>` inside the document, corrupting it.
    func testCommentInsideInternalSubsetWithTerminatorLookalike() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root ["
            + "<!-- ]> definitely not the end --><!ELEMENT Root (A*)>]>"
            + "<Root><A v=\"1\"/><A v=\"2\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk) subset must close at the real terminator",
                           file: file, line: line)
        }
    }

    /// A processing instruction inside the internal subset, same hazard.
    func testProcessingInstructionInsideInternalSubset() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root ["
            + "<?pi ]> ?><!ELEMENT Root (A*)>]><Root><A v=\"1\"/><A v=\"2\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A parameter-entity reference inside the subset uses `%name;` with no
    /// quotes, and must not confuse the scanner.
    func testParameterEntityReferenceDoesNotEndSubset() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root ["
            + "%common;<!ELEMENT Root (A*)>]><Root><A v=\"1\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            // A parameter-entity reference is not a declaration and supplies no
            // value by itself; the parse may legitimately fail validation, but it
            // must not be reported as a policy violation.
            XCTAssertNil(result.violation, "chunk=\(chunk)", file: file, line: line)
            XCTAssertGreaterThan(result.elidedBytes, 0, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// Whitespace and newlines around the `[` and `]` are legal and must not
    /// shift the terminator.
    func testWhitespaceAroundInternalSubsetDelimiters() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Root \n\t [\n<!ELEMENT Root (A*)\n]\n>"
            + "<Root><A v=\"1\"/><A v=\"2\"/></Root>"
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.elements, 3, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// A `#FIXED` keyword mentioned inside a comment must not be read as a real
    /// declaration — the scanner skips comments.
    func testKeywordInsideCommentIsNotAViolation() {
        let xml = docWithDTD(
            "<!-- <!ENTITY fake \"x\"> and <!ATTLIST A v CDATA #FIXED \"y\"> are just prose -->"
                + "<!ELEMENT Root (A*)><!ELEMENT A EMPTY>"
        )
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk) comment text is not a declaration",
                         file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// `#REQUIRED` on one attribute and a quoted default on a **later** one: the
    /// violation must still be found, proving the scanner reads the whole subset
    /// rather than stopping at the first declaration.
    func testViolationLaterInSubsetIsStillFound() {
        let xml = docWithDTD(
            "<!ELEMENT Root (A*)><!ELEMENT A EMPTY>"
                + "<!ATTLIST A v CDATA #REQUIRED>"
                + "<!ATTLIST A w CDATA #IMPLIED>"
                + "<!ATTLIST A x CDATA \"late default\">"
        )
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertFalse(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertEqual(result.violation, .quotedAttributeDefault, "chunk=\(chunk)", file: file, line: line)
        }
    }

    /// An enumerated default `(a|b)` carries no quote, so it supplies no value
    /// and must be accepted — only quoted literals and `#FIXED` do.
    func testEnumeratedDefaultSuppliesNoValue() {
        let xml = docWithDTD("<!ELEMENT Root (A*)><!ATTLIST A v (yes|no) #IMPLIED>")
        acrossChunks(xml) { result, chunk, file, line in
            XCTAssertTrue(result.parseOK, "chunk=\(chunk)", file: file, line: line)
            XCTAssertNil(result.violation, "chunk=\(chunk) enum tokens are unquoted", file: file, line: line)
            XCTAssertEqual(result.attributes, 2, "chunk=\(chunk)", file: file, line: line)
        }
    }

    // MARK: - Equivalence with the unelided parse

    /// On a value-free DTD the elided parse must agree exactly with parsing the
    /// document directly, which is the losslessness claim made operational.
    ///
    /// The direct comparison is macOS-only, and deliberately so: `XMLParser`
    /// **segfaults** on Linux for a document carrying an `ATTLIST` declaration,
    /// which is the very reason this filter exists. Calling it there would kill
    /// the test process, and taking an `XCTSkip` instead would add a skip reason
    /// the Linux gate would have to allowlist. So the test executes on both
    /// platforms and asserts the elided result on both; only the second
    /// implementation is conditional.
    func testElidedParseMatchesDirectParseOnValueFreeDTD() throws {
        let subset = "<!ELEMENT Root (A*)><!ELEMENT A EMPTY>"
            + "<!ATTLIST A v CDATA #REQUIRED><!ATTLIST A w CDATA #IMPLIED>"
        let xml = docWithDTD(subset)

        // One chunk size is enough here: the boundary behaviour is already swept
        // across every chunk size by the cases above. What this test asserts is
        // the losslessness claim, not the buffering.
        let elided = try parse(xml, chunk: 7)
        XCTAssertTrue(elided.parseOK, "elided parse should succeed")
        XCTAssertNil(elided.violation, "value-free DTD must not violate")
        XCTAssertEqual(elided.elements, 3, "Root + 2 A")
        XCTAssertEqual(elided.attributes, 2, "both v attributes survive elision")

        #if os(macOS)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dtd-equivalence-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try xml.write(to: url, atomically: true, encoding: .utf8))

        let direct = CountingDelegate()
        let directParser = XMLParser(contentsOf: url)
        let unwrappedParser = try XCTUnwrap(directParser, "direct parser should open")
        unwrappedParser.delegate = direct
        unwrappedParser.shouldResolveExternalEntities = false
        XCTAssertTrue(unwrappedParser.parse(), "Apple's parser accepts this DTD")
        XCTAssertEqual(elided.elements, direct.elements, "element count must match")
        XCTAssertEqual(elided.attributes, direct.attributes, "attribute count must match")
        #endif
    }
}
