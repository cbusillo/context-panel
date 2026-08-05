import SwiftUI
import WidgetKit

struct WatchValidationGalleryView: View {
    var body: some View {
        WatchValidationSampleContainer {
            List {
                Section("Watch app") {
                    NavigationLink {
                        WatchAppValidationGalleryView()
                    } label: {
                        Label("App states", systemImage: "applewatch")
                    }
                }

                Section("Complications") {
                    ForEach(ContextPanelWatchComplicationFamily.allCases) { family in
                        NavigationLink {
                            WatchComplicationValidationGalleryView(family: family)
                        } label: {
                            Label(family.displayName, systemImage: family.symbolName)
                        }
                    }
                }

                Section {
                    Text("Shared-view proof only. Placed complications still require the installed-build restart and glance check.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Gallery")
    }
}

private struct WatchAppValidationGalleryView: View {
    @State private var state = WatchValidationAppState.healthy
    private let adapter = WatchValidationFixtureAdapter()

    private var context: WatchValidationFixtureContext {
        adapter.appContext(state: state)
    }

    var body: some View {
        WatchValidationSampleContainer {
            List {
                Section("Sample state") {
                    Picker("State", selection: $state) {
                        ForEach(WatchValidationAppState.allCases) { state in
                            Text(state.displayName).tag(state)
                        }
                    }
                }

                WatchUsageContent(
                    result: context.result,
                    snapshot: context.snapshot,
                    displayPreferences: context.displayPreferences,
                    syncErrorMessage: context.snapshot.syncErrorMessage,
                    presentationDate: context.presentationDate
                )
            }
        }
        .navigationTitle("App states")
    }
}

private struct WatchComplicationValidationGalleryView: View {
    let family: ContextPanelWatchComplicationFamily

    @State private var state = WatchValidationComplicationState.available
    private let adapter = WatchValidationFixtureAdapter()

    private var context: WatchValidationFixtureContext {
        adapter.complicationContext(state: state)
    }

    private var entry: ContextPanelWatchWidgetEntry {
        ContextPanelWatchWidgetEntry(
            date: context.presentationDate,
            snapshot: context.snapshot,
            displayPreferences: context.displayPreferences
        )
    }

    var body: some View {
        WatchValidationSampleContainer {
            List {
                Section("Sample state") {
                    Picker("State", selection: $state) {
                        ForEach(WatchValidationComplicationState.allCases) { state in
                            Text(state.displayName).tag(state)
                        }
                    }
                }

                Section(family.displayName) {
                    GeometryReader { proxy in
                        ContextPanelWatchWidgetView(
                            entry: entry,
                            family: family.widgetFamily,
                            presentationDate: context.presentationDate
                        )
                        .frame(
                            width: family.previewWidth(availableWidth: proxy.size.width),
                            height: family.previewHeight
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                    }
                    .frame(height: family.previewHeight + 16)
                }

                Section {
                    Text(family.proofCopy)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(family.displayName)
    }
}

private struct WatchValidationSampleContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "testtube.2")
                            .accessibilityHidden(true)
                        Text("SAMPLE DATA")
                            .tracking(0.4)
                        Spacer(minLength: 2)
                        Text("READ ONLY")
                    }

                    Label("SAMPLE · READ ONLY", systemImage: "testtube.2")
                }
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample data. Read only shared-view proof.")

            content
        }
    }
}

private extension ContextPanelWatchComplicationFamily {
    var displayName: String {
        switch self {
        case .circular: "Circular"
        case .rectangular: "Rectangular"
        case .inline: "Inline"
        case .corner: "Corner"
        }
    }

    var symbolName: String {
        switch self {
        case .circular: "circle"
        case .rectangular: "rectangle"
        case .inline: "text.line.first.and.arrowtriangle.forward"
        case .corner: "circle.bottomrighthalf.filled"
        }
    }

    var previewHeight: CGFloat {
        switch self {
        case .circular, .corner: 50
        case .rectangular: 42
        case .inline: 24
        }
    }

    func previewWidth(availableWidth: CGFloat) -> CGFloat {
        switch self {
        case .circular, .corner:
            min(50, availableWidth)
        case .rectangular:
            min(156, availableWidth)
        case .inline:
            availableWidth
        }
    }

    var proofCopy: String {
        switch self {
        case .corner:
            "Reference-size production value. WidgetKit supplies the corner gauge, label, and exact canvas only on a placed face; verify those after the required restart."
        case .circular, .rectangular, .inline:
            "Reference-size production view with sample data. The face host sets the exact canvas and margins; verify placement after the required restart."
        }
    }
}
