//
//  ThoughtVoiceSummaryProcessor.swift
//  Holo
//
//  观点语音智能总结处理器
//  调用后端 AI 将 ASR 原文整理为观点风格文本
//

import Foundation
import os.log

protocol VoiceTranscriptPostProcessing: Sendable {
    func process(_ text: String) async throws -> String
}

@MainActor
final class ThoughtVoiceSummaryProcessor: VoiceTranscriptPostProcessing {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtVoiceSummaryProcessor")
    private let aiProvider: HoloBackendAIProvider
    private let promptManager: PromptManager

    init(
        aiProvider: HoloBackendAIProvider,
        promptManager: PromptManager? = nil
    ) {
        self.aiProvider = aiProvider
        self.promptManager = promptManager ?? .shared
    }

    convenience init() {
        self.init(aiProvider: HoloBackendAIProvider())
    }

    func process(_ text: String) async throws -> String {
        let systemPrompt = (try? promptManager.loadPrompt(.thoughtVoiceSummary))
            ?? promptManager.loadDefaultTemplate(.thoughtVoiceSummary)

        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .user(text)
        ]

        let result = try await aiProvider.chat(
            messages: messages,
            purpose: .thoughtVoiceSummary
        )

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.warning("观点语音总结返回空结果")
            throw SummaryError.emptyResult
        }

        return trimmed
    }
}

enum SummaryError: LocalizedError {
    case emptyResult
    case timeout

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            return "总结结果为空"
        case .timeout:
            return "总结超时"
        }
    }
}
