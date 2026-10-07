//
//  TaskClassificationMigrationTests.swift
//  HoloTests
//
//  任务分类字段模型升级的真实 SQLite 迁移与写入契约测试
//  （2026-10-06 任务重构方案 §8.2/§8.3/§8.4 / R51/R53/R54/R36）
//
//  迁移路径沿用 TodayPlanMigrationTests 的成熟范式：全量模型副本剔除新字段、
//  实体类换 NSManagedObject（避免子类双注册 134020）、KVC 写旧库、
//  全量模型打开同一库文件验证。
//

import XCTest
import CoreData
import os
@testable import Holo

final class TaskClassificationMigrationTests: XCTestCase {

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-classification-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
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

    /// 升级源模型（建库用）：makePreTaskClassificationModel 剔除两字段、保留原类名。
    /// 不做类名交换——实体版本哈希在真实模型上受类名影响（取证实证），
    /// 真实旧库由类名 TodoTask 的模型写入，测试建库必须同形态，门禁哈希才能对上。
    /// 子类双注册风险由「旧库写入全部走 KVC + 类型化读取只在 sharedModel 上下文」控制。
    private func makeLegacyStoreModel() throws -> NSManagedObjectModel {
        let legacy = try XCTUnwrap(CoreDataStack.makePreTaskClassificationModel())
        XCTAssertTrue(legacy.entitiesByName["TodoTask"]?.properties.contains { $0.name == "priority" } ?? false)
        XCTAssertFalse(legacy.entitiesByName["TodoTask"]?.properties.contains { $0.name == "importanceRaw" } ?? true)
        return legacy
    }

