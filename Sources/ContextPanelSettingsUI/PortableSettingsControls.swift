import ContextPanelCore
import SwiftUI

public struct ContextPanelSettingsControlColors {
    public let primaryText: Color
    public let secondaryText: Color
    public let tertiaryText: Color
    public let errorText: Color
    public let segmentBackground: Color
    public let selectedSegmentBackground: Color
    public let selectedSegmentText: Color
    public let unselectedSegmentText: Color
    public let border: Color

    public init(
        primaryText: Color = .primary,
        secondaryText: Color = .secondary,
        tertiaryText: Color = .secondary,
        errorText: Color = .red,
        segmentBackground: Color = .secondary.opacity(0.12),
        selectedSegmentBackground: Color = .accentColor,
        selectedSegmentText: Color = .white,
        unselectedSegmentText: Color = .secondary,
        border: Color = .clear
    ) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.errorText = errorText
        self.segmentBackground = segmentBackground
        self.selectedSegmentBackground = selectedSegmentBackground
        self.selectedSegmentText = selectedSegmentText
        self.unselectedSegmentText = unselectedSegmentText
        self.border = border
    }
}

public struct CompanionRefreshSettingsControl: View {
    private let settings: CompanionRefreshSettings
    private let errorMessage: String?
    private let colors: ContextPanelSettingsControlColors
    private let onIntervalChange: @MainActor (Int) -> Void

    public init(
        settings: CompanionRefreshSettings,
        errorMessage: String?,
        colors: ContextPanelSettingsControlColors = ContextPanelSettingsControlColors(),
        onIntervalChange: @escaping @MainActor (Int) -> Void
    ) {
        self.settings = settings
        self.errorMessage = errorMessage
        self.colors = colors
        self.onIntervalChange = onIntervalChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("Auto-update", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.primaryText)
                Spacer(minLength: 12)
                Picker("Auto-update", selection: Binding(
                    get: { settings.intervalMinutes },
                    set: { minutes in
                        MainActor.assumeIsolated {
                            onIntervalChange(minutes)
                        }
                    }
                )) {
                    ForEach(CompanionRefreshSettings.allowedIntervalMinutes, id: \.self) { minutes in
                        Text("\(minutes)m").tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .foregroundStyle(colors.primaryText)
            }
            Text("Widgets may update less often when the system limits background refreshes.")
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(colors.errorText)
            }
        }
    }
}

public struct CompanionAppearanceSettingsControl: View {
    private let settings: CompanionAppearanceSettings
    private let errorMessage: String?
    private let colors: ContextPanelSettingsControlColors
    private let onAppAppearanceChange: @MainActor (CompanionVisionOSAppAppearance) -> Void
    private let onWidgetAppearanceChange: @MainActor (CompanionVisionOSWidgetAppearance) -> Void

    public init(
        settings: CompanionAppearanceSettings,
        errorMessage: String?,
        colors: ContextPanelSettingsControlColors = ContextPanelSettingsControlColors(),
        onAppAppearanceChange: @escaping @MainActor (CompanionVisionOSAppAppearance) -> Void,
        onWidgetAppearanceChange: @escaping @MainActor (CompanionVisionOSWidgetAppearance) -> Void
    ) {
        self.settings = settings
        self.errorMessage = errorMessage
        self.colors = colors
        self.onAppAppearanceChange = onAppAppearanceChange
        self.onWidgetAppearanceChange = onWidgetAppearanceChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.primaryText)

            VStack(alignment: .leading, spacing: 10) {
                appearanceRow("App") {
                    AppearanceSegmentedControl(
                        values: CompanionVisionOSAppAppearance.allCases,
                        selection: settings.visionOSAppAppearance,
                        label: appAppearanceLabel,
                        colors: colors,
                        onSelect: onAppAppearanceChange
                    )
                }

                appearanceRow("Widget") {
                    AppearanceSegmentedControl(
                        values: CompanionVisionOSWidgetAppearance.allCases,
                        selection: settings.visionOSWidgetAppearance,
                        label: widgetAppearanceLabel,
                        colors: colors,
                        onSelect: onWidgetAppearanceChange
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(colors.errorText)
            }
        }
    }

