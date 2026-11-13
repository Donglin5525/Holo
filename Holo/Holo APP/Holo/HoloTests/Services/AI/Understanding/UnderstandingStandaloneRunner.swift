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
    }
}
