//
//  UnderstandingStandaloneRunner.swift
//  Holo
//
//  理解引擎 standalone 测试统一入口（一个 @main 顺序跑全部套件）。
//

import Foundation

@main
private struct UnderstandingStandaloneRunner {
    static func main() async throws {
        try await UnderstandingM21StandaloneTests.main()
        try await ProposalGateStandaloneTests.main2()
        try EvidenceRouterStandaloneTests.run()
        try ThemeIndexStandaloneTests.run()
        try ShadowRuntimeStandaloneTests.run()
        try EndToEndStandaloneTests.run()
        try AdversarialRegressionTests.run()
        try await ShadowRunnerStandaloneTests.run()
        try await AdversarialRound2Tests.run()
        try await SufficiencyPolicyStandaloneTests.run()
        try await UnderstandingConsentSweeperTests.run()
        try await ProjectionFixesTests.run()
        try LifeFeatureDistillerStandaloneTests.run()
        try PortraitSynthesisStandaloneTests.run()
        try PortraitContextInjectorStandaloneTests.run()
    }
}
