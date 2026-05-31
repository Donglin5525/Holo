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
    func start(seedText: String?, userContext: UserContext, provider: AIProvider) async throws -> GoalPlanningTurnResult {
        let session = GoalPlanningSession.fresh(seedText: seedText)
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
