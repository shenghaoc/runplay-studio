import XCTest
@testable import RunPlayStudio

final class DecorativeMenuSymbolTests: XCTestCase {

    func testSymbolKeepsBlankDescriptionInsteadOfSynthesisedName() throws {
        let image = try XCTUnwrap(
            DecorativeMenuSymbol.nsImage(
                systemName: "point.topleft.down.curvedto.point.bottomright.up"
            )
        )
        // AppKit treats an empty description as missing and synthesises one
        // from the symbol name; the blank must survive and speak nothing.
        XCTAssertEqual(image.accessibilityDescription, " ")
        XCTAssertTrue(
            image.accessibilityDescription?
                .trimmingCharacters(in: .whitespaces).isEmpty ?? false
        )
    }

    func testUnknownSymbolHasNoImage() {
        XCTAssertNil(DecorativeMenuSymbol.nsImage(systemName: "not.a.real.symbol.name"))
    }
}
