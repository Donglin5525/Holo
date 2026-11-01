//
//  CoreDataStoreRecoveryTests.swift
//  HoloTests
//
//  存储装载指纹防护回归（2026-10-26 共享库迁移乒乓事故后收口）：
//  打开前只读指纹预检（一致放行/不一致拒绝/读不出拒绝/新路径放行）、
//  指纹不一致时拒绝打开且原库原地保留（绝不自动迁移、绝不备份重建空库）。
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

    // MARK: - 打开前只读指纹预检（2026-10-26 共享库迁移乒乓事故收口）

    func test_storeFingerprintRejection_allowsFreshStorePath() {
        // 库文件不存在 = 全新安装，无指纹可核，必须放行
        let missingURL = workDir.appendingPathComponent("not-created.sqlite")
        let rejection = CoreDataStack.storeFingerprintRejection(at: missingURL, model: makeNoteModel(titleType: .stringAttributeType))
        XCTAssertNil(rejection, "不存在的库路径应放行（全新安装）")
    }

    func test_storeFingerprintRejection_allowsMatchingModel() throws {
        let storeURL = workDir.appendingPathComponent("HoloDataModel.sqlite")
        let modelA = makeNoteModel(titleType: .stringAttributeType)
        let containerA = makeSyncContainer(model: modelA, storeURL: storeURL)
        XCTAssertNil(loadAndWait(containerA), "建库应成功")
        if let storeA = containerA.persistentStoreCoordinator.persistentStores.first {
            try containerA.persistentStoreCoordinator.remove(storeA)
        }
        let rejection = CoreDataStack.storeFingerprintRejection(at: storeURL, model: modelA)
        XCTAssertNil(rejection, "同指纹模型应放行")
    }

    func test_storeFingerprintRejection_rejectsMismatchedModel() throws {
        let storeURL = workDir.appendingPathComponent("HoloDataModel.sqlite")
        let modelA = makeNoteModel(titleType: .stringAttributeType)
        let containerA = makeSyncContainer(model: modelA, storeURL: storeURL)
        XCTAssertNil(loadAndWait(containerA), "建库应成功")
        if let storeA = containerA.persistentStoreCoordinator.persistentStores.first {
            try containerA.persistentStoreCoordinator.remove(storeA)
        }
        // 同名实体同字段改类型：指纹不一致（轻量迁移推不动的形态）
        let modelB = makeNoteModel(titleType: .integer64AttributeType)
        let rejection = CoreDataStack.storeFingerprintRejection(at: storeURL, model: modelB)
        let fingerprintRejection = try XCTUnwrap(
            rejection as? CoreDataStack.StoreFingerprintRejection,
            "应拒绝并给出指纹预检错误，实际 \(String(describing: rejection))"
        )
        if case .mismatch(let onlyInStore, let onlyInModel, let hashDifferences) = fingerprintRejection.reason {
            XCTAssertEqual(hashDifferences, ["Note"], "哈希差异应点名 Note")
            XCTAssertTrue(onlyInStore.isEmpty && onlyInModel.isEmpty, "实体集合一致，仅哈希不同")
        } else {
            XCTFail("拒绝原因应为 mismatch，实际 \(fingerprintRejection.reason)")
        }
        XCTAssertTrue(CoreDataStack.isModelMismatch(fingerprintRejection), "预检拒绝应属指纹不一致族")
        // 原库必须原地保留——预检绝不移动/改写任何库文件
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "原库必须原地保留")
    }

    func test_storeFingerprintRejection_rejectsUnreadableMetadata() throws {
        // 存在但非 Core Data 库的文件：读不出指纹 = 无法核验，按拒绝处理（宁可不工作）
        let storeURL = workDir.appendingPathComponent("garbage.sqlite")
        try Data("not a sqlite store".utf8).write(to: storeURL)
        let rejection = CoreDataStack.storeFingerprintRejection(at: storeURL, model: makeNoteModel(titleType: .stringAttributeType))
        XCTAssertTrue(
            rejection is CoreDataStack.StoreFingerprintRejection,
            "读不出指纹的库文件应被拒绝，实际 \(String(describing: rejection))"
        )
    }

    // MARK: - 端到端：指纹不一致 → 拒绝打开，绝不自动迁移/重建

    func test_loadStoreAllowingRecovery_refusesIncompatibleModel() throws {
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

        // 2026-10-26 事故后语义：装载前指纹预检直接拒绝——
        // 绝不在指纹不一致的库上自动迁移，也不备份重建空库
        var refusalError: Error?
        let refusalDone = expectation(description: "refused load")
        CoreDataStack.loadStoreAllowingRecovery(containerB, logger: logger) { error in
            refusalError = error
            refusalDone.fulfill()
        }
        wait(for: [refusalDone], timeout: 10)
        let rejection = try XCTUnwrap(refusalError, "指纹不一致必须拒绝打开")
        XCTAssertTrue(CoreDataStack.isModelMismatch(rejection), "应为指纹不一致族错误，实际 \(rejection)")
        XCTAssertTrue(
            rejection is CoreDataStack.StoreFingerprintRejection,
            "应给出指纹预检错误供上层如实展示，实际 \(rejection)"
        )

        // 原库三件套原地保留，没有 conflict-backup 备份产生（未走重建分支）
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "原库必须原地保留")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        XCTAssertFalse(siblings.contains { $0.contains("conflict-backup") }, "不应产生冲突备份：\(siblings)")
    }

    // MARK: - 拒绝态下的重拉链路原语（恢复通道：从 iCloud 重新拉取）

    /// 指纹拒绝态（store 从未装载成功）是「从 iCloud 重新拉取」的起点态：
    /// 重拉链路用到的原语必须在该态下能推进，而不是挂死/抛错。
    /// 对应 CoreDataStack.backupAndRebuildStoreForCloudRepull 的逐步前提：
    /// 1) 拉取前计数快照（performBackgroundTask 在无已装载 store 的容器上要能完成）；
    /// 2) unloadStores 对未装载容器（空持久店 + viewContext.reset）不抛错；
    /// 3) 三件套挪走后，同模型在同路径重新装载成功（重建空库，新库无指纹 → 放行）。
    func test_cloudRepullPrimitives_progressFromRejectedState() throws {
        let storeURL = workDir.appendingPathComponent("HoloDataModel.sqlite")

        // 第一代模型建库（模拟旧版本创建的库）
        let modelA = makeNoteModel(titleType: .stringAttributeType)
        let containerA = makeSyncContainer(model: modelA, storeURL: storeURL)
        XCTAssertNil(loadAndWait(containerA), "首代模型应能直接建库")
        if let storeA = containerA.persistentStoreCoordinator.persistentStores.first {
            try containerA.persistentStoreCoordinator.remove(storeA)
        }

        // 第二代模型装载同一库 → 指纹预检拒绝，store 从未加入协调器（拒绝态）
        let modelB = makeNoteModel(titleType: .integer64AttributeType)
        let containerB = makeSyncContainer(model: modelB, storeURL: storeURL)
        let refusalError = loadAndWait(containerB)
        XCTAssertTrue(
            refusalError is CoreDataStack.StoreFingerprintRejection,
            "应被指纹预检拒绝进入拒绝态，实际 \(String(describing: refusalError))"
        )
        XCTAssertTrue(containerB.persistentStoreCoordinator.persistentStores.isEmpty, "拒绝态不应有已装载 store")

        // 1) 计数快照原语：无已装载 store 的容器上 performBackgroundTask 必须能完成
        let countDone = expectation(description: "background count completes")
        containerB.performBackgroundTask { context in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Note")
            let count = (try? context.count(for: request)) ?? -1
            XCTAssertEqual(count, 0, "无 store 的容器计数应为 0")
            countDone.fulfill()
        }
        wait(for: [countDone], timeout: 10)

        // 2) 卸载原语：viewContext.reset + 遍历空持久店（未装载容器上等同无操作，不抛错）
        containerB.viewContext.reset()
        for store in containerB.persistentStoreCoordinator.persistentStores {
            try containerB.persistentStoreCoordinator.remove(store)
        }

        // 3) 备份三件套（cloudrepull 后缀）→ 同模型同路径重建空库装载成功
        let backup = CoreDataStack.moveStoreFiles(
            at: storeURL,
            suffix: CoreDataStack.cloudRepullBackupSuffix,
            logger: logger)
        XCTAssertTrue(backup.isComplete, "拒绝态原库三件套应可完整备份：\(backup.failedFiles)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "原位不应再留库文件")

        let containerC = makeSyncContainer(model: modelB, storeURL: storeURL)
        XCTAssertNil(loadAndWait(containerC), "挪走旧库后同模型重建空库应装载成功")
        XCTAssertFalse(containerC.persistentStoreCoordinator.persistentStores.isEmpty, "重建后应有已装载 store")
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
