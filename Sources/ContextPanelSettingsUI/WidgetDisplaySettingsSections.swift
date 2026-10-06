#if os(macOS)
import ContextPanelCore
import ContextPanelWidgetUI
import SwiftUI

/// The Display form's sections are shared with the native presentation host.
/// Only layout, visibility and ordering callbacks persist settings; size is local.
public struct WidgetDisplaySettingsSections<ProviderLabel: View>: View {
    let snapshot: WidgetSnapshot?
    let preferences: WidgetDisplayPreferences
    let colors: ContextPanelSettingsControlColors
    let providerLabel: (Provider) -> ProviderLabel
    let onLayoutChange: @MainActor (Bool) -> Void
    let onVisibilityChange: @MainActor (WidgetMainLimitPreference, Bool) -> Void
    let onMove: @MainActor (IndexSet, Int) -> Void
    let presentationDate: Date?
    @State private var family: SettingsWidgetPreviewFamily

    public init(
        snapshot: WidgetSnapshot?, preferences: WidgetDisplayPreferences,
        colors: ContextPanelSettingsControlColors = .init(),
        initialFamily: SettingsWidgetPreviewFamily = .medium,
        presentationDate: Date? = nil,
        @ViewBuilder providerLabel: @escaping (Provider) -> ProviderLabel,
        onLayoutChange: @escaping @MainActor (Bool) -> Void,
        onVisibilityChange: @escaping @MainActor (WidgetMainLimitPreference, Bool) -> Void,
        onMove: @escaping @MainActor (IndexSet, Int) -> Void
    ) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.colors = colors
        self.providerLabel = providerLabel
        self.onLayoutChange = onLayoutChange
        self.onVisibilityChange = onVisibilityChange
        self.onMove = onMove
        self.presentationDate = presentationDate
        _family = State(initialValue: initialFamily)
    }

    public var body: some View {
        Section("Widget layout") {
            // Avoid Swift 6.3.3's isolated callback reabstraction crash.
            Picker("Layout", selection: Binding(
                get: { preferences.usesAccountRows },
                set: { usesAccountRows in
                    MainActor.assumeIsolated {
                        onLayoutChange(usesAccountRows)
                    }
                }
            )) {
                Text("Accounts").tag(true)
                Text("Windows").tag(false)
            }
            Text("Accounts uses every quota window to show the tightest capacity. Window selections below apply to Windows layout.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Widget preview") {
            Picker("Preview size", selection: $family) {
                ForEach(SettingsWidgetPreviewFamily.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    SettingsWidgetPreview(snapshot: snapshot, preferences: preferences,
                        family: family, presentationDate: presentationDate ?? context.date)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 8)
                if let lastReadingAt = snapshot.lastReadingAt {
                    Text("Last updated \(lastReadingAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Loading saved widget data…").foregroundStyle(.secondary)
            }
            Text("Preview only. Choose the size of your placed widget in macOS.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Widget Main Limits") {
            Text("Choose which main limits appear in the widget and drag rows to set their priority.")
                .font(.system(size: 11)).foregroundStyle(colors.secondaryText)
            List {
                WidgetMainLimitSettingsRows(
                    preferences: preferences, colors: colors, providerLabel: providerLabel,
                    onVisibilityChange: onVisibilityChange, onMove: onMove
                )
            }
            .listStyle(.inset)
            .frame(height: max(36 * CGFloat(preferences.mainLimits.count), 36 * 4) + 16)
        }
    }
}
#endif
