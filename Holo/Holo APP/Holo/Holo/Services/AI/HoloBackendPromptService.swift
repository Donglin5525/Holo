//
//  HoloBackendPromptService.swift
//  Holo
//
//  从 Holo 后端读取托管 Prompt。失败时由调用方回退到本地默认模板。
//

import Foundation
import os.log

struct LoadedPrompt: Sendable {
    let type: PromptManager.PromptType
    let version: Int
    let content: String
}

@MainActor
final class HoloBackendPromptService {

    static let shared = HoloBackendPromptService()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloBackendPromptService")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String

    // 版本化缓存：正文 + 版本号 + 加载时间
    private var cache: [PromptManager.PromptType: CachedPrompt] = [:]

    // Meta 缓存
    private var metaCache: [PromptMetadata]?
    private var metaLoadedAt: Date?

    private static let metaTTL: TimeInterval = 2 * 60 // 2 分钟

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
    }

    // MARK: - Public API

    /// 加载 Prompt 正文（兼容旧调用方）
    func loadPrompt(_ type: PromptManager.PromptType) async throws -> String {
        let result = try await loadPromptResult(type)
        return result.content
    }

    /// 加载 Prompt 正文 + 版本号
    func loadPromptResult(_ type: PromptManager.PromptType) async throws -> LoadedPrompt {
        // 检查本地缓存是否仍然有效（meta 检测到版本变化才需要重新加载）
        if let cached = cache[type] {
            let metaValid = await ensureMetaLoaded()
            if metaValid {
                if let metaVersion = metaCache?.first(where: { $0.type == type.rawValue })?.version {
                    if cached.prompt.version == metaVersion {
                        return cached.prompt
                    }
                    // 后端版本已变化，清除缓存重新加载
                    logger.info("后端 Prompt 版本变化：\(type.rawValue) v\(cached.prompt.version) → v\(metaVersion)")
                } else {
                    // meta 中无此 type，缓存仍有效
                    return cached.prompt
                }
            } else {
                // meta 加载失败，使用本地缓存
                return cached.prompt
            }
        }

        // 从后端加载正文
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/prompts/\(type.rawValue)",
            method: .get,
            headers: [
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: nil
        )

        let response: HoloBackendPromptResponse = try await apiClient.send(request)
        let rendered = PromptManager.shared.renderTemplate(response.content)
        let prompt = LoadedPrompt(type: type, version: response.version, content: rendered)
        cache[type] = CachedPrompt(prompt: prompt, loadedAt: Date())
        logger.info("已加载后端 Prompt：\(response.type) v\(response.version)")
        return prompt
    }

    /// 清除所有缓存（手动刷新时使用）
    func clearCache() {
        cache.removeAll()
        metaCache = nil
        metaLoadedAt = nil
        logger.info("Prompt 缓存已清除")
    }

    // MARK: - Meta Check

    /// 确保元数据已加载且未过期，返回是否成功
    private func ensureMetaLoaded() async -> Bool {
        if let loadedAt = metaLoadedAt, Date().timeIntervalSince(loadedAt) < Self.metaTTL, metaCache != nil {
            return true
        }

        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/prompts/meta",
            method: .get,
            headers: [
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: nil
        )

        do {
            let response: HoloBackendPromptMetaResponse = try await apiClient.send(request)
            metaCache = response.prompts
            metaLoadedAt = Date()
            return true
        } catch {
            logger.warning("Prompt meta 加载失败：\(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Private Types

private struct CachedPrompt {
    let prompt: LoadedPrompt
    let loadedAt: Date
}

private struct HoloBackendPromptResponse: Decodable {
    let type: String
    let version: Int
    let content: String
}

private struct PromptMetadata: Decodable {
    let type: String
    let version: Int
    let source: String
    let updatedAt: String?
}

private struct HoloBackendPromptMetaResponse: Decodable {
    let prompts: [PromptMetadata]
}
