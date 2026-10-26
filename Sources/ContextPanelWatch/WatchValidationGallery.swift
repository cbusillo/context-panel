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

struct WatchAppValidationGalleryView: View {
    @State private var selectedState = WatchValidationAppState.healthy
    private let adapter = WatchValidationFixtureAdapter()

    private var context: WatchValidationFixtureContext {
        adapter.appContext(state: selectedState)
    }

    var body: some View {
        WatchValidationSampleContainer {
            List {
                Section("Sample state") {
                    Picker("State", selection: $selectedState) {
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

struct WatchComplicationValidationGalleryView: View {
    let state: WatchValidationComplicationState?
    let family: ContextPanelWatchComplicationFamily

    @State private var selectedState = WatchValidationComplicationState.available
    private let adapter = WatchValidationFixtureAdapter()

    init(
        state: WatchValidationComplicationState? = nil,
        family: ContextPanelWatchComplicationFamily
    ) {
        self.state = state
        self.family = family
    }

    private var context: WatchValidationFixtureContext {
        adapter.complicationContext(state: state ?? selectedState)
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
                if state == nil {
                    Section("Sample state") {
                        Picker("State", selection: $selectedState) {
                            ForEach(WatchValidationComplicationState.allCases) { state in
                                Text(state.displayName).tag(state)
                            }
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
        .navigationTitle(state == nil ? family.displayName : "Complication")
        .task {
            // A launch for one sample also writes the framed cell for the shared-view capture.
            if state != nil {
                writeFramedCell()
            }
        }
    }

    /// Draws the complication in the frame and mask a face gives it and writes the PNG
    /// to `tmp/context-panel-shared-view-cell.png`, where the shared-view capture reads
    /// it (docs/validation-authority.md#reference-images).
    private func writeFramedCell() {
        guard let frame = family.sharedViewFrame else { return }
        let renderer = ImageRenderer(
            content: ContextPanelWatchWidgetView(
                entry: entry,
                family: family.widgetFamily,
                presentationDate: context.presentationDate
            )
            .frame(width: frame.size.width, height: frame.size.height)
            .background(Color.black)
            .clipShape(frame.mask)
            .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        renderer.isOpaque = false
        guard let data = renderer.uiImage?.pngData() else { return }
        try? data.write(
            to: URL.temporaryDirectory.appending(path: "context-panel-shared-view-cell.png"),
            options: .atomic
        )
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

    /// The frame and mask a face gives the family on Apple Watch Series 11 (46mm), the
    /// pinned Watch simulator: the HIG's circular size with its circular mask, and the
    /// HIG's rectangular widget size with its four-point corner radius.
    var sharedViewFrame: (size: CGSize, mask: AnyShape)? {
        switch self {
        case .circular: (CGSize(width: 50, height: 50), AnyShape(Circle()))
        case .rectangular:
            (CGSize(width: 194, height: 80.5), AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous)))
        case .inline, .corner: nil
        }
    }

    var previewHeight: CGFloat {
        switch self {
        case .circular, .corner: 50
        case .rectangular: 74
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
