import Foundation
import Testing

@testable import ContextPanelCore

@Test func geminiQuotaPayloadParserNormalizesBucketsAsPercentPressure() throws {
    let json = #"""
    {
      "buckets": [
        {
          "modelId": "gemini-3-flash-preview",
          "remainingFraction": 0.965,
          "resetTime": "2026-05-06T16:04:50Z"
        },
        {
          "modelId": "gemini-3.1-pro-preview",
          "remainingFraction": 1,
          "remainingAmount": 12,
          "resetTime": "2026-05-07T14:19:35Z"
        }
      ]
    }
    """#

    let buckets = try GeminiQuotaPayloadParser.buckets(from: Data(json.utf8))

    #expect(buckets.count == 2)
    #expect(buckets[0].modelID == "gemini-3-flash-preview")
    #expect(buckets[0].remainingFraction == 0.965)
    #expect(abs((buckets[0].usedPercent ?? 0) - 3.5) < 0.0001)
    #expect(ContextPanelDateFormatting.string(from: buckets[0].resetsAt!) == "2026-05-06T16:04:50Z")
    #expect(buckets[1].remainingAmount == 12)

    let limit = buckets[0].usageLimit(accountID: "local", accountName: "Gemini CLI", observedAt: Date(timeIntervalSince1970: 0))
    #expect(limit.provider == .google)
    #expect(limit.unit == .percent)
    #expect(limit.used == 4)
    #expect(limit.limit == 100)
    #expect(limit.confidence == .observed)
}

@Test func geminiQuotaPayloadParserHandlesMissingBuckets() throws {
    let json = #"{"notBuckets": true}"#

    let buckets = try GeminiQuotaPayloadParser.buckets(from: Data(json.utf8))

    #expect(buckets.isEmpty)
}
