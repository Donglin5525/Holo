//
//  AccountDataDeletionService.swift
//  Holo
//
//  Handles the App Store account/data deletion entry.
//

import CoreData
import Foundation
import OSLog

struct AccountDataDeletionResult: Equatable {
    let deletedObjectCount: Int
}

enum AccountDataDeletionError: LocalizedError {
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "无法识别当前 App 的 Bundle ID"
        }
    }
}

@MainActor
final class AccountDataDeletionService {

    static let shared = AccountDataDeletionService()

    private let logger = Logger(subsystem: "com.holo.app", category: "AccountDataDeletionService")

    private init() {}

    func deleteAccountAndLocalData() async throws -> AccountDataDeletionResult {
        await CoreDataStack.shared.waitUntilReady()
        let deletedObjectCount = try await deleteCoreDataObjects()

        try deleteLocalFiles()
        try deleteKeychainItems()
        try resetUserDefaults()

        logger.info("账号与本机数据删除完成，Core Data 对象数：\(deletedObjectCount)")
        return AccountDataDeletionResult(deletedObjectCount: deletedObjectCount)
    }

    private func deleteCoreDataObjects() async throws -> Int {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let entities = CoreDataStack.shared.persistentContainer.managedObjectModel.entities
                .filter { !$0.isAbstract }
                .compactMap(\.name)

            var deletedCount = 0

            for entityName in entities {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.includesPropertyValues = false
                let objects = try context.fetch(request)
                for object in objects {
                    context.delete(object)
                }
                deletedCount += objects.count
            }

            try context.save()
            return deletedCount
        }
    }

    private func deleteLocalFiles() throws {
        let fileManager = FileManager.default
        let directories: [URL] = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Holo", isDirectory: true),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Attachments", isDirectory: true),
            fileManager.temporaryDirectory
                .appendingPathComponent("holo-voice-input", isDirectory: true)
        ]

        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }

        let importFile = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("holo_import.csv")
        if fileManager.fileExists(atPath: importFile.path) {
            try fileManager.removeItem(at: importFile)
        }
    }

    private func deleteKeychainItems() throws {
        try KeychainService.shared.deleteAppleAuthSession()
        try KeychainService.shared.deleteAIConfig()
        try KeychainService.deleteVoiceRecognitionConfigOffMain()
    }

    private func resetUserDefaults() throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AccountDataDeletionError.missingBundleIdentifier
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }
}
