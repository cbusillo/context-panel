import ContextPanelCore
import Testing

@Test func metricProgressKeepsRemainingAndUsedSemanticsDistinct() {
    let remaining = MetricProgress.remainingCapacity(remainingRatio: 0.81)
    let used = MetricProgress.usedPressure(usedRatio: 0.19)

    #expect(remaining.kind == .remainingCapacity)
    #expect(remaining.ratio == 0.81)
    #expect(remaining.percentText == "81%")
    #expect(remaining.accessibilityValue == "81 percent remaining")

    #expect(used.kind == .usedPressure)
    #expect(used.ratio == 0.19)
    #expect(used.percentText == "19%")
    #expect(used.accessibilityValue == "19 percent used")
}

@Test func metricProgressKeepsNeutralRatesDirectionless() {
    let rate = MetricProgress.neutralRate(ratio: 0.42)

    #expect(rate.kind == .neutralRate)
    #expect(rate.percentText == "42%")
    #expect(rate.accessibilityValue == "42 percent")
}

@Test func metricProgressModelsUnknownAndUnavailableAsIndeterminate() {
    let remaining = MetricProgress.remainingCapacity(remainingRatio: nil)
    let used = MetricProgress.usedPressure(usedRatio: .nan)
    let rate = MetricProgress.neutralRate(ratio: .infinity)

    #expect(remaining.isIndeterminate)
    #expect(remaining.percentText == "—")
    #expect(remaining.accessibilityValue == "Remaining capacity unknown")
    #expect(used.isIndeterminate)
    #expect(used.accessibilityValue == "Usage pressure unknown")
    #expect(rate.isIndeterminate)
    #expect(rate.accessibilityValue == "Rate unknown")
}

@Test func metricProgressClampsDeterminateRatios() {
    let exhausted = MetricProgress.remainingCapacity(remainingRatio: -0.2)
    let overLimit = MetricProgress.usedPressure(usedRatio: 1.4)

    #expect(exhausted.ratio == 0)
    #expect(exhausted.percentText == "0%")
    #expect(overLimit.ratio == 1)
    #expect(overLimit.percentText == "100%")
}
