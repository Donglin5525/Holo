//
//  HoloBackendPromptService.swift
//  Holo
//
//  从 Holo 后端读取托管 Prompt。失败时由调用方回退到本地默认模板。
//

#if DEBUG
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

    // 版本化缓存：原始正文 + 版本号 + 加载时间。
    // 不缓存已渲染正文，避免 {{currentTime}} 等运行时变量被冻结。
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
                    if cached.version == metaVersion {
                        return cached.renderedPrompt(type: type)
                    }
                    // 后端版本已变化，清除缓存重新加载
                    logger.info("后端 Prompt 版本变化：\(type.rawValue) v\(cached.version) → v\(metaVersion)")
                } else {
                    // meta 中无此 type，缓存仍有效
                    return cached.renderedPrompt(type: type)
                }
            } else {
                // meta 加载失败，使用本地缓存
                return cached.renderedPrompt(type: type)
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
        cache[type] = CachedPrompt(
            version: response.version,
            rawContent: response.content,
            loadedAt: Date()
        )
        let prompt = LoadedPrompt(
            type: type,
            version: response.version,
            content: PromptManager.shared.renderTemplate(response.content)
        )
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
    let version: Int
    let rawContent: String
    let loadedAt: Date

    @MainActor
    func renderedPrompt(type: PromptManager.PromptType) -> LoadedPrompt {
        LoadedPrompt(
            type: type,
            version: version,
            content: PromptManager.shared.renderTemplate(rawContent)
        )
    }
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
#endif
