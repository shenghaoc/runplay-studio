import Foundation
import XCTest

final class NativeEngineTests: XCTestCase {
    func testNativeEngineExecutable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runner = repositoryRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("run-cpp-engine-tests.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", runner.path]
        process.currentDirectoryURL = repositoryRoot

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
        XCTAssertEqual(
            process.terminationReason,
            .exit,
            "Native C++ test runner terminated abnormally:\n\(output)"
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "Native C++ tests failed:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("RunPlayEngineCppTests: all checks passed"),
            "Native C++ runner did not report its success marker:\n\(output)"
        )
    }
}
