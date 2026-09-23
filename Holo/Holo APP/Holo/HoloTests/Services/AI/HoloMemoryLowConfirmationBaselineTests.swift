import Foundation

/// 记忆低确认成本方案 P0 基线 + P1 修复锁定（方案 §17 P0/P1、§21 纪律 2）。
///
/// 覆盖三块：
/// 1. 【已修复·P1】adviceEligible candidate 被收件箱当作待确认——AttentionPolicy 成为
///    唯一打扰判定入口，开关默认下线每日确认收件箱；断言同时锁定新口径与回滚口径；
/// 2. 【已修复·P5】「不再使用」= suppression + 语义墓碑，同锚点重生被拦截（§8.5）；
/// 3. 基线快照统计（admission 分布 + 稳定身份摘要，P3 迁移对账工具）双口径验证。
///
/// 标注【缺陷锁定】的断言描述的是当前错误行为，修复落地时必须连同断言一起翻转；
/// 标注【对照】的断言锁定正确行为，任何阶段不得回退。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryLowConfirmationBaselineTests.main()
    }
}
#endif
struct HoloMemoryLowConfirmationBaselineTests {
    private static var assertions = 0

    static func main() async throws {
        try await reproductionOfAdviceEligibleInboxMiscount()
        try await reproductionOfNoLongerUseRegeneration()
        try baselineSnapshotStatistics()
        print("HoloMemoryLowConfirmationBaselineTests: \(assertions) assertions passed")
    }

    // MARK: - 缺陷复现一：adviceEligible candidate 被当作待确认（P1 修复）

    private static func reproductionOfAdviceEligibleInboxMiscount() async throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow

        // Reconciler 核验通过后的典型产物：candidate + adviceEligible，
        // 语义是「可作为限定建议背景、不应进入批量确认」（HoloContextAdmissionLevel 注释）。
        let adviceEligibleCandidate = try makeContextRecord(
            statement: "近期记录显示可能更适合上午安排深度工作",
            relationText: "适合上午深度工作",
            claimKind: .hypothesis,
            admission: .adviceEligible,
            now: now
        )
        expect(
            adviceEligibleCandidate.personalContext?.v1?.admission.level == .adviceEligible,
            "前置条件：构造出的记录应为 adviceEligible"
        )
        expect(
            adviceEligibleCandidate.state == .candidate,
            "前置条件：记录处于 candidate 生命周期"
        )

        // 收件箱计数与确认队列共用的统一口径（HoloMemoryReceiptStore.inboxSnapshot /
        // MemoryConfirmationQueueView.load 均以此为过滤条件）。
        expect(
            HoloMemoryUserVisibility.isVisible(adviceEligibleCandidate),
            "对照：adviceEligible candidate 对用户可见（内容本身没问题）"
        )

        // P1 修复口径（开关默认即下线）：adviceEligible candidate 不再进入「想和你确认的」，
        // 全部 candidate 都不构成每日确认任务（方案 §8.2/P1 完成定义）。
        withInboxRollbackFlag(nil) {
            expect(
                !HoloMemoryUserVisibility.isPendingConfirmation(adviceEligibleCandidate),
                "P1：adviceEligible candidate 不再被收件箱当作待确认"
            )
            expect(
                !HoloMemoryAttentionPolicy.requiresDailyConfirmation(adviceEligibleCandidate),
                "P1：AttentionPolicy 判定 adviceEligible candidate 无需用户处理"
            )
        }

        // 回滚口径（UserDefaults 显式写 false）：恢复旧口径，candidate 仍算待确认。
        // 该断言锁定回滚通道真实可用（方案 §18.2）。
        withInboxRollbackFlag(false) {
            expect(
                HoloMemoryUserVisibility.isPendingConfirmation(adviceEligibleCandidate),
                "回滚：显式关闭开关后恢复旧口径（candidate 算待确认）"
            )
        }

