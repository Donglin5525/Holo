//
//  ThoughtFollowupCoordinator.swift
//  Holo
//
//  想法脉络核对后台协调器（W2，2026-11-16 方案 §5 B1 / §6 C3）
//
//  消费既有谷时段心跳（ThoughtSemanticPipeline 的调度模式：被动 process 入口，
//  不另起定时器；接线点 = Pipeline.startQueueHeartbeat 谷窗分支与 kickQueue，
//  Pipeline 本身不在本批改动范围）。每拍只领取一个待处理任务并启动受控子
//  Task——心跳不等新增网络请求，原 embed/relate 继续跑（§6 C3）。
//
//  限额：每日 ≤4 次新核对（含重试，每次至多 1 次自动重试，按设备日，§5 B1）；
//  同设备同一时刻 1 次（单一在途 Task）；taskKey/operationId/已开始次数持久化，
//  调用前原子标记，重启识别未完成尝试仅按退避与余量重试（复用 operationId）。
//  verified/no_result 皆终态不重算；撤权、版本变更或范围退出取消旧运行；
//  进后台/索引 shutdown 取消在途（cancelActiveRun），重启或回前台后按存储的
//  领取时间与预算恢复（store.open 把 running 回收为 waiting）。
//

import CoreData
import Foundation
import OSLog
import UIKit

