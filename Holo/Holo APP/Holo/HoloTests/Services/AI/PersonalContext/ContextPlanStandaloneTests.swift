//
//  ContextPlanStandaloneTests.swift
//  HoloTests
//
//  P6 规划核心验证：草案解析与容错、验证器（证据引用/依赖环/重复/伪造日期/
//  已完成实例/未知上限）、状态机（闸关闭/迟到结果丢弃/取消/追问修订/代际变化/
//  一次修复/预算耗尽）、prompt 组装。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ContextPlanStandaloneTests.main()
    }
}
#endif
struct ContextPlanStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        testDraftParserTolerant()
        testValidatorRules()
        testValidatorCycleDetection()
        try await testCoordinatorHappyPath()
        try await testCoordinatorEmptyArchiveAnswerOnly()
        try await testCoordinatorCancelledRunDiscardsLateResult()
        try await testCoordinatorFollowUpAdvancesRevision()
        try await testCoordinatorRepairOnceThenDeliver()
        try await testCoordinatorBudgetExhaustedFails()
        try await testCoordinatorGateClosed()
        try await testCoordinatorGenerationChanged()
        testPlanPromptComposition()
        testReceiptReconciliation()
        testBasisSnapshot()
        testPlanEffectsContract()
        print("ContextPlanStandaloneTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 工厂

    static func contextEntry(
        contextID: String,
        statement: String,
        occurrenceStatus: HoloContextOccurrence.Status? = nil
    ) -> HoloContextCatalogEntry {
        HoloContextCatalogEntry(
            recordID: "rec-\(contextID)",
            versionID: "rec-\(contextID)@v1",
            payload: HoloPersonalContextPayloadV1(
                contextID: contextID,
                statement: statement,
                relationText: statement,
                epistemicStatus: .declared,
                admission: HoloContextAdmissionV1(
                    level: .adviceEligible,
                    policyVersion: 1,
                    decidedAt: Date(timeIntervalSince1970: 0)
                )
            ),
            needsQualifiedExpression: false,
            currentOccurrenceStatus: occurrenceStatus
        )
    }

    static func frame() -> HoloPlanningRequestFrame {
        HoloPlanningRequestFrame(
            utterance: "帮我想想下周末爸妈来怎么安排",
            goalSummary: "安排父母来访周末行程",
            referenceTime: Date(timeIntervalSince1970: 1_789_000_000)
        )
    }

    static func validGuard() -> HoloContextAccessGuard {
        HoloContextAccessGuard(
            userDecisionVersion: 10,
            learningBaselineAt: nil,
            controls: HoloPersonalContextControlSnapshot(
                extractionKillEnabled: true, retrievalKillEnabled: true,
                planningInjectionKillEnabled: true, rawFallbackKillEnabled: true,
                isInternalAccount: true, automaticMemoryEnabled: true,
                memoryAssistedAnsweringEnabled: true, aiDataProcessingConsentGranted: true
            ),
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// 可编排生成器：按队列返回；可统计调用。
    final class FakeGenerator: HoloContextPlanGenerating, @unchecked Sendable {
        var responses: [String] = []
        private(set) var callCount = 0
        func generate(prompt: String) async throws -> String {
            callCount += 1
            guard !responses.isEmpty else {
                return "{\"goalSummary\":\"g\",\"answerText\":\"基础回答\"}"
            }
            return responses.removeFirst()
        }
    }

    /// 固定代际提供方（可变，用于竞态模拟）。
    final class GuardBox: @unchecked Sendable {
        var guard0 = ContextPlanStandaloneTests.validGuard()
    }

    static func makeCoordinator(
        generator: FakeGenerator,
        contexts: [HoloContextCatalogEntry] = [],
        guardBox: GuardBox = GuardBox()
    ) -> (HoloContextPlanningCoordinator, HoloPlanningInMemoryRunPersistence, GuardBox) {
        let persistence = HoloPlanningInMemoryRunPersistence()
        // catalog 走空检索服务（无语义 provider）——直接给固定 contexts 需要绕过检索；
        // 测试用自定义 recordsProvider + 无信号的 catalog 会拿不到条目，
        // 因此这里用一个固定返回的语义假件保证命中。
        let semantic = FixedSemanticProvider(recordIDs: Set(contexts.map(\.recordID)))
        let retrieval = HoloContextRetrievalService(semanticProvider: semantic)
        // recordsProvider 返回带载荷的记录（政策筛选后成为 catalog）。
        var records: [HoloMemoryRecord] = []
        for entry in contexts {
            let anchor = try! HoloMemoryAnchorRef(
                type: .userTheme, value: entry.payload.contextAnchorValue
            )
            records.append(HoloMemoryRecord(
                id: entry.recordID,
                scope: .domain,
                primaryDomain: .thought,
                sourceDomains: [.thought],
                subjectKey: "个人情境",
                anchorRefs: [anchor],
                claimKind: .observedFact,
                persistenceClass: .durable,
                displaySummary: entry.payload.statement,
                aiUseSummary: entry.payload.statement,
                prohibitedInferences: [],
                evidenceRefs: [],
                upstreamMemoryIDs: [],
                counterEvidenceRefs: [],
                confidenceScore: 0.5,
                freshnessScore: 0.5,
                scoringVersion: 1,
                scoreComputedAt: Date(timeIntervalSince1970: 0),
                extractorVersion: 1,
                promptVersion: 1,
                state: .candidate,
                sensitivity: .normal,
                userDecision: .none,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                personalContext: HoloPersonalContextPayloadEnvelope(v1: entry.payload)
            ))
        }
        let box = guardBox
        let coordinator = HoloContextPlanningCoordinator(
            generator: generator,
            retrieval: retrieval,
            persistence: persistence,
            recordsProvider: { records },
            controlSnapshotProvider: { box.guard0 }
        )
        return (coordinator, persistence, box)
    }

    /// 固定命中语义假件（按 recordID 给分，与检索服务的查键一致）。
    final class FixedSemanticProvider: HoloContextSemanticSearchProviding, @unchecked Sendable {
        let recordIDs: Set<String>
        init(recordIDs: Set<String>) { self.recordIDs = recordIDs }
        func semanticCandidateIDs(query: String, directions: [String]) async throws -> [String: Double] {
            Dictionary(uniqueKeysWithValues: recordIDs.map { ($0, 0.9) })
        }
    }

    static func draftJSON(
        answer: String = "已结合你的情况给出安排建议。",
        items: String = "[]",
        unknowns: String = "[]",
        edges: String = "[]",
        usedRefs: String = "[]"
    ) -> String {
        """
        {"goalSummary":"安排行程","answerText":"\(answer)","usedContextRefs":\(usedRefs),"items":\(items),"unknowns":\(unknowns),"dependencyEdges":\(edges),"coverage":{"readSources":[],"missingScopes":[],"externalFactsVerified":false}}
        """
    }

    // MARK: 解析器

    static func testDraftParserTolerant() {
        // 围栏 + 噪声 + 缺可选字段。
        let raw = """
        结果如下：
        ```json
        {"answerText":"可以直接阅读的回答"}
        ```
        """
        let draft = try! HoloContextPlanDraftParser.parse(raw, runID: "run-1", draftRevision: 1)
        expect(draft.answerText == "可以直接阅读的回答", "answerText 兜底必填")
        expect(draft.items.isEmpty && draft.unknowns.isEmpty, "缺可选字段默认空")

        // 缺 answerText → 明确错误（不得静默）。
        do {
            _ = try HoloContextPlanDraftParser.parse(
                "{\"goalSummary\":\"g\"}", runID: "run-1", draftRevision: 1
            )
            expect(false, "缺 answerText 应抛错")
        } catch {
            expect(true, "缺 answerText 抛 missingAnswerText")
        }
        // unknowns 超上限截断到 2。
        let many = """
        {"answerText":"a","unknowns":[{"question":"q1"},{"question":"q2"},{"question":"q3"}]}
        """
        let truncated = try! HoloContextPlanDraftParser.parse(many, runID: "run-1", draftRevision: 1)
        expect(truncated.unknowns.count == 2, "未知问题截断到 2 个")
    }

    // MARK: 验证器

    static func testValidatorRules() {
        let contexts = [
            contextEntry(contextID: "ctx-salt", statement: "父亲被要求低盐饮食"),
            contextEntry(contextID: "ctx-paid", statement: "今年暖气费已缴", occurrenceStatus: .done),
        ]
        let draft = HoloContextPlanDraft(
            runID: "run-1",
            draftRevision: 1,
            goalSummary: "g",
            answerText: "a",
            usedContextRefs: ["ctx-salt", "ctx-ghost"],
            items: [
                HoloContextPlanItem(
                    itemID: "i1", title: "选低盐餐厅", kind: .task,
                    basis: .personalEvidence, sourceRefs: ["ctx-salt"]
                ),
                HoloContextPlanItem(
                    itemID: "i2", title: "无证据个人断言", kind: .task,
                    basis: .personalEvidence, sourceRefs: []
                ),
                HoloContextPlanItem(
                    itemID: "i3", title: "一般常识准备", kind: .information,
                    basis: .generalKnowledge
                ),
                HoloContextPlanItem(
                    itemID: "i3", title: "重复 ID", kind: .information
                ),
                HoloContextPlanItem(
                    itemID: "i4", title: "再缴一次暖气费", kind: .task,
                    basis: .personalEvidence, sourceRefs: ["ctx-paid"]
                ),
                HoloContextPlanItem(
                    itemID: "i5", title: "伪造日期", kind: .task,
                    confirmedDate: Date(timeIntervalSince1970: 1_800_000_000)
                ),
            ],
            dependencyEdges: [
                HoloContextPlanDependencyEdge(from: "i1", to: "i2"),
                HoloContextPlanDependencyEdge(from: "i1", to: "ghost"),
            ]
        )
        let (sanitized, findings) = HoloContextPlanValidator.validate(draft: draft, availableContexts: contexts)
        let codes = Set(findings.map(\.code))
        expect(sanitized.usedContextRefs == ["ctx-salt"], "不可用引用剔除")
        expect(codes.contains(.personalEvidenceWithoutSource), "个人证据缺失降级推断")
        let i2 = sanitized.items.first { $0.itemID == "i2" }
        expect(i2?.basis == .inference, "无证据断言降级为推断（保留不删）")
        expect(codes.contains(.duplicateItemID), "重复 itemID 拦截")
        expect(codes.contains(.suggestsCompletedOccurrence), "已完成实例不再产出待办")
        expect(sanitized.items.contains { $0.itemID == "i4" } == false, "已完成待办被丢弃")
        expect(codes.contains(.fabricatedConfirmedDate), "伪造日期剥离")
        expect(sanitized.items.allSatisfy { $0.confirmedDate == nil }, "全部 confirmedDate 清空")
        expect(codes.contains(.danglingDependency), "悬空依赖边剔除")
        expect(sanitized.dependencyEdges.count == 1, "只保留合法边")
        expect(HoloContextPlanValidator.isDeliverable(findings: findings), "净化性问题不阻塞交付")
    }

    static func testValidatorCycleDetection() {
        let edges = [
            HoloContextPlanDependencyEdge(from: "a", to: "b"),
            HoloContextPlanDependencyEdge(from: "b", to: "c"),
            HoloContextPlanDependencyEdge(from: "c", to: "a"),
        ]
        expect(HoloContextPlanValidator.hasCycle(itemIDs: ["a", "b", "c"], edges: edges), "A→B→C→A 成环")
        let acyclic = [
            HoloContextPlanDependencyEdge(from: "a", to: "b"),
            HoloContextPlanDependencyEdge(from: "b", to: "c"),
        ]
        expect(!HoloContextPlanValidator.hasCycle(itemIDs: ["a", "b", "c"], edges: acyclic), "无环通过")
        // 成环草案：全部边丢弃。
        let draft = HoloContextPlanDraft(
            runID: "r", draftRevision: 1, goalSummary: "g", answerText: "a",
            items: [
                HoloContextPlanItem(itemID: "a", title: "A", kind: .task),
                HoloContextPlanItem(itemID: "b", title: "B", kind: .task),
            ],
            dependencyEdges: [
                HoloContextPlanDependencyEdge(from: "a", to: "b"),
                HoloContextPlanDependencyEdge(from: "b", to: "a"),
            ]
        )
        let (sanitized, findings) = HoloContextPlanValidator.validate(draft: draft, availableContexts: [])
        expect(sanitized.dependencyEdges.isEmpty, "成环丢弃全部边")
        expect(findings.contains { $0.code == .dependencyCycle }, "记录成环发现")
    }

    // MARK: 协调器

    static func testCoordinatorHappyPath() async throws {
        let contexts = [contextEntry(contextID: "ctx-salt", statement: "父亲被要求低盐饮食")]
        let generator = FakeGenerator()
        generator.responses = [draftJSON(
            answer: "建议选择清淡菜品的餐厅。",
            items: "[{\"itemID\":\"i1\",\"title\":\"选低盐餐厅\",\"kind\":\"task\",\"basis\":\"personalEvidence\",\"sourceRefs\":[\"ctx-salt\"]}]",
            usedRefs: "[\"ctx-salt\"]"
        )]
        let (coordinator, persistence, _) = makeCoordinator(generator: generator, contexts: contexts)

        let outcome = try await coordinator.start(frame: frame(), parentMessageID: "msg-1")

        expect(outcome.run.state == .draftReady, "运行到达 draftReady")
        expect(outcome.run.parentMessageID == "msg-1", "关联消息 ID")
        expect(outcome.draft.usedContextRefs == ["ctx-salt"], "采用情境引用")
        expect(outcome.draft.items.first?.sourceRefs == ["ctx-salt"], "条目挂个人证据")
        expect(generator.callCount == 1, "首版即交付（未用修复）")
        let stored = try await persistence.loadRun(runID: outcome.run.runID)
        expect(stored?.state == .draftReady, "运行状态已持久化")
    }

    static func testCoordinatorEmptyArchiveAnswerOnly() async throws {
        // 空档案：无情境可用，纯说明型回答也完整。
        let generator = FakeGenerator()
        generator.responses = [draftJSON(
            answer: "目前还没有相关记录。可以先说说父母的具体情况，我再帮你安排。"
        )]
        let (coordinator, _, _) = makeCoordinator(generator: generator, contexts: [])

        let outcome = try await coordinator.start(frame: frame())
        expect(outcome.run.state == .draftReady, "空档案也产出草案")
        expect(outcome.draft.items.isEmpty && outcome.draft.usedContextRefs.isEmpty, "无个人证据引用")
        expect(outcome.retrievalResult.entries.isEmpty, "检索无命中")
    }

    static func testCoordinatorCancelledRunDiscardsLateResult() async throws {
        let contexts = [contextEntry(contextID: "ctx-1", statement: "命题")]
        let generator = CancelAwareGenerator()
        let persistence = HoloPlanningInMemoryRunPersistence()
        let semantic = FixedSemanticProvider(recordIDs: ["rec-ctx-1"])
        let retrieval = HoloContextRetrievalService(semanticProvider: semantic)
        var records: [HoloMemoryRecord] = []
        let payload = contexts[0].payload
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: payload.contextAnchorValue)
        records.append(HoloMemoryRecord(
            id: contexts[0].recordID, scope: .domain, primaryDomain: .thought,
            sourceDomains: [.thought], subjectKey: "s", anchorRefs: [anchor],
            claimKind: .observedFact, persistenceClass: .durable,
            displaySummary: payload.statement, aiUseSummary: payload.statement,
            prohibitedInferences: [], evidenceRefs: [], upstreamMemoryIDs: [],
            counterEvidenceRefs: [], confidenceScore: 0.5, freshnessScore: 0.5,
            scoringVersion: 1, scoreComputedAt: Date(timeIntervalSince1970: 0),
            extractorVersion: 1, promptVersion: 1, state: .candidate,
            sensitivity: .normal, userDecision: .none,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            personalContext: HoloPersonalContextPayloadEnvelope(v1: payload)
        ))
        let box = GuardBox()
        let coordinator = HoloContextPlanningCoordinator(
            generator: generator,
            retrieval: retrieval,
            persistence: persistence,
            recordsProvider: { records },
            controlSnapshotProvider: { box.guard0 }
        )
        // 生成在途时取消运行：从持久化快照取真实 runID。
        generator.beforeGenerate = { _ in
            Task {
                let snapshot = await persistence.runsSnapshot()
                if let runID = snapshot.keys.first {
                    try? await coordinator.cancel(runID: runID)
                }
            }
            // 等取消落库后再返回结果（模拟迟到）。
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        generator.responses = [draftJSON(answer: "迟到结果")]

        do {
            _ = try await coordinator.start(frame: frame())
            expect(false, "取消后的运行不应产出草案")
        } catch let error as HoloContextPlanningCoordinator.PlanningError {
            expect(error == .staleRun, "迟到结果被丢弃")
        }
    }

    /// 支持生成前回调的生成器（竞态模拟）。
    final class CancelAwareGenerator: HoloContextPlanGenerating, @unchecked Sendable {
        var responses: [String] = []
        var beforeGenerate: (@Sendable (String) async -> Void)?
        func generate(prompt: String) async throws -> String {
            if let beforeGenerate { await beforeGenerate("") }
            return responses.isEmpty ? draftJSON(answer: "基础") : responses.removeFirst()
        }
    }

    static func testCoordinatorFollowUpAdvancesRevision() async throws {
        let generator = FakeGenerator()
        generator.responses = [
            draftJSON(answer: "第一版草案"),
            draftJSON(answer: "更新后的草案"),
        ]
        let (coordinator, _, _) = makeCoordinator(generator: generator, contexts: [])

        let first = try await coordinator.start(frame: frame())
        expect(first.run.requestRevision == 1, "首轮 revision=1")
        let second = try await coordinator.followUp(
            run: first.run,
            updatedFrame: HoloPlanningRequestFrame(
                utterance: "改成只安排周六一天",
                goalSummary: "周六一日行程",
                referenceTime: first.run.frame.referenceTime
            )
        )
        expect(second.run.requestRevision == 2, "追问推进 revision")
        expect(second.run.runID == first.run.runID, "同一 run")
        expect(second.draft.answerText == "更新后的草案", "新草案内容")
        expect(second.draft.draftRevision == 2, "同一 run 内 draftRevision 递增（P8 跨版本对账依赖）")
    }

    static func testCoordinatorRepairOnceThenDeliver() async throws {
        let generator = FakeGenerator()
        // 第一次：空 answerText（触发不可交付）→ 修复第二次成功。
        generator.responses = [
            "{\"goalSummary\":\"g\"}",
            draftJSON(answer: "修复后的回答"),
        ]
        let (coordinator, _, _) = makeCoordinator(generator: generator, contexts: [])

        let outcome = try await coordinator.start(frame: frame())
        expect(outcome.repaired, "经历一次修复")
        expect(generator.callCount == 2, "恰好两次生成（预算 2）")
        expect(outcome.draft.answerText == "修复后的回答", "修复后交付")
    }

    static func testCoordinatorBudgetExhaustedFails() async throws {
        let generator = FakeGenerator()
        generator.responses = [
            "{\"goalSummary\":\"g\"}",
            "{\"goalSummary\":\"g2\"}",
        ]
        let (coordinator, persistence, _) = makeCoordinator(generator: generator, contexts: [])

        do {
            _ = try await coordinator.start(frame: frame())
            expect(false, "两次都失败应抛 undeliverable")
        } catch let error as HoloContextPlanningCoordinator.PlanningError {
            expect(error == .undeliverableAfterRepair, "预算耗尽后不可交付")
        }
        expect(generator.callCount == 2, "不再有第三次调用")
        let runs = await persistence.runsSnapshot()
        let run = runs.values.first
        expect(run?.state == .failed, "运行终态 failed")
    }

    static func testCoordinatorGateClosed() async throws {
        let generator = FakeGenerator()
        let box = GuardBox()
        var closedControls = validGuard().controls
        closedControls.planningInjectionKillEnabled = false
        var closed = validGuard()
        closed.controls = closedControls
        box.guard0 = closed
        let (coordinator, _, _) = makeCoordinator(generator: generator, contexts: [], guardBox: box)

        do {
            _ = try await coordinator.start(frame: frame())
            expect(false, "闸关应直接拒绝")
        } catch let error as HoloContextPlanningCoordinator.PlanningError {
            expect(error == .gateClosed, "注入闸关闭")
        }
        expect(generator.callCount == 0, "闸关不发起生成")
    }

    static func testCoordinatorGenerationChanged() async throws {
        let generator = FakeGenerator()
        generator.responses = [draftJSON(answer: "生成完成但权限已变")]
        let box = GuardBox()
        let (coordinator, _, _) = makeCoordinator(generator: generator, contexts: [], guardBox: box)
        // 生成完成后、落库前推进用户决策版本（模拟用户清空）。
        // FakeGenerator 无回调；用另一个包装生成器。
        let wrapped = LateChangeGenerator(base: generator, onChange: {
            var changed = validGuard()
            changed.userDecisionVersion = 999
            box.guard0 = changed
        })
        let semantic = FixedSemanticProvider(recordIDs: [])
        let persistence = HoloPlanningInMemoryRunPersistence()
        let coordinator2 = HoloContextPlanningCoordinator(
            generator: wrapped,
            retrieval: HoloContextRetrievalService(semanticProvider: semantic),
            persistence: persistence,
            recordsProvider: { [] },
            controlSnapshotProvider: { box.guard0 }
        )
        do {
            _ = try await coordinator2.start(frame: frame())
            expect(false, "代际变化应拒绝落库")
        } catch let error as HoloContextPlanningCoordinator.PlanningError {
            expect(error == .generationChanged, "落库前代际复查拦截")
        }
    }

    /// 生成完成后改代际的包装生成器。
    final class LateChangeGenerator: HoloContextPlanGenerating, @unchecked Sendable {
        let base: FakeGenerator
        let onChange: @Sendable () -> Void
        init(base: FakeGenerator, onChange: @Sendable @escaping () -> Void) {
            self.base = base
            self.onChange = onChange
        }
        func generate(prompt: String) async throws -> String {
            let result = try await base.generate(prompt: prompt)
            onChange()
            return result
        }
    }

    static func testPlanPromptComposition() {
        let prompt = HoloContextPlanningCoordinator.planPrompt(
            frame: frame(),
            selected: [
                HoloContextCatalogEntry(
                    recordID: "r1", versionID: "r1@v1",
                    payload: contexts_payload(),
                    needsQualifiedExpression: true,
                    currentOccurrenceStatus: .done
                )
            ],
            fallbackSegments: [
                HoloContextSegment(
                    sourceID: "thought-9", revision: "rev-1",
                    utf16Location: 0, utf16Length: 4, text: "原文片段"
                )
            ],
            semanticCoverage: .degraded
        )
        expect(prompt.contains("\"contexts\":"), "含情境数组")
        expect(prompt.contains("needsQualifiedExpression"), "推断限定标记传入")
        expect(prompt.contains("currentOccurrenceStatus"), "实例状态传入")
        expect(prompt.contains("rawFallbackSegments"), "补查原文传入")
        expect(prompt.contains("\"semanticCoverage\":\"degraded\""), "降级状态如实传入")
        expect(prompt.contains("帮我想想下周末爸妈来怎么安排"), "用户原话传入")
    }

    private static func contexts_payload() -> HoloPersonalContextPayloadV1 {
        HoloPersonalContextPayloadV1(
            contextID: "ctx-x",
            statement: "命题",
            relationText: "命题",
            epistemicStatus: .inferred,
            temporal: HoloContextTemporalV1(kind: .ongoing, originalExpression: "持续中"),
            admission: HoloContextAdmissionV1(
                level: .adviceEligible, policyVersion: 1, decidedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    // MARK: P0 回执对账：失败不记回执、不虚报成功

    static func testReceiptReconciliation() {
        let items = [
            planItem("item-1", title: "打包行李"),
            planItem("item-2", title: "安排猫咪照料")
        ]
        let creations = [
            creation(runID: "run-1", rev: 1, itemID: "item-1"),
            creation(runID: "run-1", rev: 1, itemID: "item-2")
        ]

        // 全部成功：两项都进回执表。
        let allOK = HoloContextPlanExecutionAdapter.reconcileReceipts(
            creations: creations,
            results: [
                creations[0].idempotencyKey: .success(taskID: "t-1"),
                creations[1].idempotencyKey: .success(taskID: "t-2")
            ],
            existingReceipts: [:],
            items: items,
            confirmedDates: [:]
        )
        expect(allOK.succeededCount == 2, "全部成功计 2")
        expect(allOK.failedCount == 0, "失败计 0")
        expect(allOK.hasNewSuccesses, "有新增成功须持久化")
        expect(allOK.updatedReceipts.count == 2, "回执表记两项")

        // 部分失败：只记成功项，失败项不入表。
        let partial = HoloContextPlanExecutionAdapter.reconcileReceipts(
            creations: creations,
            results: [
                creations[0].idempotencyKey: .success(taskID: "t-1"),
                creations[1].idempotencyKey: .failure("存储空间不足")
            ],
            existingReceipts: [:],
            items: items,
            confirmedDates: [:]
        )
        expect(partial.succeededCount == 1 && partial.failedCount == 1, "部分失败计数 1/1")
        expect(partial.updatedReceipts.count == 1, "失败项不进回执表")
        expect(partial.updatedReceipts["run-1|item-2"] == nil, "失败逻辑项无回执")

        // 全部失败：不新增、不要求持久化，既有回执保留。
        let existing = ["run-1|item-9": "old-fingerprint"]
        let allFailed = HoloContextPlanExecutionAdapter.reconcileReceipts(
            creations: creations,
            results: [
                creations[0].idempotencyKey: .failure("写入失败"),
                creations[1].idempotencyKey: .failure("写入失败")
            ],
            existingReceipts: existing,
            items: items,
            confirmedDates: [:]
        )
        expect(allFailed.succeededCount == 0, "全失败成功计 0")
        expect(!allFailed.hasNewSuccesses, "全失败不触发持久化")
        expect(allFailed.updatedReceipts["run-1|item-9"] == "old-fingerprint", "既有回执不被覆盖")
    }

    private static func planItem(_ id: String, title: String) -> HoloContextPlanItem {
        HoloContextPlanItem(itemID: id, title: title, kind: .task)
    }

    private static func creation(runID: String, rev: Int, itemID: String) -> HoloContextPlanTaskCreation {
        HoloContextPlanTaskCreation(
            idempotencyKey: "\(runID)|v\(rev)|\(itemID)",
            logicalItemID: "\(runID)|\(itemID)",
            itemID: itemID,
            title: "标题",
            note: nil,
            dueDate: nil
        )
    }

    // MARK: P0 依据快照：只固化草案实际采用的情境命题

    static func testBasisSnapshot() {
        var draft = HoloContextPlanDraft(
            runID: "run-basis",
            draftRevision: 1,
            goalSummary: "安排周末",
            answerText: "建议",
            usedContextRefs: ["ctx-1"]
        )
        let entries = [
            contextEntry(contextID: "ctx-1", statement: "家里只有我照顾猫", occurrenceStatus: .done),
            contextEntry(contextID: "ctx-2", statement: "爸妈周六到")
        ]
        let snapshot = HoloContextPlanningCoordinator.basisEntries(for: draft, from: entries)
        expect(snapshot.count == 1, "未采用的情境不进快照")
        expect(snapshot[0].contextID == "ctx-1", "快照按 contextID 对应")
        expect(snapshot[0].statement == "家里只有我照顾猫", "命题原文固化")
        expect(snapshot[0].epistemicStatus == "declared", "认识状态随快照")
        expect(snapshot[0].occurrenceStatus == "done", "实例状态随快照")

        // 模型编造的引用没有对应条目：不产生伪造快照。
        draft.usedContextRefs = ["ctx-不存在"]
        expect(
            HoloContextPlanningCoordinator.basisEntries(for: draft, from: entries).isEmpty,
            "编造引用不产生伪造快照"
        )
    }

    // MARK: P0 方案影响契约：解析 + 引用净化 + 无依据不展示

    static func testPlanEffectsContract() {
        // 解析：带 planEffects 的模型输出完整透传。
        let raw = """
        {"answerText":"建议如下","usedContextRefs":["ctx-1"],
         "planEffects":[
           {"kind":"add","summary":"加入猫咪照料","contextRefs":["ctx-1"]},
           {"kind":"reschedule","summary":"出发提前到周五晚","contextRefs":["ctx-1"]},
           {"kind":"add","summary":"一般性建议项","contextRefs":[]}
         ]}
        """
        let draft = try! HoloContextPlanDraftParser.parse(raw, runID: "run-fx", draftRevision: 1)
        expect(draft.planEffects?.count == 3, "planEffects 解析透传")

        // 净化：有效引用保留；空引用的一般项保留（不进个人区块由渲染层判断）。
        let entries = [contextEntry(contextID: "ctx-1", statement: "家里只有我照顾猫")]
        let (sanitized, _) = HoloContextPlanValidator.validate(draft: draft, availableContexts: entries)
        let effects = sanitized.planEffects ?? []
        expect(effects.count == 3, "净化不丢变化条目")
        expect(effects[0].contextRefs == ["ctx-1"], "有效引用保留")

        // 编造引用被剔除后 contextRefs 为空。
        let rawBad = """
        {"answerText":"建议","planEffects":[{"kind":"add","summary":"x","contextRefs":["编造"]}]}
        """
        let bad = try! HoloContextPlanDraftParser.parse(rawBad, runID: "run-fx2", draftRevision: 1)
        let (sanitizedBad, _) = HoloContextPlanValidator.validate(draft: bad, availableContexts: entries)
        expect(sanitizedBad.planEffects?[0].contextRefs?.isEmpty == true, "编造引用剔除后为空")

        // 旧草案 JSON（无 planEffects key）解码不失败。
        let legacyJSON = """
        {"schemaVersion":1,"runID":"run-old","draftRevision":1,"goalSummary":"g",
         "answerText":"旧草案","usedContextRefs":[],"items":[],"unknowns":[],
         "dependencyEdges":[],"coverage":{"readSources":[],"missingScopes":[],"externalFactsVerified":false}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try? decoder.decode(HoloContextPlanDraft.self, from: Data(legacyJSON.utf8))
        expect(legacy != nil, "旧草案 JSON 兼容解码")
        expect(legacy?.planEffects == nil, "旧草案 planEffects 为空")
    }
}