        // 对照组：普通 active 记忆不算待确认（两种口径一致）。
        var active = adviceEligibleCandidate
        active.state = .active
        expect(
            !HoloMemoryUserVisibility.isPendingConfirmation(active),
            "对照：active 记忆不算待确认"
        )
        // 对照组：suppressed 不可见。
        var suppressed = adviceEligibleCandidate
        suppressed.state = .suppressed
        expect(
            !HoloMemoryUserVisibility.isPendingConfirmation(suppressed),
            "对照：suppressed 不进入待确认"
        )
        // 长廊 DomainMemorySection 的「想和你确认的」分组与待确认徽章已统一走
        // AttentionPolicy 口径（P1 治理完成；视图走查在模拟器 smoke 覆盖）。
    }

    // MARK: - 缺陷复现二：不再使用后同锚点内容可重生（P5 修复）

    private static func reproductionOfNoLongerUseRegeneration() async throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow
        let original = try makeDomainRecord(now: now)

        // P5 修复锁定：「不再使用」= suppression + 语义墓碑（方案 §8.5/§12.1），
        // 同锚点同命题的重生被语义匹配器拦截，不得因换 ID 或同义改写复活。
        let feedbackStore = HoloMemoryLowConfirmationTestStore(record: original)
        let feedbackService = HoloMemoryFeedbackService(store: feedbackStore)
        let didApply = try await feedbackService.apply(.noLongerUse, to: original.id, now: now)
        expect(didApply, "对照：不再使用反馈本身应成功")
        let tombstonesAfterNoLongerUse = await feedbackStore.tombstoneSnapshot()
        expect(
            tombstonesAfterNoLongerUse.count == 1,
            "P5：不再使用必须写入语义墓碑"
        )
        let suppressedAfterNoLongerUse = await feedbackStore.snapshot(id: original.id)
        expect(
            suppressedAfterNoLongerUse?.state == .suppressed,
            "P5：不再使用后记录应为 suppressed（留痕可审计，不再召回）"
        )
        // 后台重新萃取生成同锚点同 claimKind 的记忆（稳定身份相同）。
        let reborn = try makeDomainRecord(now: now)
        let rebornBlocked = tombstonesAfterNoLongerUse.contains { tombstone in
            HoloSemanticTombstoneMatcher.matches(tombstone: tombstone, record: reborn)
        }
        expect(
            rebornBlocked,
            "P5：不再使用后同锚点内容重生必须被墓碑拦截"
        )

        // 对照组：「忘记」路径先写墓碑再擦除正文，同锚点重生被语义匹配器拦截。
        let forgetStore = HoloMemoryLowConfirmationTestStore(record: original)
        let forgettingService = HoloMemoryForgettingService(store: forgetStore)
        _ = try await forgettingService.forget(id: original.id, now: now)
        let tombstonesAfterForget = await forgetStore.tombstoneSnapshot()
        expect(
            tombstonesAfterForget.count == 1,
            "对照：忘记路径写入一个语义墓碑"
        )
        let forgetRebornBlocked = tombstonesAfterForget.contains { tombstone in
            HoloSemanticTombstoneMatcher.matches(tombstone: tombstone, record: reborn)
        }
        expect(
            forgetRebornBlocked,
            "对照：忘记后同锚点重生被墓碑拦截（现行正确行为，不得回退）"
        )
    }

    // MARK: - 基线快照统计（P0 口径量化 + P3 迁移对账工具）

    private static func baselineSnapshotStatistics() throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow

        let adviceEligibleA = try makeContextRecord(
            statement: "近期记录显示可能更适合上午安排深度工作",
            relationText: "适合上午深度工作",
            claimKind: .hypothesis,
            admission: .adviceEligible,
            now: now
        )
        let adviceEligibleB = try makeContextRecord(
            statement: "从记录看晚间运动完成率更高",
            relationText: "晚间运动完成率高",
            claimKind: .association,
            admission: .adviceEligible,
            now: now
        )
        let confirmationOnly = try makeContextRecord(
            statement: "近期记录显示可能存在阶段性压力",
            relationText: "存在阶段性压力",
            claimKind: .hypothesis,
            admission: .confirmationOnly,
            now: now
        )
        let noContextCandidate = try makeDomainRecord(now: now)
        var activeRecord = try makeDomainRecord(now: now)
        activeRecord.state = .active
        activeRecord.id = activeRecord.id + "-active"
        activeRecord.subjectKey = activeRecord.subjectKey + "-active"

        let records = [adviceEligibleA, adviceEligibleB, confirmationOnly, noContextCandidate, activeRecord]
        let snapshot = HoloMemoryDecisionBaselineSnapshotBuilder.build(records: records, now: now)

        expect(snapshot.recordCount == 5, "快照应统计全量记录数")
        expect(snapshot.candidateTotal == 4, "candidate 专区只统计 candidate")
        expect(
            snapshot.candidateAdmissionCounts[HoloContextAdmissionLevel.adviceEligible.rawValue] == 2,
            "admission 分布应正确统计 adviceEligible 数量"
        )
        expect(
            snapshot.candidateAdmissionCounts[HoloContextAdmissionLevel.confirmationOnly.rawValue] == 1,
            "admission 分布应正确统计 confirmationOnly 数量"
        )
        expect(
            snapshot.candidateAdmissionCounts["noPersonalContext"] == 1,
            "无情境载荷的领域 candidate 计入 noPersonalContext"
        )

        // 回滚口径（开关关闭）：全部 candidate 算待确认，排除 adviceEligible 后剩 2——
        // 这组数字同时是旧缺陷（adviceEligible 被多算 2）的量化存档。
        withInboxRollbackFlag(false) {
            let legacy = HoloMemoryDecisionBaselineSnapshotBuilder.build(records: records, now: now)
            expect(
                legacy.candidatePendingByCurrentRule == 4,
                "回滚口径：全部 candidate 算待确认（旧口径存档）"
            )
            expect(
                legacy.candidatePendingExcludingAdviceEligible == 2,
                "回滚口径：排除 adviceEligible 后 confirmationOnly + noPersonalContext = 2"
            )
        }

        // P1 口径（开关默认）：待确认任务数归零——不再因候选库存要求用户清队列。
        withInboxRollbackFlag(nil) {
            let current = HoloMemoryDecisionBaselineSnapshotBuilder.build(records: records, now: now)
            expect(
                current.candidatePendingByCurrentRule == 0,
                "P1：收件箱下线后 pending 口径归零（完成定义）"
            )
            expect(
                current.candidatePendingExcludingAdviceEligible == 0,
                "P1：排除口径同样归零"
            )
        }

        // 迁移对账摘要：顺序无关、版本变更可检出。
        let reordered = HoloMemoryDecisionBaselineSnapshotBuilder.build(
            records: records.reversed(),
            now: now
        )
        expect(
            reordered.stableIdentityDigest == snapshot.stableIdentityDigest,
            "稳定身份摘要与记录顺序无关"
        )
        var bumped = noContextCandidate
        bumped.recordVersion += 1
        let afterBump = HoloMemoryDecisionBaselineSnapshotBuilder.build(
            records: [adviceEligibleA, adviceEligibleB, confirmationOnly, bumped, activeRecord],
            now: now
        )
        expect(
            afterBump.stableIdentityDigest != snapshot.stableIdentityDigest,
            "recordVersion 变化必须反映到稳定身份摘要（P3 对账依据）"
        )
    }

    // MARK: - 助手

    /// 开关状态管理：nil=删除 key（回到默认=收件箱下线），false=显式回滚旧口径。
    /// 结束后恢复原值，保证不污染同进程内其他测试。
    private static func withInboxRollbackFlag(_ value: Bool?, _ body: () -> Void) {
        let key = HoloMemoryAttentionPolicy.dailyConfirmationInboxDisabledKey
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

    // MARK: - 构造助手

    private static func makeContextRecord(
        statement: String,
        relationText: String,
        claimKind: HoloMemoryClaimKind,
        admission: HoloContextAdmissionLevel,
        now: Date
    ) throws -> HoloMemoryRecord {
        let contextID = "baseline-\(relationText.hashDescription)"
        let payload = HoloPersonalContextPayloadV1(
            contextID: contextID,
            statement: statement,
            relationText: relationText,
            epistemicStatus: .inferred,
            applicability: HoloContextApplicabilityV1(),
            basis: [
                HoloContextBasisRef(sourceID: "\(contextID)-source", quote: statement, sourceRevision: "rev-1")
            ],
            openQuestions: [],
            admission: HoloContextAdmissionV1(level: admission, policyVersion: 1, decidedAt: now)
        )
        let anchor = try HoloMemoryAnchorRef(type: .conversation, value: payload.contextAnchorValue)
        let evidence = HoloMemoryEvidenceRef(
            id: "\(contextID)-evidence",
            kind: .entityRef,
            sourceDomain: .conversation,
            lineageKey: "\(contextID)-lineage",
            revisionDigest: "rev-1",
            observedAt: now,
            summary: statement
        )
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .durable,
            displaySummary: statement,
            aiUseSummary: statement,
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.6,
            freshnessScore: 0.8,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now,
            personalContext: HoloPersonalContextPayloadEnvelope(v1: payload)
        )
    }

    private static func makeDomainRecord(now: Date) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .financeCategory, value: "baseline-dining")
        let evidence = HoloMemoryEvidenceRef(
            id: "baseline-dining-evidence",
            kind: .aggregateSnapshot,
            sourceDomain: .finance,
            lineageKey: "baseline-dining-30d",
            revisionDigest: "rev-1",
            observedAt: now,
            validFrom: now.addingTimeInterval(-30 * 86_400),
            validTo: now,
            aggregateDefinition: "window=30d",
            sampleCount: 30,
            summary: "近 30 天餐饮支出较前一周期上升"
        )
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .finance,
            sourceDomains: [.finance],
            claimKind: .observedFact,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: .finance,
            sourceDomains: [.finance],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .phase,
            displaySummary: "近 30 天餐饮支出较前一周期上升",
            aiUseSummary: "近 30 天餐饮支出较前一周期上升",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: evidence.validFrom,
            validTo: evidence.validTo,
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}

