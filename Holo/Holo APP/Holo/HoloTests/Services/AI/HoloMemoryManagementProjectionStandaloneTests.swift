import Foundation

/// Holo 记忆管理投影验收（方案《Holo 记忆管理独立与升级》§7.1 / §11.2 / §4.1-§4.4）。
///
/// 1. 展示优先级梯子：删除→停用→过去→冲突→观察→已记住→未知版本保守；
/// 2. 桶内字段：时间分组、形成方式、使用标注、适用范围与操作集合；
/// 3. 口径不变量：回答开关只改使用标注不改分组；排序与计数同一投影；
///    删除态不携带正文；未知决策版本保守阻断确认。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryManagementProjectionStandaloneTests.main()
    }
}
#endif
struct HoloMemoryManagementProjectionStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        test删除与墓碑不携带正文且无操作()
        test停用桶按墓碑区分停用原因()
        test过期被替代与来源失效进入过去桶()
        test冲突与候选进入观察桶()
        test五路使用级别分派()
        test未知决策版本保守处理()
        test存量无信封回退状态口径()
        test时间分组与适用范围()
        test形成方式标识()
        test回答开关只改使用标注不改分组()
        test排序与计数使用同一投影()
        test观察桶确认操作的门禁()
        try await test读服务聚合排序与墓碑停用归因()
        try await test读服务查询契约过滤与搜索()
        try await test读服务来源核验钩子注入()
        print("✅ HoloMemoryManagementProjectionStandaloneTests: \(assertions) assertions passed")
    }

    // MARK: - 优先级 1/2：删除与停用

    private static func test删除与墓碑不携带正文且无操作() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        for state in [HoloMemoryState.deleted, .tombstoned] {
            let projection = HoloMemoryManagementProjection.project(
                .init(record: makeRecord(id: "m-del", state: state, displaySummary: "不应出现的正文")),
                context: context
            )
            expect(projection.bucket == .removed, "\(state) 应进 removed 桶")
            expect(projection.displayText.isEmpty, "\(state) 不得携带正文")
            expect(projection.allowedActions.isEmpty, "\(state) 无任何操作")
            expect(projection.unavailableReason == .deleted, "\(state) 不可用原因为 deleted")
        }
    }

    private static func test停用桶按墓碑区分停用原因() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let userStopped = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-sup-1", state: .suppressed, userDecision: .rejected),
                  hasUserControlTombstone: true),
            context: context
        )
        expect(userStopped.bucket == .stopped, "suppressed 应进停用桶")
        expect(userStopped.stoppedCause == .userStopped, "有墓碑应判为不再使用")
        expect(userStopped.allowedActions == [.restore, .delete], "停用桶操作=恢复+删除")

        let inaccurate = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-sup-2", state: .suppressed, userDecision: .rejected)),
            context: context
        )
        expect(inaccurate.stoppedCause == .markedInaccurate, "rejected 无墓碑应判为不准确")

        let legacy = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-sup-3", state: .suppressed, userDecision: .none)),
            context: context
        )
        expect(legacy.stoppedCause == .legacyUnknown, "无法判定原因的存量停用标 legacyUnknown，不编造")
    }

    // MARK: - 优先级 3：过去的记忆

    private static func test过期被替代与来源失效进入过去桶() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let expired = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(
                id: "m-exp", state: .active,
                validTo: now.addingTimeInterval(-86_400),
                decision: makeDecision()
            )),
            context: context
        )
        expect(expired.bucket == .history, "validTo 已过应进过去桶（读取时立即判定，不等后台归档）")
        guard case .expired(let until)? = expired.historyCause else {
            fatalError("❌ 过期原因应携带到期时间")
        }
        expect(until == now.addingTimeInterval(-86_400), "过期原因应携带 validTo")

        let superseded = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-superseded", state: .superseded, decision: makeDecision())),
            context: context
        )
        expect(superseded.bucket == .history && superseded.historyCause == .superseded, "被替代进过去桶")

        let invalidated = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-inv", state: .invalidated, decision: makeDecision())),
            context: context
        )
        expect(invalidated.bucket == .history && invalidated.historyCause == .sourceInvalidated, "来源失效态进过去桶")

        let archived = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-arch", state: .archived, decision: makeDecision())),
            context: context
        )
        expect(archived.bucket == .history && archived.historyCause == .archived, "归档进过去桶")

        // active 但证据来源已删除/被排除：同样进过去桶，且不再提供查看来源。
        let sourceDead = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-src", state: .active, decision: makeDecision()),
                  sourceAvailability: .invalid),
            context: context
        )
        expect(sourceDead.bucket == .history, "来源失效优先于 active，进过去桶")
        expect(sourceDead.historyCause == .sourceInvalidated, "原因=来源失效")
        expect(sourceDead.unavailableReason == .sourceInvalid, "不可用原因=来源失效")
        expect(!sourceDead.allowedActions.contains(.viewSource), "来源失效不提供查看来源")
        expect(!sourceDead.allowedActions.contains(.confirm), "来源失效不能靠确认绕过门禁")
    }

    // MARK: - 优先级 4/5：冲突与候选

    private static func test冲突与候选进入观察桶() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let disputed = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-dis", state: .disputed, decision: makeDecision())),
            context: context
        )
        expect(disputed.bucket == .observing, "未解决冲突进观察桶")
        expect(disputed.observingCause == .conflictPending, "观察原因=待厘清")

        let candidate = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-cand", state: .candidate)),
            context: context
        )
        expect(candidate.bucket == .observing, "候选进观察桶")
        expect(candidate.observingCause == .awaitingEvidence, "观察原因=依据待积累")
        expect(candidate.allowedActions.contains(.confirm), "正常候选可确认")
    }

    // MARK: - 优先级 6：五路使用级别

    private static func test五路使用级别分派() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let fact = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-fact", state: .active, decision: makeDecision(useLevel: .factEligible))),
            context: context
        )
        expect(fact.bucket == .remembered && fact.useLabel == .usableFact, "factEligible 进已记住作事实")
        expect(
            fact.allowedActions == [.correct, .markOutdated, .markInaccurate, .disable, .delete, .viewSource],
            "已记住操作集=纠正/过时/不准确/停用/删除/看来源"
        )

        let qualified = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-qual", state: .active, decision: makeDecision(useLevel: .qualifiedAdvice))),
            context: context
        )
        expect(qualified.bucket == .remembered && qualified.useLabel == .referenceOnly, "qualifiedAdvice 进已记住标仅作参考")

        let observeOnly = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-obs", state: .active, decision: makeDecision(useLevel: .observeOnly))),
            context: context
        )
        expect(observeOnly.bucket == .observing, "observeOnly 进观察桶")
        expect(observeOnly.useLabel == .notUsedForAnswers, "observeOnly 不用于回答")
        expect(observeOnly.observingCause == .observeOnly, "观察原因=仅可限定参考")

        let blocked = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-blk", state: .active, decision: makeDecision(useLevel: .blocked))),
            context: context
        )
        expect(blocked.bucket == .observing, "blocked 不进正常已记住")
        expect(blocked.useLabel == .conservativelyBlocked, "blocked 保守不使用")
        expect(!blocked.allowedActions.contains(.confirm), "禁止性推断不提供确认")
        expect(blocked.unavailableReason == .blockedByPolicy, "不可用原因=策略阻断")

        let clarification = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(
                id: "m-clar", state: .active,
                decision: makeDecision(
                    useLevel: .factEligible,
                    attentionPolicy: .askWhenRelevant,
                    clarification: HoloMemoryClarificationMetadata(
                        logicalQuestionKey: "k", missingVariable: "v", impactSummary: "i",
                        options: ["a", "b"], lastPromptedAt: nil, cooldownUntil: nil,
                        promptCount: 0, materialEvidenceRevisionAtLastPrompt: nil
                    )
                )
            )),
            context: context
        )
        expect(clarification.bucket == .observing, "未完成澄清的 askWhenRelevant 进观察桶")
        expect(clarification.observingCause == .awaitingClarification, "观察原因=待澄清")
    }

    // MARK: - 优先级 7：未知版本

    private static func test未知决策版本保守处理() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let unknown = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(
                id: "m-unk", state: .active,
                decisionEnvelope: HoloMemoryDecisionMetadataEnvelope(unknownVersion: 99, rawJSON: "{\"x\":1}")
            )),
            context: context
        )
        expect(unknown.bucket == .observing, "未知版本不作为正常已记住")
        expect(unknown.useLabel == .conservativelyBlocked, "未知版本保守不使用")
        expect(unknown.unavailableReason == .unknownDecisionVersion, "不可用原因=未知决策版本")
        expect(!unknown.allowedActions.contains(.confirm), "未知版本不提供确认")
        expect(unknown.allowedActions.contains(.disable), "未知版本仍可停用/删除")
    }

    private static func test存量无信封回退状态口径() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let legacy = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-legacy", state: .active)),
            context: context
        )
        expect(legacy.bucket == .remembered, "存量 active 无信封按状态口径进已记住（不因缺元数据隐藏存量）")
        expect(legacy.useLabel == .usableFact, "存量回退按事实可用（与 QueryService 现行口径一致）")
        expect(legacy.originLabel == .autoFormed, "无用户决策标 Holo 推断")
    }

    // MARK: - 桶内字段

    private static func test时间分组与适用范围() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let durable = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-dur", state: .active,
                                     persistenceClass: .durable, decision: makeDecision())),
            context: context
        )
        expect(durable.timeGroup == .longTerm, "durable → 长期了解")
        expect(durable.effectiveRange == .longTerm, "durable 适用范围=长期")

        let phase = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-phase", state: .active,
                                     persistenceClass: .currentState, decision: makeDecision())),
            context: context
        )
        expect(phase.timeGroup == .recent, "currentState → 最近这段时间")
        expect(phase.effectiveRange == .currentPhase, "currentState 适用范围=当前阶段")

        let bounded = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(
                id: "m-bound", state: .active,
                persistenceClass: .durable,
                validTo: now.addingTimeInterval(30 * 86_400),
                decision: makeDecision()
            )),
            context: context
        )
        expect(bounded.timeGroup == .recent, "用户指定的更窄范围优先，bounded → 近期")
        guard case .bounded(let until) = bounded.effectiveRange else {
            fatalError("❌ bounded 适用范围应携带到期时间")
        }
        expect(until == now.addingTimeInterval(30 * 86_400), "bounded 携带 validTo")
    }

    private static func test形成方式标识() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let confirmed = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-c1", state: .active,
                                     userDecision: .confirmed, decision: makeDecision())),
            context: context
        )
        expect(confirmed.originLabel == .userConfirmed, "userDecision confirmed → 你确认过")

        let corrected = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-c2", state: .active,
                                     userDecision: .corrected, decision: makeDecision())),
            context: context
        )
        expect(corrected.originLabel == .userCorrected, "userDecision corrected → 你纠正过")

        let added = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-c3", state: .active,
                                     decision: makeDecision(sourceAuthority: .explicitMemoryRequest))),
            context: context
        )
        expect(added.originLabel == .userAdded, "explicitMemoryRequest → 你添加")

        let stated = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-c4", state: .active,
                                     decision: makeDecision(sourceAuthority: .explicitUserStatement))),
            context: context
        )
        expect(stated.originLabel == .userConfirmed, "explicitUserStatement → 用户声明按确认标识")
    }

    // MARK: - 口径不变量

    private static func test回答开关只改使用标注不改分组() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let off = HoloMemoryManagementProjectionContext(now: now, answeringEnabled: false)

        let remembered = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-p1", state: .active, decision: makeDecision())),
            context: off
        )
        expect(remembered.bucket == .remembered, "回答开关关闭不改分组")
        expect(remembered.useLabel == .usableFact, "内容使用资格不变")
        expect(remembered.isPausedForAnswering, "已记住统一标注暂停使用")
        expect(remembered.allowedActions.contains(.disable), "管理能力照常可用")

        let observing = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-p2", state: .active,
                                     decision: makeDecision(useLevel: .observeOnly))),
            context: off
        )
        expect(!observing.isPausedForAnswering, "暂停标注只作用于已记住桶")
    }

    private static func test排序与计数使用同一投影() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: base)

        let older = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "a-old", state: .active, decision: makeDecision(),
                                     updatedAt: base.addingTimeInterval(-100))),
            context: context
        )
        let newer = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "b-new", state: .active, decision: makeDecision(),
                                     updatedAt: base.addingTimeInterval(-10))),
            context: context
        )
        let tieA = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "x-tie", state: .candidate, updatedAt: base.addingTimeInterval(-10))),
            context: context
        )
        expect(HoloMemoryManagementProjection.isInOrder(newer, before: older), "更新时间倒序")
        expect(HoloMemoryManagementProjection.isInOrder(newer, before: tieA), "候选不因使用统计改变排序（同刻比 id）")
        expect(!HoloMemoryManagementProjection.isInOrder(tieA, before: newer), "同更新时间按稳定 ID 升序（b-new 在前）")

        let removed = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "z-del", state: .deleted, updatedAt: base)),
            context: context
        )
        let stopped = HoloMemoryManagementProjection.project(
            .init(
                record: makeRecord(id: "c-stop", state: .suppressed, userDecision: .rejected, updatedAt: base),
                hasUserControlTombstone: true
            ),
            context: context
        )
        let summary = HoloMemoryManagementProjection.summarize([older, newer, tieA, removed, stopped])
        expect(summary.remembered == 2, "计数与列表同一投影：已记住 2")
        expect(summary.observing == 1, "观察 1")
        expect(summary.stopped == 1, "停用 1")
        expect(summary.history == 0, "过去 0")
    }

    private static func test观察桶确认操作的门禁() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        let sourceDead = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-g1", state: .candidate), sourceAvailability: .invalid),
            context: context
        )
        expect(!sourceDead.allowedActions.contains(.confirm), "来源失效的候选不能确认")
        expect(!sourceDead.allowedActions.contains(.viewSource), "来源失效不提供查看来源")
        expect(sourceDead.unavailableReason == .sourceInvalid, "不可用原因=来源失效")

        let pending = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "m-g2", state: .candidate), sourceAvailability: .available),
            context: context
        )
        expect(pending.allowedActions.contains(.confirm), "来源可用的候选可确认")
        expect(pending.allowedActions.contains(.viewSource), "来源可提供查看")
    }

    // MARK: - 读服务（M02b）

    private static func test读服务聚合排序与墓碑停用归因() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = MockManagementReadRepository()
        for record in [
            makeRecord(id: "r-old", state: .active, decision: makeDecision(),
                       updatedAt: now.addingTimeInterval(-100)),
            makeRecord(id: "r-new", state: .active, decision: makeDecision(),
                       updatedAt: now.addingTimeInterval(-5)),
            makeRecord(id: "r-cand", state: .candidate, updatedAt: now.addingTimeInterval(-50)),
            makeRecord(id: "r-sup", state: .suppressed, userDecision: .rejected,
                       updatedAt: now.addingTimeInterval(-70))
        ] {
            repository.records[record.id] = record
        }
        repository.tombstones = [
            HoloMemoryTombstone(
                identityKey: "r-sup", scope: .domain, claimKind: .observedFact,
                anchorKeys: ["a"], userDecisionVersion: 2, createdAt: now
            )
        ]
        let service = HoloMemoryManagementReadService(repository: repository)

        let snapshot = try await service.loadSnapshot(answeringEnabled: true, now: now)

        expect(snapshot.projections.count == 4, "全量记录进快照")
        expect(snapshot.projections.map(\.recordID) == ["r-new", "r-cand", "r-sup", "r-old"],
               "快照按更新时间倒序")
        expect(snapshot.summary.remembered == 2 && snapshot.summary.observing == 1 && snapshot.summary.stopped == 1,
               "计数与列表同一投影")
        let stopped = snapshot.projections.first { $0.recordID == "r-sup" }
        expect(stopped?.stoppedCause == .userStopped, "墓碑 identityKey=记录 id → 归因为不再使用")
    }

    private static func test读服务查询契约过滤与搜索() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = MockManagementReadRepository()
        let coffee = makeRecord(id: "r-coffee", state: .active, displaySummary: "不喝咖啡，偏好无糖茶",
                                decision: makeDecision())
        let running = makeRecord(id: "r-run", state: .active, displaySummary: "最近把跑步挪到了晚上",
                                 decision: makeDecision())
        repository.records[coffee.id] = coffee
        repository.records[running.id] = running
        let service = HoloMemoryManagementReadService(repository: repository)
        let snapshot = try await service.loadSnapshot(answeringEnabled: true, now: now)

        let remembered = snapshot.applying(.init(bucket: .remembered))
        expect(remembered.count == 2, "桶过滤")
        expect(snapshot.applying(.init(bucket: .remembered, timeGroup: .longTerm)).count == 2,
               "durable 默认 → 长期组过滤命中")
        let searched = snapshot.applying(.init(bucket: .remembered, searchText: "咖啡"))
        expect(searched.map(\.recordID) == ["r-coffee"], "本地文本搜索只命中当前陈述")
        expect(snapshot.applying(.init(bucket: .observing, searchText: "咖啡")).isEmpty,
               "搜索默认作用于当前查询的桶")
    }

    private static func test读服务来源核验钩子注入() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = MockManagementReadRepository()
        for record in [
            makeRecord(id: "r-ok", state: .active, decision: makeDecision()),
            makeRecord(id: "r-dead", state: .active, decision: makeDecision())
        ] {
            repository.records[record.id] = record
        }
        let service = HoloMemoryManagementReadService(
            repository: repository,
            sourceVerifier: DeadSourceMarkerVerifier(deadIDs: ["r-dead"])
        )
        let snapshot = try await service.loadSnapshot(answeringEnabled: true, now: now)

        let dead = snapshot.projections.first { $0.recordID == "r-dead" }
        expect(dead?.bucket == .history, "核验器判来源失效 → 进过去桶")
        expect(dead?.historyCause == .sourceInvalidated, "原因=来源失效")
        let alive = snapshot.projections.first { $0.recordID == "r-ok" }
        expect(alive?.bucket == .remembered, "来源可用的正常进已记住")
    }

    // MARK: - Fixtures

    private static func makeRecord(
        id: String,
        state: HoloMemoryState,
        userDecision: HoloMemoryUserDecision = .none,
        persistenceClass: HoloMemoryPersistenceClass = .durable,
        displaySummary: String = "不喝咖啡，偏好无糖茶",
        validTo: Date? = nil,
        expiresAt: Date? = nil,
        decision: HoloMemoryDecisionMetadataV2? = nil,
        decisionEnvelope: HoloMemoryDecisionMetadataEnvelope? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_799_900_000)
    ) -> HoloMemoryRecord {
        HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            subjectKey: "subject-\(id)",
            anchorRefs: [],
            claimKind: .observedFact,
            persistenceClass: persistenceClass,
            displaySummary: displaySummary,
            aiUseSummary: displaySummary,
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: nil,
            validTo: validTo,
            lastSupportedAt: nil,
            expiresAt: expiresAt,
            confidenceScore: 0.9,
            freshnessScore: 0.8,
            scoringVersion: 1,
            scoreComputedAt: updatedAt,
            extractorVersion: 1,
            promptVersion: 1,
            lastObservationKey: nil,
            state: state,
            sensitivity: .normal,
            userDecision: userDecision,
            adoptionMetadata: nil,
            recordVersion: 1,
            predecessorVersionID: nil,
            supersedesMemoryID: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            schemaVersion: 1,
            usageCount: nil,
            lastUsedAt: nil,
            personalContext: nil,
            decisionMetadata: decisionEnvelope ?? decision.map { HoloMemoryDecisionMetadataEnvelope(v2: $0) }
        )
    }

    private static func makeDecision(
        useLevel: HoloMemoryUseLevel = .factEligible,
        attentionPolicy: HoloMemoryAttentionPolicyKind = .silent,
        sourceAuthority: HoloMemorySourceAuthority = .structuredObservation,
        clarification: HoloMemoryClarificationMetadata? = nil
    ) -> HoloMemoryDecisionMetadataV2 {
        HoloMemoryDecisionMetadataV2(
            policyVersion: 4,
            sourceAuthority: sourceAuthority,
            evidenceVerdict: .supported,
            impactLevel: .low,
            persistencePermission: .durable,
            useLevel: useLevel,
            attentionPolicy: attentionPolicy,
            reasonCodes: [],
            evaluatedAt: Date(timeIntervalSince1970: 1_799_000_000),
            evidenceRevision: "rev-1",
            clarification: clarification
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            fatalError("❌ \(message)")
        }
    }
}

