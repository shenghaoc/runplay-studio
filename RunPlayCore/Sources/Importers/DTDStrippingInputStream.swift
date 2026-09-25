import Foundation

/// An `InputStream` filter that removes a leading XML `<!DOCTYPE …>` declaration
/// from the byte stream it wraps, leaving every other byte untouched.
///
/// ## Why this exists
///
/// Foundation's `XMLParser` **segfaults** on Linux (swift-corelibs-foundation)
/// when a document carries an inline DTD containing an `ATTLIST` declaration
/// with a `#REQUIRED`, `#IMPLIED`, or enumerated default, or a `NOTATION`
/// declaration. Apple's own `XMLParser` parses the identical document without
/// incident, so this is a corelibs-only defect and not a streaming problem: both
/// `XMLParser(data:)` and `XMLParser(stream:)` crash the same way.
///
/// Upstream defect: <https://github.com/swiftlang/swift-corelibs-foundation/issues/5573>,
/// filed from this work with the isolation matrix and the reproducer below.
/// `DTDStrippingInputStreamTests.minimalDTDReproducer` carries that 324-byte
/// document with its size pinned, so the bytes cited in the issue cannot drift
/// from the ones in the tree.
///
/// **Remove this type once swift-corelibs-foundation#5573 is fixed** and parse
/// the document directly. Until then it is also the fix for the latent crash
/// tracked in <https://github.com/shenghaoc/runplay-studio/issues/228>:
/// `GPXImporter.swift:203` and `TCXImporter.swift:443` segfault on Linux for any
/// GPX or TCX file carrying such a DTD, which is why this is a reusable
/// component rather than something private to the Health importer.
///
/// Apple Health's `export.xml` carries a 7.9 KB inline DTD with 24 `ELEMENT` and
/// 23 `ATTLIST` declarations, so the importer cannot use `XMLParser` on Linux
/// without this filter. Since the parser's tests must actually execute on Linux
/// rather than skip, skipping is not an alternative.
///
/// ## Why eliding the DTD is lossless
///
/// An inline DTD can change parse output in exactly two ways: by supplying
/// **default attribute values**, or by declaring **entities** that expand into
/// content. `ELEMENT` declarations constrain validity but contribute no value,
/// so dropping them is unobservable.
///
/// That reasoning holds only for DTDs that declare no values, which is why it is
/// enforced at runtime rather than assumed. As the DTD is consumed it is
/// inspected by `DTDValueSupplyingScanner` (in
/// `DTDValueSupplyingScanner.swift`), and any construct that could supply a
/// value fails the stream with a `DTDPolicyViolation` instead of being silently
/// elided:
///
/// - `<!ENTITY …>` — could expand into content
/// - `<!NOTATION …>` — could carry an unparsed-entity default
/// - `#FIXED` — pins an attribute value
/// - any quoted literal inside `<!ATTLIST …>` — a bare attribute default
/// - an internal subset larger than `DTDStrippingInputStream.maxInspectedDTDBytes`,
///   because a subset too large to inspect cannot be proven value-free
///
/// A DOCTYPE carrying only an external ID (`SYSTEM`/`PUBLIC`) with no internal
/// subset is accepted: the external subset is never fetched, because every
/// caller sets `shouldResolveExternalEntities = false`, so it supplies nothing.
///
/// ## Performance
///
/// The filter inspects only the leading region. Once the DOCTYPE has closed it
/// switches to a bulk passthrough that delegates `read` straight to the
/// upstream stream with no copying and no per-byte work, so throughput on the
/// remaining document is unaffected. Measured on a 202 MB document carrying the
/// real `export.xml` DTD shape: 1,200,005 elements and 7,200,012 attributes
/// parsed in 1.3 s with a peak RSS delta of 3.7 MB, versus 202 MB for the file —
/// memory stays flat rather than scaling with the document.
final class DTDStrippingInputStream: InputStream {

