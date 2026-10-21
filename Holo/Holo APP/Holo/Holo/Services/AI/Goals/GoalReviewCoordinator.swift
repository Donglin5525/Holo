//
//  GoalReviewCoordinator.swift
//  Holo
//
//  目标闭环·回顾协调（最终规格 §2.2 / §2.3 / §5 / §6.4）
//
//  - 发起：解析生效计划 → 统一事实快照 → 冻结 goalScope → 落「用户问句 + 分析占位」两条消息到 HoloAI
//    对话 → 复用现有云端 deep_analysis 链（HoloCloudAnalysisService.attempt）；不造平行报告系统。
//  - 去重：同 goalID + planRevisionID + sourceDigest 的生成中任务直接恢复、已完成直接打开已有报告；
//    只有用户明确「重新分析」才新建 reviewID。目标页与 HoloAI 并发点按也只建一个 job（主线程串行 + inFlight）。
//  - 索引：GoalReviewLinkMO 只存 goalID / planRevisionID / reviewID / reportMessageID / 窗口 / 状态，
//    reportMessageID = 占位消息 id = 完成后的报告消息 id（ChatMessage.id 即两入口共用的报告身份）。
//  - 状态：完成由 .agentReportDidFinalize 回写；报告消息被删除 → 关联标 unavailable，不复活正文；
//    依据 digest 与最新完成报告不一致 → 修正建议标「待刷新」。
//

import Foundation
import CoreData
import Combine
import os

struct GoalReviewLinkSummary: Identifiable, Equatable {
    let id: UUID
    let reviewID: UUID
    let planRevisionID: UUID
    let reportMessageID: UUID?
    let status: GoalReviewLinkStatus
    let sourceDigest: String
    let windowStart: Date
    let windowEndExclusive: Date
    let snapshotCutoffAt: Date
    let createdAt: Date
    let completedAt: Date?
    let failureReason: String?
}

/// 目标详情「目标分析」区读取的一份状态（同一快照同时供风险/通知使用）
struct GoalReviewState: Equatable {
    var snapshot: GoalEvaluationSnapshot
    var plan: GoalResolvedPlan
    var latestCompleted: GoalReviewLinkSummary?
    var running: GoalReviewLinkSummary?
    var history: [GoalReviewLinkSummary]
    /// 最新完成报告的修正草案（报告消息里带的；依据过期时仍返回但 isAdjustmentStale=true）
    var adjustmentDraft: GoalAdjustmentDraftV2?
    /// 最新报告生成时的依据与当前事实不一致（§2.2「依据或计划已变化」）
    var isAdjustmentStale: Bool
    var isDue: Bool { snapshot.review.isDue }
}

@MainActor
final class GoalReviewCoordinator: ObservableObject {

    static let shared = GoalReviewCoordinator()

    enum LaunchOutcome: Equatable {
        case started(reviewID: UUID, reportMessageID: UUID)
        case resumedRunning(reviewID: UUID, reportMessageID: UUID)
        case openedExisting(reviewID: UUID, reportMessageID: UUID)
        case needsConsent
        case unavailable(String)
        case failed(String)
    }

    /// 发起/完成后广播，目标详情与列表据此刷新
    static let reviewStateDidChange = Notification.Name("holo.goalReview.stateDidChange")

    private let logger = Logger(subsystem: "com.holo.app", category: "GoalReview")
    private let context: NSManagedObjectContext
    private let repository: ChatMessageRepository
    private let cloudService: HoloCloudAnalysisService
    private let snapshotBuilder: GoalEvaluationSnapshotBuilder
    private var inFlightGoalIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(context: NSManagedObjectContext,
         repository: ChatMessageRepository,
         cloudService: HoloCloudAnalysisService,
         snapshotBuilder: GoalEvaluationSnapshotBuilder) {
        self.context = context
        self.repository = repository
        self.cloudService = cloudService
        self.snapshotBuilder = snapshotBuilder
        observeFinalization()
    }

