#if os(macOS)
import AppKit
import ContextPanelApp
import ContextPanelCore
import SwiftUI

// Offscreen only. Never displays a window or registers an app/extension bundle.
var arguments = Array(CommandLine.arguments.dropFirst())
// Foundation reads these normal launch-default arguments before main. The fixture
// overrides them; accept them here to exercise real foreign host locales.
for flag in ["-AppleLocale", "-AppleLanguages"] {
    if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
        arguments.removeSubrange(index ... index + 1)
    }
}
guard arguments.count == 3, ["overview", "detail", "overview-window", "detail-window"].contains(arguments[0]),
      ["light", "dark"].contains(arguments[1]), !FileManager.default.fileExists(atPath: arguments[2]) else {
    fputs("usage: ContextPanelAppStoreCapture overview|detail|overview-window|detail-window light|dark NEW.png\n", stderr)
    exit(64)
}
ScreenshotFixture.configureProcess()
let dark = arguments[1] == "dark"
let includesWindow = arguments[0].hasSuffix("-window")
let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
let canvas = NSRect(x: 0, y: 0, width: 1440, height: 900)
let size = includesWindow ? NSWindow.contentRect(forFrameRect: canvas, styleMask: style).size : canvas.size
let content = MacValidationGallery.appStorePresentation(snapshot: ScreenshotFixture.snapshot,
    now: ScreenshotFixture.date, detail: arguments[0].hasPrefix("detail"))
let host = NSHostingView(rootView: content
    .frame(width: size.width, height: size.height)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, dark ? .dark : .light)
    .appStoreScreenshotEnvironment())
host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
host.frame = NSRect(origin: .zero, size: size)
// AppKit-backed List needs a window hierarchy even for an offscreen bitmap.
// This window is never ordered onto a display or registered as an application.
let window = NSWindow(contentRect: host.frame, styleMask: style, backing: .buffered, defer: false)
window.title = "Context Panel"
window.appearance = host.appearance
window.contentView = host
host.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
host.layoutSubtreeIfNeeded()
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2880, pixelsHigh: 1800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(70) }
let renderedView = includesWindow ? (host.superview ?? host) : host
renderedView.layoutSubtreeIfNeeded()
bitmap.size = renderedView.bounds.size
renderedView.cacheDisplay(in: renderedView.bounds, to: bitmap)
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(70) }
try data.write(to: URL(fileURLWithPath: arguments[2]), options: .withoutOverwriting)
print("rendered \(arguments[0]): 2880 x 1800, \(data.count) bytes")
#endif
