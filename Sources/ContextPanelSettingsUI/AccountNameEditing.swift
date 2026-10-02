import SwiftUI

/// Keeps a text field's fallback connected to the model across save and refresh.
public enum AccountNameEditing {
    @MainActor
    public static func commit<Field: Hashable>(
        for field: Field,
        drafts: Binding<[Field: String]>,
        allowsEmpty: Bool,
        save: (String) -> Bool
    ) -> String? {
        guard let draft = drafts.wrappedValue[field] else { return nil }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 80 else { return "Use a name of 80 characters or fewer." }
        guard allowsEmpty || !value.isEmpty else { return "Enter an account name." }
        guard save(value) else { return "Name was not saved. Please try again." }
        drafts.wrappedValue.removeValue(forKey: field)
        return nil
    }

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
