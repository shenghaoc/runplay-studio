import XCTest
@testable import RunPlayCore

final class RunPlayEngineBridgeTests: XCTestCase {
    func testEngineInfoReportsABIVersionOne() {
        let info = RunPlayEngineBridge.engineInfo()
        XCTAssertEqual(info.abiVersion, 1)
    }

    func testEngineInfoPreservesCxx23Identifier() {
        let info = RunPlayEngineBridge.engineInfo()
        XCTAssertEqual(info.languageStandard, "C++23")
    }

    func testRepeatedCallsProduceEqualSwiftValues() {
        let first = RunPlayEngineBridge.engineInfo()
        let second = RunPlayEngineBridge.engineInfo()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.abiVersion, second.abiVersion)
        XCTAssertEqual(first.languageStandard, second.languageStandard)
    }

    func testReturnedValueIsPureSwiftEngineInfo() {
        let info = RunPlayEngineBridge.engineInfo()
        // Type identity: adapter returns the internal Swift value type only.
        // Imported C++ types must not appear in the public shape of this API.
        XCTAssertTrue(type(of: info) == RunPlayEngineInfo.self)
        // Field types are ordinary Swift values (not C++ imported types).
        XCTAssertTrue(type(of: info.abiVersion) == UInt32.self)
        XCTAssertTrue(type(of: info.languageStandard) == String.self)
        // Round-trip equality through the pure-Swift value type.
        let copy = RunPlayEngineInfo(
            abiVersion: info.abiVersion,
            languageStandard: info.languageStandard
        )
        XCTAssertEqual(info, copy)
    }
}
