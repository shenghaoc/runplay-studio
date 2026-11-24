import XCTest
@testable import RunPlayStudio

/// `@MainActor` because the test reads `MapReferenceView.routeColorSymbolName`,
/// a static on a SwiftUI `View`, which is main-actor isolated. Swift 6.4 only
/// warns about reading it from an assertion's autoclosure; Swift 6.3.3 rejects
/// it. Marking the suite matches the other main-actor suites and is correct on
/// both.
@MainActor
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

    func testRouteColorSymbolResolvesWithBlankDescription() throws {
        // A missing symbol would fall back to `Image(systemName:)`, which
        // brings back the generated "Paint palette" description.
        let image = try XCTUnwrap(
            DecorativeMenuSymbol.nsImage(systemName: MapReferenceView.routeColorSymbolName)
        )
        XCTAssertEqual(
            image.accessibilityDescription,
            DecorativeMenuSymbol.blankAccessibilityDescription
        )
    }

    func testUnknownSymbolHasNoImage() {
        XCTAssertNil(DecorativeMenuSymbol.nsImage(systemName: "not.a.real.symbol.name"))
    }
}
