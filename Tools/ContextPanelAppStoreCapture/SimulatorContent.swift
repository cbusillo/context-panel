#if CONTEXT_PANEL_SCREENSHOTS || os(macOS)
import ContextPanelCore
import SwiftUI
import OSLog

extension View {
    func appStoreScreenshotEnvironment() -> some View {
        environment(\.locale, ScreenshotFixture.locale)
            .environment(\.timeZone, ScreenshotFixture.timeZone)
            .modifier(ScreenshotReadiness())
    }
}

private struct ScreenshotReadiness: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.task(id: phase) {
            guard phase == .active,
                  let index = CommandLine.arguments.firstIndex(of: "--screenshot-token"),
                  CommandLine.arguments.indices.contains(index + 1) else { return }
            // Let the active scene finish its first layout before publishing readiness.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let token = CommandLine.arguments[index + 1]
            Logger(subsystem: "com.shinycomputers.contextpanel.screenshots", category: "readiness")
                .notice("active fixture scene: \(token, privacy: .public)")
        }
    }
}

#if os(watchOS)
struct ScreenshotWatchRoot: View {
    var body: some View {
        ScrollViewReader { scroll in
            WatchRootContent(isLoading: false, onRefresh: {}) {
                WatchUsageContent(result: ScreenshotFixture.result, snapshot: ScreenshotFixture.snapshot,
                    displayPreferences: .defaultPreferences, syncErrorMessage: nil,
                    presentationDate: ScreenshotFixture.date)
            }
            .onAppear {
                if CommandLine.arguments.contains("--screenshot-accounts"),
                   let account = ScreenshotFixture.snapshot.accountOverview(now: ScreenshotFixture.date).accounts.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        scroll.scrollTo(account.id, anchor: .top)
                    }
                }
            }
        }
    }
}
#elseif os(tvOS)
import ContextPanelTVSupport
struct ScreenshotTVRoot: View {
    @State private var mode = TVPresentationMode.fullDetail.rawValue
    var body: some View {
        NavigationStack {
            TVAccountOverviewContent(overview: ScreenshotFixture.snapshot.accountOverview(now: ScreenshotFixture.date),
                now: ScreenshotFixture.date, presentationModeRawValue: $mode, isRefreshing: false,
                notice: nil, onRefresh: {}, openAccount: { _ in }, openDeadlines: {}, openDetails: {}, openAbout: {})
        }
        .preferredColorScheme(.dark)
    }
}
#endif
#endif
