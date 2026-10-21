#if CONTEXT_PANEL_SCREENSHOTS || os(macOS)
import ContextPanelCore
import SwiftUI

extension View {
    func appStoreScreenshotEnvironment() -> some View {
        environment(\.locale, ScreenshotFixture.locale)
            .environment(\.timeZone, ScreenshotFixture.timeZone)
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