actor ThoughtFollowupCoordinator {

    static let shared = ThoughtFollowupCoordinator()

    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtFollowup")
    /// 受控子 Task：非 nil = 有核对在途（同设备同一时刻 1 次，§5 B1）
    private var activeRun: Task<Void, Never>?
    private var lifecycleInstalled = false

    // MARK: - 心跳入口（Pipeline 谷窗节拍调用；设置页手动重试可再触发一次）

    func process(store: ThoughtSemanticStore) async {
        installLifecycleObserverIfNeeded()
        guard activeRun == nil else { return }
        // 全链资格（§5 B1）：AI 处理授权 + 智能整理 + 自动成主题 + 试点开关 +
        // pilotTopicID 非空；服务器能力在子任务内再核（能力缓存最多 5 分钟）。
        let granted = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
        let scopeID = await MainActor.run { ThoughtSemanticFeatureFlags.followupPilotScope() }
        let automaticOn = await MainActor.run { ThoughtSemanticFeatureFlags.automaticEnabled }
        let newTopicsOn = await MainActor.run { ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.newTopicsKey) }
        guard granted, automaticOn, newTopicsOn, let scopeID else {
            // 资格链断开（撤权/试点关闭/切换范围）：取消旧运行并清能力缓存，
            // 迟到结果不得落库（§2 A08）。撤权波及全部范围，按旧 scope 取消。
            await ThoughtFollowupCapabilityCache.shared.invalidate()
            if let scopeID {
                try? await store.cancelFollowupTasks(scopeID: scopeID, errorCode: "scope_exited")
            }
            return
        }
        let generation = await MainActor.run { ThoughtSemanticFeatureFlags.consentGeneration }
        activeRun = Task {
            await runOne(store: store, scopeID: scopeID, generation: generation)
            await finishActiveRun()
        }
    }

    /// 取消在途核对（进后台/索引 shutdown）。已被原子标记的尝试计入日额度，
    /// 状态由执行路径回 waiting，按退避与余量恢复（§6 C3）。
    func cancelActiveRun() {
        activeRun?.cancel()
        activeRun = nil
    }

    private func finishActiveRun() {
        activeRun = nil
    }

    /// 进后台即取消在途（§6 C3）；回前台由下一拍心跳恢复。
    private func installLifecycleObserverIfNeeded() {
        guard !lifecycleInstalled else { return }
        lifecycleInstalled = true
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.cancelActiveRun() }
        }
    }

    // MARK: - 单轮执行

    private func runOne(store: ThoughtSemanticStore, scopeID: UUID, generation: Int64) async {
        do {
            // 服务器能力（§2 A13：服务端暗开与客户端试点都成立才可出网）
            guard await followupSupported() else { return }
            guard let snapshot = await collectScopeSnapshot(scopeID: scopeID, store: store) else { return }
            // 先领全局队列（重启恢复的 waiting 优先），空则入队新锚点再领
            guard let task = try await pickAndClaimTask(snapshot: snapshot, store: store) else { return }
            try await execute(task: task, snapshot: snapshot, store: store, scopeID: scopeID, generation: generation)
            try? await store.pruneFollowupRetention(scopeID: scopeID)
        } catch {
            logger.error("脉络核对本轮中止（下拍再试）：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 能力口缓存（≤5 分钟）+ 未命中拉取；关闭态（followupVersion=0）不计算脉络。
    private func followupSupported() async -> Bool {
        let subject = HoloBackendDeviceIdentity.shared.deviceId
        if let cached = await ThoughtFollowupCapabilityCache.shared.capabilities(for: subject) {
            return cached.isFollowupSupported
        }
        do {
            let capabilities = try await ThoughtFollowupClient.fetchCapabilities()
            await ThoughtFollowupCapabilityCache.shared.store(capabilities, subject: subject)
            return capabilities.isFollowupSupported
        } catch ThoughtFollowupClientError.unsupportedByServer, ThoughtFollowupClientError.disabled {
            // 旧后端 404 = 不支持，禁止探测正文请求（§6 C2）；禁用同样不出网
            return false
        } catch {
            // 网络类失败：本拍跳过；离线且能力过期时新增派生卡隐藏（§6 C2）
            return false
        }
    }

    // MARK: - 范围快照采集（值快照出 actor，§6 C3）

    struct ScopeSnapshot {
        var topicID: UUID
        var scopeTitle: String
        var early: [ThoughtFollowupSampling.NoteSnapshot]
        var middle: [ThoughtFollowupSampling.NoteSnapshot]
        var recent: [ThoughtFollowupSampling.NoteSnapshot]
    }

    /// 主题有效性 + 合规成员（未删未归档、AI 可见、有效成员投影、非空正文）+
    /// 轻量分层采样 ≤120 后再加载正文与向量（§5 B1「先过滤合规对象再排位，
    /// 取到样本后再加载有限的正文与向量」）。仓库读在其上下文内完成。
    private func collectScopeSnapshot(scopeID: UUID, store: ThoughtSemanticStore) async -> ScopeSnapshot? {
        let context = CoreDataStack.shared.newBackgroundContext()
        let preliminary: (title: String, members: [(id: UUID, createdAt: Date)])? = await context.perform {
            guard let topic = Topic.resolveValid(id: scopeID, in: context) else { return nil }
            let request = Thought.fetchRequest()
            request.predicate = ThoughtAIAudience.aiVisible(
                NSPredicate(format: "deletedAt == nil AND isArchived == NO AND ANY topicLinks.topic.id == %@", scopeID as CVarArg))
            let candidates = (try? context.fetch(request)) ?? []
            // 成员语义与 TopicRepository.fetchThoughts(byTopic:) 同口径（投影裁决）
            let members = candidates
                .filter { ThoughtTopicLinkProjection.isEffectiveMember($0, of: topic) }
                .map { (id: $0.id, createdAt: $0.createdAt) }
            return (topic.title, members)
        }
        guard let preliminary, preliminary.members.count >= ThoughtFollowupContract.notesMinCount else { return nil }
        let slice = ThoughtFollowupSampling.sampleMemberSlice(preliminary.members)
        guard let early = await loadSnapshots(slice.early, context: context, store: store),
              let middle = await loadSnapshots(slice.middle, context: context, store: store),
              let recent = await loadSnapshots(slice.recent, context: context, store: store),
              early.count + middle.count + recent.count >= ThoughtFollowupContract.notesMinCount else { return nil }
        let title = ThoughtSemanticText.prefix(
            ThoughtIndexV2Policy.redactedText(forUpload: preliminary.title),
            maxUTF16: ThoughtFollowupContract.scopeTitleMaxUTF16)
        return ScopeSnapshot(topicID: scopeID, scopeTitle: title, early: early, middle: middle, recent: recent)
    }

    /// 分段成员逐条加载正文/向量快照；向量缺失的成员留在段内（锚点候选照排），
    /// 只是不参与相似度召回（复用已有入队补向量，不另起全库生成，§5 B1）。
    private func loadSnapshots(_ members: [(id: UUID, createdAt: Date)],
                               context: NSManagedObjectContext,
                               store: ThoughtSemanticStore) async -> [ThoughtFollowupSampling.NoteSnapshot]? {
        var snapshots: [ThoughtFollowupSampling.NoteSnapshot] = []
        for member in members {
            let content: String? = await context.perform {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", member.id as CVarArg)
                guard let thought = (try? context.fetch(request))?.first,
                      !ThoughtAIAudience.isExcluded(thought) else { return nil }
                let text = ThoughtIndexV2Policy.redactedText(forUpload: thought.content)
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
            guard let content else { continue }
            let hash = ThoughtSemanticText.contentHash(content)
            let vector = try? await store.activeVector(thoughtID: member.id, contentHash: hash)
            snapshots.append(ThoughtFollowupSampling.NoteSnapshot(thoughtID: member.id, createdAt: member.createdAt,
                                                                  contentHash: hash, redactedText: content, vector: vector))
        }
        return snapshots
    }

    // MARK: - 锚点选择与领取（§5 B1：从较新的独立锚点开始，新中旧分层）

    struct PickedTask {
        var claim: ThoughtSemanticStore.FollowupResultRecord
        var inputs: [ThoughtFollowupSampling.NoteSnapshot]
        var windows: [[ThoughtFollowupSampling.Window]]   // 与 inputs 同序（每条 1–2 窗）
    }

    /// 组装一个锚点的完整输入（召回 + 窗口 + taskKey）；锚点不可用（无向量/
    /// 无过门槛候选）返回 nil。
    private func buildAnchorInputs(anchor: ThoughtFollowupSampling.NoteSnapshot,
                                   snapshot: ScopeSnapshot,
                                   store: ThoughtSemanticStore) async -> (inputs: [ThoughtFollowupSampling.NoteSnapshot],
                                                                          windows: [[ThoughtFollowupSampling.Window]],
                                                                          taskKey: String)? {
        guard anchor.vector != nil else { return nil }
        let rejected = (try? await store.relatedFeedbackIDs(thoughtID: anchor.thoughtID)) ?? []
        let references = ThoughtFollowupSampling.anchorReferences(anchor: anchor)
        let candidates = ThoughtFollowupSampling.recallCandidates(
            anchor: anchor,
            early: snapshot.early, middle: snapshot.middle, recent: snapshot.recent,
            rejectedPairIDs: rejected,
            minCosine: ThoughtSemanticCalibration.current().config.recallMinCosine)
        guard !candidates.isEmpty else { return nil }
        let inputs = [anchor] + candidates
        let windows = inputs.map {
            ThoughtFollowupSampling.windows(for: $0, isAnchor: $0.thoughtID == anchor.thoughtID,
                                            anchorHead: references.head, anchorTail: references.tail)
        }
        let taskKey = ThoughtFollowupSampling.taskKey(
            scopeID: snapshot.topicID,
            anchorID: anchor.thoughtID,
            notes: zip(inputs, windows).map { (thoughtID: $0.thoughtID, contentHash: $0.contentHash, windows: $1) },
            policyVersion: ThoughtFollowupContract.policyVersion,
            redactionVersion: ThoughtIndexV2Policy.engineVersion,
            embeddingModelVersion: ThoughtSemanticStore.defaultModelVersion)
        return (inputs, windows, taskKey)
    }

    /// 领取语义（§6 C3 领取事务 + §6 C2 末条原子标记）：
    /// 1) 先领全局队列——重启恢复的 waiting 任务优先重试（复用 operationId）；
    /// 2) 队列空时按「较新 → 中段 → 较早」找第一个未终态锚点入队再领。
    /// 领到的任务按其 anchorID 重组输入；输入已变化（taskKey 对不上）时旧键
    /// 终态化，新键下一拍执行——重试只发生在输入完全一致的键上。
    private func pickAndClaimTask(snapshot: ScopeSnapshot, store: ThoughtSemanticStore) async throws -> PickedTask? {
        if let claim = try await store.claimNextFollowupTask() {
            return try await rematchClaimed(claim: claim, snapshot: snapshot, store: store)
        }
        // 较新段逆序（新→旧）→ 中段 → 较早：初始种子从较新的独立锚点开始（§5 B1）
        let anchors = (snapshot.recent + snapshot.middle + snapshot.early).reversed()
        for anchor in anchors {
            guard let built = await buildAnchorInputs(anchor: anchor, snapshot: snapshot, store: store) else { continue }
            if try await store.hasTerminalFollowup(taskKey: built.taskKey) { continue }
            guard try await store.upsertFollowupTask(taskKey: built.taskKey, scopeID: snapshot.topicID,
                                                     anchorID: anchor.thoughtID,
                                                     policyVersion: ThoughtFollowupContract.policyVersion) else { continue }
            guard let claim = try await store.claimNextFollowupTask() else { return nil } // 日额度满
            return try await rematchClaimed(claim: claim, snapshot: snapshot, store: store)
        }
        return nil
    }

    /// 领到的行按 anchorID 重组输入并核对 taskKey：一致（新任务或同输入重试）
    /// 才执行；输入已变则旧键终态化（input_stale），本拍到此为止。
    private func rematchClaimed(claim: ThoughtSemanticStore.FollowupResultRecord,
                                snapshot: ScopeSnapshot,
                                store: ThoughtSemanticStore) async throws -> PickedTask? {
        let pool = snapshot.early + snapshot.middle + snapshot.recent
        guard let anchor = pool.first(where: { $0.thoughtID == claim.anchorID }),
              let built = await buildAnchorInputs(anchor: anchor, snapshot: snapshot, store: store) else {
            // 锚点已不可用（被排除/删除/无候选）：旧键作废，等新输入另起新键
            try await store.finishFollowupFailed(taskKey: claim.taskKey, errorCode: "anchor_unavailable")
            return nil
        }
        guard built.taskKey == claim.taskKey else {
            try await store.finishFollowupFailed(taskKey: claim.taskKey, errorCode: "input_stale")
            return nil
        }
        return PickedTask(claim: claim, inputs: built.inputs, windows: built.windows)
    }

    // MARK: - 执行（上传前/提交前资格校验 → 输入映射 → 网络 → 校验 → 落库）

    private func execute(task: PickedTask, snapshot: ScopeSnapshot, store: ThoughtSemanticStore,
                         scopeID: UUID, generation: Int64) async throws {
        // 上传前统一资格与版本校验（§2 A08）
        guard await eligibilityHolds(scopeID: scopeID, generation: generation) else {
            try await store.cancelFollowupTasks(scopeID: scopeID, errorCode: "consent_changed")
            return
        }
        // 输入映射（§6 C3 事务）：记录该请求全部输入，含最终没进入卡片的输入
        let (noteIDByRef, windowOffsets) = buildRefMaps(inputs: task.inputs, windows: task.windows)
        let sources = task.inputs.enumerated().map { index, note -> ThoughtSemanticStore.FollowupSourceRecord in
            let noteWindows = task.windows[index]
            return ThoughtSemanticStore.FollowupSourceRecord(
                taskKey: task.claim.taskKey,
                thoughtID: note.thoughtID,
                scopeID: scopeID,
                contentHash: note.contentHash,
                redactionVersion: ThoughtIndexV2Policy.engineVersion,
                frozenCreatedAt: note.createdAt,
                windows: noteWindows.map { .init(ref: $0.ref, offsetUTF16: $0.offsetUTF16, lengthUTF16: $0.lengthUTF16) },
                summary: ThoughtSemanticText.prefix(noteWindows.first?.text ?? "", maxUTF16: 80))
        }
        try await store.recordFollowupSources(sources)
        // 组装请求（ref 短编号 / UTC 毫秒 / 冻结窗口，§6 C2）
        let requestNotes = task.inputs.enumerated().map { index, note -> (ref: String, createdAtMs: Int, windows: [(ref: String, text: String)]) in
            ("N\(index)",
             Int(note.createdAt.timeIntervalSince1970 * 1000),
             task.windows[index].map { (ref: $0.ref, text: $0.text) })
        }
        guard let request = ThoughtFollowupValidator.makeRequest(
            operationId: task.claim.operationID,
            scopeTitle: snapshot.scopeTitle,
            anchorRef: "N0",
            notes: requestNotes) else {
            try await store.finishFollowupFailed(taskKey: task.claim.taskKey, errorCode: "INVALID_REQUEST")
            return
        }
        do {
            let response = try await ThoughtFollowupClient.verifyFollowup(request)
            // 提交前再核资格与版本（§2 A08：资格变化不得落库）
            guard await eligibilityHolds(scopeID: scopeID, generation: generation) else {
                try await store.cancelFollowupTasks(scopeID: scopeID, errorCode: "consent_changed")
                return
            }
            switch ThoughtFollowupValidator.validate(response: response, request: request,
                                                     noteIDByRef: noteIDByRef,
                                                     windowOffsetByNoteRef: windowOffsets) {
            case .noResult:
                try await store.finishFollowupNoResult(taskKey: task.claim.taskKey)
            case .verified(let content):
                try await store.finishFollowupVerified(taskKey: task.claim.taskKey,
                                                       decisions: content.decisions.map(Self.persistableDecision),
                                                       thread: content.thread.map { thread in
                                                           // 独立 thread local UUID，不拿标题当身份（§5 B2）
                                                           (id: UUID().uuidString, title: thread.title,
                                                            question: thread.question, memberIDs: thread.memberThoughtIDs)
                                                       })
            case .contractViolation(let reason):
                // 协议错 = 失败态，绝不降级 no_result（§6 C2）
                logger.error("脉络核对协议失败：\(reason, privacy: .public)")
                try await store.finishFollowupFailed(taskKey: task.claim.taskKey, errorCode: "INVALID_AI_RESULT")
            }
        } catch {
            try await handleFailure(error: error, claim: task.claim, store: store)
        }
    }

    private static func persistableDecision(_ decision: ThoughtFollowupVerifiedDecision) -> ThoughtSemanticStore.FollowupDecisionRecord {
        func evidence(_ raw: ThoughtFollowupVerifiedEvidence?) -> ThoughtSemanticStore.FollowupEvidenceRecord? {
            raw.map { .init(thoughtID: $0.thoughtID, windowRef: $0.windowRef,
                            windowOffsetUTF16: $0.windowOffsetUTF16, quote: $0.quote,
                            rangeUTF16: $0.rangeUTF16) }
        }
        return .init(otherThoughtID: decision.otherThoughtID, relation: decision.relation,
                     reason: decision.reason, anchorEvidence: evidence(decision.anchorEvidence),
                     otherEvidence: evidence(decision.otherEvidence))
    }

    /// 网络类有界重试（每次至多 1 次自动重试，§5 B1）；配额等下个设备日
    /// （ThoughtSemanticRetryPolicy.delay 对 BUDGET/DAILY 对齐次日）；功能禁用
    /// 立即清能力缓存（§6 C2）；取消（进后台）按短退避回 waiting。
    private func handleFailure(error: Error, claim: ThoughtSemanticStore.FollowupResultRecord,
                               store: ThoughtSemanticStore) async throws {
        if error is CancellationError {
            try await store.finishFollowupWaiting(taskKey: claim.taskKey,
                                                  nextAttemptAt: Date().addingTimeInterval(60),
                                                  errorCode: "interrupted")
            return
        }
        if let clientError = error as? ThoughtFollowupClientError {
            // 禁用/不支持：清能力缓存，下拍重新核能力再决定；超限本地已防
            await ThoughtFollowupCapabilityCache.shared.invalidate()
            let code = clientError == .inputTooLarge ? "INPUT_TOO_LARGE" : "THOUGHT_FOLLOWUP_DISABLED"
            try await store.finishFollowupFailed(taskKey: claim.taskKey, errorCode: code)
            return
        }
        let code = ThoughtSemanticRetryPolicy.code(error)
        if ThoughtSemanticRetryPolicy.isTerminal(error) {
            try await store.finishFollowupFailed(taskKey: claim.taskKey, errorCode: code)
            return
        }
        // claim.attemptCount 已含本次尝试；>1 即自动重试已用完（每次至多 1 次，§5 B1）
        if claim.attemptCount > 1 {
            try await store.finishFollowupFailed(taskKey: claim.taskKey, errorCode: code)
            return
        }
        let delay = ThoughtSemanticRetryPolicy.delay(error, attempt: claim.attemptCount)
        try await store.finishFollowupWaiting(taskKey: claim.taskKey,
                                              nextAttemptAt: Date().addingTimeInterval(delay),
                                              errorCode: code)
    }

    /// 上传/落库前的统一资格与版本校验（§2 A08）：授权、代数与试点范围仍成立。
    /// 正文版本核对由读侧按 source 行 contentHash 完成（§6 C3 读侧校验）。
    private func eligibilityHolds(scopeID: UUID, generation: Int64) async -> Bool {
        let granted = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
        guard granted else { return false }
        let currentGeneration = await MainActor.run { ThoughtSemanticFeatureFlags.consentGeneration }
        guard currentGeneration == generation else { return false }
        let scopeHolds = await MainActor.run { ThoughtSemanticFeatureFlags.followupPilotScope() == scopeID }
        return scopeHolds
    }

    /// ref → 本机映射（§6 C3：句柄只从本机 source 映射绑定，不从响应字符串拼接）。
    private func buildRefMaps(inputs: [ThoughtFollowupSampling.NoteSnapshot],
                              windows: [[ThoughtFollowupSampling.Window]])
        -> ([String: UUID], [String: [String: Int]]) {
        var noteIDByRef: [String: UUID] = [:]
        var windowOffsets: [String: [String: Int]] = [:]
        for (index, note) in inputs.enumerated() {
            let ref = "N\(index)"
            noteIDByRef[ref] = note.thoughtID
            windowOffsets[ref] = Dictionary(windows[index].map { ($0.ref, $0.offsetUTF16) }, uniquingKeysWith: { first, _ in first })
        }
        return (noteIDByRef, windowOffsets)
    }
}
