import AppKit
import CryptoKit
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
    environment: [String: String] = [:],
    executable: String = "ContextPanelSharedViewRenderer"
) throws -> RendererRun {
    let process = Process()
    process.executableURL = try builtProductsDirectory().appending(path: executable)
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

@Test func appStoreDraftImageBytesMatchTheirRecordedIdentity() throws {
    for folder in ["horizon-draft", "horizon-capture"] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Resources/AppStore/Screenshots/\(folder)")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "manifest.json"))) as? [String: Any])
        let assets = try #require(manifest["assets"] as? [[String: Any]])
        #expect(!assets.isEmpty)
        for asset in assets {
            let file = try #require(asset["file"] as? String)
            let data = try Data(contentsOf: root.appending(path: file))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == asset["sha256"] as? String, "\(file)")
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == asset["width"] as? Int, "\(file)")
            #expect(bitmap.pixelsHigh == asset["height"] as? Int, "\(file)")
        }
    }
}

@Test func appStoreDraftRendererProducesTheRecordedCanvases() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let manifestURL = root.appending(path: "Resources/AppStore/Screenshots/horizon-draft/manifest.json")
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    let base = try #require(manifest["rendererBaseArguments"] as? [String])
    let assets = try #require(manifest["assets"] as? [[String: Any]])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for asset in assets {
        let file = try #require(asset["file"] as? String)
        let output = directory.appending(path: file)
        let scale = try #require(asset["scale"] as? Int)
        let arguments = base + [
            "--presentation", try #require(asset["presentation"] as? String),
            "--family", try #require(asset["family"] as? String),
            "--appearance", try #require(asset["appearance"] as? String),
            "--scale", String(scale), "--output", output.path,
        ]
        let run = try runRenderer(arguments)
        #expect(run.status == 0, "\(file): \(run.output)")
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        let width = try #require(asset["width"] as? Int)
        let height = try #require(asset["height"] as? Int)
        #expect(bitmap.pixelsWide == (asset["rawWidth"] as? Int ?? width))
        #expect(bitmap.pixelsHigh == (asset["rawHeight"] as? Int ?? height))
        #expect(bitmap.pixelsWide <= width)
        #expect(bitmap.pixelsHigh <= height)
    }
}

@Test func rendererDrawsEveryMacCellInTheSharedViewMatrix() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cells = try macOSMatrixCells()
    #expect(Set(cells.map(\.surface)) == ["macos.app", "macos.widget"])

    var images: Set<Data> = []
    for (index, entry) in cells.enumerated() {
        let output = directory.appending(path: "cell-\(index).png")
        let run = try runRenderer(try rendererArguments(cell: entry.cell, output: output))

        #expect(run.status == 0, "\(entry.surface): \(run.output)")
        let png = try Data(contentsOf: output)
        #expect(NSBitmapImageRep(data: png) != nil)
        images.insert(png)
    }
    #expect(images.count == cells.count, "different cells must not render to the same image")
}

@Test func rendererRefusesAPresentationTheMacGalleryDoesNotOffer() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "settings.png")
    let run = try runRenderer(["--fixture", "healthy", "--family", "systemLarge", "--appearance", "light",
                               "--presentation", "settings", "--output", output.path])

    // 3 is the tool's dedicated "no such Mac presentation" status, so a crash or an
    // argument error cannot satisfy this test, and the gallery's fallback is never drawn.
    #expect(run.status == 3, "\(run.output)")
    #expect(!FileManager.default.fileExists(atPath: output.path))
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
        valid + ["--scale", "4"],
        valid + ["--scale", "x"],
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

@Test func renderersPinTimeZoneAndAppStoreCapturePinsFoundationLocale() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // The app overview prints dates and times; the framed widget cell may not.
    let cell = try #require(try macOSMatrixCells().first { $0.surface == "macos.app" }).cell
    let hosts: [[String: String]] = [
        ["TZ": "UTC", "LANG": "en_US.UTF-8"],
        ["TZ": "Asia/Tokyo", "LANG": "ja_JP.UTF-8"],
        ["TZ": "America/Los_Angeles", "LANG": "de_DE.UTF-8"],
    ]

    for executable in ["ContextPanelSharedViewRenderer", "ContextPanelAppStoreCapture"] {
        let presentations = executable == "ContextPanelAppStoreCapture" ? ["overview", "detail"] : ["overview"]
        for presentation in presentations {
            var images: Set<Data> = []
            for (index, host) in hosts.enumerated() {
                let output = directory.appending(path: "\(executable)-\(presentation)-host-\(index).png")
                // The new capture CLI accepts Foundation launch defaults, so its
                // locale is varied for real. The legacy CLI covers timezone only.
                let locales = ["en_US", "ja_JP", "de_DE"]
                let languages = ["(en)", "(ja)", "(de)"]
                let arguments = executable == "ContextPanelAppStoreCapture"
                    ? [presentation, "light", output.path, "-AppleLocale", locales[index], "-AppleLanguages", languages[index]]
                    : try rendererArguments(cell: cell, output: output)
                let run = try runRenderer(arguments, environment: host, executable: executable)
                #expect(run.status == 0, "\(host): \(run.output)")
                images.insert(try Data(contentsOf: output))
            }
            #expect(images.count == 1)
        }
    }
}
