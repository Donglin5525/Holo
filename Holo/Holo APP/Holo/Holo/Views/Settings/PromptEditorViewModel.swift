//
//  PromptEditorViewModel.swift
//  Holo
//
//  Prompt 编辑器 ViewModel
//  管理编辑状态、保存/重置、测试功能
//

import Combine
import Foundation
import os.log

@MainActor
final class PromptEditorViewModel: ObservableObject {

    // MARK: - 编辑状态

    @Published var editedContent: String = ""
    @Published var isSaving: Bool = false
    @Published var variablePreview: [String: String] = [:]

    // MARK: - 测试状态

    @Published var testInput: String = ""
    @Published var testResult: String?
    @Published var testError: String?
    @Published var isTesting: Bool = false
    @Published var showTestSheet: Bool = false

    // MARK: - 重置确认

    @Published var showResetConfirmation: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.holo.app", category: "PromptEditorViewModel")
    private let promptType: PromptManager.PromptType
    private let promptManager: PromptManager
    private let keychainService: KeychainService
    private let initialContent: String

    // MARK: - Computed

    var hasUnsavedChanges: Bool { editedContent != initialContent }

    var isCustomized: Bool { promptManager.isCustomized(promptType) }

    var canSave: Bool {
        !editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String { promptType.displayName }

    // MARK: - Init

    init(
        promptType: PromptManager.PromptType,
        promptManager: PromptManager = .shared,
        keychainService: KeychainService = .shared
    ) {
        self.promptType = promptType
        self.promptManager = promptManager
        self.keychainService = keychainService
        self.initialContent = promptManager.loadRawTemplate(promptType)
        self.editedContent = initialContent
        self.variablePreview = PromptManager.currentVariableValues()
    }

    // MARK: - 保存

    func save() {
        guard canSave else { return }
        promptManager.saveCustomPrompt(promptType, content: editedContent)
    }

    // MARK: - 重置

    func reset() {
        promptManager.resetCustomPrompt(promptType)
        editedContent = promptManager.loadRawTemplate(promptType)
    }

    // MARK: - 测试

    func runTest() async {
        guard !testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testError = "请输入测试文本"
            return
        }

        isTesting = true
        testResult = nil
        testError = nil

        do {
            let config = try await Task.detached {
                try KeychainService.loadAIConfigOffMain()
            }.value

            guard let config, config.isConfigured else {
                testError = "请先在 AI 设置中配置 API Key"
                isTesting = false
                return
            }

            let systemContent = promptManager.loadRawTemplate(promptType)
            let request = APIRequest(
                baseURL: config.baseURL,
                path: "/chat/completions",
                method: .post,
                headers: [
                    "Authorization": "Bearer \(config.apiKey)",
                    "Content-Type": "application/json"
                ],
                body: ChatCompletionRequest(
                    model: config.model,
                    messages: [
                        .system(systemContent),
                        .user(testInput)
                    ],
                    temperature: config.temperature,
                    maxTokens: config.maxTokens,
                    stream: false
                )
            )

            let response: ChatCompletionResponse = try await APIClient.shared.send(request)

            if let content = response.choices?.first?.message?.content {
                testResult = content
            } else {
                testError = "未收到有效响应"
            }
        } catch {
            testError = error.localizedDescription
            logger.error("Prompt 测试失败：\(error.localizedDescription)")
        }

        isTesting = false
    }
}
