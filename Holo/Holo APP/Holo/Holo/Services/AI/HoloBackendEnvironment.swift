//
//  HoloBackendEnvironment.swift
//  Holo
//
//  Holo 后端网关环境配置
//

import Foundation

enum HoloBackendEnvironment {
    static var isEnabledByDefault: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static var baseURL: String {
        ProcessInfo.processInfo.environment["HOLO_BACKEND_URL"] ?? "http://123.56.104.9"
    }

    @MainActor
    static func makeDefaultProvider() -> AIProvider {
        if isEnabledByDefault {
            return HoloBackendAIProvider(baseURL: baseURL)
        }
        return MockAIProvider()
    }
}
