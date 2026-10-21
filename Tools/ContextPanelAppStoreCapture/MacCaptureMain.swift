import AppKit
import CoreGraphics
import ContextPanelApp
import ContextPanelCore
import SwiftUI

@main
@MainActor
enum MacCaptureApplication {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            fputs("Mac fixture UI capture runs only on an isolated GitHub-hosted runner.\n", stderr)
            exit(64)
        }
        let display = CGMainDisplayID()
        let modes = (CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]) ?? []
        guard let mode = modes.filter({ $0.width >= 1440 && $0.height >= 900 })
            .min(by: { $0.width * $0.height < $1.width * $1.height }) else {
            print("Hosted display has no mode large enough for native capture: \(modes.map { "\($0.width)x\($0.height)" })")
            exit(65)
        }
        let status = CGDisplaySetDisplayMode(display, mode, nil)
        guard status == .success else {
            print("Hosted display mode change failed: \(status.rawValue)")
            exit(65)
        }
        let arguments = CommandLine.arguments
        let dark = arguments.contains("dark")
        ScreenshotFixture.configureProcess()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.presentationOptions = [.hideDock, .hideMenuBar]
        if arguments.contains("widgets") {
            app.activate(ignoringOtherApps: true)
            app.run()
            return
        }
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let frame = NSRect(x: 40, y: 40, width: 1280, height: 800)
        guard NSScreen.screens.contains(where: { $0.frame.contains(frame) }) else {
            print("Hosted screen cannot contain the complete fixture window: \(NSScreen.screens.map(\.frame))")
            exit(65)
        }
        let size = NSWindow.contentRect(forFrameRect: frame, styleMask: style).size
        let content = MacValidationGallery.appStorePresentation(snapshot: ScreenshotFixture.snapshot,
            now: ScreenshotFixture.date, detail: arguments.contains("detail"))
        let host = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .appStoreScreenshotEnvironment())
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: style, backing: .buffered, defer: false)
        window.title = "Context Panel"
        window.isRestorable = false
        window.appearance = host.appearance
        window.contentView = host
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
