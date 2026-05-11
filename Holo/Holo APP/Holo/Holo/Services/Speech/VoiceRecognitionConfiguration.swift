//
//  VoiceRecognitionConfiguration.swift
//  Holo
//
//  语音识别服务配置
//

import Foundation

nonisolated enum VoiceRecognitionRegion: String, Codable, CaseIterable {
    case beijing
    case singapore

    var displayName: String {
        switch self {
        case .beijing:
            return "中国内地（北京）"
        case .singapore:
            return "国际（新加坡）"
        }
    }

    var websocketURL: String {
        switch self {
        case .beijing:
            return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        case .singapore:
            return "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"
        }
    }
}

nonisolated struct VoiceRecognitionConfig: Codable, Equatable {
    var apiKey: String
    var region: VoiceRecognitionRegion
    var model: String
    var language: String
    var sampleRate: Int

    init(
        apiKey: String = "",
        region: VoiceRecognitionRegion = .beijing,
        model: String = "qwen3-asr-flash-realtime",
        language: String = "zh",
        sampleRate: Int = 16_000
    ) {
        self.apiKey = apiKey
        self.region = region
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var endpointURL: URL? {
        var components = URLComponents(string: region.websocketURL)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        return components?.url
    }
}
