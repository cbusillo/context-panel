import Foundation
import Testing
@testable import ContextPanelCore

private let resetObservation = Date(timeIntervalSince1970: 1_800_000_000)

@Test func claudeResetCreditsDeduplicateAndUseOfferExpiry() throws {
    let json = #"""
    {"cedar_ember":{"eligible":true,"weekly_resets_at":"2099-02-01T00:00:00Z","grants":[
      {"id":"offer_a","resets_total":3,"resets_left":2,"clears":["seven_day"],"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"offer_a","resets_total":3,"resets_left":2,"clears":["seven_day"],"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"offer_b","resets_total":1,"resets_left":5,"clears":["seven_day"],"ends_at":"2099-01-02T00:00:00Z"},
      {"id":"paused","resets_total":2,"resets_left":2,"clears":["seven_day"],"ends_at":"2099-01-01T00:00:00Z","paused":true},
      {"id":"expired","resets_total":2,"resets_left":2,"clears":["seven_day"],"ends_at":"2000-01-01T00:00:00Z"}
    ]}}
    """#
    let summary = try #require(ClaudeResetCreditParser.summary(from: Data(json.utf8), observedAt: resetObservation))
    #expect(summary.availableCount == 3)
    #expect(summary.coverage == .complete)
    #expect(summary.knownExpiries.count == summary.availableCount)
    #expect(summary.knownExpiries.first == ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
    #expect(summary.knownExpiries.last == ISO8601DateFormatter().date(from: "2099-01-02T00:00:00Z"))
    let saved = try JSONEncoder().encode(summary)
    #expect(!String(decoding: saved, as: UTF8.self).contains("offer_a"))
}

@Test func claudeResetCreditsDistinguishUnknownFromEmptyInventory() throws {
    for json in ["{}", #"{"cedar_ember":{"eligible":false}}"#,
                 #"{"cedar_ember":{"eligible":true}}"#,
                 #"{"cedar_ember":{"eligible":true,"grants":[{"id":"bad","resets_total":2,"resets_left":1}]}}"#] {
        #expect(ClaudeResetCreditParser.summary(from: Data(json.utf8), observedAt: resetObservation) == nil)
    }
    let empty = #"{"cedar_ember":{"eligible":true,"grants":[]}}"#
    let summary = try #require(ClaudeResetCreditParser.summary(from: Data(empty.utf8), observedAt: resetObservation))
    #expect(summary.availableCount == 0)
    #expect(summary.earliestKnownExpiry == nil)
}

@Test func claudeResetCreditCooldownIsAccountSpecificAndAllowsRecovery() async throws {
    let cooldown = ClaudeResetCreditReadCooldown()
    let endpoint = try #require(URL(string: "https://example.test/usage"))
    #expect(await cooldown.begin(accountID: "one", endpoint: endpoint, now: resetObservation))
    #expect(await !cooldown.begin(accountID: "one", endpoint: endpoint, now: resetObservation.addingTimeInterval(60)))
    #expect(await cooldown.begin(accountID: "two", endpoint: endpoint, now: resetObservation.addingTimeInterval(60)))
    #expect(await cooldown.begin(accountID: "one", endpoint: endpoint, now: resetObservation.addingTimeInterval(7 * 60 * 60)))
    await cooldown.succeeded(accountID: "one", endpoint: endpoint)
    #expect(await cooldown.begin(accountID: "one", endpoint: endpoint, now: resetObservation.addingTimeInterval(7 * 60 * 60 + 1)))
}

@Test func claudeResetCreditsKeepModelGrantsAndOffersOutOfGeneralCapacity() throws {
    let data = Data(#"""
    {"cedar_ember":{"eligible":true,"grants":[
      {"id":"general","resets_total":2,"resets_left":2,"clears":["seven_day"],"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"model","resets_total":3,"resets_left":3,"clears":["seven_day_opus"],"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"unknown","resets_total":1,"resets_left":1,"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"offer","resets_total":1,"resets_left":0,"usable_now":true,"clears":["seven_day"],"ends_at":"2099-01-01T00:00:00Z"}
    ]}}
    """#.utf8)
    let summary = try #require(ClaudeResetCreditParser.summary(from: data, observedAt: resetObservation))
    #expect(summary.availableCount == 2)
    #expect(summary.unrecognizedKindCount == 4)
    #expect(summary.excludedOfferCount == 1)
    #expect(summary.knownExpiries.count == 2)
    let restored = try JSONDecoder().decode(ProviderResetCreditSummary.self, from: JSONEncoder().encode(summary))
    #expect(restored == summary)
}