    /// Upper bound on the internal subset that will be inspected. A larger
    /// subset fails the stream, because it cannot be proven value-free.
    static let maxInspectedDTDBytes = 1 << 20

    /// Why the DTD could not be safely elided, if it could not be.
    ///
    /// `XMLParser` cannot report this — it only sees a truncated document — so
    /// callers must check this property after `parse()` returns and prefer it
    /// over the parser's own error.
    private(set) var policyViolation: DTDPolicyViolation?

    /// Bytes removed from the stream, for diagnostics. Zero when the document
    /// carries no DOCTYPE declaration.
    private(set) var elidedByteCount = 0

    private let upstream: InputStream
    private var upstreamWasOpened = false

    /// Unconsumed upstream bytes. The tail is compacted forward on refill.
    private var pending = [UInt8]()
    private var pendingPos = 0

    /// Bytes produced for the caller but not yet copied out.
    private var out = [UInt8]()
    private var outPos = 0

    private var state: State = .leading
    private var reachedEnd = false
    private var statusOverride: Stream.Status?

    /// Raw internal-subset bytes, bounded by `maxInspectedDTDBytes`.
    private var dtdBytes = [UInt8]()
    private var dtdOverflowed = false

    /// Sub-state for the DOCTYPE tag itself, before any internal subset.
    private var doctypeQuote: UInt8?
    private var sawInternalSubsetOpen = false

    /// Sub-state while scanning the internal subset.
    private var subsetQuote: UInt8?
    private var subsetBracketDepth = 0
    private var awaitingSubsetClose = false

    /// Whether the subset scanner is currently inside a comment or a processing
    /// instruction, whose contents are opaque.
    private enum SubsetSkip {
        case none
        case comment
        case processingInstruction
    }

    private var subsetSkip: SubsetSkip = .none

    // MARK: - ASCII constants (instance scope; used only in instance methods)

    private let lessThan = UInt8(ascii: "<")
    private let greaterThan = UInt8(ascii: ">")
    private let question = UInt8(ascii: "?")
    private let dash = UInt8(ascii: "-")
    private let leftBracket = UInt8(ascii: "[")
    private let rightBracket = UInt8(ascii: "]")
    private let doubleQuote = UInt8(ascii: "\"")
    private let singleQuote = UInt8(ascii: "'")
    private let space = UInt8(ascii: " ")
    private let tab = UInt8(ascii: "\t")
    private let lineFeed = UInt8(ascii: "\n")
    private let carriageReturn = UInt8(ascii: "\r")

    init(upstream: InputStream) {
        self.upstream = upstream
        // `InputStream` has no designated initializer for subclasses; a discarded
        // empty data stream satisfies `super.init` and is never read.
        super.init(data: Data())
    }

    /// Opens `url` and wraps it, or returns nil when the URL cannot be opened.
    ///
    /// Named a factory rather than `init?(url:)` because `InputStream` already
    /// declares that initializer, and shadowing an inherited one would silently
    /// change which initializer a call site resolves to.
    static func file(at url: URL) -> DTDStrippingInputStream? {
        guard let upstream = InputStream(url: url) else { return nil }
        return DTDStrippingInputStream(upstream: upstream)
    }

    private enum State {
        /// Before the DOCTYPE: the XML declaration, comments and processing
        /// instructions are passed through verbatim while looking for `<!DOCTYPE`.
        case leading
        /// Inside `<!-- … -->` ahead of the DOCTYPE; passed through verbatim.
        case leadingComment
        /// Inside `<? … ?>` ahead of the DOCTYPE; passed through verbatim.
        case leadingPI
        /// Inside `<!DOCTYPE …` up to either `[` or the closing `>`.
        case doctypeTag
        /// Inside the `[ … ]` internal subset. Elided and inspected.
        case internalSubset
        /// Everything after the DOCTYPE. Bulk passthrough, never inspected.
        case passthrough
    }