extension String {
    /// 仅用于测试构造稳定字符串键，不做安全用途。
    var hashDescription: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// 本套件私有的反馈存储假件：与 HoloMemoryFeedbackTestStore 同契约，避免跨测试文件耦合。
private final class HoloMemoryLowConfirmationTestStore: HoloMemoryFeedbackStore, @unchecked Sendable {
    private var records: [String: HoloMemoryRecord]
    private let control = HoloMemoryControlState.initial(now: Date(timeIntervalSince1970: 0))
    private var tombstones: [HoloMemoryTombstone] = []

    init(record: HoloMemoryRecord) {
        records = [record.id: record]
    }

    func fetch(id: String) async throws -> HoloMemoryRecord? { records[id] }
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] {
        Array(records.values)
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
        switch decision {
        case .confirmed, .corrected:
            record.state = .active
        case .rejected:
            record.state = .suppressed
        case .forgotten:
            record.state = .tombstoned
            record.displaySummary = ""
            record.aiUseSummary = ""
            record.evidenceRefs = []
        case .none, .markedIrrelevant:
            break
        }
        records[id] = record
        return true
    }

    func loadControlState() async throws -> HoloMemoryControlState { control }
    func saveControlState(_ state: HoloMemoryControlState) async throws {}
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {
        tombstones.append(tombstone)
    }

    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }

    func deleteRecord(id: String) async throws -> Bool {
        records.removeValue(forKey: id) != nil
    }

    func snapshot(id: String) -> HoloMemoryRecord? { records[id] }
    func tombstoneSnapshot() -> [HoloMemoryTombstone] { tombstones }
}
