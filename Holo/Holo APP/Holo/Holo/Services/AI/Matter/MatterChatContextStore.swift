//
//  MatterChatContextStore.swift
//  Holo
//
//  Matter-scoped Chat 的类型化上下文通道（方案 §13.5）
//
//  详情页「和 Holo 讨论这件事」→ enter(matterID:)；聊天页顶部胶囊展示并允许退出；
//  退出后下一条消息不再自动关联，避免上下文泄漏。
//  显式 matterID 贯穿全链路，禁止靠标题关键词反猜当前 Matter（方案 §4.2-8）。
//

import Foundation
import Combine

@MainActor
final class MatterChatContextStore: ObservableObject {

    static let shared = MatterChatContextStore()

    /// 当前生效的 Matter 对话上下文；nil = 普通聊天。
    @Published var active: HoloMatterConversationContext?

    /// 最近一次对账回执（「已更新到…·撤销」轻提示），nil 表示无待展示内容。
    @Published var lastFeedback: MatterFeedback?

    /// 歧义追问（「东京还是京都？」），由聊天页展示选项。
    @Published var pendingAmbiguity: HoloMatterAmbiguity?

    /// 待确认的计划修订提案（2026-09-23）：「建议加入计划：确定深圳到香港的交通」。
    @Published var pendingTaskProposal: PendingTaskProposal?

    /// 可恢复的上次上下文（2026-09-23：重启后上下文清空导致用户无感掉队——
    /// 以灰态幽灵条提示，用户点按才恢复，不自动挂载）。
    @Published var recoverableContext: RecoverableContext?

    nonisolated struct RecoverableContext: Equatable, Identifiable {
        var id: UUID { matterID }
        let matterID: UUID
        let title: String
        let enteredAt: Date
    }

    nonisolated struct PendingTaskProposal: Equatable, Identifiable {
        let id: String
        let draft: HoloMatterTaskDraft

        init(proposalID: String, draft: HoloMatterTaskDraft) {
            self.id = proposalID
            self.draft = draft
        }
    }

    /// 恢复提示窗口（方案拍板：24h 内的上下文才提示恢复）。
    nonisolated static let recoverableWindow: TimeInterval = 24 * 3600
    private nonisolated static let recentContextKey = "holo_matter_recent_context_v1"

    nonisolated struct MatterFeedback: Identifiable, Equatable {
        let id = UUID()
        let matterTitle: String
        let summaries: [String]
        /// 可撤销的自动更新事件（最新 resolve）。
        let revertEventID: UUID?
    }

    private init() {}

    func enter(matterID: UUID, source: HoloMatterConversationEntrySource) {
        active = HoloMatterConversationContext(matterID: matterID, source: source)
        lastFeedback = nil
        pendingAmbiguity = nil
        pendingTaskProposal = nil
        recoverableContext = nil
        Self.persistRecentContext(matterID: matterID, at: Date())
        // 进入/重进都给一次明确确认（2026-09-23 东林验收反馈：静默切换感知不到自己在聊哪件事）。
        // 重进同一件事也提示——避免「胶囊早已在、再点无变化」的空反馈。
        let title = HoloMatterRepository.shared.matter(id: matterID)?.title ?? ""
        if title.isEmpty {
            HoloToastCenter.shared.show(String(localized: "已进入这件事的对话"), type: .info)
        } else {
            HoloToastCenter.shared.show(String(localized: "正在聊「\(title)」"), type: .info)
        }
    }

    func exit() {
        active = nil
        lastFeedback = nil
        pendingAmbiguity = nil
        pendingTaskProposal = nil
        // 用户显式退出 = 不想再被关联，清掉恢复记录（不提示恢复）。
        Self.clearPersistedRecentContext()
        recoverableContext = nil
    }

    // MARK: - 上次上下文恢复（2026-09-23）

    /// enter 时写入持久化记录（重启后幽灵条的来源）。
    nonisolated private static func persistRecentContext(
        matterID: UUID, at: Date, defaults: UserDefaults = .standard
    ) {
        let payload: [String: Any] = [
            "matterID": matterID.uuidString,
            "enteredAt": at.timeIntervalSince1970
        ]
        defaults.set(payload, forKey: recentContextKey)
    }