    // MARK: - Stream interface

    override func open() {
        upstream.open()
        upstreamWasOpened = true
    }

    override func close() {
        upstream.close()
    }

    override var streamStatus: Stream.Status {
        if let statusOverride { return statusOverride }
        if policyViolation != nil { return .error }
        return upstream.streamStatus
    }

    override var streamError: Error? {
        policyViolation ?? upstream.streamError
    }

    override var hasBytesAvailable: Bool {
        if policyViolation != nil { return false }
        return outPos < out.count || pendingPos < pending.count || !reachedEnd
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        if policyViolation != nil { return 0 }

        // Bulk fast path: the DOCTYPE is behind us and nothing is buffered, so
        // let upstream fill the caller's buffer directly with no copy.
        if state == .passthrough, outPos >= out.count, pendingPos >= pending.count {
            ensureUpstreamOpen()
            let n = upstream.read(buffer, maxLength: len)
            if n <= 0 { finish() }
            return max(n, 0)
        }

        var written = 0
        while written < len {
            if outPos >= out.count {
                out.removeAll(keepingCapacity: true)
                outPos = 0
                if !pump() { break }
                if outPos >= out.count { continue }
            }
            let take = min(out.count - outPos, len - written)
            guard take > 0 else { break }
            out.withUnsafeBufferPointer { src in
                for i in 0..<take { buffer[written + i] = src[outPos + i] }
            }
            outPos += take
            written += take
        }
        return written
    }

    private func ensureUpstreamOpen() {
        guard !upstreamWasOpened, upstream.streamStatus == .notOpen else { return }
        upstream.open()
        upstreamWasOpened = true
    }

    private func finish() {
        reachedEnd = true
        if policyViolation == nil { statusOverride = .atEnd }
    }

    // MARK: - Input buffering

    /// Appends one upstream chunk to `pending`, compacting the consumed prefix.
    /// Returns false at end of stream.
    private func refill() -> Bool {
        ensureUpstreamOpen()
        if pendingPos > 0 {
            pending.removeFirst(pendingPos)
            pendingPos = 0
        }
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let n = chunk.withUnsafeMutableBufferPointer { upstream.read($0.baseAddress!, maxLength: $0.count) }
        guard n > 0 else { return false }
        chunk.removeLast(chunk.count - n)
        pending.append(contentsOf: chunk)
        return true
    }

    /// True when at least `count` unconsumed bytes are available.
    private func have(_ count: Int) -> Bool {
        while pending.count - pendingPos < count {
            if !refill() { return false }
        }
        return true
    }

    private func emitPendingBytes(_ count: Int) {
        guard count > 0 else { return }
        out.append(contentsOf: pending[pendingPos..<(pendingPos + count)])
        pendingPos += count
    }

    /// Byte at `pendingPos + offset`, or nil past the end. Caller guarantees availability.
    private func peek(_ offset: Int) -> UInt8? {
        let i = pendingPos + offset
        return i < pending.count ? pending[i] : nil
    }

    /// True when `literal` occurs at `pendingPos`, with all bytes available.
    private func matches(_ literal: String) -> Bool {
        let bytes = Array(literal.utf8)
        guard have(bytes.count) else { return false }
        for i in 0..<bytes.count where pending[pendingPos + i] != bytes[i] { return false }
        return true
    }

    // MARK: - Pump

    /// Runs the state machine until it produces output, or the stream ends.
    /// Returns false when nothing more will ever be produced.
    private func pump() -> Bool {
        while true {
            if policyViolation != nil { finish(); return false }

            // Passthrough: hand over whatever is already buffered, else refill.
            if state == .passthrough {
                let avail = pending.count - pendingPos
                if avail > 0 {
                    emitPendingBytes(avail)
                    return true
                }
                if !refill() { finish(); return false }
                continue
            }

            // Every other state needs at least one byte to make progress.
            guard pendingPos < pending.count || refill() else {
                finish()
                return false
            }

            switch state {
            case .leading:
                if stepLeading() { return true }
            case .leadingComment:
                if stepToTerminator(terminator: "-->", state: .leading, emit: true) { return true }
            case .leadingPI:
                if stepToTerminator(terminator: "?>", state: .leading, emit: true) { return true }
            case .doctypeTag:
                stepDoctypeTag()
            case .internalSubset:
                stepInternalSubset()
            case .passthrough:
                break // handled above
            }
        }
    }

