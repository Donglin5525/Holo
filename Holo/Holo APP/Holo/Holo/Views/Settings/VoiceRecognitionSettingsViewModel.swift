//
//  VoiceRecognitionSettingsViewModel.swift
//  Holo
//
//  语音识别配置 ViewModel
//

import Combine
import Foundation
import os.log

#if DEBUG

@MainActor
final class VoiceRecognitionSettingsViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var region: VoiceRecognitionRegion = .beijing
    @Published var model: String = "qwen3-asr-flash-realtime"
    @Published var language: String = "zh"
    @Published var sampleRate: Int = 16_000
    @Published var isTesting = false
    @Published var testResult: TestResult?
    @Published var isConfigured = false
    @Published var isLoading = true

    private let logger = Logger(subsystem: "com.holo.app", category: "VoiceRecognitionSettings")

    enum TestResult {
        case success(String)
        case failure(String)
    }

    func loadConfig() async {
        do {
            let config = try await Task.detached {
                try KeychainService.loadVoiceRecognitionConfigOffMain()
            }.value

            if let config {
                apiKey = config.apiKey
                region = config.region
                model = config.model
                language = config.language
                sampleRate = config.sampleRate
                isConfigured = config.isConfigured
                KeychainService.updateCachedVoiceRecognitionConfigPresence(config.isConfigured)
            }
        } catch {
            logger.error("加载语音识别配置失败：\(error.localizedDescription)")
        }

        isLoading = false
    }

    func saveConfig() async {
        let config = buildConfig()

        do {
            try await Task.detached {
                try KeychainService.saveVoiceRecognitionConfigOffMain(config)
            }.value
            isConfigured = config.isConfigured
            logger.info("语音识别配置已保存")
        } catch {
            logger.error("保存语音识别配置失败：\(error.localizedDescription)")
            testResult = .failure(error.localizedDescription)
        }
    }

    func deleteConfig() async {
        do {
            try await Task.detached {
                try KeychainService.deleteVoiceRecognitionConfigOffMain()
            }.value
            apiKey = ""
            isConfigured = false
            testResult = nil
            logger.info("语音识别配置已删除")
        } catch {
            logger.error("删除语音识别配置失败：\(error.localizedDescription)")
            testResult = .failure(error.localizedDescription)
        }
    }

    func testConnection() async {
        isTesting = true
        testResult = nil

        let config = buildConfig()
        guard config.isConfigured else {
            testResult = .failure("请先填写 API Key 和模型名称")
            isTesting = false
            return
        }

        do {
            try await AliyunQwenASRRealtimeProvider(config: config).testConnection()
            testResult = .success("连接成功")
        } catch {
            testResult = .failure(error.localizedDescription)
        }

        isTesting = false
    }

    private func buildConfig() -> VoiceRecognitionConfig {
        VoiceRecognitionConfig(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "qwen3-asr-flash-realtime" : model,
            language: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "zh" : language,
            sampleRate: sampleRate
        )
    }
}
#endif