    /// 门禁内容级识别：旧形态库（无两列）→ true；迁移完成后（有两列）→ false；
    /// 非 Core Data 库 → false
    func test_门禁内容识别_按TodoTask列集合判定() throws {
        let legacyModel = try makeLegacyStoreModel()
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
            let store = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: sqliteURL(), options: nil
            )
            try coordinator.remove(store)
        }
        XCTAssertTrue(CoreDataStack.storeIsKnownPreTaskClassification(at: sqliteURL()), "迁移前应识别为已知旧库")

        // 用全量模型打开触发迁移后，新列就位 → 不再识别为旧库
        let full = NSPersistentStoreCoordinator(managedObjectModel: CoreDataTestSupport.sharedModel)
        let migrated = try full.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: sqliteURL(), options: migrationOptions
        )
        try full.remove(migrated)
        XCTAssertFalse(CoreDataStack.storeIsKnownPreTaskClassification(at: sqliteURL()), "迁移后不应再识别为旧库")

        // 非 Core Data 库（空 SQLite）→ false，走既有恢复分支
        let plainURL = storeDirectory.appendingPathComponent("plain.sqlite")
        try Data().write(to: plainURL)
        XCTAssertFalse(CoreDataStack.storeIsKnownPreTaskClassification(at: plainURL))
    }

    // MARK: - R53 旧源模型 SQLite 升级

    func test_旧SQLite库升级_记录关系附件引用保留_新字段默认正确() throws {
        let legacyModel = try makeLegacyStoreModel()
        let legacyTitle = "升级前就存在的任务-\(UUID().uuidString.prefix(6))"
        let legacyDue = Date(timeIntervalSince1970: 1_750_000_000)
        let legacyUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let attachmentFileName = "receipt-\(UUID().uuidString.prefix(6)).jpg"

        // 1) 旧模型建库：一条任务（高优先级）+ 附件关系
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
                task.setValue(UUID(), forKey: "id")
                task.setValue(legacyTitle, forKey: "title")
                task.setValue("todo", forKey: "status")
                task.setValue(Int16(2), forKey: "priority") // 高优先级
                task.setValue(legacyDue, forKey: "dueDate")
                task.setValue(false, forKey: "isAllDay")
                task.setValue(false, forKey: "completed")
                task.setValue(false, forKey: "archived")
                task.setValue(false, forKey: "deletedFlag")
                task.setValue(Int16(0), forKey: "postponedCount")
                task.setValue(Date(timeIntervalSince1970: 1_600_000_000), forKey: "createdAt")
                task.setValue(legacyUpdatedAt, forKey: "updatedAt")

                let attachment = NSEntityDescription.insertNewObject(forEntityName: "TaskAttachment", into: context)
                attachment.setValue(UUID(), forKey: "id")
                attachment.setValue(attachmentFileName, forKey: "fileName")
                attachment.setValue("", forKey: "thumbnailFileName")
                attachment.setValue(Int16(0), forKey: "sortOrder")
                attachment.setValue("photoLibrary", forKey: "sourceType")
                attachment.setValue(task, forKey: "task")

                do { try context.save() } catch { saveError = error }
            }
            XCTAssertNil(saveError, "旧模型建库写入失败")
            try coordinator.remove(store)
        }

        // 2) 内容级识别：迁移前无两个新列 → 已知旧库（门禁可识别）
        XCTAssertTrue(CoreDataStack.storeIsKnownPreTaskClassification(at: sqliteURL()))

        // 3) 全量模型打开同一库（触发轻量迁移）
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
                let tasks = try context.fetch(TodoTask.fetchRequest())
                let migrated = try XCTUnwrap(tasks.first { $0.title == legacyTitle })

                // 原字段与时间戳保留（迁移不批量改写 updatedAt）
                XCTAssertEqual(migrated.priority, 2)
                XCTAssertEqual(migrated.dueDate, legacyDue)
                XCTAssertEqual(migrated.updatedAt, legacyUpdatedAt)
                XCTAssertEqual(migrated.createdAt, Date(timeIntervalSince1970: 1_600_000_000))

                // 新字段默认 0（模型层默认；打开库不自动迁移——迁移走 TaskPriorityMigration）
                XCTAssertEqual(migrated.importanceRaw, 0)
                XCTAssertEqual(migrated.urgencyModeRaw, 0)

                // 附件关系与引用保留
                let attachments = migrated.sortedAttachments
                XCTAssertEqual(attachments.count, 1)
                XCTAssertEqual(attachments.first?.fileName, attachmentFileName)

                // 新字段可写可读（P 档体系：raw 兼容旧分配）
                migrated.importance = .p1
                migrated.urgencyMode = .p3
                try context.save()
                let reread = try context.fetch(TodoTask.fetchRequest()).first { $0.title == legacyTitle }
                XCTAssertEqual(reread?.importance, .p1)
                XCTAssertEqual(reread?.urgencyMode, .p3)
            } catch {
                assertionError = error
            }
        }
        XCTAssertNil(assertionError)
        try coordinator.remove(store)
    }

    // MARK: - R54 迁移失败门禁：原库不移动重建

    func test_迁移失败_门禁保留原库并如实上报() throws {
        // 建一个「升级前」形态的库
        let legacyModel = try makeLegacyStoreModel()
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
            let store = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: sqliteURL(), options: nil
            )
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.performAndWait {
                let task = NSEntityDescription.insertNewObject(forEntityName: "TodoTask", into: context)
                task.setValue(UUID(), forKey: "id")
                task.setValue("门禁任务", forKey: "title")
                task.setValue("todo", forKey: "status")
                try? context.save()
            }
            try coordinator.remove(store)
        }

        // 敌对模型：TodoTask.title 改 Integer16（轻量迁移无法推断）
        let hostile = try XCTUnwrap(CoreDataTestSupport.sharedModel.copy() as? NSManagedObjectModel)
        let hostileEntity = try XCTUnwrap(hostile.entitiesByName["TodoTask"])
        let titleAttr = try XCTUnwrap(hostileEntity.properties.first { $0.name == "title" } as? NSAttributeDescription)
        titleAttr.attributeType = .integer16AttributeType
        titleAttr.isOptional = false
        titleAttr.defaultValue = 0

        let container = NSPersistentContainer(name: "GateTest", managedObjectModel: hostile)
        let description = NSPersistentStoreDescription(url: sqliteURL())
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        let logger = os.Logger(subsystem: "com.holo.tests", category: "TaskClassificationMigrationGate")
        let expectation = expectation(description: "load 完成")
        var loadError: Error?
        CoreDataStack.loadStoreAllowingRecovery(container, logger: logger) { error in
            loadError = error
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        // 失败如实上报（不以空库通过验收）
        XCTAssertNotNil(loadError, "敌对模型装载应失败")
        if let error = loadError {
            XCTAssertTrue(CoreDataStack.isModelMismatch(error), "失败应属模型不匹配族，实际：\(error)")
        }
        // 原库三件套原地保留，没有 conflict-backup 备份产生（未走重建分支）
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteURL().path), "原库必须原地保留")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)
        XCTAssertFalse(siblings.contains { $0.contains("conflict-backup") }, "不应产生冲突备份：\(siblings)")
    }

    // MARK: - 写入契约（内存容器）

    private func makeRepo() throws -> (TodoRepository, NSManagedObjectContext) {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["TodoTask", "TodoList", "RepeatRule", "CheckItem", "TaskAttachment", "TodoFolder"])
        let repository = TodoRepository(context: ctx)
        // hosted XCTest 释放 MainActor/CoreData 组合对象存在系统层重复释放（在档坑）：
        // 与 TodoTaskPlannedTimeRangeTests 同法，测试进程内延长仓库生命周期
        CoreDataTestSupport.retain(repository)
        return (repository, ctx)
    }

    func test_创建默认未知重要_按日期紧急_R01() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(title: "只填标题")
        XCTAssertEqual(task.importance, .unknown)
        XCTAssertEqual(task.urgencyMode, .auto)
        XCTAssertEqual(task.dueDate, nil)
        XCTAssertEqual(task.list, nil)
    }

    func test_创建可显式带两轴() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(
            title: "从象限新增", importance: .p3, urgencyMode: .p1
        )
        XCTAssertEqual(task.importance, .p3)
        XCTAssertEqual(task.urgencyMode, .p1)
    }

    func test_分类直写_独立不改截止时段旧优先级_R17() throws {
        let (repo, _) = try makeRepo()
        let due = Date(timeIntervalSince1970: 1_760_000_000)
        let task = try repo.createTask(title: "独立验证", priority: .high, dueDate: due)
        let updatedAtBefore = task.updatedAt

        try repo.updateTaskClassification(taskID: task.id, importance: .p1, urgencyMode: .p3)

        let reread = try XCTUnwrap(repo.findTask(by: task.id))
        XCTAssertEqual(reread.importance, .p1)
        XCTAssertEqual(reread.urgencyMode, .p3)
        // 不应随之改变（§3.3 独立性）
        XCTAssertEqual(reread.dueDate, due)
        XCTAssertEqual(reread.plannedStart, nil)
        XCTAssertEqual(reread.plannedEnd, nil)
        XCTAssertEqual(reread.taskPriority, .high)
        XCTAssertGreaterThanOrEqual(reread.updatedAt, updatedAtBefore)
    }

    func test_修改截止_不覆盖手动紧急方式_R18() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(title: "手动不紧急", importance: .p1, urgencyMode: .p3)
        try repo.updateTask(task, dueDate: .set(Date(timeIntervalSince1970: 1_770_000_000)))
        XCTAssertEqual(repo.findTask(by: task.id)?.urgencyMode, .p3, "改日期不能覆盖手动方式")
    }

    func test_重复任务下一实例继承两轴_R36() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(
            title: "每日重复", importance: .p1, urgencyMode: .p3
        )
        _ = try repo.createRepeatRule(type: .daily, for: task)

        let generated = try repo.completeRepeatingTask(task)
        XCTAssertTrue(generated, "应生成下一实例")

        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", "每日重复")
        let instances = try repo.context.fetch(request)
        XCTAssertEqual(instances.count, 2, "原任务 + 下一实例")
        let next = try XCTUnwrap(instances.first { !$0.completed })
        XCTAssertEqual(next.importance, .p1, "下一实例继承重要性")
        XCTAssertEqual(next.urgencyMode, .p3, "手动方式保持")
    }

    func test_未知raw容错读取_不崩溃() throws {
        let (repo, ctx) = try makeRepo()
        let task = try repo.createTask(title: "异常raw")
        task.importanceRaw = 99
        task.urgencyModeRaw = 77
        try ctx.save()
        XCTAssertEqual(task.importance, .unknown)
        XCTAssertEqual(task.urgencyMode, .auto)
    }

    // MARK: - R51 同 id 多行副本

    /// R51 专用：真实 SQLite 临时存储（同 id 多行的「物理行号最小」语义只在
    /// SQLite 有 Z_PK；内存存储 objectID 无行号，dedup 会退化为取 fetch 首行）
    private func makeSQLiteStore() throws -> (context: NSManagedObjectContext, teardown: () throws -> Void) {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataTestSupport.sharedModel)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil,
            at: sqliteURL(), options: nil
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return (context, { try coordinator.remove(store) })
    }

    func test_同UUID多行_先选规范行再过滤_不重计不复活() throws {
        let (ctx, teardown) = try makeSQLiteStore()
        defer { try? teardown() }
        let sharedID = UUID()

        let rowA = TodoTask.create(in: ctx, title: "规范行")
        rowA.id = sharedID
        rowA.deletedFlag = true
        rowA.deletedAt = Date()
        try ctx.save()

        let rowB = TodoTask.create(in: ctx, title: "云端副本")
        rowB.id = sharedID
        rowB.deletedFlag = false
        try ctx.save()

        // 物理行号 A < B（先插入）；规范行 A 已删除 → 副本不复活该任务
        let snapshots = try TaskSnapshotReader.readAllSnapshots(in: ctx)
        XCTAssertEqual(snapshots.filter { $0.id == sharedID }.count, 1)
        XCTAssertEqual(snapshots.first { $0.id == sharedID }?.deleted, true, "已删规范行不被大行号副本复活")
    }

    func test_快照读取_同UUID两活行只计一次() throws {
        let (ctx, teardown) = try makeSQLiteStore()
        defer { try? teardown() }
        let sharedID = UUID()
        for _ in 0..<2 {
            let row = TodoTask.create(in: ctx, title: "重复行")
            row.id = sharedID
        }
        try ctx.save()
        let snapshots = try TaskSnapshotReader.readAllSnapshots(in: ctx)
        XCTAssertEqual(snapshots.filter { $0.id == sharedID }.count, 1)
    }

    // MARK: - 旧优先级 → 两轴 一次性迁移（东林 2026-10-06 拍板）

    func test_迁移映射_四档规则() {
        XCTAssertEqual(TaskPriorityMigration.map(.urgent).importance, .p1)
        XCTAssertEqual(TaskPriorityMigration.map(.urgent).urgencyMode, .p1)
        XCTAssertEqual(TaskPriorityMigration.map(.high).importance, .p1)
        XCTAssertEqual(TaskPriorityMigration.map(.high).urgencyMode, .auto)
        XCTAssertEqual(TaskPriorityMigration.map(.medium).importance, .unknown)
        XCTAssertEqual(TaskPriorityMigration.map(.low).importance, .p3)
    }

    func test_迁移写入与幂等() throws {
        let (repo, ctx) = try makeRepo()
        let urgent = try repo.createTask(title: "十分紧急任务", priority: .urgent)
        let high = try repo.createTask(title: "高优先级任务", priority: .high)
        let medium = try repo.createTask(title: "中优先级任务", priority: .medium)
        let low = try repo.createTask(title: "低优先级任务", priority: .low)
        // 已是目标值的任务：迁移不应改它（P1＋手动P1 = urgent 的目标）
        let settled = try repo.createTask(title: "已迁移任务", priority: .urgent)
        settled.importance = .p1
        settled.urgencyMode = .p1
        try ctx.save()

        let changed = TaskPriorityMigration.run(in: ctx)
        XCTAssertEqual(changed, 3, "只迁移有差异的 3 条（settled 已是目标值）")

        XCTAssertEqual(repo.findTask(by: urgent.id)?.importance, .p1)
        XCTAssertEqual(repo.findTask(by: urgent.id)?.urgencyMode, .p1)
        XCTAssertEqual(repo.findTask(by: high.id)?.importance, .p1)
        XCTAssertEqual(repo.findTask(by: high.id)?.urgencyMode, .auto)
        XCTAssertEqual(repo.findTask(by: medium.id)?.importance, .unknown, "中 → 暂未判断进待整理")
        XCTAssertEqual(repo.findTask(by: low.id)?.importance, .p3)

        // 幂等：再跑零写入
        XCTAssertEqual(TaskPriorityMigration.run(in: ctx), 0)
    }

    func test_迁移标记_只跑一次() throws {
        let (repo, _) = try makeRepo()
        _ = try repo.createTask(title: "标记任务", priority: .high)
        let defaults = UserDefaults(suiteName: "task-priority-migration-test")!
        defaults.removePersistentDomain(forName: "task-priority-migration-test")

        TaskPriorityMigration.runIfNeeded(in: repo.context, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: TaskPriorityMigration.migrationFlagKey))
        // 标记已置位后，新出现的旧值任务不再被自动迁移（避免覆盖用户后续编辑）
        _ = try repo.createTask(title: "标记后的新任务", priority: .high)
        TaskPriorityMigration.runIfNeeded(in: repo.context, defaults: defaults)
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", "标记后的新任务")
        let late = try XCTUnwrap(try repo.context.fetch(request).first)
        XCTAssertEqual(late.importance, .unknown, "runIfNeeded 只跑一次")
    }
}
