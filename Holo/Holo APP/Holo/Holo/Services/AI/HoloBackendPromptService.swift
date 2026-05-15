//
//  HoloBackendPromptService.swift
//  Holo
//
//  从 Holo 后端读取托管 Prompt。失败时由调用方回退到本地默认模板。
//

import Foundation
import os.log

@MainActor
final class HoloBackendPromptService {

    static let shared = HoloBackendPromptService()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloBackendPromptService")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String
    private var cache: [PromptManager.PromptType: String] = [:]

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
    }

    func loadPrompt(_ type: PromptManager.PromptType) async throws -> String {
        if let cached = cache[type] {
            return cached
        }

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
        cache[type] = rendered
        logger.info("已加载后端 Prompt：\(response.type) v\(response.version)")
        return rendered
    }

    func clearCache() {
        cache.removeAll()
    }
}

private struct HoloBackendPromptResponse: Decodable {
    let type: String
    let version: Int
    let content: String
}
