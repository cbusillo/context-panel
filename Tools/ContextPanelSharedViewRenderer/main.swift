import AppKit
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import Foundation
import SwiftUI

// Renders one macOS Validation Gallery cell to a PNG without launching the app.
// Operator and CI tooling only: it links no app or widget bundle, registers
// nothing with LaunchServices or PlugInKit, and reads only synthetic fixtures.
//
//   ContextPanelSharedViewRenderer --fixture healthy --family systemSmall \
//     --appearance light --presentation widget --output cell.png
//
// Exit codes: EX_USAGE for bad arguments, 3 when the cell needs views this tool
// cannot draw, EX_SOFTWARE when rendering fails, EX_CANTCREAT when writing fails.

private let canvas = CGSize(width: 1_024, height: 768)

private let unsupportedPresentationStatus: Int32 = 3

private func fail(_ message: String, status: Int32 = EX_USAGE) -> Never {
    FileHandle.standardError.write(Data("ContextPanelSharedViewRenderer: \(message)\n".utf8))
    exit(status)
}

private func parseArguments(_ arguments: [String]) -> (route: ValidationGalleryRoute, output: URL) {
    let names = ["--fixture", "--family", "--appearance", "--presentation", "--output"]
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let name = arguments[index]
        guard names.contains(name), index + 1 < arguments.count, values[name] == nil else {
            fail("unexpected or repeated argument: \(name)")
        }
        values[name] = arguments[index + 1]
        index += 2
    }
    guard let fixture = values["--fixture"].flatMap(ValidationFixtureID.init(rawValue:)),
          let family = values["--family"].flatMap(ValidationGalleryFamily.init(rawValue:)),
          let appearance = values["--appearance"].flatMap(ValidationGalleryAppearance.init(rawValue:)),
          appearance != .adaptive,
          let presentation = values["--presentation"].flatMap(ValidationGalleryPresentation.init(rawValue:)),
          let output = values["--output"], !output.isEmpty
    else {
        fail("--fixture, --family, --appearance (light|dark), --presentation, and --output are required")
    }
    // Application presentations are drawn by views that live in the Mac app target.
    // Without them the gallery falls back to the widget, which would be the wrong image.
    guard presentation == .widget else {
        fail(
            "only the widget presentation can be rendered headlessly; \(presentation.rawValue) needs the Mac app's views",
            status: unsupportedPresentationStatus
        )
    }
    return (
        ValidationGalleryRoute(
            fixtureID: fixture,
            family: family,
            appearance: appearance,
            presentation: presentation
        ),
        URL(fileURLWithPath: output)
    )
}

@MainActor
private func render(route: ValidationGalleryRoute) -> Data? {
    let isDark = route.appearance == .dark
    let content = ValidationGalleryView(route: route)
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, isDark ? .dark : .light)
        // The gallery prints its fixed presentation time; pin how it is formatted so
        // the image does not depend on the host's region or time zone.
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .gmt)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    hostingView.frame = NSRect(origin: .zero, size: canvas)
    hostingView.layoutSubtreeIfNeeded()
    // One pixel per point regardless of the host display's backing scale.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width),
        pixelsHigh: Int(canvas.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    bitmap.size = canvas
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
}

// The gallery formats its fixed presentation time with the process's current time
// zone and locale, not SwiftUI's environment. Pin both so the PNG is the same on
// every host.
setenv("TZ", "UTC", 1)
tzset()
NSTimeZone.default = TimeZone(identifier: "UTC") ?? .gmt
UserDefaults.standard.setVolatileDomain(
    ["AppleLocale": "en_US_POSIX", "AppleLanguages": ["en-US"]],
    forName: UserDefaults.argumentDomain
)

let (route, output) = parseArguments(Array(CommandLine.arguments.dropFirst()))
guard !FileManager.default.fileExists(atPath: output.path) else {
    fail("refusing to overwrite \(output.path)")
}
guard let png = render(route: route) else {
    fail("the gallery cell could not be rendered", status: EX_SOFTWARE)
}
do {
    try png.write(to: output, options: .withoutOverwriting)
} catch {
    fail("the PNG could not be written", status: EX_CANTCREAT)
}
print("rendered \(route.id) \(Int(canvas.width))x\(Int(canvas.height)) \(png.count) bytes")
