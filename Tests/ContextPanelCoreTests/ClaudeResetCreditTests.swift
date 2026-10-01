import Foundation
import Testing
@testable import ContextPanelCore

private let resetObservation = Date(timeIntervalSince1970: 1_800_000_000)

@Test func claudeResetCreditsDeduplicateAndUseOfferExpiry() throws {
    let json = #"""
    {"cedar_ember":{"eligible":true,"weekly_resets_at":"2099-02-01T00:00:00Z","grants":[
      {"id":"offer_a","resets_total":3,"resets_left":2,"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"offer_a","resets_total":3,"resets_left":2,"ends_at":"2099-01-01T00:00:00Z"},
      {"id":"offer_b","resets_total":1,"resets_left":5,"ends_at":"2099-01-02T00:00:00Z"},
      {"id":"paused","resets_total":2,"resets_left":2,"ends_at":"2099-01-01T00:00:00Z","paused":true},
      {"id":"expired","resets_total":2,"resets_left":2,"ends_at":"2000-01-01T00:00:00Z"}
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

@Test func claudeResetCreditsClaimabilityRespectsBlockingAndCooldown() throws {
    func count(_ fields: String) throws -> Int {
        let json = """
        {"cedar_ember":{"eligible":true,\(fields)"grants":[
        {"id":"claim","resets_total":1,"resets_left":0,"ends_at":"2099-01-01T00:00:00Z",
         "usable_now":true,"clears":["seven_day"],"blocking":[]} ]}}
        """
        return try #require(ClaudeResetCreditParser.summary(from: Data(json.utf8), observedAt: resetObservation)).availableCount
    }
    #expect(try count(#""at_limit":true,"exhausted":["seven_day"],"#) == 1)
    #expect(try count(#""at_limit":false,"#) == 0)
    #expect(try count(#""at_limit":true,"exhausted":["seven_day"],"cooldown_until":"2099-01-01T00:00:00Z","#) == 0)
}
