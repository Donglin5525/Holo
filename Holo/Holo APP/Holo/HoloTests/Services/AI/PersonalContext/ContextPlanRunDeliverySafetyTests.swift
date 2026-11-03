//
//  ContextPlanRunDeliverySafetyTests.swift
//  HoloTests
//
//  云端个性化规划落卡安全网（2026-09-20 真机事故回归）：
//  「已就绪但无方案」死状态的三道防线——
//  ① draftReady 终态不单独落盘（必须与方案 JSON 同笔原子写）；
//  ② 仓库终态保护（排队旧写不得把终态改回进行中）；
//  ③ 就绪孤儿进对账收治（此前终态永不收治，用户只见「已就绪」空白卡）。
//  2026-11-02 增设第四道：④ 定稿通道（finalizeMessage）终态同进退——
//  迟到的失败/旧写不得抹掉已交付方案；ack 门禁改读「已提交存储」。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class ContextPlanRunDeliverySafetyTests: XCTestCase {

    // MARK: - ① 控制器：draftReady 不单独 writeThrough

    func testCompleteDraftDoesNotPersistEnvelopeAlone() {
        let messageID = UUID()
        var persistedStages: [HoloContextPlanStage] = []
        let envelope = HoloContextPlanRunEnvelope(
            runID: messageID.uuidString,
            assistantMessageID: messageID,
            stage: .uploadingContext
        )
        let controller = HoloContextPlanRunController(envelope: envelope) { _, json in
            if let stage = HoloContextPlanRunController.decode(json)?.stage {
                persistedStages.append(stage)
            }
        }

        // 阶段推进仍走 writeThrough（运行卡真实阶段需要单字段原子落盘）
        XCTAssertTrue(controller.advance(to: .cloudPlanning, cloudTaskID: "task-1"))
        XCTAssertEqual(persistedStages, [.cloudPlanning])

        // completeDraft 只推进内存态 + 注销登记表，不落「就绪」——
        // 否则落库链路任何失败都会留下「已就绪无方案」死状态（真机实锤）
        controller.completeDraft(finalRunID: "run-final")
        XCTAssertEqual(controller.envelope.stage, .draftReady)
        XCTAssertEqual(controller.envelope.runID, "run-final")
        XCTAssertEqual(persistedStages, [.cloudPlanning], "draftReady 不得单独落盘")
        XCTAssertFalse(HoloContextPlanRunRegistry.shared.isLive(messageID), "completeDraft 后登记表应注销")
    }

    // MARK: - ③ 孤儿识别：「就绪但无方案」

    private func makeView(
        id: UUID,
        messageType: ChatMessageType,
        stage: HoloContextPlanStage,
        draftJSON: String?
    ) -> ChatMessageViewData {
        let envelope = HoloContextPlanRunEnvelope(
            runID: id.uuidString,
            assistantMessageID: id,
            stage: stage,
            cloudTaskID: "task-1"
        )
        return ChatMessageViewData(
            id: id,
            role: "assistant",
            content: "",
            timestamp: Date(),
            intent: nil,
            extractedDataJSON: nil,
            isStreaming: false,
            parentMessageId: nil,
            messageType: messageType,
            contextPlanJSON: draftJSON,
            contextPlanRunJSON: HoloContextPlanRunController.encode(envelope)
        )
    }

    func testOrphanReadyRunIDSDetection() {
        let orphan = makeView(id: UUID(), messageType: .contextPlan, stage: .draftReady, draftJSON: nil)
        let healthy = makeView(id: UUID(), messageType: .contextPlan, stage: .draftReady, draftJSON: "{\"runID\":\"x\"}")
        let running = makeView(id: UUID(), messageType: .contextPlan, stage: .cloudPlanning, draftJSON: nil)
        let failed = makeView(id: UUID(), messageType: .contextPlan, stage: .failed, draftJSON: nil)
        let nonPlan = makeView(id: UUID(), messageType: .normal, stage: .draftReady, draftJSON: nil)

        let ids = HoloContextPlanRunController.orphanReadyRunIDs(from: [orphan, healthy, running, failed, nonPlan])
        XCTAssertEqual(ids, [orphan.id], "只有「contextPlan+就绪+无方案」进收治")
    }

    func testInterruptedEnvelopeCarriesCustomFailureCode() {
        let envelope = HoloContextPlanRunController.interruptedEnvelope(
            for: UUID(),
            previous: nil,
            failureCode: "PLANNING_DRAFT_LOST"
        )
        XCTAssertEqual(envelope.stage, .failed)
        XCTAssertEqual(envelope.failureCode, "PLANNING_DRAFT_LOST")
        XCTAssertFalse(envelope.canResume)
    }

    // MARK: - ② 仓库：终态保护 + 方案回读

    func testUpdateContextPlanRunTerminalGuard() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }

        let repo = ChatMessageRepository.shared
        let messageID = repo.addStreamingMessage(role: "assistant", parentMessageId: nil, messageType: .contextPlan)

        func runStage() throws -> HoloContextPlanStage {
            let json = try XCTUnwrap(
                repo.messages.first(where: { $0.id == messageID })?.contextPlanRunJSON
            )
            return try XCTUnwrap(HoloContextPlanRunController.decode(json)?.stage)
        }

        func envelope(_ stage: HoloContextPlanStage, revision: Int) -> String? {
            HoloContextPlanRunController.encode(
                HoloContextPlanRunEnvelope(
                    runID: messageID.uuidString,
                    assistantMessageID: messageID,
                    stage: stage,
                    stageRevision: revision
                )
            )
        }

        // 落终态：就绪（与方案同笔 finalize 的等价形态——先有终态信封）
        repo.updateContextPlanRun(messageID, runJSON: envelope(.draftReady, revision: 3), messageType: .contextPlan)
        XCTAssertEqual(try runStage(), .draftReady)

        // 排队中的旧阶段写不得把终态改回进行中
        repo.updateContextPlanRun(messageID, runJSON: envelope(.cloudPlanning, revision: 1))
        XCTAssertEqual(try runStage(), .draftReady, "非终态旧写不得覆盖终态")

        // 清空写（nil）同样不得覆盖终态
        repo.updateContextPlanRun(messageID, runJSON: nil)
        XCTAssertEqual(try runStage(), .draftReady, "nil 写不得覆盖终态")

        // 同终态、revision 不回退的写允许（失败收尾/就绪补写）
        repo.updateContextPlanRun(messageID, runJSON: envelope(.failed, revision: 4))
        XCTAssertEqual(try runStage(), .failed)
    }

    func testContextPlanDraftJSONReadback() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }

        let repo = ChatMessageRepository.shared
        let messageID = repo.addStreamingMessage(role: "assistant", parentMessageId: nil, messageType: .contextPlan)

        // ack 前回读校验依赖：finalize 后能读到方案 JSON；未写时为 nil
        XCTAssertNil(repo.contextPlanDraftJSON(messageID))

        let draftJSON = "{\"schemaVersion\":1,\"runID\":\"r1\",\"answerText\":\"方案\"}"
        repo.finalizeMessage(
            messageID,
            finalContent: "方案",
            intent: AIIntent.contextualPlanning.rawValue,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            analysisContextJSON: nil,
            rawLogJSON: nil,
            contextPlanJSON: draftJSON,
            contextPlanRunJSON: nil,
            messageType: .contextPlan
        )
        XCTAssertEqual(repo.contextPlanDraftJSON(messageID), draftJSON)
    }

    // MARK: - 根因回归：方案 JSON 必须随轻量装载带回

    /// 2026-09-20 真机事故根因：轻量装载只取信封不取方案，重进后已完成的方案卡
    /// 退化为「已就绪」纯状态卡（方案明明在库里）。此测试锁定装载字段完整性。
    func testLightweightLoadRestoresContextPlanDraft() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }

        let repo = ChatMessageRepository.shared
        let messageID = repo.addStreamingMessage(role: "assistant", parentMessageId: nil, messageType: .contextPlan)

        let draftJSON = "{\"schemaVersion\":1,\"runID\":\"r1\",\"answerText\":\"方案正文\"}"
        let envelopeJSON = HoloContextPlanRunController.encode(
            HoloContextPlanRunEnvelope(
                runID: "r1",
                assistantMessageID: messageID,
                stage: .draftReady,
                stageRevision: 2
            )
        )
        repo.finalizeMessage(
            messageID,
            finalContent: "方案正文",
            intent: AIIntent.contextualPlanning.rawValue,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            analysisContextJSON: nil,
            rawLogJSON: nil,
            contextPlanJSON: draftJSON,
            contextPlanRunJSON: envelopeJSON,
            messageType: .contextPlan
        )
        // 先断开 live cache（装载会清），确保断言读的是「从磁盘重新装载」的结果而非内存残留
        await repo.loadCurrentSessionLightweightMessagesAsync(limit: 10)
        // 防空转假绿：装载失败时 catch 提前 return、不会重建消息数组；
        // 装载成功必然重置数组。数组里找得到消息 = fetch 成功路径真实执行。
        let loaded = try XCTUnwrap(
            repo.messages.first(where: { $0.id == messageID }),
            "装载后找不到消息（fetch 可能抛错被吞，断言空转）"
        )
        XCTAssertEqual(loaded.contextPlanJSON, draftJSON, "方案 JSON 必须随轻量装载带回，否则重进后方案卡永远渲染不出来")
        XCTAssertEqual(loaded.contextPlanRunJSON, envelopeJSON)
        XCTAssertEqual(loaded.messageType, .contextPlan)
    }

    // MARK: - 判别：带 contextPlanJSON 字段的字典取数本身是否抛错

    /// 直接对 CoreDataStack 的 store 做与轻量装载同形的字典取数。
    /// 若 propertiesToFetch 含 contextPlanJSON 会抛错（属性名/模型不匹配等），
    /// 装载器会 catch 吞错提前 return——这是「字段修了却渲染不出来」的候选根因。
    func testDictionaryFetchWithContextPlanFieldDoesNotThrow() async throws {
        await CoreDataStack.shared.waitUntilReady()
        let ctx = CoreDataStack.shared.newBackgroundContext()
        let exp = expectation(description: "fetch")
        var thrown: String?
        var sampleDraftLen = -99
        await ctx.perform {
            let req = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
            req.resultType = .dictionaryResultType
            req.propertiesToFetch = ["id", "role", "messageType", "contextPlanJSON", "contextPlanRunJSON"]
            req.predicate = NSPredicate(format: "deletedAt == nil")
            do {
                let rows = try ctx.fetch(req)
                for row in rows {
                    if (row["messageType"] as? String) == ChatMessageType.contextPlan.rawValue,
                       let draft = row["contextPlanJSON"] as? String {
                        sampleDraftLen = draft.count
                    }
                }
            } catch {
                thrown = "\(error)"
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertNil(thrown, "字典取数抛错：\(thrown ?? "")")
        print("DISCRIMINATOR sampleDraftLen=\(sampleDraftLen)")
    }

    // MARK: - ④ 定稿通道终态保护（2026-11-02 真机事故回归）

    /// 2026-11-02 事故形态：云端领取已成功落卡（draftReady+方案），随后一个
    /// 迟到的失败收尾把方案整条抹空、只留下「已就绪」信封——用户对着
    /// 「个性化规划已就绪」死卡无内容可看、无入口可点。此处锁定：
    /// 已交付方案对任何迟到定稿写（nil/旧/改判失败）都不可抹除。
    private func seedDeliveredPlanMessage() async throws -> (UUID, String, ChatMessageRepository) {
        await CoreDataStack.shared.waitUntilReady()
        let repo = ChatMessageRepository.shared
        let messageID = repo.addStreamingMessage(role: "assistant", parentMessageId: nil, messageType: .contextPlan)
        let draftJSON = "{\"schemaVersion\":1,\"runID\":\"r1\",\"answerText\":\"方案正文\"}"
        let envelopeJSON = HoloContextPlanRunController.encode(
            HoloContextPlanRunEnvelope(
                runID: "r1",
                assistantMessageID: messageID,
                stage: .draftReady,
                stageRevision: 2
            )
        )
        repo.finalizeMessage(
            messageID,
            finalContent: "方案正文",
            intent: AIIntent.contextualPlanning.rawValue,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            analysisContextJSON: nil,
            rawLogJSON: nil,
            contextPlanJSON: draftJSON,
            contextPlanRunJSON: envelopeJSON,
            messageType: .contextPlan
        )
        return (messageID, draftJSON, repo)
    }

    private func finalizedState(_ repo: ChatMessageRepository, _ messageID: UUID) throws -> (plan: String?, stage: HoloContextPlanStage?) {
        let view = try XCTUnwrap(repo.messages.first(where: { $0.id == messageID }))
        return (view.contextPlanJSON, view.contextPlanRunJSON.flatMap { HoloContextPlanRunController.decode($0)?.stage })
    }

    func testLateFailureWriteDoesNotEraseDeliveredPlan() async throws {
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }
        let (messageID, draftJSON, repo) = try await seedDeliveredPlanMessage()

        // 迟到失败写形态①：控制器缺席（nil 信封 + nil 方案）
        repo.finalizeMessage(
            messageID,
            finalContent: "这次的个性化规划没有完成",
            intent: nil,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            rawLogJSON: nil,
            contextPlanRunJSON: nil,
            messageType: .contextPlan
        )
        var state = try finalizedState(repo, messageID)
        XCTAssertEqual(state.plan, draftJSON, "nil 定稿写不得抹掉已交付方案")
        XCTAssertEqual(state.stage, .draftReady)

        // 迟到失败写形态②：带「就绪」信封（fail 被终态锁拒绝后的编码产物）+ nil 方案
        let staleReadyJSON = HoloContextPlanRunController.encode(
            HoloContextPlanRunEnvelope(
                runID: "r1",
                assistantMessageID: messageID,
                stage: .draftReady,
                stageRevision: 3
            )
        )
        repo.finalizeMessage(
            messageID,
            finalContent: "这次的个性化规划没有完成",
            intent: nil,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            rawLogJSON: nil,
            contextPlanRunJSON: staleReadyJSON,
            messageType: .contextPlan
        )
        state = try finalizedState(repo, messageID)
        XCTAssertEqual(state.plan, draftJSON, "就绪信封迟写不得制造「已就绪无方案」")

        // 迟到失败写形态③：显式 failed 信封 + nil 方案（改判失败要清方案）
        let failedJSON = HoloContextPlanRunController.encode(
            HoloContextPlanRunEnvelope(
                runID: "r1",
                assistantMessageID: messageID,
                stage: .failed,
                stageRevision: 4,
                failureCode: "PLANNING_POLL_TIMEOUT"
            )
        )
        repo.finalizeMessage(
            messageID,
            finalContent: "这次个性化规划等待超时",
            intent: nil,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            rawLogJSON: nil,
            contextPlanRunJSON: failedJSON,
            messageType: .contextPlan
        )
        state = try finalizedState(repo, messageID)
        XCTAssertEqual(state.plan, draftJSON, "领取已成功的运行，迟到改判失败不得抹掉已交付方案")
        XCTAssertEqual(state.stage, .draftReady, "已交付消息的信封保持就绪终态")
    }

    /// 就绪孤儿（draftReady 但方案本就缺失）仍必须能被收治成诚实失败——
    /// 终态保护只保「已交付」，不得把孤儿收治路一并堵死。
    func testOrphanReadyStillConvertibleToHonestFailure() async throws {
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }
        await CoreDataStack.shared.waitUntilReady()
        let repo = ChatMessageRepository.shared
        let messageID = repo.addStreamingMessage(role: "assistant", parentMessageId: nil, messageType: .contextPlan)
        let orphanEnvelope = HoloContextPlanRunController.encode(
            HoloContextPlanRunEnvelope(
                runID: messageID.uuidString,
                assistantMessageID: messageID,
                stage: .draftReady,
                stageRevision: 2
            )
        )
        repo.updateContextPlanRun(messageID, runJSON: orphanEnvelope, messageType: .contextPlan)

        let honestFailJSON = HoloContextPlanRunController.encode(
            HoloContextPlanRunController.interruptedEnvelope(
                for: messageID,
                previous: HoloContextPlanRunController.decode(orphanEnvelope),
                failureCode: "PLANNING_DRAFT_LOST"
            )
        )
        repo.finalizeMessage(
            messageID,
            finalContent: "这次的个性化规划已生成，但结果没能保存到手机上。",
            intent: nil,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            rawLogJSON: nil,
            contextPlanRunJSON: honestFailJSON,
            messageType: .contextPlan
        )
        let state = try finalizedState(repo, messageID)
        XCTAssertNil(state.plan, "孤儿本无方案")
        XCTAssertEqual(state.stage, .failed, "孤儿必须仍能收治为诚实失败")
    }

    /// 非终态（进行中）消息不适用终态保护：把一条 pending 运行失败定稿
    /// （nil 信封 + nil 方案）是既有合法语义，守卫不得改变它。
    func testPendingRunFailureFinalizeKeepsLegacySemantics() async throws {
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }
        await CoreDataStack.shared.waitUntilReady()
        let repo = ChatMessageRepository.shared
        let messageID = repo.addStreamingMessage(role: "assistant", parentMessageId: nil, messageType: .contextPlan)
        let runningEnvelope = HoloContextPlanRunController.encode(
            HoloContextPlanRunEnvelope(
                runID: messageID.uuidString,
                assistantMessageID: messageID,
                stage: .cloudPlanning,
                stageRevision: 1
            )
        )
        repo.updateContextPlanRun(messageID, runJSON: runningEnvelope, messageType: .contextPlan)

        repo.finalizeMessage(
            messageID,
            finalContent: "这次个性化规划等待超时",
            intent: nil,
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            rawLogJSON: nil,
            contextPlanRunJSON: nil,
            messageType: .contextPlan
        )
        let state = try finalizedState(repo, messageID)
        XCTAssertNil(state.plan)
        XCTAssertNil(state.stage, "进行中运行允许被失败定稿整笔收尾（既有语义）")
    }

    /// ack 即焚门禁（2026-11-02）：回读必须读「已提交存储」而非可能未保存的
    /// 主上下文对象——save 失败时内存值仍在，据此 ack 会销毁云端唯一副本。
    func testCommittedContextPlanDraftJSONReflectsPersistedState() async throws {
        ChatMessageRepository.shared.clearAllMessages()
        defer { ChatMessageRepository.shared.clearAllMessages() }
        let (messageID, draftJSON, repo) = try await seedDeliveredPlanMessage()

        let committed = await repo.committedContextPlanDraftJSON(messageID)
        XCTAssertEqual(committed, draftJSON, "已提交方案必须能从干净上下文读到")
    }

    /// 2026-11-02 性能根治回归：query(.active) 知识门闸从逐命题全表扫（O(P×R)）
    /// 换成快照构建期预计算命题集合（O(P)）。锁两条：①新判定与旧判定同语义
    /// （冲突/不可读命题必须仍然受限——丢了限制会让冲突数据悄悄进规划候选）；
    /// ②干净命题不受限。
    func testKnowledgeSnapshotRestrictedPredicatesStayEquivalent() {
        func makeRevision(propositionID: String, semanticRevisionID: String) -> HoloKnowledgeRevision {
            HoloKnowledgeRevision(
                propositionID: propositionID,
                semanticRevisionID: semanticRevisionID,
                semanticDigest: "digest-\(semanticRevisionID)",
                topicID: "topic",
                topicLabel: "主题",
                domains: [.conversation],
                sensitivity: .normal,
                partition: .normal,
                semantic: HoloKnowledgeSemantic(
                    subjectRef: "self",
                    relation: "likes",
                    dimension: "diet",
                    formation: .directExpression,
                    evidenceForm: .explicitSemanticFact,
                    displayText: "喜欢吃辣",
                    aiUseText: "喜欢吃辣"
                ),
                initialEvidenceSnapshot: HoloKnowledgeEvidenceSnapshot(capturedAt: Date()),
                createdAt: Date()
            )
        }
        let conflicted = makeRevision(propositionID: "p-conflict", semanticRevisionID: "rev-dup")
        let clean = makeRevision(propositionID: "p-clean", semanticRevisionID: "rev-clean")
        var snapshot = HoloKnowledgeStoreSnapshot(
            revisions: [conflicted, clean],
            operations: []
        )
        snapshot.conflictingRevisionIDs = ["rev-dup"]
        // 与 knowledgeStoreSnapshot 构建期归并口径一致：冲突修订所属命题整体受限
        snapshot.conflictedPropositionIDs = ["p-conflict"]
        snapshot.unreadablePropositionIDs = ["p-unreadable"]

        // 受限命题：新旧判定必须同时为真（语义等价）
        XCTAssertTrue(snapshot.isUnreadableOrConflicted(propositionID: "p-conflict"), "旧判定：冲突命题受限")
        XCTAssertTrue(snapshot.isRestrictedByDataIssues(propositionID: "p-conflict"), "新判定：冲突命题不得因预计算漏判")
        XCTAssertTrue(snapshot.isUnreadableOrConflicted(propositionID: "p-unreadable"), "旧判定：不可读命题受限")
        XCTAssertTrue(snapshot.isRestrictedByDataIssues(propositionID: "p-unreadable"), "新判定：不可读命题不得漏判")
        // 干净命题：两者都必须放行
        XCTAssertFalse(snapshot.isUnreadableOrConflicted(propositionID: "p-clean"))
        XCTAssertFalse(snapshot.isRestrictedByDataIssues(propositionID: "p-clean"))
    }

    // MARK: - 探针（临时诊断）：对 PROBE_STORE 指定的外部库做轻量取数
    // （已弃用：外部库路径在测试沙盒内不可达，保留 XCTSkip 分支避免误跑）

}
