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
#if DEBUG
        ProcessInfo.processInfo.environment["HOLO_BACKEND_URL"] ?? "http://123.56.104.9:8787"
#else
        ProcessInfo.processInfo.environment["HOLO_BACKEND_URL"] ?? "https://api.holoapp.cn"
#endif
    }

    @MainActor
    static func makeDefaultProvider() -> AIProvider {
        if isEnabledByDefault {
            return HoloBackendAIProvider(baseURL: baseURL)
        }
        return MockAIProvider()
    }
}
