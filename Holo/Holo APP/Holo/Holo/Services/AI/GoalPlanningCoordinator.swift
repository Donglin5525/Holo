//
//  GoalPlanningCoordinator.swift
//  Holo
//
//  目标规划状态机：追问 → 草案生成 → 确认
//

import Foundation

struct GoalPlanningTurnResult: Equatable {
    var session: GoalPlanningSession
    var assistantText: String?
    var draft: GoalDraft?
}

@MainActor
final class GoalPlanningCoordinator {
    func start(seedText: String?, userContext: UserContext, provider: AIProvider,
               maxTurns: Int = GoalPlanningSession.defaultMaxTurns) async throws -> GoalPlanningTurnResult {
        let session = GoalPlanningSession.fresh(seedText: seedText, maxTurns: maxTurns)
        return try await nextQuestionOrDraft(session: session, userContext: userContext, provider: provider)
    }

    func handleUserReply(_ reply: String, session: GoalPlanningSession, userContext: UserContext, provider: AIProvider) async throws -> GoalPlanningTurnResult {
        var updated = session
        updated.answers.append(reply)
        updated.turnCount += 1
        return try await nextQuestionOrDraft(session: updated, userContext: userContext, provider: provider)
    }

    func regenerateDraft(session: GoalPlanningSession, mode: GoalPlanningMode, userContext: UserContext, provider: AIProvider) async throws -> GoalPlanningTurnResult {
        var updated = session
        updated.mode = mode
        let draft = try await generateDraft(session: updated, userContext: userContext, provider: provider)
        updated.draft = draft
        updated.status = .draftReady
        return GoalPlanningTurnResult(session: updated, assistantText: nil, draft: draft)
    }

    private func nextQuestionOrDraft(session: GoalPlanningSession, userContext: UserContext, provider: AIProvider) async throws -> GoalPlanningTurnResult {
        if session.turnCount >= session.maxTurns {
            var ready = session
            let draft = try await generateDraft(session: ready, userContext: userContext, provider: provider)
            ready.draft = draft
            ready.status = .draftReady
            return GoalPlanningTurnResult(session: ready, assistantText: nil, draft: draft)
        }

        let prompt = GoalPlanningPromptBuilder.questionPrompt(session: session, userContext: userContext)
        let response = try await provider.completeGoalPlanning(prompt: prompt, context: userContext)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if response == "DRAFT_READY" {
            var ready = session
            let draft = try await generateDraft(session: ready, userContext: userContext, provider: provider)
            ready.draft = draft
            ready.status = .draftReady
            return GoalPlanningTurnResult(session: ready, assistantText: nil, draft: draft)
        }

        var collecting = session
        collecting.status = .collecting
        return GoalPlanningTurnResult(session: collecting, assistantText: response, draft: nil)
    }

    private func generateDraft(session: GoalPlanningSession, userContext: UserContext, provider: AIProvider) async throws -> GoalDraft {
        let prompt = GoalPlanningPromptBuilder.draftPrompt(session: session, userContext: userContext)
        let response = try await provider.completeGoalPlanning(prompt: prompt, context: userContext)
        let json = extractJSON(response)
        guard let data = json.data(using: .utf8) else {
            throw GoalPlanningError.invalidDraftJSON
        }
        return try JSONDecoder().decode(GoalDraft.self, from: data)
    }

    private func extractJSON(_ text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}

enum GoalPlanningError: LocalizedError {
    case invalidDraftJSON

    var errorDescription: String? {
        switch self {
        case .invalidDraftJSON:
            return "目标草案解析失败"
        }
    }
}

/// 目标规划进行中会话的轻量持久化。
/// 会话此前只存 ChatViewModel 内存，切 Tab / 杀 App 即丢——用户回来继续回答时
/// 掉进普通聊天路由，被意图识别按字面判成建任务（2026-09-18 实锤事故）。
/// 会话语义是「用户进行中的一场问答」，生命周期应独立于页面：落 UserDefaults，
/// 恢复带时效，confirmed / cancelled / 额度终态即清。
enum GoalPlanningSessionStore {
    private static let key = "goal_planning_active_session_v1"

    /// 恢复时效：超过该间隔的未完成问答作废，防止陈旧会话吞掉用户的新消息
    static let staleInterval: TimeInterval = 2 * 60 * 60

    private struct Envelope: Codable {
        var session: GoalPlanningSession
        var draftForReview: GoalDraft?
        var lastActiveAt: Date
    }

    static func save(session: GoalPlanningSession, draftForReview: GoalDraft?) {
        let envelope = Envelope(session: session, draftForReview: draftForReview, lastActiveAt: Date())
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 读取未过期会话；过期或数据损坏视为无会话并清掉残留
    static func restore() -> (session: GoalPlanningSession, draftForReview: GoalDraft?)? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(envelope.lastActiveAt) < staleInterval else {
            clear()
            return nil
        }
        return (envelope.session, envelope.draftForReview)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