/// 读服务专用 mock：只实现读路径，写路径全部无操作（读服务只读不写）。
final class MockManagementReadRepository: HoloMemoryRepository, @unchecked Sendable {    var records: [String: HoloMemoryRecord] = [:]
    var tombstones: [HoloMemoryTombstone] = []

    func upsert(_ record: HoloMemoryRecord, observationKey: String?) async throws -> HoloMemoryUpsertResult {
        let existed = records[record.id] != nil
        records[record.id] = record
        return existed ? .updated : .inserted
    }
    func hasSuccessfulObservation(_ key: String) async throws -> Bool { false }
    func applyObservationBatch(
        _ records: [HoloMemoryRecord], observationKey: String, domain: HoloMemoryDomain,
        extractorVersion: Int, promptVersion: Int, completedAt: Date
    ) async throws -> [HoloMemoryUpsertResult] { [] }
    func fetch(id: String) async throws -> HoloMemoryRecord? { records[id] }
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] {
        switch query {
        case .all: return Array(records.values)
        case .active: return records.values.filter { $0.state == .active }
        case .domain(let domain): return records.values.filter { $0.primaryDomain == domain }
        }
    }
    func markUserDecision(id: String, decision: HoloMemoryUserDecision, now: Date) async throws -> Bool { false }
    func supersede(id: String, replacementVersionID: String, now: Date) async throws -> Bool { false }
    func storageCounts() async throws -> HoloMemoryStorageCounts {
        HoloMemoryStorageCounts(mainRecords: records.count, sensitiveRecords: 0)
    }
    func loadControlState() async throws -> HoloMemoryControlState { .initial() }
    func saveControlState(_ state: HoloMemoryControlState) async throws {}
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {
        tombstones.append(tombstone)
    }
    func fetchTombstone(identityKey: String) async throws -> HoloMemoryTombstone? {
        tombstones.first { $0.identityKey == identityKey }
    }
    func queryTombstones() async throws -> [HoloMemoryTombstone] { tombstones }
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }
    func recordUsage(ids: [String], now: Date) async throws {}
    func replaceRecordForMigration(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }
    func hardDeleteRecordForMigration(id: String) async throws {
        records[id] = nil
    }
    func deleteTombstoneForMigration(identityKey: String) async throws {
        tombstones.removeAll { $0.identityKey == identityKey }
    }
}

/// 标记指定记录来源失效的核验器（测试用）。
final class DeadSourceMarkerVerifier: HoloMemorySourceAvailabilityVerifying {
    let deadIDs: Set<String>

    init(deadIDs: Set<String>) {
        self.deadIDs = deadIDs
    }

    func availability(of record: HoloMemoryRecord) async -> HoloMemoryManagementSourceAvailability {
        deadIDs.contains(record.id) ? .invalid : .available
    }
}
