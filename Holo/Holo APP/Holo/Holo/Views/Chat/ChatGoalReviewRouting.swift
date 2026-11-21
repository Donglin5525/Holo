//
//  ChatGoalReviewRouting.swift
//  Holo
//
//  对话里问目标 → 走目标复盘链路（2026-11-20 报告改版 D 期）。
//  根因：此前对话里问「我的目标怎么样」（含点「目标复盘」场景）都走 180 天全库快照，
//  没有任何代码把问题绑到某个目标上，报告只能拿任务/习惯凑数、答非所问。
//  规则：没有进行中目标 → 引导卡；问句点名或只有 1 个 → 直接复盘；多个 → 弹选择框。
//

import Foundation

/// 纯判定（可单测）
nonisolated enum ChatGoalReviewIntent {
    private static let progressWords = ["怎么样", "如何", "进展", "进度", "完成", "走到", "推进", "达成", "复盘", "回顾", "情况", "做得", "到哪"]

    static func isGoalQuestion(_ text: String, scenarioID: String?) -> Bool {
        if scenarioID == "goal" { return true }
        guard text.contains("目标") else { return false }
        return progressWords.contains { text.contains($0) }
    }

    /// 问句里点名的目标（标题被问句包含；多个命中取最长标题，避免「减肥」吃掉「减肥到 65」）
    static func mentionedGoalID(in text: String, goals: [(id: UUID, title: String)]) -> UUID? {
        goals
            .filter { !$0.title.isEmpty && text.contains($0.title) }
            .max { $0.title.count < $1.title.count }?
            .id
    }
}

/// 多个目标时等待用户选择的挂起请求
struct ChatPendingGoalReviewChoice: Identifiable, Equatable {
    struct Option: Identifiable, Equatable {
        let id: UUID
        let title: String
    }
    let id = UUID()
    let question: String
    let aiMessageID: UUID
    let intent: String?
    let options: [Option]
}

extension ChatViewModel {

    /// 拦截目标类问题；返回 true = 已接管（含引导卡 / 选择框 / 复盘发起）
    @MainActor
    func routeGoalReviewIfNeeded(question: String, aiMessageId: UUID, intent: String?, scenarioID: String?) async -> Bool {
        guard ChatGoalReviewIntent.isGoalQuestion(question, scenarioID: scenarioID) else { return false }
        let goals = GoalRepository.shared.activeGoals()
        guard !goals.isEmpty else {
            finalizeGoalReviewCard(aiMessageId, intent: intent,
                                   detail: String(localized: "你还没有进行中的目标。在「目标」里建一个目标、关联几个习惯或任务后，Holo 就能按这个目标帮你复盘。"))
            return true
        }
        let options = goals.map { (id: $0.id, title: $0.title) }
        if let mentioned = ChatGoalReviewIntent.mentionedGoalID(in: question, goals: options),
           let goal = goals.first(where: { $0.id == mentioned }) {
            await launchGoalReview(goal: goal, question: question, aiMessageId: aiMessageId, intent: intent)
            return true
        }
        if goals.count == 1, let only = goals.first {
            await launchGoalReview(goal: only, question: question, aiMessageId: aiMessageId, intent: intent)
            return true
        }
        pendingGoalReviewChoice = ChatPendingGoalReviewChoice(
            question: question, aiMessageID: aiMessageId, intent: intent,
            options: options.map { .init(id: $0.id, title: $0.title) }
        )
        return true
    }

    @MainActor
    func choosePendingGoalReview(_ optionID: UUID?) {
        guard let pending = pendingGoalReviewChoice else { return }
        pendingGoalReviewChoice = nil
        guard let optionID, let goal = GoalRepository.shared.activeGoals().first(where: { $0.id == optionID }) else {
            finalizeGoalReviewCard(pending.aiMessageID, intent: pending.intent,
                                   detail: String(localized: "这次没有选目标。想复盘时，直接说目标名字就行，比如「减肥目标最近怎么样」。"))
            return
        }
        Task { [weak self] in
            await self?.launchGoalReview(goal: goal, question: pending.question,
                                         aiMessageId: pending.aiMessageID, intent: pending.intent)
        }
    }

    @MainActor
    private func launchGoalReview(goal: Goal, question: String, aiMessageId: UUID, intent: String?) async {
        if goal.metricSourceEnum == .healthKit {
            await GoalHealthKitCache.shared.refreshIfNeeded(for: goal)
        }
        // 对话里的提问总是要一个回答：同依据的旧报告也重新生成，而不是把用户晾在占位上
        let outcome = await GoalReviewCoordinator.shared.startOrOpenReview(
            goal: goal, forceNew: true,
            handoff: .init(reportMessageID: aiMessageId, question: question)
        )
        switch outcome {
        case .started, .openedExisting:
            break
        case .resumedRunning:
            finalizeGoalReviewCard(aiMessageId, intent: intent,
                                   detail: String(localized: "「\(goal.title)」的复盘正在生成，完成后会出现在对话里。"))
        case .needsConsent:
            finalizeGoalReviewCard(aiMessageId, intent: intent, detail: String(localized: "深度分析需要先确认云端隐私说明。"))
        case .unavailable(let text), .failed(let text):
            finalizeGoalReviewCard(aiMessageId, intent: intent, detail: text)
        }
    }
}
