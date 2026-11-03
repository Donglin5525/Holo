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


// MARK: - 升级登记簿与模型绊线（2026-11-02 根治「跳版老用户被整库拒开」）

final class CoreDataSchemaHistoryTests: XCTestCase {

    /// 模型绊线：当前模型每个实体的版本指纹必须与快照一致。变红 = 有人改了数据结构：
    /// 给已有实体加可选属性/关系 → 在 CoreDataStoreUpgrade.propertyHistory 追加一批并更新快照；
    /// 只加新表 → 只更新快照；删改属性、改类型 → 破坏性变更，先报东林。
    func test_schemaTripwire_currentModelMatchesSnapshot() {
        let actual = CoreDataStack.shared.createDataModel().entityVersionHashesByName
            .mapValues { $0.base64EncodedString() }
        let expected = Self.currentEntityHashes
        let changed = actual.keys.filter { expected[$0] != nil && expected[$0] != actual[$0] }.sorted()
        let added = actual.keys.filter { expected[$0] == nil }.sorted()
        let removed = expected.keys.filter { actual[$0] == nil }.sorted()
        XCTAssertTrue(changed.isEmpty && added.isEmpty && removed.isEmpty, """
            数据模型变了——改动实体 \(changed)，新增实体 \(added)，消失实体 \(removed)。
            给已有实体加可选属性/关系：在 CoreDataStoreUpgrade.propertyHistory 登记新批次并更新本快照；
            只加新表：只更新快照；删改属性或改类型：破坏性变更，先报东林。
            """)
    }

    /// 登记簿必须能把当前模型倒推回真实旧库的样子（锚点取自本机模拟器历史库只读比对）
    func test_registeredShapes_matchRealHistoricalStores() {
        for anchor in Self.legacyAnchors {
            guard let index = CoreDataStoreUpgrade.propertyHistory.firstIndex(where: { $0.release == anchor.release }) else {
                XCTFail("登记簿缺少批次「\(anchor.release)」")
                continue
            }
            let shape = CoreDataStack.shared.legacyModelHashes(removing: CoreDataStoreUpgrade.additions(since: index))
            for (entity, hash) in anchor.hashes {
                XCTAssertEqual(shape[entity]?.base64EncodedString(), hash,
                               "\(anchor.note)：\(entity) 倒推形态与真实旧库不符")
            }
        }
    }

