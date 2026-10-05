//
//  CoreDataStoreRecoveryTests.swift
//  HoloTests
//
//  存储装载冲突恢复回归：模型指纹不匹配识别、冲突库三件套备份、
//  备份后重建空库装载成功（App 与小组件模型分叉导致的随机启动闪退防护）。
//  用临时目录 + 独立小模型驱动，不触碰共享 AppGroup 库。
//

import XCTest
import CoreData
import os.log
@testable import Holo

final class CoreDataStoreRecoveryTests: XCTestCase {

    private var workDir: URL!
    private let logger = Logger(subsystem: "com.holo.app.tests", category: "StoreRecoveryTests")

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - 指纹冲突识别

    func test_isModelMismatch_matchesCocoaConflictFamily() {
        func cocoa(_ code: Int) -> Error {
            NSError(domain: NSCocoaErrorDomain, code: code)
        }
        XCTAssertTrue(CoreDataStack.isModelMismatch(cocoa(134100)), "134100 不兼容哈希属冲突族")
        XCTAssertTrue(CoreDataStack.isModelMismatch(cocoa(134130)), "134130 找不到源模型属冲突族")
        XCTAssertFalse(CoreDataStack.isModelMismatch(cocoa(134099)), "134099 不在冲突族")
        XCTAssertFalse(CoreDataStack.isModelMismatch(cocoa(134200)), "134200 不在冲突族")
        XCTAssertFalse(
            CoreDataStack.isModelMismatch(NSError(domain: "OtherDomain", code: 134100)),
            "其他 domain 不算冲突族"
        )
    }

    // MARK: - 冲突库备份

    func test_backupIncompatibleStoreFiles_movesTrioAndKeepsBackup() throws {
        let storeURL = workDir.appendingPathComponent("HoloDataModel.sqlite")
        try Data("main".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: workDir.appendingPathComponent("HoloDataModel.sqlite-wal"))
        try Data("shm".utf8).write(to: workDir.appendingPathComponent("HoloDataModel.sqlite-shm"))

        let moved = CoreDataStack.backupIncompatibleStoreFiles(at: storeURL, logger: logger)

        XCTAssertTrue(moved.hasMainFile, "主库文件应被挪走")
        XCTAssertTrue(moved.isComplete, "三件套应全部搬走成功：\(moved.failedFiles)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "原位不应再留主库文件")

        let leftovers = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        let backups = leftovers.filter { $0.lastPathComponent.contains(".conflict-backup-") }
        XCTAssertEqual(backups.count, 3, "三件套各留一份备份，实际 \(backups.map(\.lastPathComponent))")
        XCTAssertTrue(backups.contains { $0.lastPathComponent.hasPrefix("HoloDataModel.sqlite.conflict-backup-") })
    }

    func test_backupIncompatibleStoreFiles_returnsFalseWhenNothingToMove() throws {
        let storeURL = workDir.appendingPathComponent("HoloDataModel.sqlite")
        let moved = CoreDataStack.backupIncompatibleStoreFiles(at: storeURL, logger: logger)
        XCTAssertFalse(moved.hasMainFile, "目录里没有库文件时不应报告已备份")
    }

    // MARK: - 端到端：指纹冲突 → 备份 → 重建成功

    func test_loadStoreAllowingRecovery_recoversFromIncompatibleModel() throws {
        let storeURL = workDir.appendingPathComponent("HoloDataModel.sqlite")

        // 第一代模型：Note.title 为 String；建库并落一条数据
        let modelA = makeNoteModel(titleType: .stringAttributeType)
        let containerA = makeSyncContainer(model: modelA, storeURL: storeURL)
        let firstError = loadAndWait(containerA)
        XCTAssertNil(firstError, "首代模型应能直接建库")

        let contextA = containerA.viewContext
        let noteA = NSEntityDescription.insertNewObject(forEntityName: "Note", into: contextA)
        noteA.setValue("旧数据", forKey: "title")
        try contextA.save()

        // 释放第一代容器对库文件的占用，模拟「另一个进程先写完退出」
        if let storeA = containerA.persistentStoreCoordinator.persistentStores.first {
            try containerA.persistentStoreCoordinator.remove(storeA)
        }

        // 第二代模型：同名实体同名字段改成 Int64（轻量迁移推不动 → 指纹冲突）
        let modelB = makeNoteModel(titleType: .integer64AttributeType)
        let containerB = makeSyncContainer(model: modelB, storeURL: storeURL)

        // 裸装载：应报指纹冲突族的错误（恢复函数会吞掉首错自动重试，故这里用原始 API）
        var directError: Error?
        let directDone = expectation(description: "direct load fails")
        containerB.loadPersistentStores { _, error in
            directError = error
            directDone.fulfill()
        }
        wait(for: [directDone], timeout: 10)
        let directNsError = try XCTUnwrap(directError, "不兼容模型直接装载应失败")
        XCTAssertTrue(CoreDataStack.isModelMismatch(directNsError), "应为指纹冲突族错误，实际 \(directNsError)")

        // 恢复：备份冲突库 → 重建空库 → 装载成功
        var recoveryError: Error?
        let recoveryDone = expectation(description: "recovery load")
        CoreDataStack.loadStoreAllowingRecovery(containerB, logger: logger) { error in
            recoveryError = error
            recoveryDone.fulfill()
        }
        wait(for: [recoveryDone], timeout: 10)
        XCTAssertNil(recoveryError, "恢复装载应成功")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "恢复后应在原位重建新库"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(
            leftovers.contains { $0.lastPathComponent.contains("HoloDataModel.sqlite.conflict-backup-") },
            "旧库应保留为备份"
        )

        // 新库可用：按新模型写入并读回
        let contextB = containerB.viewContext
        let noteB = NSEntityDescription.insertNewObject(forEntityName: "Note", into: contextB)
        noteB.setValue(Int64(7), forKey: "title")
        try contextB.save()

        let fetch = NSFetchRequest<NSManagedObject>(entityName: "Note")
        let rows = try contextB.fetch(fetch)
        XCTAssertEqual(rows.count, 1, "新库只含重建后的数据")
        XCTAssertEqual(rows.first?.value(forKey: "title") as? Int64, 7)
    }

    // MARK: - 辅助

    /// 单实体 Note（title 字段类型参数化，制造同名字段不同指纹的冲突对）
    private func makeNoteModel(titleType: NSAttributeType) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "Note"
        entity.managedObjectClassName = "NSManagedObject"

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = titleType
        title.isOptional = true
        entity.properties = [title]

        model.entities = [entity]
        return model
    }

    private func makeSyncContainer(model: NSManagedObjectModel, storeURL: URL) -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "HoloDataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [description]
        return container
    }

    /// 同步装载并回收完成回调里的错误
    private func loadAndWait(_ container: NSPersistentContainer) -> Error? {
        var loadError: Error?
        let done = expectation(description: "load \(container.name)")
        CoreDataStack.loadStoreAllowingRecovery(container, logger: logger) { error in
            loadError = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return loadError
    }
}