    private func appearanceRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(colors.secondaryText)
            content()
        }
    }

    private func appAppearanceLabel(_ appearance: CompanionVisionOSAppAppearance) -> String {
        switch appearance {
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }

    private func widgetAppearanceLabel(_ appearance: CompanionVisionOSWidgetAppearance) -> String {
        switch appearance {
        case .matchApp:
            "Match App"
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }
}

public struct WidgetMainLimitSettingsRows<ProviderLabel: View>: View {
    private let preferences: WidgetDisplayPreferences
    private let colors: ContextPanelSettingsControlColors
    private let showsDragIndicator: Bool
    private let providerLabel: (Provider) -> ProviderLabel
    private let onVisibilityChange: @MainActor (WidgetMainLimitPreference, Bool) -> Void
    private let onMove: @MainActor (IndexSet, Int) -> Void

    public init(
        preferences: WidgetDisplayPreferences,
        colors: ContextPanelSettingsControlColors = ContextPanelSettingsControlColors(),
        showsDragIndicator: Bool = true,
        @ViewBuilder providerLabel: @escaping (Provider) -> ProviderLabel,
        onVisibilityChange: @escaping @MainActor (WidgetMainLimitPreference, Bool) -> Void,
        onMove: @escaping @MainActor (IndexSet, Int) -> Void
    ) {
        self.preferences = preferences
        self.colors = colors
        self.showsDragIndicator = showsDragIndicator
        self.providerLabel = providerLabel
        self.onVisibilityChange = onVisibilityChange
        self.onMove = onMove
    }

    public var body: some View {
        ForEach(preferences.mainLimits) { preference in
            WidgetMainLimitSettingsRow(
                preference: preference,
                colors: colors,
                showsDragIndicator: showsDragIndicator,
                providerLabel: providerLabel,
                onVisibilityChange: onVisibilityChange
            )
        }
        .onMove { source, destination in
            MainActor.assumeIsolated {
                onMove(source, destination)
            }
        }
    }

}

public struct WidgetMainLimitSettingsStack<ProviderLabel: View>: View {
    private let preferences: WidgetDisplayPreferences
    private let colors: ContextPanelSettingsControlColors
    private let isReordering: Bool
    private let providerLabel: (Provider) -> ProviderLabel
    private let onVisibilityChange: @MainActor (WidgetMainLimitPreference, Bool) -> Void
    private let onMove: @MainActor (IndexSet, Int) -> Void

    public init(
        preferences: WidgetDisplayPreferences,
        colors: ContextPanelSettingsControlColors = ContextPanelSettingsControlColors(),
        isReordering: Bool,
        @ViewBuilder providerLabel: @escaping (Provider) -> ProviderLabel,
        onVisibilityChange: @escaping @MainActor (WidgetMainLimitPreference, Bool) -> Void,
        onMove: @escaping @MainActor (IndexSet, Int) -> Void
    ) {
        self.preferences = preferences
        self.colors = colors
        self.isReordering = isReordering
        self.providerLabel = providerLabel
        self.onVisibilityChange = onVisibilityChange
        self.onMove = onMove
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(preferences.mainLimits.enumerated()), id: \.element.id) { index, preference in
                if index > 0 {
                    Divider()
                }

                VStack(alignment: .leading, spacing: 4) {
                    WidgetMainLimitSettingsRow(
                        preference: preference,
                        colors: colors,
                        showsDragIndicator: false,
                        providerLabel: providerLabel,
                        onVisibilityChange: onVisibilityChange
                    )

                    if isReordering {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            reorderButton(
                                systemName: "chevron.up",
                                title: "Move Up",
                                accessibilityLabel: "Move \(preference.displayName) up",
                                isEnabled: index > 0
                            ) {
                                onMove(IndexSet(integer: index), index - 1)
                            }
                            reorderButton(
                                systemName: "chevron.down",
                                title: "Move Down",
                                accessibilityLabel: "Move \(preference.displayName) down",
                                isEnabled: index < preferences.mainLimits.count - 1
                            ) {
                                onMove(IndexSet(integer: index), index + 2)
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isReordering)
    }

    private func reorderButton(
        systemName: String,
        title: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemName)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 76, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isEnabled ? colors.secondaryText : colors.tertiaryText.opacity(0.35))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WidgetMainLimitSettingsRow<ProviderLabel: View>: View {
    let preference: WidgetMainLimitPreference
    let colors: ContextPanelSettingsControlColors
    let showsDragIndicator: Bool
    let providerLabel: (Provider) -> ProviderLabel
    let onVisibilityChange: @MainActor (WidgetMainLimitPreference, Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsDragIndicator {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.tertiaryText)
                    .frame(width: 14)
            }
            Toggle(isOn: Binding(
                get: { preference.isVisible },
                set: { isVisible in
                    MainActor.assumeIsolated {
                        onVisibilityChange(preference, isVisible)
                    }
                }
            )) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        providerLabel(preference.provider)
                        Text(widgetMainLimitSettingsDisplayName(preference.window))
                        Spacer()
                        visibilityText
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            providerLabel(preference.provider)
                            Text(widgetMainLimitSettingsDisplayName(preference.window))
                        }
                        visibilityText
                    }
                }
            }
            .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    private var visibilityText: some View {
        Text(preference.isVisible ? "Shown" : "Hidden")
            .font(.caption2.weight(.medium))
            .foregroundStyle(colors.secondaryText)
    }
}

private func widgetMainLimitSettingsDisplayName(_ window: MainLimitWindow) -> String {
    switch window {
    case .availability:
        "Google reset window"
    default:
        window.displayName
    }
}

private struct AppearanceSegmentedControl<Value: Hashable>: View {
    let values: [Value]
    let selection: Value
    let label: (Value) -> String
    let colors: ContextPanelSettingsControlColors
    let onSelect: @MainActor (Value) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selection
                Button {
                    onSelect(value)
                } label: {
                    Text(label(value))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(isSelected ? colors.selectedSegmentText : colors.unselectedSegmentText)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .padding(.horizontal, 8)
                        .background(
                            isSelected ? colors.selectedSegmentBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(value))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            colors.segmentBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        }
    }
}
