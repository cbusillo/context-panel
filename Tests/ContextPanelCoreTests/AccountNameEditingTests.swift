import ContextPanelSettingsUI
import SwiftUI
import Testing

@MainActor
@Test func accountNameBindingReadsCommittedNameWithoutWaitingForAnotherRender() {
    var saved = "Old name"
    var drafts: [String: String] = [:]
    let binding = AccountNameEditing.binding(for: "account",
        drafts: Binding(get: { drafts }, set: { drafts = $0 }), savedName: { saved })
    binding.wrappedValue = "new@example.invalid"
    #expect(binding.wrappedValue == "new@example.invalid")
    saved = drafts.removeValue(forKey: "account")!
    // SwiftUI can still hold the previous render's binding after committing.
    #expect(binding.wrappedValue == saved)
    saved = "Name from a subsequent model refresh"
    #expect(binding.wrappedValue == saved)
}

@MainActor
@Test func accountNameRefreshPreservesUnsavedAliasAndOtherFieldDrafts() {
    var savedAlias = "Old alias"
    var drafts: [String: String] = ["other": "Other edit"]
    var edits = 0
    let binding = AccountNameEditing.binding(for: "alias",
        drafts: Binding(get: { drafts }, set: { drafts = $0 }), savedName: { savedAlias },
        onEdit: { edits += 1 })
    binding.wrappedValue = "alias@example.invalid"
    savedAlias = "Refreshed alias"
    #expect(binding.wrappedValue == "alias@example.invalid")
    #expect(drafts["other"] == "Other edit")
    #expect(edits == 1)
    savedAlias = drafts.removeValue(forKey: "alias")!
    #expect(binding.wrappedValue == savedAlias)
}