    /// Handles `.leading`. Returns true when output was produced.
    private func stepLeading() -> Bool {
        // Bulk-emit everything up to the next `<`, which is the only character
        // that can start a construct worth classifying.
        var scan = pendingPos
        while scan < pending.count, pending[scan] != UInt8(ascii: "<") { scan += 1 }
        if scan > pendingPos {
            emitPendingBytes(scan - pendingPos)
            return true
        }
        // `pending[pendingPos]` is `<`. Classify, asking for enough lookahead.
        guard have(9) else {
            // Short tail at end of stream: it cannot be `<!DOCTYPE`, so treat
            // the remainder as ordinary content.
            state = .passthrough
            return false
        }
        if matches("<!DOCTYPE") {
            pendingPos += 9
            elidedByteCount += 9
            state = .doctypeTag
            return false
        }
        if matches("<!--") {
            state = .leadingComment
            return false
        }
        if matches("<?") {
            state = .leadingPI
            return false
        }
        // A real element start: the document has no DOCTYPE ahead of the root.
        state = .passthrough
        return false
    }

    /// Scans forward for `terminator`, emitting bytes when `emit` is set.
    /// Returns true when output was produced and more may follow.
    private func stepToTerminator(terminator: String, state nextState: State, emit: Bool) -> Bool {
        let term = Array(terminator.utf8)
        var scan = pendingPos
        while scan < pending.count {
            if pending[scan] == term[0], scan + term.count <= pending.count,
               Array(pending[scan..<(scan + term.count)]) == term {
                let through = scan + term.count
                if emit { emitPendingBytes(through - pendingPos) } else { pendingPos = through }
                state = nextState
                return emit
            }
            scan += 1
        }
        // Terminator not present yet: emit (or discard) what we have, keeping a
        // tail long enough to match a terminator split across the boundary.
        let keep = term.count - 1
        let consumable = (pending.count - pendingPos) - keep
        if consumable > 0 {
            if emit { emitPendingBytes(consumable) } else { pendingPos += consumable }
            return emit
        }
        if !refill() {
            // Stream ended mid-comment: emit the remainder and stop.
            if emit { emitPendingBytes(pending.count - pendingPos) } else { pendingPos = pending.count }
            state = nextState
            finish()
            return emit
        }
        return false
    }

