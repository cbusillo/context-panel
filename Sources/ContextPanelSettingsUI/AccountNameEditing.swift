import SwiftUI

/// Keeps a text field's fallback connected to the model across save and refresh.
public enum AccountNameEditing {
    @MainActor
    public static func binding<Field: Hashable>(
        for field: Field,
        drafts: Binding<[Field: String]>,
        savedName: @escaping () -> String,
        onEdit: @escaping () -> Void = {}
    ) -> Binding<String> {
        return Binding(
            get: { drafts.wrappedValue[field] ?? savedName() },
            set: {
                drafts.wrappedValue[field] = $0
                onEdit()
            }
        )
    }
}
