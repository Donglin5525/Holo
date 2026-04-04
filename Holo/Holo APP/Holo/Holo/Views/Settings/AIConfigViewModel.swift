//
//  AIConfigViewModel.swift
//  Holo
//
//  AI 配置 ViewModel
//  管理 API Key 存储、Provider 选择和连接测试
//

import Foundation
import Combine
import os.log

@MainActor
final class AIConfigViewModel: ObservableObject {

    @Published var selectedProvider: AIProviderType = .deepseek
    @Published var apiKey: String = ""
    @Published var customBaseURL: String = ""
    @Published var customModel: String = ""
    @Published var temperature: Double = 0.7
    @Published var maxTokens: Int = 2048
    @Published var isTesting = false
    @Published var testResult: TestResult?
    @Published var isConfigured = false

    private let logger = Logger(subsystem: "com.holo.app", category: "AIConfigViewModel")
    private let keychainService: KeychainService

    enum TestResult {
        case success(String)
        case failure(String)
    }

    init(keychainService: KeychainService = .shared) {
        self.keychainService = keychainService
        loadConfig()
    }

    // MARK: - Load / Save

    func loadConfig() {
        do {
            if let config = try keychainService.loadAIConfig() {
                selectedProvider = config.provider
                apiKey = config.apiKey
                temperature = config.temperature
                maxTokens = config.maxTokens

                if config.provider == .custom {
                    customBaseURL = config.baseURL
                    customModel = config.model
                }

                isConfigured = config.isConfigured
            }
        } catch {
            logger.error("加载 AI 配置失败：\(error.localizedDescription)")
        }
    }

    func saveConfig() {
        let config = buildConfig()

        do {
            try keychainService.saveAIConfig(config)
            isConfigured = config.isConfigured
            logger.info("AI 配置已保存")
        } catch {
            logger.error("保存 AI 配置失败：\(error.localizedDescription)")
        }
    }

    func deleteConfig() {
        do {
            try keychainService.deleteAIConfig()
            apiKey = ""
            isConfigured = false
            testResult = nil
            logger.info("AI 配置已删除")
        } catch {
            logger.error("删除 AI 配置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Test Connection

    func testConnection() async {
        isTesting = true
        testResult = nil

        let config = buildConfig()

        guard config.isConfigured else {
            testResult = .failure("请先填写 API Key")
            isTesting = false
            return
        }

        let provider = OpenAICompatibleProvider(config: config)

        do {
            let result = try await provider.chat(
                messages: [.user("你好")],
                userContext: UserContext(
                    todayDate: "测试",
                    transactions: TransactionSummary(todayExpense: "0", todayIncome: "0", recentTransactions: []),
                    habits: HabitSummary(totalActive: 0, todayCompleted: 0, todayTotal: 0, recentCheckIns: []),
                    tasks: TaskSummary(todayTotal: 0, todayCompleted: 0, overdueCount: 0, recentTasks: []),
                    thoughts: ThoughtSummary(recentThoughts: [], totalThoughts: 0)
                )
            )
            testResult = .success("连接成功：\(result.prefix(50))...")
        } catch {
            testResult = .failure(error.localizedDescription)
        }

        isTesting = false
    }

    // MARK: - Provider Update

    func updateProvider(_ provider: AIProviderType) {
        selectedProvider = provider
        if provider != .custom {
            customBaseURL = provider.defaultBaseURL
            customModel = provider.defaultModel
        }
    }

    // MARK: - Private

    private func buildConfig() -> AIProviderConfig {
        if selectedProvider == .custom {
            return AIProviderConfig(
                provider: .custom,
                apiKey: apiKey,
                model: customModel.isEmpty ? "custom-model" : customModel,
                baseURL: customBaseURL,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }

        return AIProviderConfig(
            provider: selectedProvider,
            apiKey: apiKey,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }
}