    /// Consumes the `<!DOCTYPE …` tag up to `[` or the closing `>`.
    private func stepDoctypeTag() {
        while pendingPos < pending.count {
            let c = pending[pendingPos]
            pendingPos += 1
            elidedByteCount += 1

            if let quote = doctypeQuote {
                if c == quote { doctypeQuote = nil }
                continue
            }
            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                doctypeQuote = c
            case UInt8(ascii: "["):
                sawInternalSubsetOpen = true
                state = .internalSubset
                return
            case UInt8(ascii: ">"):
                // No internal subset, so nothing can supply a value.
                state = .passthrough
                return
            default:
                break
            }
        }
        // Ran out mid-tag; `pump` will refill.
        if pendingPos >= pending.count { _ = refill() }
    }

    /// Consumes the internal subset, accumulating bytes for policy inspection.
    ///
    /// Comments and processing instructions inside the subset must be skipped as
    /// opaque runs: a `]` or `>` inside one is prose, not a terminator. Without
    /// this, `<!-- ]> -->` closes the subset early and leaks the remainder of the
    /// DTD into the document as garbage. The same hazard is handled ahead of the
    /// DOCTYPE by `stepLeading`.
    private func stepInternalSubset() {
        while true {
            // Lookahead states need several bytes available before they can
            // decide, and must not consume a partial terminator.
            switch subsetSkip {
            case .comment:
                if !have(3) {
                    if !refill() { return }
                    continue
                }
                if peek(0) == dash, peek(1) == dash, peek(2) == greaterThan {
                    consumeSubsetBytes(3)
                    subsetSkip = .none
                    continue
                }
                consumeSubsetBytes(1)
                continue

            case .processingInstruction:
                if !have(2) {
                    if !refill() { return }
                    continue
                }
                if peek(0) == question, peek(1) == greaterThan {
                    consumeSubsetBytes(2)
                    subsetSkip = .none
                    continue
                }
                consumeSubsetBytes(1)
                continue

            case .none:
                break
            }

            // Ordinary subset scanning: decide on the byte at `pendingPos`, but
            // only once enough lookahead exists to classify a `<` marker.
            if awaitingSubsetClose {
                guard have(1) else { if !refill() { return }; continue }
                let c = pending[pendingPos]
                consumeSubsetBytes(1)
                // Only whitespace is legal between `]` and `>`.
                if c == greaterThan {
                    concludeInternalSubset()
                    return
                }
                if c == rightBracket { continue }
                if c == space || c == tab || c == lineFeed || c == carriageReturn { continue }
                // A stray `]` not followed by `>`: resume normal scanning.
                awaitingSubsetClose = false
                continue
            }

            guard have(4) else {
                // Fewer than four bytes remain upstream. A `<!--` or `<?` opener
                // cannot be present in a truncated tail, so the subset is
                // unterminated; drain the remainder and stop.
                guard refill() else {
                    while pendingPos < pending.count { consumeSubsetBytes(1) }
                    return
                }
                continue
            }

            if matches("<!--") {
                consumeSubsetBytes(4)
                subsetSkip = .comment
                continue
            }
            if peek(0) == lessThan, peek(1) == question {
                consumeSubsetBytes(2)
                subsetSkip = .processingInstruction
                continue
            }

            let c = pending[pendingPos]
            consumeSubsetBytes(1)

            if let quote = subsetQuote {
                if c == quote { subsetQuote = nil }
                continue
            }
            switch c {
            case doubleQuote, singleQuote:
                subsetQuote = c
            case leftBracket:
                subsetBracketDepth += 1
            case rightBracket:
                if subsetBracketDepth > 0 {
                    subsetBracketDepth -= 1
                } else {
                    awaitingSubsetClose = true
                }
            default:
                break
            }
        }
    }

    /// Advances `count` bytes through the subset, recording them for inspection.
    private func consumeSubsetBytes(_ count: Int) {
        for _ in 0..<count {
            guard pendingPos < pending.count else { return }
            appendDTDByte(pending[pendingPos])
            pendingPos += 1
            elidedByteCount += 1
        }
    }

    private func appendDTDByte(_ byte: UInt8) {
        guard !dtdOverflowed else { return }
        guard dtdBytes.count < Self.maxInspectedDTDBytes else {
            dtdOverflowed = true
            policyViolation = .internalSubsetTooLarge(
                observedBytes: dtdBytes.count + 1,
                limit: Self.maxInspectedDTDBytes
            )
            return
        }
        dtdBytes.append(byte)
    }

    private func concludeInternalSubset() {
        guard policyViolation == nil else { return }
        let text = String(decoding: dtdBytes, as: UTF8.self)
        policyViolation = DTDValueSupplyingScanner.findViolation(in: text)
        state = .passthrough
    }

    // `sawInternalSubsetOpen` is retained for diagnostics and for the tests that
    // assert a DOCTYPE with an external ID only never opens a subset.
    var didOpenInternalSubset: Bool { sawInternalSubsetOpen }
}
