//
//  HoloBackendEnvironment.swift
//  Holo
//
//  Holo 后端网关环境配置
//

import Foundation

nonisolated enum HoloBackendEnvironment {
    static var isEnabledByDefault: Bool {
        return true
    }

    static var baseURL: String {
        ProcessInfo.processInfo.environment["HOLO_BACKEND_URL"] ?? "https://api.holoapp.cn"
    }

    @MainActor
    static func makeDefaultProvider() -> AIProvider {
        if isEnabledByDefault {
            return HoloBackendAIProvider(baseURL: baseURL)
        }
        return MockAIProvider()
    }
}