    nonisolated private static func clearPersistedRecentContext(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: recentContextKey)
    }

    /// 对话页出现时调用：读持久化记录，构造可恢复提示。
    /// 条件：记录在窗口内、事项仍存在且 active。默认单例便于生产；测试注入隔离仓库。
    @MainActor
    func loadRecoverableIfAny(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        repository: HoloMatterRepository = .shared
    ) {
        guard active == nil, recoverableContext == nil else { return }
        guard let payload = defaults.dictionary(forKey: Self.recentContextKey),
              let idString = payload["matterID"] as? String,
              let matterID = UUID(uuidString: idString),
              let enteredAtInterval = payload["enteredAt"] as? Double else {
            return
        }
        let enteredAt = Date(timeIntervalSince1970: enteredAtInterval)
        guard now.timeIntervalSince(enteredAt) <= Self.recoverableWindow else {
            Self.clearPersistedRecentContext(defaults: defaults)
            return
        }
        guard let matter = repository.matter(id: matterID),
              matter.lifecycle == .active else {
            Self.clearPersistedRecentContext(defaults: defaults)
            return
        }
        recoverableContext = RecoverableContext(matterID: matterID, title: matter.title, enteredAt: enteredAt)
    }

    /// 用户点按幽灵条：恢复为正式上下文（复用 enter 的全套反馈）。
    func restoreRecoverable() {
        guard let recoverable = recoverableContext else { return }
        enter(matterID: recoverable.matterID, source: .restored)
    }

    /// 用户点掉幽灵条：不再提示（持久化记录一并清除，等同显式退出的语义）。
    func dismissRecoverable(defaults: UserDefaults = .standard) {
        Self.clearPersistedRecentContext(defaults: defaults)
        recoverableContext = nil
    }

    /// 用户确认「加入计划」：接在计划末尾，回执带撤销。
    func confirmTaskProposal() {
        guard let pending = pendingTaskProposal else { return }
        guard let matterID = active?.matterID else {
            pendingTaskProposal = nil
            return
        }
        pendingTaskProposal = nil
        let draft = pending.draft
        Task { @MainActor in
            do {
                let result = try await HoloMatterRepository.shared.appendTaskToPlan(
                    matterID: matterID,
                    title: draft.title,
                    note: draft.note,
                    sourceProposalID: pending.id
                )
                let matterTitle = HoloMatterRepository.shared.matter(id: matterID)?.title ?? ""
                lastFeedback = MatterChatContextStore.MatterFeedback(
                    matterTitle: matterTitle,
                    summaries: [String(localized: "已加入计划：「\(draft.title)」")],
                    revertEventID: result.eventID
                )
                // 任务模块观察者刷新（新建了 TodoTask）
                NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
            } catch {
                HoloToastCenter.shared.show(String(localized: "没有加入成功，可以再试一次"), type: .error)
            }
        }
    }

    /// 用户忽略提案：不落库，仅收起。
    func dismissTaskProposal() {
        pendingTaskProposal = nil
    }

    /// 歧义消解（2026-09-23 自视图层下沉）：用户点选选项 = 显式语义，
    /// 按 resolved 落盘、刷新投影并给回执。视图层只管调这一下。
    func resolveAmbiguity(_ ambiguity: HoloMatterAmbiguity, option: HoloMatterAmbiguityOption) {
        pendingAmbiguity = nil
        guard let matterID = active?.matterID, let loopID = option.openLoopID else { return }
        Task { @MainActor in
            try? await HoloMatterRepository.shared.setOpenLoopState(
                id: loopID, state: .resolved, actor: .user,
                sourceRevision: ambiguity.id, sourceType: "chatMessage"
            )
            let matterTitle = HoloMatterRepository.shared.matter(id: matterID)?.title ?? ""
            let coordinator = HoloMatterReconciliationCoordinator()
            await coordinator.refreshProjection(matterID: matterID)
            lastFeedback = MatterChatContextStore.MatterFeedback(
                matterTitle: matterTitle,
                summaries: [String(localized: "已解决「\(option.title)」")],
                revertEventID: nil
            )
        }
    }
}