    private convenience init() {
        self.init(context: CoreDataStack.shared.viewContext,
                  repository: .shared,
                  cloudService: .shared,
                  snapshotBuilder: .makeDefault())
    }

    // MARK: - 读取状态

    /// 解析计划（必要时生成 legacy 基线并保存）→ 构建快照 → 合并索引状态
    func loadState(goal: Goal, now: Date = Date()) throws -> GoalReviewState {
        let plan = try GoalPlanResolver.resolveCurrentPlan(goal: goal, now: now, in: context, persist: true)
        let windowDays = plan.payload.review?.observationWindowDays ?? GoalPlanReviewV2.defaultObservationWindowDays
        let window = GoalObservationWindow.trailingDays(windowDays, cutoff: now)
        let snapshot = snapshotBuilder.build(goal: goal, plan: plan, window: window, now: now)

        reconcileLinks(goalID: goal.id)
        let links = Self.links(goalID: goal.id, in: context).map(Self.summary)
        let latestCompleted = links.first { $0.status == .completed || $0.status == .stale }
        let running = links.first { $0.status == .running }

        var draft: GoalAdjustmentDraftV2?
        var stale = false
        if let latestCompleted, let messageID = latestCompleted.reportMessageID,
           let rendered = repository.loadMessageViewData(id: messageID)?.agentResult {
            draft = rendered.goalAdjustmentDraft
            stale = latestCompleted.sourceDigest != snapshot.sourceDigest
                || latestCompleted.planRevisionID != plan.revisionID
                || (draft.map { $0.isExpired(at: now) } ?? false)
        }
        return GoalReviewState(snapshot: snapshot, plan: plan, latestCompleted: latestCompleted, running: running,
                               history: links, adjustmentDraft: draft, isAdjustmentStale: stale)
    }

    func history(goalID: UUID) -> [GoalReviewLinkSummary] {
        reconcileLinks(goalID: goalID)
        return Self.links(goalID: goalID, in: context).map(Self.summary)
    }

    // MARK: - 发起

