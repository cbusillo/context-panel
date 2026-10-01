import Foundation

public extension Provider {
    var accountDisplayName: String { self == .anthropic ? "Claude" : displayName }
}

public extension AccountCapacityState {
    var displayText: String {
        switch self {
        case .available: "Available"
        case .closeToLimit: "Close to limit"
        case .limited: "Limited"
        case .stale, .unavailable: "Saved"
        case .notConnected: "Not connected"
        case .off: "Paused"
        case .refreshing: "Updating"
        case .unknown: "Unknown"
        }
    }
}

public extension AccountOverview.Account {
    var remainingText: String {
        guard let fraction = remainingFraction else { return "—" }
        let approximate = windows.contains { $0.assumption != nil } ? "≈ " : ""
        if fraction > 0, fraction < 0.01 { return approximate + "<1%" }
        return approximate + "\(Int((fraction * 100).rounded()))%"
    }
    var resetDisplayText: String {
        if [.stale, .unavailable].contains(state) {
            return observedAt.map { "Saved " + ContextPanelDateFormatting.accountReset($0, compact: true) } ?? "Saved time unknown"
        }
        guard let window = limitingWindow, let date = window.naturalResetAt else { return "Reset unknown" }
        return (window.assumption == nil ? "" : "Assumed · ") + ContextPanelDateFormatting.accountReset(date, compact: true)
    }
    var accessibilityText: String {
        var text = "\(metadata.provider.accountDisplayName), \(metadata.label), \(state.displayText), \(remainingText) left"
        if let date = limitingWindow?.naturalResetAt {
            text += ", \(limitingWindow?.assumption == nil ? "reset" : "assumed after reset") \(ContextPanelDateFormatting.accountReset(date))"
        }
        if [.stale, .unavailable].contains(state), let observedAt {
            text += ", last observed \(ContextPanelDateFormatting.accountReset(observedAt))"
        }
        if let bankedResets {
            text += ", \(bankedState == .available ? "" : "last seen ")\(bankedResets.availableCount) banked resets"
            if (unknownExpiryCount ?? 0) > 0 { text += ", some expiry dates unknown" }
        }
        return text
    }
}
