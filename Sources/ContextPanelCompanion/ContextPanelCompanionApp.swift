import ContextPanelCore
import ContextPanelCompanionSupport
import ContextPanelWidgetUI
import SwiftUI
import UIKit
import WidgetKit

@main
struct ContextPanelCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionRootView()
        }
    }
}

@MainActor
private struct CompanionRootView: View {
    @State private var model = CompanionSyncModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ContextPanelWidgetContentView(
                        family: .systemLarge,
                        snapshot: model.snapshot,
                        displayPreferences: model.displayPreferences,
                        links: CompanionDeepLinks.links
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .background(CPWTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    CompanionSyncStatusView(result: model.result)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Context Panel")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task {
                model.reload()
            }
        }
    }
}

@MainActor
@Observable
private final class CompanionSyncModel {
    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private(set) var displayPreferences = WidgetDisplayPreferences.defaultPreferences

    func reload(now: Date = Date()) {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                CompanionSyncLoader.load(now: now)
            }.value
            result = loaded
            snapshot = WidgetSnapshot.fromCompanionSync(loaded, now: now)
            displayPreferences = loaded.document?.widgetDisplayPreferences ?? .defaultPreferences
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

private struct CompanionSyncStatusView: View {
    let result: CompanionSyncLoadResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(statusDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let generatedAt = result.document?.snapshot.generatedAt {
                Text("Last synced " + generatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var statusTitle: String {
        switch result.status {
        case .healthy:
            "Synced"
        case .close:
            "Close to limit"
        case .limited:
            "Limited"
        case .stale:
            "Sync is stale"
        case .failure:
            "Sync failed"
        case .loading:
            "Loading"
        case .unknown:
            "Waiting for Mac sync"
        }
    }

    private var statusDetail: String {
        if let error = result.errorMessage {
            return error
        }
        switch result.status {
        case .stale:
            return "Open Context Panel on your Mac to publish a fresh snapshot."
        case .unknown:
            return "Open Context Panel on your Mac to publish usage lanes through iCloud."
        case .failure:
            return "The companion could not read the synced snapshot."
        case .close, .limited:
            return "Latest Mac sync is current. Check the highlighted lane before starting heavier work."
        default:
            return "Latest Mac sync is current."
        }
    }

    private var statusSymbol: String {
        switch result.status {
        case .healthy:
            "checkmark.icloud"
        case .close:
            "gauge.with.dots.needle.67percent"
        case .limited:
            "exclamationmark.octagon"
        case .stale:
            "clock.badge.exclamationmark"
        case .failure:
            "icloud.slash"
        case .loading:
            "arrow.clockwise.icloud"
        case .unknown:
            "icloud.and.arrow.down"
        }
    }
}
