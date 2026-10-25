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

        // 迁移前自动快照（方案 M03-b 硬保证 1）：检测到库文件将与当前模型发生迁移时，
        // 先整份拷贝库文件；快照失败即抛错拒绝加载——没有保险就不搬家，原库不动。
        try snapshotForMigrationIfNeeded(
            container: container,
            storeURL: url,
            inMemory: inMemory
        )

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // 硬保证 2 的收尾：迁移成功后按保留策略清理旧快照（最新 2 份、14 天）。
        pruneMigrationSnapshots(storeURL: url)
    }

    // MARK: - 迁移前快照（M03-b）

    /// 快照目录与库文件同目录：`<storeDir>/MigrationSnapshots/<容器名>-<时间戳>/`。
    static func migrationSnapshotsDirectory(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("MigrationSnapshots", isDirectory: true)
    }

    private static func snapshotForMigrationIfNeeded(
        container: NSPersistentContainer,
        storeURL: URL,
        inMemory: Bool
    ) throws {
        guard !inMemory else { return }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return // 新装：无旧库，不触发
        }

        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: storeURL,
                options: nil
            )
        } catch {
            // 元数据读不出来（疑似损坏）：保守按「需要迁移」处理，先拍快照再让加载去判定。
            NSLog("[HoloMemoryPersistence] 读取库元数据失败，保守拍快照: \(error.localizedDescription)")
            try copyStoreFilesForSnapshot(container: container, storeURL: storeURL)
            return
        }

        let model = container.managedObjectModel
        guard !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
            return // 模型兼容：不会发生迁移，不拍
        }

        try copyStoreFilesForSnapshot(container: container, storeURL: storeURL)
    }

    private static func copyStoreFilesForSnapshot(
        container: NSPersistentContainer,
        storeURL: URL
    ) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = migrationSnapshotsDirectory(storeURL: storeURL)
            .appendingPathComponent("\(container.name)-\(stamp)", isDirectory: true)

        // 必需文件：主库文件 + 可能存在的 WAL/SHM 边车。任一拷贝失败即整体失败并抛错。
        var candidates = [storeURL]
        for sidecar in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + sidecar)
            if FileManager.default.fileExists(atPath: url.path) {
                candidates.append(url)
            }
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        do {
            for source in candidates {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
            }
        } catch {
            // 快照不完整 = 没有保险：删除半成品目录并抛错，拒绝本次迁移。
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// 保留策略：每库最多最近 2 份、超过 14 天的删除。清理失败不影响加载（快照只是多占空间）。
    private static func pruneMigrationSnapshots(storeURL: URL) {
        let snapshotsRoot = migrationSnapshotsDirectory(storeURL: storeURL)
        let containerPrefix = storeURL.deletingPathExtension().lastPathComponent + "-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        func modifiedAt(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }

        let mine = entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix(containerPrefix) }
            .sorted { modifiedAt($0) > modifiedAt($1) }
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        for (index, url) in mine.enumerated() {
            if index >= 2 || modifiedAt(url) < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
