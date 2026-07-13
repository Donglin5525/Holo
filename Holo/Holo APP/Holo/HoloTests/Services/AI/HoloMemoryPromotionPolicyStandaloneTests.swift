//
//  HoloMemoryPromotionPolicyStandaloneTests.swift
//  HoloTests
//
//  严格 V2 长期记忆晋升策略 standalone 验证
//

import Foundation

@main
struct HoloMemoryPromotionPolicyStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        expectSilentlyAccepted(
            makeCandidate(type: .stablePattern, evidenceCount: 3),
            "三条证据的普通稳定模式应静默接受"
        )
        expectObserved(
            makeCandidate(type: .phaseShift, evidenceCount: 1),
            "证据不足的阶段变化应继续观察"
        )
        expectSilentlyAccepted(
            makeCandidate(type: .statMilestone, evidenceCount: 1, scopes: [.displayOnly, .retrospective]),
            "轻量统计收藏应直接进入展示，不打扰用户确认"
        )
        expectRequiresConfirmation(
            makeCandidate(type: .lifeEvent, evidenceCount: 1, sensitivity: .sensitive),
            "敏感人生节点必须确认"
        )
        print("HoloMemoryPromotionPolicy standalone tests passed")
    }

    private static func makeCandidate(
        type: HoloMemorySemanticType,
        evidenceCount: Int,
        sensitivity: HoloMemorySensitivity = .normal,
        scopes: [HoloMemoryUseScope] = [.coreContext]
    ) -> HoloLongTermMemory {
        let evidence = (0..<evidenceCount).map { index in
            HoloLongTermMemoryEvidence(
                id: "ev-\(index)",
                source: .memoryInsight,
                sourceID: "source-\(index)",
                excerpt: "证据 \(index)",
                observedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        return HoloLongTermMemory(
            id: "candidate-\(type.rawValue)",
            subjectKey: "test:\(type.rawValue)",
            title: "测试记忆",
            confidence: evidenceCount >= 3 ? .high : .medium,
            confirmationState: .candidate,
            sensitivity: sensitivity,
            evidence: evidence,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil,
            semanticType: type,
            displaySummary: "测试摘要",
            aiUseSummary: "仅在测试场景使用，不扩展推断。",
            useScopes: scopes,
            prohibitedInferences: ["不要扩展推断"]
        )
    }

    private static func expectSilentlyAccepted(_ candidate: HoloLongTermMemory, _ message: String) {
        guard case .silentlyAccept = HoloMemoryPromotionPolicy.evaluate(candidate: candidate) else {
            fatalError(message)
        }
    }

    private static func expectObserved(_ candidate: HoloLongTermMemory, _ message: String) {
        guard case .observe = HoloMemoryPromotionPolicy.evaluate(candidate: candidate) else {
            fatalError(message)
        }
    }

    private static func expectRequiresConfirmation(_ candidate: HoloLongTermMemory, _ message: String) {
        guard case .requireConfirmation = HoloMemoryPromotionPolicy.evaluate(candidate: candidate) else {
            fatalError(message)
        }
    }
}
