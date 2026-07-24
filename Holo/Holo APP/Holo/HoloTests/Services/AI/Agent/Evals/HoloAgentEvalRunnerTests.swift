//
//  HoloAgentEvalRunnerTests.swift
//  HoloTests
//
//  Agent 成熟度演进 P0-A — Agent Eval 基线 runner 测试
//
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/HoloAgentTimeRange.swift" \
//    "Holo/Models/AI/Agent/HoloEvidenceModels.swift" \
//    "Holo/Models/AI/Agent/HoloAgentOutputModels.swift" \
//    "Holo/Services/AI/Agent/HoloAgentTimeSemanticResolver.swift" \
//    "Holo/Services/AI/Agent/Verification/HoloClaimVerifier.swift" \
//    "Holo/Services/AI/Agent/Evals/"*.swift \
//    <本测试> -o /tmp/holo_agent_eval_test && /tmp/holo_agent_eval_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloAgentEvalRunnerTests.main()
    }
}
#endif

struct HoloAgentEvalRunnerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        // 加载全部 seed 用例并运行统一 runner
        let cases = HoloAgentEvalSeedCorpus.allCases()
        expect(!cases.isEmpty, "seed corpus 不应为空")

        let verdicts = HoloAgentEvalRunner.evaluate(cases)
        let summary = HoloAgentEvalRunner.summarize(verdicts)

        // 逐条检查失败，输出详细原因
        for verdict in verdicts where !verdict.passed {
            let msg = "❌ [\(verdict.caseID)] \(verdict.failures.joined(separator: "; "))"
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }

        expect(summary.failed == 0, "Eval 基线有 \(summary.failed) 条失败（共 \(summary.total) 条）")

        // 验收：覆盖 9 类场景
        let categories = Set(cases.map { $0.category })
        expect(categories.count == HoloAgentEvalCategory.allCases.count,
               "应覆盖全部 \(HoloAgentEvalCategory.allCases.count) 类场景，实际 \(categories.count)")

        // 验收：达到首批 80 条基线
        expect(cases.count >= 80, "首批 Eval 基线应 >= 80 条，实际 \(cases.count)")

        print("✅ HoloAgentEvalRunner passed: \(summary.passed)/\(summary.total)，覆盖 \(categories.count) 类场景")
    }
}
