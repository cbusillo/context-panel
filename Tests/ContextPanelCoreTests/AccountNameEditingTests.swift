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
    #expect(AccountNameEditing.commit(for: "account",
        drafts: Binding(get: { drafts }, set: { drafts = $0 }), allowsEmpty: false,
        save: { saved = $0; return true }) == nil)
    // SwiftUI can still hold the previous render's binding after committing.
    #expect(binding.wrappedValue == saved)
    saved = "Name from a subsequent model refresh"
    #expect(binding.wrappedValue == saved)
}

@MainActor
@Test func invalidAccountNameKeepsDraftAndDoesNotSave() {
    for value in ["   ", String(repeating: "x", count: 81)] {
        var drafts = ["account": value]
        var saves = 0
        let error = AccountNameEditing.commit(for: "account",
            drafts: Binding(get: { drafts }, set: { drafts = $0 }), allowsEmpty: false,
            save: { _ in saves += 1; return true })
        #expect(error != nil)
        #expect(saves == 0)
        #expect(drafts["account"] == value)
    }
}

@MainActor
@Test func accountNameCommitTrimsAndEmptyAliasCanClear() {
    var drafts = ["account": "  typed@example.invalid \n", "alias": "  "]
    var saved: [String] = []
    for field in ["account", "alias"] {
        #expect(AccountNameEditing.commit(for: field,
            drafts: Binding(get: { drafts }, set: { drafts = $0 }), allowsEmpty: field == "alias",
            save: { saved.append($0); return true }) == nil)
    }
    #expect(saved == ["typed@example.invalid", ""])
    #expect(drafts.isEmpty)
}

@MainActor
@Test func rejectedAccountNameSaveKeepsEditThroughRefreshAndCanRetry() {
    var saved = "Old name"
    var drafts = ["account": "new@example.invalid"]
    let draftBinding = Binding(get: { drafts }, set: { drafts = $0 })
    let binding = AccountNameEditing.binding(for: "account", drafts: draftBinding, savedName: { saved })
    #expect(AccountNameEditing.commit(for: "account", drafts: draftBinding,
        allowsEmpty: false, save: { _ in false }) != nil)
    saved = "Name from refresh after rejected save"
    #expect(binding.wrappedValue == "new@example.invalid")
    #expect(AccountNameEditing.commit(for: "account", drafts: draftBinding,
        allowsEmpty: false, save: { saved = $0; return true }) == nil)
    #expect(drafts.isEmpty)
    #expect(binding.wrappedValue == "new@example.invalid")
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
