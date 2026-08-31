import CoreData
import Foundation
import OSLog

private let sensitiveMigrationLogger = Logger(subsystem: "com.holo.app", category: "SensitiveDebugMigration")

enum SensitiveDebugDataMigration {
    private static let completionKey = "holo.migration.sensitiveDebugData.v1"
    /// 完成标记存 Keychain 而非 UserDefaults：本迁移会删 Keychain 里的 AI/语音配置，
    /// 若标记随 UserDefaults 卸载清空，重装后会重跑迁移、把用户正式配置的 Key 一并误删
    private static let keychainCompletionAccount = "com.holo.migration.sensitiveDebugData.v1"

    private static var hasCompletedInKeychain: Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainCompletionAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return false }
        return data == Data([1])
    }

    private static func markCompletedInKeychain() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainCompletionAccount
        ] as CFDictionary)
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainCompletionAccount,
            kSecValueData as String: Data([1]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: completionKey), !hasCompletedInKeychain else { return }
        await CoreDataStack.shared.waitUntilReady()

        let context = CoreDataStack.shared.newBackgroundContext()
        do {
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "ChatMessage")
                request.predicate = NSPredicate(format: "rawLogJSON != nil")
                for message in try context.fetch(request) {
                    message.setValue(nil, forKey: "rawLogJSON")
                }
                if context.hasChanges { try context.save() }
            }
            try? KeychainService.deleteAIConfigOffMain()
            try? KeychainService.deleteVoiceRecognitionConfigOffMain()
            defaults.set(true, forKey: completionKey)
            markCompletedInKeychain()
        } catch {
            sensitiveMigrationLogger.warning("历史敏感调试数据清理失败，将在下次启动重试")
        }
    }
}
