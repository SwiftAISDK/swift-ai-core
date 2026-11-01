import Testing
@testable import SwiftAIProviderUtilities
import SwiftAIProvider

@Suite("Weekly20261101 reasoning fallback")
struct Weekly20261101ReasoningTests {
    @Test(arguments: [("xhigh", "high"), ("minimal", "low"), ("none", "low"), ("max", "high")])
    func unsupportedLevelsChooseClosestReasoning(_ requested: String, _ expected: String) {
        var warnings: [AIWarning] = []
        #expect(mapReasoningToProviderEffort(reasoning: requested, effortMap: ["none": "none", "low": "low", "high": "high"], warnings: &warnings) == (requested == "none" ? "none" : expected))
        if requested != "none" { #expect(warnings.first?.type == "compatibility") }
    }
    @Test func unsupportedNoneNeverFallsBackToNoneAndExplicitOverrideIsUnchanged() {
        var warnings: [AIWarning] = []
        #expect(mapReasoningToProviderEffort(reasoning: "none", effortMap: ["low": "low"], warnings: &warnings) == "low")
        #expect(warnings.count == 1)
        warnings = []
        #expect(mapReasoningToProviderEffort(reasoning: "max", effortMap: ["low": "low"], warnings: &warnings, providerOptionsEffort: "provider-custom") == "provider-custom")
        #expect(warnings.isEmpty)
        #expect(mapReasoningToProviderEffort(reasoning: nil, effortMap: [:], warnings: &warnings) == nil)
        #expect(mapReasoningToProviderEffort(reasoning: "provider-default", effortMap: [:], warnings: &warnings) == nil)
        #expect(warnings.isEmpty)
    }
    @Test func missingBudgetOverrideUsesDefaultAndNoneUsesMinimum() {
        var warnings: [AIWarning] = []
        #expect(mapReasoningToProviderBudget(reasoning: "medium", maxOutputTokens: 10000, maxReasoningBudget: 9000, budgetPercentages: ["low": 0.2], warnings: &warnings) == 3000)
        #expect(warnings.isEmpty)
        #expect(mapReasoningToProviderBudget(reasoning: "none", maxOutputTokens: 10000, maxReasoningBudget: 9000, minReasoningBudget: 128, warnings: &warnings) == 128)
        #expect(warnings.first?.type == "compatibility")
    }
}
