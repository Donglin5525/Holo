import CoreData
import Foundation
import OSLog

private let sensitiveMigrationLogger = Logger(subsystem: "com.holo.app", category: "SensitiveDebugMigration")

enum SensitiveDebugDataMigration {
    private static let completionKey = "holo.migration.sensitiveDebugData.v1"

    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: completionKey) else { return }
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
        } catch {
            sensitiveMigrationLogger.warning("历史敏感调试数据清理失败，将在下次启动重试")
        }
    }
}