    /// 目标详情 / HoloAI 发起同一入口。forceNew = 用户明确要求重新分析。
    func startOrOpenReview(goal: Goal, forceNew: Bool = false, now: Date = Date()) async -> LaunchOutcome {
        guard !inFlightGoalIDs.contains(goal.id) else {
            if let running = Self.links(goalID: goal.id, in: context).first(where: { $0.statusRaw == GoalReviewLinkStatus.running.rawValue }),
               let messageID = running.reportMessageID {
                return .resumedRunning(reviewID: running.reviewID, reportMessageID: messageID)
            }
            return .unavailable(String(localized: "正在准备这次分析，请稍候"))
        }
        inFlightGoalIDs.insert(goal.id)
        defer { inFlightGoalIDs.remove(goal.id) }

        let state: GoalReviewState
        do {
            state = try loadState(goal: goal, now: now)
        } catch let error as GoalPlanResolveError {
            return .failed(Self.describe(error))
        } catch {
            return .failed(error.localizedDescription)
        }

        // 去重：同依据生成中直接恢复；同依据已完成直接打开
        if !forceNew {
            if let running = state.running, let messageID = running.reportMessageID,
               running.sourceDigest == state.snapshot.sourceDigest {
                return .resumedRunning(reviewID: running.reviewID, reportMessageID: messageID)
            }
            if let completed = state.latestCompleted, let messageID = completed.reportMessageID,
               completed.status == .completed,
               completed.planRevisionID == state.plan.revisionID,
               completed.sourceDigest == state.snapshot.sourceDigest {
                return .openedExisting(reviewID: completed.reviewID, reportMessageID: messageID)
            }
        }
        // 已有另一份不同依据的生成中任务：不再并发建第二个 job
        if let running = state.running, let messageID = running.reportMessageID {
            return .resumedRunning(reviewID: running.reviewID, reportMessageID: messageID)
        }

        // 云端前置条件：不满足时不落消息、不建索引
        guard HoloAIFeatureFlags.cloudDeepAnalysisEnabled else {
            return .unavailable(String(localized: "云端深度分析当前未开放"))
        }
        guard HoloCloudAnalysisService.privacyConsented else { return .needsConsent }
        guard cloudService.canTakeCloudTask() else {
            return .unavailable(String(localized: "HoloAI 正在进行另一项分析，等它结束再来"))
        }

        let reviewID = UUID()
        let scope = HoloAgentGoalScope(
            goalID: goal.id,
            planRevisionID: state.plan.revisionID,
            reviewID: reviewID,
            windowStart: state.snapshot.windowStart,
            windowEndExclusive: state.snapshot.windowEndExclusive,
            snapshotCutoffAt: state.snapshot.snapshotCutoffAt,
            timeZoneID: state.snapshot.timeZoneID,
            sourceDigest: state.snapshot.sourceDigest
        )
        let question = Self.reviewQuestion(goalTitle: goal.title)

        // 落对话：用户问句 + 分析占位（占位消息 id 即报告身份）
        let userMessageID = repository.addMessage(role: "user", content: question, intent: "query_analysis")
        let reportMessageID = repository.addStreamingMessage(role: "assistant", parentMessageId: userMessageID)
        do {
            try Self.createLink(in: context, scope: scope, reportMessageID: reportMessageID)
        } catch {
            logger.error("回顾索引写入失败：\(String(describing: error), privacy: .public)")
            return .failed(String(localized: "没能登记这次分析，请稍后再试"))
        }
        NotificationCenter.default.post(name: Self.reviewStateDidChange, object: goal.id)
        logger.info("目标回顾发起 goal=\(goal.id.uuidString, privacy: .public) review=\(reviewID.uuidString, privacy: .public) digest=\(scope.sourceDigest, privacy: .public)")

        // 不阻塞调用方：云端分析在后台跑，完成由 finalize 通知回写索引
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.cloudService.attempt(
                question: question,
                sourceMessageID: reportMessageID,
                scenario: .goal,
                goalScope: scope,
                goalReview: state.snapshot
            )
            await MainActor.run {
                switch outcome {
                case .handled:
                    break
                case .userCancelled:
                    self.updateLinkStatus(reviewID: reviewID, status: .cancelled, failureReason: nil)
                case .unavailable(let reason):
                    let text: String
                    switch reason {
                    case .featureDisabled: text = String(localized: "云端深度分析当前未开放")
                    case .needsConsent: text = String(localized: "需要先在 HoloAI 同意云端分析")
                    case .busy: text = String(localized: "HoloAI 正在进行另一项分析")
                    }
                    self.cloudService.markAnalysisUnavailable(sourceMessageID: reportMessageID,
                                                              summary: text + String(localized: "；原计划继续有效，稍后可重试。"))
                    self.updateLinkStatus(reviewID: reviewID, status: .failed, failureReason: text)
                }
            }
        }
        return .started(reviewID: reviewID, reportMessageID: reportMessageID)
    }

    // MARK: - 完成 / 失败回写

    private func observeFinalization() {
        NotificationCenter.default.publisher(for: .agentReportDidFinalize)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let messageID = notification.userInfo?["messageID"] as? UUID else { return }
                let rendered = notification.userInfo?["rendered"] as? HoloRenderedAgentResult
                self.handleFinalized(messageID: messageID, rendered: rendered)
            }
            .store(in: &cancellables)
    }

    func handleFinalized(messageID: UUID, rendered: HoloRenderedAgentResult?) {
        guard let link = Self.link(reportMessageID: messageID, in: context) else { return }
        if let failure = rendered?.failure {
            link.statusRaw = GoalReviewLinkStatus.failed.rawValue
            link.failureReason = Self.describe(failure)
        } else {
            link.statusRaw = GoalReviewLinkStatus.completed.rawValue
            link.completedAt = Date()
            link.failureReason = nil
        }
        link.updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(name: Self.reviewStateDidChange, object: link.goalID)
    }

    /// 读路径自愈：报告消息已被删除 → 关联标不可用；占位既不在途又已落失败卡 → 标失败
    private func reconcileLinks(goalID: UUID) {
        var changed = false
        for link in Self.links(goalID: goalID, in: context) {
            guard let messageID = link.reportMessageID else { continue }
            let status = GoalReviewLinkStatus(rawValue: link.statusRaw) ?? .running
            guard status == .running || status == .completed || status == .stale else { continue }
            guard let message = repository.loadMessageViewData(id: messageID) else {
                link.statusRaw = GoalReviewLinkStatus.unavailable.rawValue
                link.updatedAt = Date()
                changed = true
                continue
            }
            if status == .running, !message.isStreaming {
                if let rendered = message.agentResult {
                    link.statusRaw = (rendered.failure == nil ? GoalReviewLinkStatus.completed : .failed).rawValue
                    link.completedAt = rendered.failure == nil ? Date() : nil
                    link.failureReason = rendered.failure.map(Self.describe)
                } else {
                    link.statusRaw = GoalReviewLinkStatus.failed.rawValue
                    link.failureReason = String(localized: "分析没有产生结果")
                }
                link.updatedAt = Date()
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    private func updateLinkStatus(reviewID: UUID, status: GoalReviewLinkStatus, failureReason: String?) {
        guard let link = Self.link(reviewID: reviewID, in: context) else { return }
        link.statusRaw = status.rawValue
        link.failureReason = failureReason
        link.updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(name: Self.reviewStateDidChange, object: link.goalID)
    }

    // MARK: - 索引存取（nonisolated static：测试与后台 context 共用）

    /// 轻量到期判定（列表卡片用，不构建快照）：与 GoalEvaluationSnapshotBuilder.buildReview 同一规则——
    /// 有完成过的回顾按「上次完成 + 周期」，否则按计划 nextReviewAt；关闭定期回顾永不到期；无 v2 计划不到期
    nonisolated static func isReviewDue(goalID: UUID, now: Date = Date(), calendar: Calendar = .current,
                                        in context: NSManagedObjectContext) -> Bool {
        guard let payload = GoalPlanRevisionStore.latestRevisionRow(goalID: goalID, in: context)?.planPayloadV2,
              let review = payload.review, let cadence = review.cadenceDays, cadence > 0 else { return false }
        let request = NSFetchRequest<GoalReviewLinkMO>(entityName: "GoalReviewLinkMO")
        request.predicate = NSPredicate(format: "goalID == %@ AND statusRaw == %@ AND deletedAt == nil",
                                        goalID as CVarArg, GoalReviewLinkStatus.completed.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: false)]
        request.fetchLimit = 1
        if let completedAt = (try? context.fetch(request))?.first?.completedAt,
           let next = calendar.date(byAdding: .day, value: cadence, to: completedAt) {
            return next <= now
        }
        if let next = review.nextReviewAt { return next <= now }
        return false
    }

    nonisolated static func links(goalID: UUID, in context: NSManagedObjectContext) -> [GoalReviewLinkMO] {
        let request = NSFetchRequest<GoalReviewLinkMO>(entityName: "GoalReviewLinkMO")
        request.predicate = NSPredicate(format: "goalID == %@ AND deletedAt == nil", goalID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        var seen = Set<UUID>()
        return ((try? context.fetch(request)) ?? []).filter { seen.insert($0.reviewID).inserted }
    }

    nonisolated static func link(reviewID: UUID, in context: NSManagedObjectContext) -> GoalReviewLinkMO? {
        let request = NSFetchRequest<GoalReviewLinkMO>(entityName: "GoalReviewLinkMO")
        request.predicate = NSPredicate(format: "reviewID == %@ AND deletedAt == nil", reviewID as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    nonisolated static func link(reportMessageID: UUID, in context: NSManagedObjectContext) -> GoalReviewLinkMO? {
        let request = NSFetchRequest<GoalReviewLinkMO>(entityName: "GoalReviewLinkMO")
        request.predicate = NSPredicate(format: "reportMessageID == %@ AND deletedAt == nil", reportMessageID as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 同依据（goalID + planRevisionID + sourceDigest）且仍有效的索引：去重判定用
    nonisolated static func matchingLink(scope: HoloAgentGoalScope, in context: NSManagedObjectContext) -> GoalReviewLinkMO? {
        let request = NSFetchRequest<GoalReviewLinkMO>(entityName: "GoalReviewLinkMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND planRevisionID == %@ AND sourceDigest == %@ AND deletedAt == nil AND (statusRaw == %@ OR statusRaw == %@)",
            scope.goalID as CVarArg, scope.planRevisionID as CVarArg, scope.sourceDigest,
            GoalReviewLinkStatus.running.rawValue, GoalReviewLinkStatus.completed.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    @discardableResult
    nonisolated static func createLink(in context: NSManagedObjectContext,
                                       scope: HoloAgentGoalScope,
                                       reportMessageID: UUID,
                                       now: Date = Date()) throws -> GoalReviewLinkMO {
        let link = GoalReviewLinkMO(context: context)
        link.id = UUID()
        link.schemaVersion = 1
        link.goalID = scope.goalID
        link.planRevisionID = scope.planRevisionID
        link.reviewID = scope.reviewID
        link.reportMessageID = reportMessageID
        link.windowStart = scope.windowStart
        link.windowEndExclusive = scope.windowEndExclusive
        link.snapshotCutoffAt = scope.snapshotCutoffAt
        link.timeZoneID = scope.timeZoneID
        link.sourceDigest = scope.sourceDigest
        link.statusRaw = GoalReviewLinkStatus.running.rawValue
        link.createdAt = now
        link.updatedAt = now
        try context.save()
        return link
    }

    nonisolated static func summary(_ link: GoalReviewLinkMO) -> GoalReviewLinkSummary {
        GoalReviewLinkSummary(
            id: link.id,
            reviewID: link.reviewID,
            planRevisionID: link.planRevisionID,
            reportMessageID: link.reportMessageID,
            status: GoalReviewLinkStatus(rawValue: link.statusRaw) ?? .running,
            sourceDigest: link.sourceDigest,
            windowStart: link.windowStart,
            windowEndExclusive: link.windowEndExclusive,
            snapshotCutoffAt: link.snapshotCutoffAt,
            createdAt: link.createdAt,
            completedAt: link.completedAt,
            failureReason: link.failureReason
        )
    }

    // MARK: - 文案

    static func reviewQuestion(goalTitle: String) -> String {
        String(localized: "回顾目标「\(goalTitle)」：这段时间行动做了多少、结果变化多少、差距在哪里，下一步该继续什么、调整什么。")
    }

    static func describe(_ error: GoalPlanResolveError) -> String {
        switch error {
        case .unsupportedFutureSchema(let version):
            return String(localized: "这个目标的计划由更新版本的 Holo 写入（schema \(version)），当前版本只能查看，不能分析或修改")
        case .corruptedPayload:
            return String(localized: "目标计划数据损坏，无法分析")
        case .goalDeleted:
            return String(localized: "目标已删除")
        }
    }

    static func describe(_ failure: HoloRenderedAgentFailure) -> String {
        switch failure {
        case .quotaExhausted(let message): return message
        case .analysisFailed: return String(localized: "分析失败")
        case .executionSuspended: return String(localized: "分析被系统暂停")
        case .continuationUnavailable(let message): return message
        }
    }
}
