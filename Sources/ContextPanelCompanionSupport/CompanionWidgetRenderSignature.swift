import ContextPanelCore
import Foundation

/// What the companion app shows, and whether its widgets need a reload.
/// Keeps the synced snapshot whole: a field-by-field copy once dropped the account names (#806).
public struct CompanionWidgetRenderSignature: Equatable {
    public let snapshot: WidgetSnapshot
    public let displayPreferences: WidgetDisplayPreferences
    let hasDocument: Bool
    let deliveryStatus: CompanionSyncDeliveryStatus?

    public init(
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences,
        now: Date
    ) {
        snapshot = WidgetSnapshot.fromCompanionSync(
            result,
            now: now,
            stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
                maximumAge: SnapshotFreshness.companionProviderMaximumAge
            )
        )
        hasDocument = result.document != nil
        self.displayPreferences = displayPreferences
        deliveryStatus = result.transportMetadata?.deliveryStatus
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.hasDocument == rhs.hasDocument,
              lhs.displayPreferences == rhs.displayPreferences,
              lhs.deliveryStatus == rhs.deliveryStatus else { return false }
        guard lhs.hasDocument else {
            // Without a document, generatedAt is the load time and nothing else varies.
            return lhs.snapshot.state == rhs.snapshot.state && lhs.snapshot.status == rhs.snapshot.status
                && lhs.snapshot.message == rhs.snapshot.message
                && lhs.snapshot.syncErrorMessage == rhs.snapshot.syncErrorMessage
        }
        return lhs.snapshot == rhs.snapshot
    }
}
