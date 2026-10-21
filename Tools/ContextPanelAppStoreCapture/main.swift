#if os(macOS)
import AppKit
import ContextPanelApp
import ContextPanelCore
import SwiftUI

// Offscreen only. Never creates a window or registers an app/extension bundle.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, ["overview", "detail"].contains(arguments[0]),
      ["light", "dark"].contains(arguments[1]), !FileManager.default.fileExists(atPath: arguments[2]) else {
    fputs("usage: ContextPanelAppStoreCapture overview|detail light|dark NEW.png\n", stderr)
    exit(64)
}
ScreenshotFixture.configureProcess()
let dark = arguments[1] == "dark"
let size = CGSize(width: 1440, height: 900)
let content = MacValidationGallery.appStorePresentation(snapshot: ScreenshotFixture.snapshot,
    now: ScreenshotFixture.date, detail: arguments[0] == "detail")
let host = NSHostingView(rootView: content
    .frame(width: size.width, height: size.height)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, dark ? .dark : .light)
    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    .environment(\.timeZone, .gmt))
host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
host.frame = NSRect(origin: .zero, size: size)
// AppKit-backed List needs a window hierarchy even for an offscreen bitmap.
// This window is never ordered onto a display or registered as an application.
let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host
host.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
host.layoutSubtreeIfNeeded()
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2880, pixelsHigh: 1800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(70) }
bitmap.size = size
host.cacheDisplay(in: host.bounds, to: bitmap)
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(70) }
try data.write(to: URL(fileURLWithPath: arguments[2]), options: .withoutOverwriting)
print("rendered \(arguments[0]): 2880 x 1800, \(data.count) bytes")
#endif
