#if DEBUG
import XCTest
@testable import RunPlayStudio

final class DemoAssetCommandLineTests: XCTestCase {
    private let executable = "/build/RunPlayStudio"

    func testOnlyTheFlagRequestsTheHeadlessMode() {
        XCTAssertFalse(DemoAssetCommandLine.isRequested(by: [executable]))
        XCTAssertFalse(
            DemoAssetCommandLine.isRequested(by: [executable, "-NSDocumentRevisionsDebugMode", "YES"])
        )
        // The executable path itself never counts.
        XCTAssertFalse(DemoAssetCommandLine.isRequested(by: ["--demo-assets"]))
        XCTAssertTrue(DemoAssetCommandLine.isRequested(by: [executable, "--demo-assets", "render"]))
    }

    func testRenderDefaultsToEveryAsset() throws {
        XCTAssertEqual(
            try DemoAssetCommandLine.parse([executable, "--demo-assets", "render", "--output-dir", "/tmp/out"]),
            .render(outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true), selection: .all)
        )
    }

    func testUserDefaultsPairsAreSkippedWhereverTheyAppear() throws {
        let invocation = try DemoAssetCommandLine.parse([
            executable,
            "-AppleLocale", "en_US",
            "-AppleLanguages", "(en-US)",
            "--demo-assets", "render",
            "--only", "summary",
            "-AppleInterfaceStyle", "Dark",
            "--output-dir", "/tmp/out",
        ])
        XCTAssertEqual(
            invocation,
            .render(outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true), selection: .summary)
        )
    }

    func testCompareTakesAnOptionalDiffOutput() throws {
        XCTAssertEqual(
            try DemoAssetCommandLine.parse([
                executable, "--demo-assets", "compare", "--reference", "/a.png", "--candidate", "/b.png",
            ]),
            .compare(
                reference: URL(fileURLWithPath: "/a.png"),
                candidate: URL(fileURLWithPath: "/b.png"),
                diffOutput: nil
            )
        )
        XCTAssertEqual(
            try DemoAssetCommandLine.parse([
                executable, "--demo-assets", "compare",
                "--diff-output", "/d.png", "--candidate", "/b.png", "--reference", "/a.png",
            ]),
            .compare(
                reference: URL(fileURLWithPath: "/a.png"),
                candidate: URL(fileURLWithPath: "/b.png"),
                diffOutput: URL(fileURLWithPath: "/d.png")
            )
        )
    }

    func testMalformedInvocationsAreRejected() {
        let malformed: [[String]] = [
            [executable, "render", "--demo-assets"],
            [executable, "--demo-assets"],
            [executable, "--demo-assets", "publish"],
            [executable, "--demo-assets", "render"],
            [executable, "--demo-assets", "render", "--output-dir"],
            [executable, "--demo-assets", "render", "--output-dir", "--only", "summary"],
            [executable, "--demo-assets", "render", "--output-dir", "/a", "--output-dir", "/b"],
            [executable, "--demo-assets", "render", "--output-dir", "/a", "--only", "posters"],
            [executable, "--demo-assets", "render", "--output-dir", "/a", "--reference", "/r.png"],
            [executable, "--demo-assets", "render", "--output-dir", "/a", "stray"],
            [executable, "--demo-assets", "compare", "--reference", "/a.png"],
        ]
        for arguments in malformed {
            XCTAssertThrowsError(
                try DemoAssetCommandLine.parse(arguments),
                arguments.joined(separator: " ")
            )
        }
    }
}
#endif
