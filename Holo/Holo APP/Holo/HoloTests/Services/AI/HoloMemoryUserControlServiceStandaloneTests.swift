import Foundation

/// M04 控制服务验收（方案 §6 操作矩阵 / §11.6 最小落库效果）。
///
/// 七操作全链路（预检→事务→事件账本→墓碑）+ 撤销规则 +
/// 「改一下」的结构化同步（用户陈述/AI 摘要/个人情境三处一致）。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryUserControlServiceStandaloneTests.main()
    }
}
#endif
struct HoloMemoryUserControlServiceStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test确认候选进入已记住并记账()
        try await test纠正三处同步并升版本()
        try await test过时与判错()
        try await test停用写墓碑()
        try await test删除清正文()
        try await test恢复解除墓碑并重新落位()
        try await test撤销停用回到原位()
        try await test撤销确认退回原位不保级()
        try await test有较新操作时撤销冲突()
        try await test纠正撤销如实拒绝()
        try await test预检拒绝来源失效()
        try await test删除连带依赖失效()
        test停用记忆不得进入回答上下文()
        print("✅ HoloMemoryUserControlServiceStandaloneTests: \(assertionCount) assertions passed")
    }

    private static func makeStack() throws -> (repository: CoreDataHoloMemoryRepository,
                                               service: HoloMemoryUserControlService) {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        return (repository, HoloMemoryUserControlService(repository: repository, eventStore: store))
    }

    private static func request(
        _ action: HoloMemoryUserControlAction,
        record: HoloMemoryRecord,
        operationID: String = "op-\(UUID().uuidString.prefix(8))"
    ) -> HoloMemoryUserControlRequest {
        HoloMemoryUserControlRequest(
            operationID: operationID,
            recordID: record.id,
            expectedContentVersion: record.recordVersion,
            action: action,
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private static func test确认候选进入已记住并记账() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "confirm-me", state: .candidate)
        try await repository.upsert(record, observationKey: nil)
        let projection = project(record)

        let outcome = try await service.apply(request(.confirm, record: record), projection: projection)
        expect(outcome.isSuccess, "确认成功")
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .active && after?.userDecision == .confirmed, "候选确认后 active+confirmed")
        expect((after?.confidenceScore ?? 0) >= 0.95, "确认抬升置信度")
        let events = try await service.eventStore.events(forRecordID: record.id)
        expect(events.count == 1 && events[0].kind == .confirmed, "账本记一笔 confirmed")
    }

    private static func test纠正三处同步并升版本() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "correct-me", state: .active)
        try await repository.upsert(record, observationKey: nil)

        let outcome = try await service.apply(
            request(.correct(statement: "改成晚上跑步"), record: record),
            projection: project(record)
        )
        guard case .applied(let newVersion, _) = outcome else {
            fatalError("❌ 纠正应成功并返回新版本")
        }
        expect(newVersion == record.recordVersion + 1, "纠正升内容版本")
        let after = try await repository.fetch(id: record.id)
        expect(after?.displaySummary == "改成晚上跑步", "用户陈述更新")
        expect(after?.aiUseSummary == "改成晚上跑步", "AI 摘要同步")
        expect(after?.predecessorVersionID == "\(record.id)@v\(record.recordVersion)", "版本链前驱正确")
        // personalContext.v1?.statement 的同步（信封存在时）见服务实现；
        // 信封的完整构造与差异矩阵随 M05 载荷批一并验收。
    }

    private static func test过时与判错() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "outdate-me", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(request(.markOutdated, record: record), projection: project(record))
        var after = try await repository.fetch(id: record.id)
        expect(after?.state == .archived, "过时 → 过去的记忆")

        _ = try await service.apply(request(.markInaccurate(reason: "说反了"), record: record), projection: nil)
        after = try await repository.fetch(id: record.id)
        expect(after?.state == .suppressed && after?.userDecision == .rejected, "判错 → 停用桶")
    }

    private static func test停用写墓碑() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "disable-me", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(request(.disable, record: record), projection: project(record))
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .suppressed, "停用生效")
        let tombstone = try await repository.fetchTombstone(identityKey: record.id)
        expect(tombstone != nil, "停用写命题墓碑（防同命题重生）")
    }

    private static func test删除清正文() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "forget-me", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(request(.forget, record: record), projection: project(record))
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .tombstoned && after?.userDecision == .forgotten, "删除态落库")
        expect(after?.displaySummary.isEmpty == true && after?.aiUseSummary.isEmpty == true, "正文清除")
        expect(after?.evidenceRefs.isEmpty == true, "证据引用清除（§9.2）")
        let tombstone = try await repository.fetchTombstone(identityKey: record.id)
        expect(tombstone != nil, "保留最小阻断墓碑")
        expect(after?.subjectKey.isEmpty == true, "主题键清除")
        expect(after?.prohibitedInferences.isEmpty == true, "禁止推断文本清除")
        expect(after?.usageCount == nil && after?.lastUsedAt == nil, "使用统计清除")
    }

    private static func test删除连带依赖失效() async throws {
        let (repository, service) = try makeStack()
        let upstream = try makeRecord(anchor: "upstream-src", state: .active)
        try await repository.upsert(upstream, observationKey: nil)
        var dependent = try makeRecord(anchor: "derived-view", state: .active)
        dependent.upstreamMemoryIDs = [upstream.id]
        try await repository.upsert(dependent, observationKey: nil)

        _ = try await service.apply(request(.forget, record: upstream), projection: project(upstream))
        let afterDependent = try await repository.fetch(id: dependent.id)
        expect(afterDependent?.state == .invalidated, "上游删除 → 依赖派生记忆失效进过去桶（§9.2）")
    }

    private static func test停用记忆不得进入回答上下文() {
        // M06：带载荷的停用记录必须被统一判据挡在规划/情境之外（修复前会漏）。
        var stopped = try! makeRecord(anchor: "stopped-context", state: .suppressed)
        stopped.userDecision = .rejected
        let active = try! makeRecord(anchor: "active-context", state: .active)
        let eligible = HoloMemoryAnswerEligibility.filter([stopped, active])
        expect(eligible.count == 1 && eligible.first?.id == active.id,
               "停用记录被挡、active 记录放行")
    }

    private static func test恢复解除墓碑并重新落位() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "restore-me", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(request(.disable, record: record), projection: project(record))
        _ = try await service.apply(
            HoloMemoryUserControlRequest(
                operationID: "op-restore",
                recordID: record.id,
                expectedContentVersion: record.recordVersion,
                action: .restore,
                issuedAt: Date()
            ),
            projection: nil
        )
        let after = try await repository.fetch(id: record.id)
        // fixture 无决策信封 → 恢复落观察（保守），不直接进已记住。
        expect(after?.state == .candidate && after?.userDecision == HoloMemoryUserDecision.none, "无决策信封恢复回观察（保守）")
        let tombstone = try await repository.fetchTombstone(identityKey: record.id)
        expect(tombstone == nil, "恢复解除墓碑（§6.2）")
    }

    private static func test撤销停用回到原位() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "undo-me", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(
            request(.disable, record: record, operationID: "op-disable-x"),
            projection: project(record)
        )
        let outcome = try await service.apply(
            request(.undo(operationID: "op-disable-x"), record: record),
            projection: nil
        )
        expect(outcome.isSuccess, "撤销成功")
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .candidate && after?.userDecision == HoloMemoryUserDecision.none, "撤销停用回到原位（无信封 → 观察）")
        let tombstone = try await repository.fetchTombstone(identityKey: record.id)
        expect(tombstone == nil, "撤销一并解除墓碑")
    }

    private static func test撤销确认退回原位不保级() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "undo-confirm", state: .candidate)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(
            request(.confirm, record: record, operationID: "op-cf"),
            projection: project(record)
        )
        var after = try await repository.fetch(id: record.id)
        expect(after?.state == .active, "确认晋升 active")

        _ = try await service.apply(
            request(.undo(operationID: "op-cf"), record: record),
            projection: nil
        )
        after = try await repository.fetch(id: record.id)
        expect(after?.state == .candidate && after?.userDecision == HoloMemoryUserDecision.none,
               "撤销确认退回观察位，不凭空保级")
    }

    private static func test有较新操作时撤销冲突() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "undo-conflict", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(
            request(.disable, record: record, operationID: "op-first"),
            projection: project(record)
        )
        // 中间插入新操作后，旧操作的撤销必须冲突（A18：不静默覆盖较新控制）。
        _ = try await service.apply(
            request(.markOutdated, record: record, operationID: "op-second"),
            projection: nil
        )
        let outcome = try await service.apply(
            request(.undo(operationID: "op-first"), record: record),
            projection: nil
        )
        guard case .conflict = outcome else {
            fatalError("❌ 非最新操作的撤销应冲突")
        }
    }

    private static func test纠正撤销如实拒绝() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "undo-correct", state: .active)
        try await repository.upsert(record, observationKey: nil)

        _ = try await service.apply(
            request(.correct(statement: "新说法"), record: record, operationID: "op-c"),
            projection: project(record)
        )
        let outcome = try await service.apply(
            request(.undo(operationID: "op-c"), record: record),
            projection: nil
        )
        expect(!outcome.isSuccess, "纠正撤销需旧正文差异（M05），当前如实拒绝")
    }

    private static func test预检拒绝来源失效() async throws {
        let (repository, service) = try makeStack()
        let record = try makeRecord(anchor: "precheck-dead", state: .candidate)
        try await repository.upsert(record, observationKey: nil)
        let deadProjection = HoloMemoryManagementProjection.project(
            .init(record: record, sourceAvailability: .invalid),
            context: HoloMemoryManagementProjectionContext(now: Date())
        )

        let outcome = try await service.apply(request(.confirm, record: record), projection: deadProjection)
        guard case .notAllowed(let reason) = outcome, reason == .sourceInvalid else {
            fatalError("❌ 来源失效的确认应被预检拒绝")
        }
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .candidate, "被拒路径记录不动（保存成功才展示成功）")
    }

    // MARK: - Fixtures

    private static func project(
        _ record: HoloMemoryRecord,
        availability: HoloMemoryManagementSourceAvailability = .available
    ) -> HoloMemoryManagementProjection {
        HoloMemoryManagementProjection.project(
            .init(record: record, sourceAvailability: availability),
            context: HoloMemoryManagementProjectionContext(now: Date())
        )
    }

    private static func makeRecord(
        anchor: String,
        state: HoloMemoryState
    ) throws -> HoloMemoryRecord {
        let anchorRef = try HoloMemoryAnchorRef(type: .userTheme, value: anchor)
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            claimKind: .recurringPattern,
            anchors: [anchorRef]
        )
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            subjectKey: anchor,
            anchorRefs: [anchorRef],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "\(anchor) 的阶段结论",
            aiUseSummary: "用户近期呈现 \(anchor)",
            prohibitedInferences: [],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: "ev-1", kind: .entityRef, sourceDomain: .conversation,
                lineageKey: "lineage-ev-1", sourceID: "ev-1",
                revisionDigest: "rev-1", observedAt: now
            )],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }
}
