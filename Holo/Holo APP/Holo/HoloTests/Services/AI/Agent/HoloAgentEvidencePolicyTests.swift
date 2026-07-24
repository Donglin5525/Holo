//
//  HoloAgentEvidencePolicyTests.swift
//  HoloTests
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloAgentEvidencePolicyTests.main()
    }
}
#endif
struct HoloAgentEvidencePolicyTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        test工具映射到正确证据来源()
        try test旧工具结果缺敏感度仍可解码()
        print("HoloAgentEvidencePolicyTests passed")
    }

    private static func test工具映射到正确证据来源() {
        let expected: [String: HoloEvidenceSourceModule] = [
            "finance": .finance,
            "habit": .habit,
            "task": .task,
            "goal": .goal,
            "thought": .thought,
            "health": .health,
            "memory": .memory,
            "profile": .profile,
            "conversation": .conversation,
            "insight": .memoryInsight
        ]

        for (tool, module) in expected {
            expect(
                HoloAgentEvidencePolicy.sourceModule(for: tool) == module,
                "\(tool) 应映射到 \(module.rawValue)"
            )
        }
        expect(HoloAgentEvidencePolicy.sourceModule(for: "unknown") == .agent, "未知工具应回退 agent")
    }

    private static func test旧工具结果缺敏感度仍可解码() throws {
        let json = """
        {
          "toolRequestID": "legacy-1",
          "tool": "thought",
          "status": "success",
          "coverage": null,
          "metrics": [],
          "events": [],
          "warnings": [],
          "error": null
        }
        """

        let decoded = try JSONDecoder().decode(
            HoloDataToolResult.self,
            from: Data(json.utf8)
        )
        expect(decoded.sensitivity == nil, "旧结果缺 sensitivity 时应解码为 nil")
    }
}
