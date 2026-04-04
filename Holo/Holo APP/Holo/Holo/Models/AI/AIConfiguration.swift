//
//  AIConfiguration.swift
//  Holo
//
//  AI Provider 配置模型
//  定义各 LLM 服务商的连接参数
//

import Foundation

/// LLM 服务商类型
enum AIProviderType: String, Codable, CaseIterable {
    case deepseek = "DeepSeek"
    case qwen = "通义千问"
    case moonshot = "Moonshot"
    case zhipu = "智谱"
    case custom = "自定义"

    /// 默认 Base URL
    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .custom: return ""
        }
    }

    /// 默认模型名称
    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-turbo"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .custom: return ""
        }
    }

    var displayName: String { rawValue }
}

/// AI Provider 配置
struct AIProviderConfig: Codable {
    var provider: AIProviderType
    var apiKey: String
    var model: String
    var baseURL: String
    var temperature: Double
    var maxTokens: Int

    init(
        provider: AIProviderType = .deepseek,
        apiKey: String = "",
        model: String? = nil,
        baseURL: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model ?? provider.defaultModel
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// 是否已配置有效的 API Key
    var isConfigured: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }
}
