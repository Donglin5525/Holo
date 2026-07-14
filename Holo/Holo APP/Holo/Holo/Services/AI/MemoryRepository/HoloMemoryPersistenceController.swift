//
//  HoloMemoryPersistenceController.swift
//  Holo
//
//  普通记忆与本机敏感记忆的双物理 Store
//

import CoreData
import Foundation

final class HoloMemoryPersistenceController: @unchecked Sendable {
    let mainContainer: NSPersistentContainer
    let sensitiveContainer: NSPersistentContainer
    let sensitiveStoreHasCloudKitOptions = false

    convenience init(inMemory: Bool) throws {
        try self.init(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("holo-memory-in-memory-\(UUID().uuidString)"),
            inMemory: inMemory
        )
    }

    convenience init(directoryURL: URL) throws {
        try self.init(directoryURL: directoryURL, inMemory: false)
    }

    init(directoryURL: URL, inMemory: Bool) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let model = HoloMemoryManagedObjectModelFactory.makeModel()
        mainContainer = NSPersistentContainer(
            name: "HoloMemoryMain",
            managedObjectModel: model
        )
        sensitiveContainer = NSPersistentContainer(
            name: "HoloSensitiveMemory",
            managedObjectModel: model
        )

        try Self.configureAndLoad(
            mainContainer,
            url: directoryURL.appendingPathComponent("HoloMemoryMain.sqlite"),
            inMemory: inMemory
        )
        try Self.configureAndLoad(
            sensitiveContainer,
            url: directoryURL.appendingPathComponent("HoloSensitiveMemory.sqlite"),
            inMemory: inMemory
        )
    }

    init(mainContainer: NSPersistentContainer, sensitiveDirectoryURL: URL) throws {
        self.mainContainer = mainContainer
        let model = HoloMemoryManagedObjectModelFactory.makeModel()
        sensitiveContainer = NSPersistentContainer(
            name: "HoloSensitiveMemory",
            managedObjectModel: model
        )
        try FileManager.default.createDirectory(
            at: sensitiveDirectoryURL,
            withIntermediateDirectories: true
        )
        try Self.configureAndLoad(
            sensitiveContainer,
            url: sensitiveDirectoryURL.appendingPathComponent("HoloSensitiveMemory.sqlite"),
            inMemory: false
        )
    }

    private static func configureAndLoad(
        _ container: NSPersistentContainer,
        url: URL,
        inMemory: Bool
    ) throws {
        let description = NSPersistentStoreDescription()
        description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        description.url = inMemory ? URL(fileURLWithPath: "/dev/null") : url
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        // 敏感容器和测试主容器都不设置 cloudKitContainerOptions。
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
