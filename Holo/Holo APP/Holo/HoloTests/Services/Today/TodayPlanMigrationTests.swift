//
//  TodayPlanMigrationTests.swift
//  HoloTests
//
//  「今天减负」真实 SQLite 迁移测试（2026-10-03 实施方案 §15.2 / R42）
//
//  冻结「改动前模型」（全量模型副本剔除新实体、实体类全部改用通用 NSManagedObject，
//  避免同名 NSManagedObject 子类被两份实体声明全局双注册——那是 134020/NSArray
//  崩溃族根源）建 SQLite 库写入原任务；再用全量模型打开同一库文件：
//  原记录不丢、新实体可读写。in-memory store 不能证明升级成功，必须走真实文件。
//

import XCTest
import CoreData
@testable import Holo

final class TodayPlanMigrationTests: XCTestCase {

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-plan-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    /// 改动前模型：全量模型副本剔除 HoloTodayPlanRevision；实体类一律换通用类，
    /// 全进程只允许 sharedModel 声明 NSManagedObject 子类。
    private func makeLegacyModel() throws -> NSManagedObjectModel {
        let full = CoreDataTestSupport.sharedModel
        let legacy = try XCTUnwrap(full.copy() as? NSManagedObjectModel)
        for entity in legacy.entities {
            entity.managedObjectClassName = "NSManagedObject"
        }
        legacy.entities = legacy.entities.filter { $0.name != "HoloTodayPlanRevision" }
        XCTAssertFalse(legacy.entities.contains { $0.name == "HoloTodayPlanRevision" })
        return legacy
    }

    private func sqliteURL() -> URL {
        storeDirectory.appendingPathComponent("Migration.sqlite")
    }

    private var migrationOptions: [String: Any] {
        [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true,
        ]
    }

    func test_旧SQLite库在新模型下打开_原任务不丢且新实体可读写() throws {
        let legacyModel = try makeLegacyModel()
        let legacyTitle = "迁移前就存在的任务-\(UUID().uuidString.prefix(6))"

        // 1) 旧模型建库，KVC 写入一条真实任务（不触碰任何 NSManagedObject 子类）
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
            let store = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil,
                at: sqliteURL(), options: nil
            )
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            var saveError: Error?
            context.performAndWait {
                let task = NSEntityDescription.insertNewObject(forEntityName: "TodoTask", into: context)
                task.setValue(legacyTitle, forKey: "title")
                do { try context.save() } catch { saveError = error }
            }
            XCTAssertNil(saveError, "旧模型建库写入失败")
            try coordinator.remove(store)
        }

        // 2) 全量模型打开同一库文件（模型指纹不同 → 触发轻量迁移）
        let fullModel = CoreDataTestSupport.sharedModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: fullModel)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil,
            at: sqliteURL(), options: migrationOptions
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        var legacyTaskID: UUID?
        var assertionError: Error?
        context.performAndWait {
            do {
                // 原任务不丢（不能靠清库通过）
                let taskRequest = NSFetchRequest<TodoTask>(entityName: "TodoTask")
                let tasks = try context.fetch(taskRequest)
                let migrated = try XCTUnwrap(tasks.first { $0.title == legacyTitle })
                legacyTaskID = migrated.id

                // 新实体表已建出且可读写
                let planRequest = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
                XCTAssertEqual(try context.count(for: planRequest), 0, "新实体初始为空表")

                let scope = HoloTodayDayScope.current()
                let payload = HoloTodayPlanPayload(
                    selectionMode: .explicit,
                    entries: [.init(taskID: migrated.id, goal: .taskResult)]
                )
                let revision = HoloTodayPlanRevision(context: context)
                revision.id = UUID()
                revision.schemaVersion = 1
                revision.scopeKey = scope.scopeKey
                revision.dateKey = scope.dateKey
                revision.timeZoneIdentifier = scope.timeZoneIdentifier
                revision.dayStart = scope.dayStart
                revision.dayEnd = scope.dayEnd
                revision.parentRevisionIDsJSON = "[]"
                revision.operationID = "migration-op-1"
                revision.commandRaw = HoloTodayPlanCommand.adopt.rawValue
                revision.payloadJSON = String(decoding: try payload.canonicalData(), as: UTF8.self)
                revision.payloadDigest = try payload.digest()
                revision.createdAt = Date()
                try context.save()

                let refetch = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
                refetch.predicate = NSPredicate(format: "operationID == %@", "migration-op-1")
                XCTAssertEqual(try context.count(for: refetch), 1, "新实体写入后可读回")
            } catch {
                assertionError = error
            }
        }
        XCTAssertNil(assertionError)
        XCTAssertNotNil(legacyTaskID)
        try coordinator.remove(store)
    }

    func test_全新安装_全量模型直接建库读写() throws {
        let fullModel = CoreDataTestSupport.sharedModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: fullModel)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil,
            at: sqliteURL(), options: migrationOptions
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        var assertionError: Error?
        context.performAndWait {
            do {
                _ = TodoTask.create(in: context, title: "全新安装任务")
                let revision = HoloTodayPlanRevision(context: context)
                revision.id = UUID()
                revision.schemaVersion = 1
                let scope = HoloTodayDayScope.current()
                revision.scopeKey = scope.scopeKey
                revision.dateKey = scope.dateKey
                revision.timeZoneIdentifier = scope.timeZoneIdentifier
                revision.dayStart = scope.dayStart
                revision.dayEnd = scope.dayEnd
                revision.parentRevisionIDsJSON = "[]"
                revision.operationID = "fresh-install-op"
                revision.commandRaw = HoloTodayPlanCommand.manualAdd.rawValue
                let payload = HoloTodayPlanPayload(selectionMode: .inheritBase)
                revision.payloadJSON = String(decoding: try payload.canonicalData(), as: UTF8.self)
                revision.payloadDigest = try payload.digest()
                revision.createdAt = Date()
                try context.save()
            } catch {
                assertionError = error
            }
        }
        XCTAssertNil(assertionError)
        try coordinator.remove(store)
    }
}
