import AppKit
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
        let arguments = CommandLine.arguments
        let dark = arguments.contains("dark")
        ScreenshotFixture.configureProcess()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let frame = NSRect(x: 40, y: 40, width: 1280, height: 800)
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
