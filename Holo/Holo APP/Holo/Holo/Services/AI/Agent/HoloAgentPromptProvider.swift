//
//  HoloAgentPromptProvider.swift
//  Holo
//
//  Agent systemTemplate 的统一获取入口。
//  修复 Release configuration 编译阻塞：
//  HoloAgentAnalysisService / HoloBackgroundContinuationManager 原先调用
//  PromptManager.shared.loadRawTemplate(.agentLoop)，但 loadRawTemplate 在 Release stub
//  里不存在（PromptManager 整类 #if DEBUG），导致 Release 编译失败。
//
//  后端 injectServerPrompt（serverPromptPolicy.js）已为 agent_loop purpose 注入完整
//  system prompt（人格层 + agentLoop 正文 + contract appendix + 变量渲染）。
//  因此客户端组装的 systemTemplate 在正常后端链路下是冗余的——它的作用是保持
//  HoloAgentPromptBuilder 消息结构完整，并在后端异常时提供最小协议约束。
//
//  本 Provider 不烘焙商业 Prompt 正文：
//  - Debug：后端优先，失败回退 PromptManager 本地内嵌模板（开发断网可用）。
//  - Release：后端优先，失败返回安全占位（最小协议提示），绝不内嵌完整正文。
//

import Foundation
import os.log

/// Agent systemTemplate 的统一获取入口。Debug/Release 都编译。
enum HoloAgentPromptProvider {

    private static let logger = Logger(subsystem: "com.holo.app", category: "HoloAgentPromptProvider")

    /// 获取已渲染变量的 agentLoop systemTemplate。
    ///
    /// - Debug：后端 `/v1/prompts/agent_loop` 优先，失败回退本地内嵌模板。
    /// - Release：后端优先，失败返回安全占位。
    /// - Returns: 非空的 systemTemplate 字符串。绝不返回 nil。
    static func agentLoopSystemTemplate(
        apiClient: APIClient = .shared,
        baseURL: String = HoloBackendEnvironment.baseURL,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) async -> String {
        // 后端注入已是 agent_loop 的权威 prompt 来源，客户端只需一份本地消息结构占位。
        // 优先尝试后端拉取，拿不到就用本地兜底（Debug）或安全占位（Release）。
        let backend = await fetchFromBackend(
            apiClient: apiClient,
            baseURL: baseURL,
            deviceIdProvider: deviceIdProvider
        )
        if let backend {
            return backend
        }

        return fallbackTemplate()
    }

    // MARK: - Backend Fetch

    /// 从后端 `/v1/prompts/agent_loop` 拉取已渲染变量的 prompt 正文。
    /// Release 可见（不依赖任何 DEBUG-only 类型）。
    private static func fetchFromBackend(
        apiClient: APIClient,
        baseURL: String,
        deviceIdProvider: () -> String
    ) async -> String? {
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/prompts/agent_loop",
            method: .get,
            headers: ["X-Holo-Device-Id": deviceIdProvider()],
            body: nil
        )
        do {
            let response: HoloBackendPromptBody = try await apiClient.send(request)
            let rendered = HoloPromptVariableRenderer.renderVariables(in: response.content)
            logger.info("已加载后端 agent_loop prompt v\(response.version)")
            return rendered
        } catch {
            logger.warning("后端 agent_loop prompt 拉取失败，使用本地兜底：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Fallback

#if DEBUG
    /// Debug：回退到 PromptManager 的本地内嵌模板（含完整正文，开发断网可用）。
    private static func fallbackTemplate() -> String {
        let raw = PromptManager.shared.loadRawTemplate(.agentLoop)
        return HoloPromptVariableRenderer.renderVariables(in: raw)
    }
#else
    /// Release：安全占位。不含商业 Prompt 正文，仅保证消息结构完整 + 最小协议约束。
    /// 真正的 system prompt 由后端 injectServerPrompt 注入。
    private static func fallbackTemplate() -> String {
        HoloAgentPromptFallbacks.agentLoopSafePlaceholder
    }
#endif
}

/// 后端 prompt 响应体（Release 可见，独立于 DEBUG-only 的 HoloBackendPromptService）。
private struct HoloBackendPromptBody: Decodable {
    let type: String
    let version: Int
    let content: String
}
