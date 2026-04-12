//
//  KeychainService.swift
//  Holo
//
//  Keychain 安全存储服务
//  用于保存 API Key 等敏感信息
//

import Foundation
import Security
import os.log

@MainActor
final class KeychainService {

    static let shared = KeychainService()

    private let logger = Logger(subsystem: "com.holo.app", category: "KeychainService")

    private init() {}

    // MARK: - Base CRUD

    func save(key: String, data: Data) throws {
        // 先删除已有的
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            logger.error("Keychain save 失败: \(status)")
            throw KeychainError.saveFailed(status)
        }
    }

    func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain load 失败: \(status)")
            throw KeychainError.loadFailed(status)
        }
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Keychain delete 失败: \(status)")
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - AI Config 便捷方法

    private static let aiConfigKey = "com.holo.ai.config"
    private static let aiConfigPresenceKey = "com.holo.ai.configured"

    nonisolated static var hasCachedAIConfig: Bool {
        UserDefaults.standard.bool(forKey: aiConfigPresenceKey)
    }

    nonisolated static func updateCachedAIConfigPresence(_ configured: Bool) {
        UserDefaults.standard.set(configured, forKey: aiConfigPresenceKey)
    }

    func saveAIConfig(_ config: AIProviderConfig) throws {
        let data = try JSONEncoder().encode(config)
        try save(key: Self.aiConfigKey, data: data)
        Self.updateCachedAIConfigPresence(config.isConfigured)
        logger.info("AI 配置已保存到 Keychain")
    }

    func loadAIConfig() throws -> AIProviderConfig? {
        guard let data = try load(key: Self.aiConfigKey) else {
            return nil
        }
        return try JSONDecoder().decode(AIProviderConfig.self, from: data)
    }

    /// 非主线程安全的 AI 配置读取（可在任意线程调用）
    /// 使用 nonisolated static 避免 @MainActor 限制，解决真机上 SecItemCopyMatching 阻塞主线程的问题
    nonisolated static func loadAIConfigOffMain() throws -> AIProviderConfig? {
        let key = "com.holo.ai.config"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(AIProviderConfig.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    func deleteAIConfig() throws {
        try delete(key: Self.aiConfigKey)
        Self.updateCachedAIConfigPresence(false)
        logger.info("AI 配置已从 Keychain 删除")
    }

    // MARK: - 非主线程安全操作

    /// 非主线程安全的 AI 配置保存（可在任意线程调用）
    nonisolated static func saveAIConfigOffMain(_ config: AIProviderConfig) throws {
        let key = "com.holo.ai.config"
        let data = try JSONEncoder().encode(config)

        // 先删除已有的
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }

        updateCachedAIConfigPresence(config.isConfigured)
    }

    /// 非主线程安全的 AI 配置删除（可在任意线程调用）
    nonisolated static func deleteAIConfigOffMain() throws {
        let key = "com.holo.ai.config"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }

        updateCachedAIConfigPresence(false)
    }
}

// MARK: - Keychain Error

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain 保存失败（错误码：\(status)）"
        case .loadFailed(let status):
            return "Keychain 读取失败（错误码：\(status)）"
        case .deleteFailed(let status):
            return "Keychain 删除失败（错误码：\(status)）"
        }
    }
}
