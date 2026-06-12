//
//  HoloMemoryPromotionPolicyStandaloneTests.swift
//  HoloTests
//
//  长期记忆晋升策略 standalone 验证：旧格式浅摘要止血（V3.1 Task 0.2）
//  运行：swiftc HoloLongTermMemoryModels.swift HoloShortTermMemoryModels.swift
//        HoloMemoryPromotionPolicy.swift HoloMemoryPromotionPolicyStandaloneTests.swift
//        -o /tmp/holo_promotion_test && /tmp/holo_promotion_test
//

import Foundation

@main
struct HoloMemoryPromotionPolicyStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testLegacyShallow_任务清零节奏好转_被丢弃()
        testLegacyShallow_支出偏高_证据不足_被丢弃()
        testLegacyShallow_证据充足不丢弃()
        test普通记忆_不受LegacyShallow影响()
        print("HoloMemoryPromotionPolicy standalone tests passed")
    }

    // MARK: - Helper

    private static func makeCandidate(
        title: String,
        summary: String = "",
        evidenceCount: Int,
        sensitivity: HoloMemorySensitivity = .normal,
        semanticType: HoloMemorySemanticType? = nil
    ) -> HoloLongTermMemory {
        let evidence = (0..<evidenceCount).map { i in
            HoloLongTermMemoryEvidence(
                id: "ev-\(i)",
                source: .memoryInsight,
                sourceID: nil,
                excerpt: "证据\(i)",
                observedAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        return HoloLongTermMemory(
            id: "cand-\(title)",
            type: .recurringPattern,
            title: title,
            summary: summary,
            confidence: evidenceCount >= 2 ? .medium : .low,
            confirmationState: .candidate,
            sensitivity: sensitivity,
            evidence: evidence,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil,
            semanticType: semanticType,
            displaySummary: nil,
            aiUseSummary: nil,
            useScopes: nil,
            prohibitedInferences: nil
        )
    }

    // MARK: - 旧格式浅摘要应被丢弃（V3.1 Task 0.2 核心）

    private static func testLegacyShallow_任务清零节奏好转_被丢弃() {
        let candidate = makeCandidate(
            title: "任务清零，节奏好转",
            summary: "本周任务完成不错，积压仍在",
            evidenceCount: 1
        )
        let decision = HoloMemoryPromotionPolicy.evaluate(candidate: candidate)
        if case .discard = decision {
            // 期望命中
        } else {
            expect(false, "旧格式浅摘要「任务清零，节奏好转」证据不足应被 discard，实际：\(decision)")
        }
    }

    private static func testLegacyShallow_支出偏高_证据不足_被丢弃() {
        let candidate = makeCandidate(
            title: "支出偏高",
            summary: "本月支出偏高",
            evidenceCount: 0
        )
        let decision = HoloMemoryPromotionPolicy.evaluate(candidate: candidate)
        if case .discard = decision {
            // 期望命中
        } else {
            expect(false, "旧格式浅摘要「支出偏高」无证据应被 discard，实际：\(decision)")
        }
    }

    // MARK: - 回归保护：证据充足 / 普通记忆不被误伤

    private static func testLegacyShallow_证据充足不丢弃() {
        // 同样含系统词，但证据充足（>=2）→ 不应被 legacy shallow 丢弃，走正常路由
        let candidate = makeCandidate(
            title: "支出偏低",
            summary: "近期支出偏低",
            evidenceCount: 3
        )
        let decision = HoloMemoryPromotionPolicy.evaluate(candidate: candidate)
        if case .discard = decision {
            expect(false, "证据充足的候选不应被 legacy shallow 误杀")
        }
    }

    private static func test普通记忆_不受LegacyShallow影响() {
        // 无系统词的普通记忆，证据 1 个 → 按现有逻辑 observe，不被 legacy 规则误伤
        let candidate = makeCandidate(
            title: "每周三晚上跑步",
            summary: "稳定的有氧习惯",
            evidenceCount: 1
        )
        let decision = HoloMemoryPromotionPolicy.evaluate(candidate: candidate)
        if case .observe = decision {
            // 期望命中
        } else {
            expect(false, "普通记忆（无系统词）证据不足时应 observe，实际：\(decision)")
        }
    }
}
