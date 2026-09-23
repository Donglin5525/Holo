import Foundation

/// 按需澄清协调器验收（低确认成本方案 P4 / §8.4/§8.5/§11.4）。
///
/// 锁定产品硬契约（§21 纪律 9：30 天/7 天/1 问是首版契约，不得改成「尽量」）：
/// 1. 不相关的 askWhenRelevant 永不出现；
/// 2. 相关冲突只问最小问题（每流程 ≤1，高影响优先）；
/// 3. 跳过后同题 30 天冷却，实质证据变化才解锁；
/// 4. 普通入口滚动 7 天全局最多 1 问；
/// 5. 回答按最窄适用范围写回（明确长期表达才 durable），澄清不触发业务动作。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryClarificationStandaloneTests.main()
    }
}
#endif
struct HoloMemoryClarificationStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        withFlag(HoloMemoryClarificationCoordinator.enabledKey, nil) {
            selectionRules()
        }
        try await writebackRules()
        print("HoloMemoryClarificationStandaloneTests: \(assertions) assertions passed")
    }

    // MARK: - 选取规则

    private static func selectionRules() {
        let now = HoloMemoryFiveWayFixtures.anchorNow
        let conflict = HoloMemoryFiveWayFixtures.mtx14ConflictingDeclaredStatements.record
        let highImpact = HoloMemoryFiveWayFixtures.mtx11HighImpactQualifiedInference.record
        expect(
            HoloMemoryDecisionPolicy.evaluate(conflict, now: now).route == .askWhenRelevant,
            "前置条件：冲突 fixture 应为 askWhenRelevant"
        )

        // 1) 不相关（当前结果不依赖）→ 永不出现。
        expect(
            HoloMemoryClarificationCoordinator.selectQuestion(
                records: [conflict, highImpact],
                affectsCurrentOutcome: { _ in false },
                now: now,
                history: .empty
            ).map { _ in false } ?? true,
            "不相关的 askWhenRelevant 永不出现"
        )

        // 2) 相关 → 至多一个问题，高影响优先。
        let selected = HoloMemoryClarificationCoordinator.selectQuestion(
            records: [conflict, highImpact],
            affectsCurrentOutcome: { _ in true },
            now: now,
            history: .empty
        )
        guard let (question, updatedHistory) = selected else {
            fatalError("相关 askWhenRelevant 应产生一个问题")
        }
        assertions += 1
        expect(
            question.recordID == highImpact.id,
            "高影响候选应优先被问（impact 排序）"
        )
        expect(
            question.options.count == 4
                && question.options.contains(where: \.expressesDurableRule)
                && question.options.contains(where: \.isDismissal),
            "选项应含长期规则/最窄范围/暂不确定/不再使用四类"
        )
        expect(
            !question.logicalQuestionKey.isEmpty && question.logicalQuestionKey != question.questionText,
            "logicalQuestionKey 应为规范签名而非显示文案"
        )
        expect(
            updatedHistory.recentPromptDates.count == 1,
            "提问应计入全局滚动预算"
        )

        // 3) 全局预算：7 天内已问过 → 不再问（即使另一个问题相关）。
        let withinWindow = now.addingTimeInterval(3 * 86_400)
        expect(
            HoloMemoryClarificationCoordinator.selectQuestion(
                records: [conflict],
                affectsCurrentOutcome: { _ in true },
                now: withinWindow,
                history: updatedHistory
            ).map { _ in false } ?? true,
            "滚动 7 天全局预算（1 问）用尽后不再问"
        )

        // 4) 同题冷却：dismissed 后 30 天内不重复。
        var dismissedHistory = updatedHistory
        dismissedHistory.perQuestion[question.logicalQuestionKey]?.cooldownUntil =
            now.addingTimeInterval(Double(HoloMemoryClarificationCoordinator.sameQuestionCooldownDays) * 86_400)
        dismissedHistory.recentPromptDates = [] // 预算已释放，仅测同题冷却
        expect(
            HoloMemoryClarificationCoordinator.selectQuestion(
                records: [highImpact],
                affectsCurrentOutcome: { _ in true },
                now: now.addingTimeInterval(10 * 86_400),
                history: dismissedHistory
            ).map { _ in false } ?? true,
            "同题 30 天冷却期内不得重复询问"
        )
        // 冷却期满 → 可再问。
        expect(
            HoloMemoryClarificationCoordinator.selectQuestion(
                records: [highImpact],
                affectsCurrentOutcome: { _ in true },
                now: now.addingTimeInterval(31 * 86_400),
                history: dismissedHistory
            ).map { _ in true } ?? false,
            "冷却期满后可再次询问"
        )

        // 5) 实质证据解锁：证据修订变化即解除冷却（新证据能改变候选答案的确定性代理）。
        var rebornEvidence = highImpact
        rebornEvidence.evidenceRefs[0].revisionDigest = "rev-2-material-change"
        expect(
            HoloMemoryClarificationCoordinator.selectQuestion(
                records: [rebornEvidence],
                affectsCurrentOutcome: { _ in true },
                now: now.addingTimeInterval(10 * 86_400),
                history: dismissedHistory
            ).map { _ in true } ?? false,
            "证据修订实质变化应解除同题冷却"
        )

        // 6) 开关关闭 → 一律不问（回滚位）。
        withFlag(HoloMemoryClarificationCoordinator.enabledKey, false) {
            expect(
                HoloMemoryClarificationCoordinator.selectQuestion(
                    records: [conflict],
                    affectsCurrentOutcome: { _ in true },
                    now: now,
                    history: .empty
                ).map { _ in false } ?? true,
                "开关关闭后不再产生任何澄清问题"
            )
        }
    }

    // MARK: - 写回规则（§8.5）

    private static func writebackRules() async throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow
        let conflict = HoloMemoryFiveWayFixtures.mtx14ConflictingDeclaredStatements.record
        let question = HoloMemoryClarificationCoordinator.selectQuestion(
            records: [conflict],
            affectsCurrentOutcome: { _ in true },
            now: now,
            history: .empty
        )!.question

        // durable 选项 → userConfirmed + active + factEligible，证据可回源。
        let durableStore = HoloMemoryClarificationTestStore(record: conflict)
        let durableOutcome = try await HoloMemoryClarificationCoordinator.apply(
            answer: .answered(optionIndex: 0),
            to: question,
            in: durableStore,
            now: now,
            history: .empty
        )
        expect(durableOutcome.outcome.didWriteBack, "明确长期表达应写回")
        let durableRecord = await durableStore.snapshot(id: conflict.id)
        expect(durableRecord?.userDecision == .confirmed, "长期表达 → userConfirmed")
        expect(durableRecord?.state == .active, "长期表达 → active")
        expect(
            durableRecord?.decisionMetadata?.v2?.useLevel == .factEligible,
            "长期表达 → factEligible"
        )
        expect(
            durableRecord?.evidenceRefs.contains { $0.lineageKey.hasPrefix("clarification:") } == true,
            "回答应追加可回源的用户声明证据"
        )
        expect(
            durableRecord?.predecessorVersionID == conflict.versionID,
            "写回必须走版本链"
        )

        // 最窄范围选项 → 不升 durable，observeOnly sourceScoped。
        let narrowStore = HoloMemoryClarificationTestStore(record: conflict)
        let narrowOutcome = try await HoloMemoryClarificationCoordinator.apply(
            answer: .answered(optionIndex: 1),
            to: question,
            in: narrowStore,
            now: now,
            history: .empty
        )
        expect(narrowOutcome.outcome.didWriteBack, "最窄范围回答也应写回（仅本次证据）")
        let narrowRecord = await narrowStore.snapshot(id: conflict.id)
        expect(narrowRecord?.userDecision == HoloMemoryUserDecision.none, "最窄范围不得标记为用户确认的长期事实")
        expect(
            narrowRecord?.decisionMetadata?.v2?.useLevel == .observeOnly,
            "最窄范围 → observeOnly（不进入事实召回）"
        )
        expect(
            narrowRecord?.decisionMetadata?.v2?.persistencePermission == .sourceScoped,
            "最窄范围 → sourceScoped"
        )

        // dismissed → 事实状态不变，进入 30 天冷却。
        let dismissStore = HoloMemoryClarificationTestStore(record: conflict)
        let dismissOutcome = try await HoloMemoryClarificationCoordinator.apply(
            answer: .dismissed,
            to: question,
            in: dismissStore,
            now: now,
            history: HoloMemoryClarificationPromptHistory.empty
        )
        expect(dismissOutcome.outcome.enteredCooldown, "跳过应进入冷却")
        expect(
            dismissOutcome.updatedHistory.perQuestion[question.logicalQuestionKey]?.cooldownUntil != nil,
            "冷却截止应写入历史"
        )
        let dismissedRecord = await dismissStore.snapshot(id: conflict.id)
        expect(dismissedRecord?.recordVersion == conflict.recordVersion, "跳过不得改动事实状态")

        // doNotUse → suppression + 语义墓碑，同锚点重生被拦截。
        let rejectStore = HoloMemoryClarificationTestStore(record: conflict)
        let rejectOutcome = try await HoloMemoryClarificationCoordinator.apply(
            answer: .doNotUse,
            to: question,
            in: rejectStore,
            now: now,
            history: HoloMemoryClarificationPromptHistory.empty
        )
        expect(rejectOutcome.outcome.suppressedWithTombstone, "不要使用应写语义墓碑")
        let rejectedRecord = await rejectStore.snapshot(id: conflict.id)
        expect(rejectedRecord?.state == .suppressed, "不要使用后记录应为 suppressed")
        let tombstones = await rejectStore.tombstoneSnapshot()
        expect(
            tombstones.contains { HoloSemanticTombstoneMatcher.matches(tombstone: $0, record: conflict) },
            "墓碑应拦截同锚点重生（不得借澄清通道洗白）"
        )
    }

    // MARK: - 助手

    private static func withFlag(_ key: String, _ value: Bool?, _ body: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        body()
    }

    private static func isNil<T>(_ value: T?) -> Bool {
        if case .none = value { return true }
        return false
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}

/// 澄清写回仓库假件：与统一 Repository 同契约的最小面。
private final class HoloMemoryClarificationTestStore: HoloMemoryClarificationWritebackStore, @unchecked Sendable {
    private var records: [String: HoloMemoryRecord]
    private let control = HoloMemoryControlState.initial(now: Date(timeIntervalSince1970: 0))
    private var tombstones: [HoloMemoryTombstone] = []

    init(record: HoloMemoryRecord) {
        records = [record.id: record]
    }

    func fetch(id: String) async throws -> HoloMemoryRecord? { records[id] }
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }

    func markUserDecision(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool {
        guard var record = records[id] else { return false }
        record.userDecision = decision
        record.recordVersion += 1
        record.updatedAt = now
        if decision == .rejected { record.state = .suppressed }
        records[id] = record
        return true
    }

    func loadControlState() async throws -> HoloMemoryControlState { control }
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {
        tombstones.append(tombstone)
    }

    func snapshot(id: String) -> HoloMemoryRecord? { records[id] }
    func tombstoneSnapshot() -> [HoloMemoryTombstone] { tombstones }
}
