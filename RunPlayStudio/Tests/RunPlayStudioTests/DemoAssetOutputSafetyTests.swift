#if DEBUG
import Foundation
import XCTest

final class DemoAssetOutputSafetyTests: XCTestCase {
    func testBuildRootIsRefusedEvenWhenItHasTheMarker() throws {
        try withFakeRepository { repo, build in
            let marker = build.appendingPathComponent(".runplay-demo-assets")
            let sentinel = build.appendingPathComponent("demo-keep.png")
            try Data().write(to: marker)
            try Data("untouched".utf8).write(to: sentinel)
            let result = try invokeScript(repo: repo, output: build)
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.log.contains("unsafe --output-dir"), result.log)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        }
    }

    func testSymlinkedAncestorCannotEscapeBuildWhenLeafDoesNotExist() throws {
        try withFakeRepository { repo, build in
            let outside = repo.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let link = build.appendingPathComponent("escape", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let result = try invokeScript(repo: repo, output: link.appendingPathComponent("new", isDirectory: true))
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.log.contains("unsafe --output-dir"), result.log)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        }
    }

    private func withFakeRepository(_ test: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let build = root.appendingPathComponent(".build", isDirectory: true)
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: build, withIntermediateDirectories: false)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try fm.copyItem(at: repository.appendingPathComponent("scripts/generate-demo-assets.sh"),
                        to: scripts.appendingPathComponent("generate-demo-assets.sh"))
        try test(root, build)
    }

    private func invokeScript(repo: URL, output: URL) throws -> (status: Int32, log: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["./scripts/generate-demo-assets.sh", "--skip-build", "--output-dir", output.path]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, log)
    }
}
#endif