    /// 登记项卫生：名字必须真实存在；属性可选或带默认值、关系可选（轻量迁移与 CloudKit 的共同前提）
    func test_registeredProperties_existAndAreAdditiveSafe() {
        let model = CoreDataStack.shared.createDataModel()
        for batch in CoreDataStoreUpgrade.propertyHistory {
            XCTAssertFalse(batch.additions.isEmpty, "「\(batch.release)」是空批次")
            for (entityName, names) in batch.additions {
                guard let entity = model.entitiesByName[entityName] else {
                    XCTFail("「\(batch.release)」登记了不存在的实体 \(entityName)")
                    continue
                }
                for name in names {
                    guard let property = entity.propertiesByName[name] else {
                        XCTFail("「\(batch.release)」登记了不存在的属性 \(entityName).\(name)")
                        continue
                    }
                    if let attribute = property as? NSAttributeDescription {
                        XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil,
                                      "\(entityName).\(name) 既非可选也无默认值，不能当增量升级登记")
                    } else {
                        XCTAssertTrue(property.isOptional, "\(entityName).\(name) 关系必须可选")
                    }
                }
            }
        }
    }

    /// 判定口径：一致 / 纯加表 / 登记形态 / 拒绝（未登记改表、降级）
    func test_verdict_classifiesStoreShapes() {
        let a = Data([1]), b = Data([2]), c = Data([3]), legacyB = Data([9])
        let model: [String: Data] = ["A": a, "B": b, "C": c]
        let shape: (Int) -> [String: Data] = { _ in ["A": a, "B": legacyB, "C": c] }
        func verdict(_ store: [String: Data]) -> CoreDataStoreUpgrade.Verdict {
            CoreDataStoreUpgrade.verdict(store: store, model: model, legacyShape: shape)
        }
        XCTAssertEqual(verdict(model), .identical)
        XCTAssertEqual(verdict(["A": a, "B": b]), .additiveTables)
        XCTAssertEqual(verdict(["A": a, "B": legacyB]),
                       .registered(release: CoreDataStoreUpgrade.propertyHistory.last?.release ?? ""))
        XCTAssertEqual(verdict(["A": a, "B": Data([7])]), .rejected, "未登记的改表必须拒开")
        XCTAssertEqual(verdict(["A": a, "B": b, "C": c, "D": Data([4])]), .rejected, "库比模型多出实体 = 降级，必须拒开")
    }

    // MARK: 当前模型快照（1.1.6，65 实体；Habit 含习惯描述，其余取自 1.1.4 构建写下的真实库）
    static let currentEntityHashes: [String: String] = [
        "Account": "ovMHcXG4YxhTNgKPpW8eLMO0cUcZWllBCcle/nWSGkI=",
        "Anniversary": "CsOU1vM24WP4iciccGy3T9+iiqEqRk1dwgfd7Vy8Ecc=",
        "Budget": "hdkln9Baf0drjJZw054cMs0Gtigdoci+V3WZykA58Oc=",
        "Category": "ZYvOYKKZXU45rtHC2nOFDvl5Km6D8UYs41PAeB3lNr8=",
        "CategoryInductionRuleEntity": "zhmtSqr5/P2SVEMH1yYBioTo/eeOwzEdugrBHG0BqvA=",
        "CategoryMappingRecordEntity": "KYD1Whz7HpcK2GwRE8aZO1yZQGd00irIU6UIw4ncJX8=",
        "ChatMessage": "k8PzLmnOXfDd66YKDOymMmc6p5B4lYAvWYq18eXCkUw=",
        "CheckItem": "3nWdfd6a6vRzYdpnBVaPUNOiva5OaL8h/q7boT09ZBQ=",
        "FinanceProject": "sNx7xspijU0EKfDd3ivrxILuLyf+dFmCoVn9QkuJyGE=",
        "Goal": "OctYDLr2+/DaVCrMO1R9Wa/tkZfW7vjhEOQZUCwgMr8=",
        "GoalMetricLog": "xuieECsr9ezrYOW+O2udaRnXD0G0r9yhuT6xCwEThoY=",
        "GoalPlanRevisionMO": "rYag1nJkfPRtCQdkWPfbDtajnruma0TiuvBlFsQJjgA=",
        "GoalReviewLinkMO": "8JNdN7j7LY7HZwBNWrtHYPWz6XgTLcH3dPT89zu3nDg=",
        "GoalWorkshopSessionMO": "pYgJBbdBRy5RhlWZwEPEkaeYGo5++H8pcGe5LKcyS5I=",
        "Habit": "sTtC95zHqoXzSl1iZ7zs0zptX1g9lPosT1QX27K1q1E=",
        "HabitDailyConfirmationMO": "MP5sdx6f3gV3uMUjVjvozfxmwylPv6mF4ssI67GumwE=",
        "HabitRecord": "HA+8OUQuXUOmCDv+lmEYppXSd/usihlFqMYScKp3ANM=",
        "HoloMatter": "QnFKzi5qiMscz4Qi2LiuWRs/UTzbyZhOoI7GJ4RXmow=",
        "HoloMatterEvent": "DI3IOkwbKaQYPl6oNkQleHclU1gsvMEFSJ0zuH96/bc=",
        "HoloMatterLink": "/X3ZPmwiE9QhHKMX6T7+yjUi7AegLZ0eJhDS0XC29gk=",
        "HoloMatterOpenLoop": "XF4ms8Fxk1TSSdfG7IjSD3jlWtrl+tCf6N3k2AycquA=",
        "HoloMemoryAnchorAliasMO": "qoFufCp4rSCHD8GAopE3sDijJtFpGA4CqGxEtwNcdFQ=",
        "HoloMemoryControlEventMO": "zBdzDxSjWFlPZZXok1ipteo1qZ9m3MhigGy2SvNOw6w=",
        "HoloMemoryControlStateMO": "bZWaFHAc+lOq2z5/uIMwQwiXtLsMFc3LjMjU+PNg8jI=",
        "HoloMemoryEvidenceMO": "OzecAjoNRp9K8bQlurIsAqv2aOBwc4KQzVN7yaD9BBU=",
        "HoloMemoryKnowledgeOperationMO": "Wfw1o2MsiThoZncBC+uOD6opzCtaDQlOLGcGHZtu8/A=",
        "HoloMemoryKnowledgeRevisionMO": "05M3jZ/1U0oOTL+DMw/wN8pKxvzuHLsPDUQjx1tQRws=",
        "HoloMemoryObservationRunMO": "WUXxXJX/ufdxky24ppDDVEkSVU+g1Kiisurqa9baf/8=",
        "HoloMemoryRecordMO": "YlLomzlAnsZJsjNN0pFu4ngUPkZTGHRfXXgd2Lez3Ns=",
        "HoloMemoryTombstoneMO": "pqZA2JGT1VkjqylWqtEgDe660DoDQphATLEHjTCep3w=",
        "HoloTaskExecutionReceipt": "DQYzF2N+IKUUMIIUbG2Hdh9/0HjsqwZ3rpilLpOGFAs=",
        "HoloTaskExecutionRevision": "x1iJTrRfVxyIcr9KA/pQ2RHm3JroBZcZKujbe/9iPLw=",
        "HoloTaskExecutionStep": "SaSb6JygZ8wN9sKlv0dbsA0lEHPvFb62MLYW958HYrs=",
        "HoloTodayPlanRevision": "lMeHgtRT+Eb3ec+huj+Yduc7dH4oONREGKn8mWTD9B8=",
        "HomeIconConfig": "uYB1deLFzNtPvLlosLz52UqqU53HeuNTKtbd2a0qNG0=",
        "ICloudSyncProbe": "XXI2mLg0VbUAgaIp03XfqdGfvj+RZ/vAvPmbyXT93tM=",
        "LifePlanMO": "bYmrq0xAO5onTspWvLoZ+qne55HrEB5KRz8HKrx6KVk=",
        "MemoryInsight": "z5QJtXYoNZ//92MwrPBqMf8j0OV/lU8bZ3s2u333tW8=",
        "MemoryInsightFeedback": "jwx7BsLoXJBSlhuHD2sYoyEzJvBCZg4P76JaY/rQAZI=",
        "PlanActionMO": "abGhiTUSHJtEZL3OyHe1VGLsTTiMiiB4S9lNwFvYGrY=",
        "PlanFeedbackMO": "gXZw+AppglM7pL6hrKa/Suj69iVlm2aYyczWpH5RfE8=",
        "PlanPriorityMO": "kG/YUx0HuYacI1dpT2hsFG7GyZu9xVFtGPjFbj+4ivk=",
        "PlanRunMO": "BsliMYM5xj7ESQ/1iLfYJ5/qt9s5/ZTw6Zcdx0doQXY=",
        "PlanSignalMO": "ip6+cnUuLPEpbKdIVV8sKHTYYLWxPT1bo1gjev78/SY=",
        "RecycleBinBatch": "QIouNCais6f37FpCYqQwjf84Cn1NanTA5a2ioFCm8EU=",
        "RepeatRule": "pC6XzT5J9+tkBesxqhgR9gZPb4RGTCytqXL7iLyJRqI=",
        "SpendingProject": "WtYlwjbZD3scyI4QS6EOyGLFPIYS2URKTfWA2d0ycn0=",
        "TaskAttachment": "1/3Y51dfSZQoa2dEwV/9c97xECRrBNJyqg0b+ZleC+c=",
        "TaskScheduleMirror": "sWvW52Dk23TP4qrYF+gJ/7TEtCiPwrhaJv9KeS/5S/A=",
        "Thought": "yr4JRLLgySoKq+56tWM8Puysr3knQvKi1FpE/LB35fc=",
        "ThoughtAttachment": "F+TefCdC0r/yV90oGe4hwBJebgDQ7YbMqvqMnJT84Mg=",
        "ThoughtReference": "BVuof89riyx6hBlsB/qotx9QmXXswC8XRheIIpwoDOM=",
        "ThoughtTag": "C6GQVqw35DJoSK0Xx1RCvXm/jqn1lkbhYss2fnOSivk=",
        "ThoughtTagAssignment": "Hie3z2Z39AsjSR/kCrGMgAs1g9TGb2xJ49SuU+lmW/g=",
        "ThoughtTagConvergenceRejection": "Kw11G2MlnzaVEpf1G7XWJn9IBRK/KoEJ8vtfPfMMBiM=",
        "ThoughtTopicLink": "+xB4k9FExttIP25MRdNz1qe7f8o6/5WIN0M5dbWivd0=",
        "TodoFolder": "Wl1goHqCx9oGScQ9uJDq70Zdmt9VqvGwlWyA/Bte4is=",
        "TodoList": "I8foRw/pGGAplOubmLHXfLrm82jqBaCtgMJ0etovkDw=",
        "TodoTag": "oImgH+BtB4dN4b2PYdrrBOETV+jkkclUzO5fQ0eB8tg=",
        "TodoTask": "ECiRNGhEJ29POvC5bnRXMwnQjbrYbk9KArnQGknwlBM=",
        "Topic": "a1FFJfgpbTGE899p4X+nEcRf1wS4NzNauPrGGitIsG8=",
        "Transaction": "hwzFm4nOCJ6FC5U8SRyRtNs8cXXnn+iY9LLlxU67Bh8=",
        "TransactionAttachment": "Co2y517EKCQINYHGpWgtLECXnnXlRbznoxBv70bTITQ=",
        "UserAvatarEntity": "RGNVTE+zZtYf/JzaxmJajBY2uPZUosC4XDgRpnKGkRQ=",
        "UserPreferenceEntity": "d2n0eWHrPSB5FoeLj71jqG8fF7dW6AiSeNin4WllQwY=",
    ]

    // MARK: 历史形态锚点（真实旧库中与当前不同的实体指纹）
    static let legacyAnchors: [(release: String, note: String, hashes: [String: String])] = [
        ("1.1.6（习惯描述）", "11-02 库 · 1.1.3/1.1.4 正式版形态", [
            "Habit": "3MlFS2KW4u3JuzCrbYywWg/yVWOEFWXTPjG7wQ6VmUM=",
        ]),
        ("1.1.3", "10-18 库 · 1.1.1/1.1.2 正式版形态", [
            "GoalPlanRevisionMO": "Ad638sYoGieQGV4k4OUB3oWPvCzJPZ3124nvzI8PV48=",
            "Habit": "QBk9RTR8QrKuNK3b34zJCHgCdEimdJ4KY/b7unhrdO0=",
            "Thought": "82srlx8J3kSfAxenFQraaRpxHVYRuohWDBdKszX/bMc=",
            "ThoughtTag": "S6L7n1ulLoxgEi2HlcZK59UBQe7IS3TqTZFtxZn8uao=",
        ]),
        ("1.1.1", "10-10 库 · 1.1.0 正式版形态", [
            "CheckItem": "3T5fF/XqTLBmiPJ++lDgudUuaiFu0mTSD90P8JpvUL8=",
            "GoalPlanRevisionMO": "Ad638sYoGieQGV4k4OUB3oWPvCzJPZ3124nvzI8PV48=",
            "Habit": "QBk9RTR8QrKuNK3b34zJCHgCdEimdJ4KY/b7unhrdO0=",
            "Thought": "82srlx8J3kSfAxenFQraaRpxHVYRuohWDBdKszX/bMc=",
            "ThoughtTag": "S6L7n1ulLoxgEi2HlcZK59UBQe7IS3TqTZFtxZn8uao=",
            "TodoList": "xcBu77B4NiHDhXhpEN9LrSQQPl7I1E99AP4G7aKViTQ=",
            "Topic": "2aGluMIF6Z3+SXcJPLZvR1lAUwTpBDyQ2psPISU4Y1M=",
        ]),
        ("1.1.0（任务分类）", "10-05 开发库", [
            "CheckItem": "3T5fF/XqTLBmiPJ++lDgudUuaiFu0mTSD90P8JpvUL8=",
            "GoalPlanRevisionMO": "Ad638sYoGieQGV4k4OUB3oWPvCzJPZ3124nvzI8PV48=",
            "Habit": "QBk9RTR8QrKuNK3b34zJCHgCdEimdJ4KY/b7unhrdO0=",
            "Thought": "82srlx8J3kSfAxenFQraaRpxHVYRuohWDBdKszX/bMc=",
            "ThoughtTag": "S6L7n1ulLoxgEi2HlcZK59UBQe7IS3TqTZFtxZn8uao=",
            "TodoList": "xcBu77B4NiHDhXhpEN9LrSQQPl7I1E99AP4G7aKViTQ=",
            "TodoTask": "Cc/H1iJ8DmEIVvfPrBVh/54H3SaIYunLnijjRVxGOxw=",
            "Topic": "2aGluMIF6Z3+SXcJPLZvR1lAUwTpBDyQ2psPISU4Y1M=",
        ]),
        ("1.0.9（习惯暂停、退款与账单附件）", "10-01 开发库", [
            "ChatMessage": "Xf+Fmymwt2SRkgZoYJPEt70XrGc3W/LziX7ZW/zrwaU=",
            "CheckItem": "3T5fF/XqTLBmiPJ++lDgudUuaiFu0mTSD90P8JpvUL8=",
            "GoalPlanRevisionMO": "Ad638sYoGieQGV4k4OUB3oWPvCzJPZ3124nvzI8PV48=",
            "Habit": "w4uv4jOlzoQgczDqDnV6Pt4hMaWJCFypnmlUgrCOQyM=",
            "Thought": "82srlx8J3kSfAxenFQraaRpxHVYRuohWDBdKszX/bMc=",
            "ThoughtTag": "S6L7n1ulLoxgEi2HlcZK59UBQe7IS3TqTZFtxZn8uao=",
            "TodoList": "xcBu77B4NiHDhXhpEN9LrSQQPl7I1E99AP4G7aKViTQ=",
            "TodoTask": "Cc/H1iJ8DmEIVvfPrBVh/54H3SaIYunLnijjRVxGOxw=",
            "Topic": "2aGluMIF6Z3+SXcJPLZvR1lAUwTpBDyQ2psPISU4Y1M=",
            "Transaction": "jE/8JcBF/w9lo7NzXxDjLqf0UD9ZN0dvr8sw7gMmE/M=",
        ]),
        ("1.0.8", "09-18 库 · 1.0.7 形态", [
            "ChatMessage": "Xf+Fmymwt2SRkgZoYJPEt70XrGc3W/LziX7ZW/zrwaU=",
            "CheckItem": "3T5fF/XqTLBmiPJ++lDgudUuaiFu0mTSD90P8JpvUL8=",
            "GoalPlanRevisionMO": "Ad638sYoGieQGV4k4OUB3oWPvCzJPZ3124nvzI8PV48=",
            "Habit": "w4uv4jOlzoQgczDqDnV6Pt4hMaWJCFypnmlUgrCOQyM=",
            "HoloMatterLink": "xqKV42t3mtPWL4kPFxlupZllTzFGEAeTbGMTG47771M=",
            "Thought": "82srlx8J3kSfAxenFQraaRpxHVYRuohWDBdKszX/bMc=",
            "ThoughtTag": "S6L7n1ulLoxgEi2HlcZK59UBQe7IS3TqTZFtxZn8uao=",
            "TodoList": "xcBu77B4NiHDhXhpEN9LrSQQPl7I1E99AP4G7aKViTQ=",
            "TodoTask": "nmmlRBZFSl+KCbYr3pQ3YdwaMOjyg98aqd+VjZvo02A=",
            "Topic": "2aGluMIF6Z3+SXcJPLZvR1lAUwTpBDyQ2psPISU4Y1M=",
            "Transaction": "jE/8JcBF/w9lo7NzXxDjLqf0UD9ZN0dvr8sw7gMmE/M=",
        ]),
        ("1.0.7（目标共创）", "09-16 库 · 1.0.6 形态", [
            "ChatMessage": "Xf+Fmymwt2SRkgZoYJPEt70XrGc3W/LziX7ZW/zrwaU=",
            "CheckItem": "3T5fF/XqTLBmiPJ++lDgudUuaiFu0mTSD90P8JpvUL8=",
            "Goal": "e8qWjA3mbuabSVmt+puhOKHtfNtyL6rzwik0m3LhTkE=",
            "Habit": "w4uv4jOlzoQgczDqDnV6Pt4hMaWJCFypnmlUgrCOQyM=",
            "HoloMatterLink": "xqKV42t3mtPWL4kPFxlupZllTzFGEAeTbGMTG47771M=",
            "Thought": "82srlx8J3kSfAxenFQraaRpxHVYRuohWDBdKszX/bMc=",
            "ThoughtTag": "S6L7n1ulLoxgEi2HlcZK59UBQe7IS3TqTZFtxZn8uao=",
            "TodoList": "xcBu77B4NiHDhXhpEN9LrSQQPl7I1E99AP4G7aKViTQ=",
            "TodoTask": "nmmlRBZFSl+KCbYr3pQ3YdwaMOjyg98aqd+VjZvo02A=",
            "Topic": "2aGluMIF6Z3+SXcJPLZvR1lAUwTpBDyQ2psPISU4Y1M=",
            "Transaction": "jE/8JcBF/w9lo7NzXxDjLqf0UD9ZN0dvr8sw7gMmE/M=",
        ]),
    ]
}
