import AppKit
import Foundation
import Testing

/// Runs the built `ContextPanelSharedViewRenderer` tool, which renders macOS
/// Validation Gallery cells without launching the app or registering any bundle.
private struct RendererRun {
    let status: Int32
    let output: String
}

private final class TestBundleToken {}

private func builtProductsDirectory() throws -> URL {
    var url = Bundle(for: TestBundleToken.self).bundleURL
    while url.pathExtension != "xctest", url.path != "/" {
        url.deleteLastPathComponent()
    }
    try #require(url.pathExtension == "xctest")
    return url.deletingLastPathComponent()
}

private func runRenderer(
    _ arguments: [String],
    environment: [String: String] = [:]
) throws -> RendererRun {
    let process = Process()
    process.executableURL = try builtProductsDirectory().appending(path: "ContextPanelSharedViewRenderer")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RendererRun(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

private func macOSMatrixCells() throws -> [(surface: String, cell: [String: String])] {
    let matrixURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Config/ContextPanelSharedViewMatrix.json")
    let matrix = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: matrixURL)) as? [String: Any])
    let surfaces = try #require(matrix["surfaces"] as? [[String: Any]])
    return try surfaces
        .filter { ($0["id"] as? String)?.hasPrefix("macos.") == true }
        .flatMap { surface in
            let surfaceID = try #require(surface["id"] as? String)
            return try #require(surface["cells"] as? [[String: String]]).map { (surfaceID, $0) }
        }
}

private func rendererArguments(cell: [String: String], output: URL) throws -> [String] {
    [
        "--fixture", try #require(cell["fixtureID"]),
        "--family", try #require(cell["family"]),
        "--appearance", try #require(cell["appearance"]),
        "--presentation", try #require(cell["presentation"]),
        "--output", output.path,
    ]
}

@Test func rendererDrawsEveryMacWidgetCellInTheSharedViewMatrix() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let widgetCells = try macOSMatrixCells().filter { $0.cell["presentation"] == "widget" }
    #expect(!widgetCells.isEmpty)

    var images: Set<Data> = []
    for (index, entry) in widgetCells.enumerated() {
        let output = directory.appending(path: "cell-\(index).png")
        let run = try runRenderer(try rendererArguments(cell: entry.cell, output: output))

        #expect(run.status == 0, "\(entry.surface): \(run.output)")
        let png = try Data(contentsOf: output)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 1_024)
        #expect(bitmap.pixelsHigh == 768)
        images.insert(png)
    }
    #expect(images.count == widgetCells.count, "different cells must not render to the same image")
}

@Test func rendererRefusesApplicationPresentationsInsteadOfFallingBackToTheWidget() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let applicationCells = try macOSMatrixCells().filter { $0.cell["presentation"] != "widget" }

    for (index, entry) in applicationCells.enumerated() {
        let output = directory.appending(path: "app-\(index).png")
        let run = try runRenderer(try rendererArguments(cell: entry.cell, output: output))

        // 3 is the tool's dedicated "needs the Mac app's views" status, so a crash or an
        // argument error cannot satisfy this test.
        #expect(run.status == 3, "\(entry.surface): \(run.output)")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@Test func rendererFailsClosedOnBadArgumentsAndNeverOverwrites() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "cell.png")
    let valid = ["--fixture", "healthy", "--family", "systemSmall", "--appearance", "light",
                 "--presentation", "widget", "--output", output.path]

    let invalid: [[String]] = [
        [],
        Array(valid.dropLast(2)),
        valid.map { $0 == "healthy" ? "no-such-fixture" : $0 },
        valid.map { $0 == "light" ? "adaptive" : $0 },
        valid + ["--fixture", "stale"],
        valid + ["--unlock"],
    ]
    for arguments in invalid {
        #expect(try runRenderer(arguments).status != 0, "\(arguments)")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    #expect(try runRenderer(valid).status == 0)
    let first = try Data(contentsOf: output)
    #expect(try runRenderer(valid).status != 0)
    #expect(try Data(contentsOf: output) == first)
}

@Test func rendererOutputDoesNotDependOnTheHostTimeZoneOrLocale() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cell = try #require(try macOSMatrixCells().first { $0.cell["presentation"] == "widget" }).cell
    let hosts: [[String: String]] = [
        ["TZ": "UTC", "LANG": "en_US.UTF-8"],
        ["TZ": "Asia/Tokyo", "LANG": "ja_JP.UTF-8"],
        ["TZ": "America/Los_Angeles", "LANG": "de_DE.UTF-8"],
    ]

    var images: Set<Data> = []
    for (index, host) in hosts.enumerated() {
        let output = directory.appending(path: "host-\(index).png")
        let run = try runRenderer(try rendererArguments(cell: cell, output: output), environment: host)
        #expect(run.status == 0, "\(host): \(run.output)")
        images.insert(try Data(contentsOf: output))
    }
    #expect(images.count == 1)
}
