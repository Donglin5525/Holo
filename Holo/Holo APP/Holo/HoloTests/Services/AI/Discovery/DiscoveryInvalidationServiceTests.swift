//
//  DiscoveryInvalidationServiceTests.swift
//  HoloTests
//
//  「一个发现」G2 失效信号测试（02 §9.3；G0 缺口 B）：
//  保存通知（而非三域 UI 通知）→ 提取三域变更 sourceRefs → findingsAffected
//  （含反例/基线角色）→ invalidateFinding；Habit 定义变更与授权变化走保守撤销；
//  CheckItem 变化映射回所属任务。合成 in-memory 业务壳模型（实体名对齐业务实体、
//  不绑 NSManagedObject 子类防类映射冲突）+ in-memory DiscoveryStore。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
import CoreData
@testable import Holo

@MainActor
final class DiscoveryInvalidationServiceTests: XCTestCase {

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    // MARK: - 合成业务壳栈

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext!
    private var store: DiscoveryStore!

    override func setUpWithError() throws {
        // 实体名与业务实体一致（服务按 entity.name 提取）；managedObjectClassName 用
        // NSManagedObject 基类——不 claim 任何 NSManagedObject 子类，避免与真实
        // CoreDataStack 程序化模型产生 134020 类映射歧义
        let model = NSManagedObjectModel()

        func entity(_ name: String, attributes: [NSAttributeDescription],
                    relationships: [NSRelationshipDescription] = []) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = "NSManagedObject"
            entity.properties = attributes + relationships
            return entity
        }
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        let thought = entity("Thought", attributes: [
            attr("id", .UUIDAttributeType), attr("deletedAt", .dateAttributeType, optional: true),
        ])
        let todoTask = entity("TodoTask", attributes: [attr("id", .UUIDAttributeType)])
        let habit = entity("Habit", attributes: [attr("id", .UUIDAttributeType)])
        let habitRecord = entity("HabitRecord", attributes: [attr("id", .UUIDAttributeType)])
        let checkItem = entity("CheckItem", attributes: [attr("id", .UUIDAttributeType)])

        // CheckItem.task → TodoTask（服务用 valueForKey("task") 映射回所属任务）
        let itemTask = NSRelationshipDescription()
        itemTask.name = "task"
        itemTask.destinationEntity = todoTask
        itemTask.minCount = 0
        itemTask.maxCount = 1
        itemTask.isOptional = true
        itemTask.deleteRule = .nullifyDeleteRule
        let taskItems = NSRelationshipDescription()
        taskItems.name = "checkItems"
        taskItems.destinationEntity = checkItem
        taskItems.minCount = 0
        taskItems.maxCount = 0
        taskItems.isOptional = true
        taskItems.deleteRule = .cascadeDeleteRule
        itemTask.inverseRelationship = taskItems
        taskItems.inverseRelationship = itemTask
        checkItem.properties = checkItem.properties + [itemTask]
        todoTask.properties = todoTask.properties + [taskItems]

        model.entities = [thought, todoTask, habit, habitRecord, checkItem]

        let container = NSPersistentContainer(name: "G2InvalidationShell", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        self.container = container
        self.context = container.viewContext

        store = try DiscoveryStore(configuration: .init(
            inMemory: true,
            feedbackKey: Data(repeating: 0x03, count: 32),
            feedbackSalt: "invalidation-test-salt"
        ))
    }

    override func tearDown() {
        container = nil
        context = nil
        store = nil
        super.tearDown()
    }

    /// iOS 26.3 测试宿主坑（habit-drag 档案）：MainActor 类用例内释放踩析构 double-free，钉池不释放。
    nonisolated(unsafe) private static var pinnedInstances: [AnyObject] = []

    private func makeService(started: Bool = true) -> DiscoveryInvalidationService {
        let service = DiscoveryInvalidationService(
            store: store,
            businessCoordinator: container.persistentStoreCoordinator
        )
        Self.pinnedInstances.append(service)
        if started { service.start() }
        return service
    }

    private func publishFinding(dependencies: [DiscoveryFindingDependency]) throws -> UUID {
        // 有效期放到远未来：失效断言用真实 now 轮询，不能让「过期」伪装成「已撤销」
        let farFutureExpiry = Date(timeIntervalSince1970: 2_000_000_000)
        return try store.publishFinding(
            runID: "run-1",
            payload: DiscoveryPublishedPayload(
                candidateID: "C01",
                type: .twoEpisodes,
                title: "这两次重新开始，你都把第一步变轻了。",
                body: ["恢复运动时先走十分钟。"],
                citations: [.init(evidenceID: "E01", quote: "先出去走了十分钟", sourceRef: dependencies.first?.sourceRef)],
                coverageNote: "范围：近 30 天想法",
                sensitivity: .nonSensitive,
                timeRange: DiscoveryTimeRange(start: nil, end: nil),
                fingerprintMaterial: "subject:lighter-start"
            ),
            dependencies: dependencies,
            publishedAt: fixedNow,
            expiresAt: farFutureExpiry,
            freezeDigest: "d1"
        )
    }

    /// 双 Optional 扁平化：store 抛错与「无有效发现」都视为已撤下
    private func currentFinding() -> DiscoveryPublishedFindingRecord? {
        (try? store.activeFinding(now: Date())) ?? nil
    }

    private func waitForInvalidation(timeout: TimeInterval = 3) {
        let expectation = expectation(description: "finding invalidated")
        Task { @MainActor in
            for _ in 0..<150 {
                if self.currentFinding() == nil {
                    expectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        wait(for: [expectation], timeout: timeout)
    }

    @discardableResult
    private func insertObject(_ entityName: String, id: UUID) -> NSManagedObject {
        let mo = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
        mo.setValue(id, forKey: "id")
        return mo
    }

    // MARK: - 精确失效（直接调 apply）

    func test_精确失效_想法来源变化撤销依赖它的发现() throws {
        let thoughtID = UUID()
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:\(thoughtID.uuidString)", kind: .thought, sourceRevision: "r1", role: .support),
        ])
        XCTAssertNotNil(try store.activeFinding(now: fixedNow))

        makeService().applyInvalidation(
            sourceRefs: ["thought:\(thoughtID.uuidString)"],
            conservative: false,
            now: fixedNow
        )
        XCTAssertNil(try store.activeFinding(now: fixedNow), "依赖来源变化 → 立即撤销")
    }

    func test_精确失效_反例角色同样触发() throws {
        let counterID = UUID()
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:support-1", kind: .thought, sourceRevision: "r1", role: .support),
            .init(sourceRef: "thought:\(counterID.uuidString)", kind: .thought, sourceRevision: "r2", role: .counterExample),
        ])
        makeService().applyInvalidation(
            sourceRefs: ["thought:\(counterID.uuidString)"],
            conservative: false,
            now: fixedNow
        )
        XCTAssertNil(try store.activeFinding(now: fixedNow), "反例来源变化也撤销（依赖索引不只存支持来源）")
    }

    func test_无关来源不影响() throws {
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:support-1", kind: .thought, sourceRevision: "r1", role: .support),
        ])
        makeService().applyInvalidation(
            sourceRefs: ["thought:unrelated", "task:unrelated"],
            conservative: false,
            now: fixedNow
        )
        XCTAssertNotNil(try store.activeFinding(now: fixedNow))
    }

    // MARK: - 保存通知（异步路径）

    func test_保存通知_想法插入触发失效() throws {
        let service = makeService()
        let thoughtID = UUID()
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:\(thoughtID.uuidString)", kind: .thought, sourceRevision: "r1", role: .support),
        ])

        insertObject("Thought", id: thoughtID)
        try context.save()   // 真实 NSManagedObjectContextDidSave → 服务提取 → 撤销

        waitForInvalidation()
        XCTAssertNil(try store.activeFinding(now: Date()), "保存通知路径必须生效（不依赖三域 UI 通知，缺口 B）")
        _ = service // 持有：deinit 前观察者一直在
    }

    func test_保存通知_习惯记录与任务同样触发() throws {
        _ = makeService()
        let recordID = UUID()
        let taskID = UUID()
        try publishFinding(dependencies: [
            .init(sourceRef: "habitEvent:\(recordID.uuidString)", kind: .habitEvent, sourceRevision: "r1", role: .baseline),
            .init(sourceRef: "task:\(taskID.uuidString)", kind: .task, sourceRevision: "r2", role: .support),
        ])

        insertObject("HabitRecord", id: recordID)
        insertObject("TodoTask", id: taskID)
        try context.save()

        waitForInvalidation()
        XCTAssertNil(try store.activeFinding(now: Date()))
    }

    func test_保存通知_子任务变化映射回所属任务() throws {
        _ = makeService()
        let taskID = UUID()
        try publishFinding(dependencies: [
            .init(sourceRef: "task:\(taskID.uuidString)", kind: .task, sourceRevision: "r1", role: .support),
        ])

        let task = insertObject("TodoTask", id: taskID)
        let item = insertObject("CheckItem", id: UUID())
        item.setValue(task, forKey: "task")
        try context.save()

        waitForInvalidation()
        XCTAssertNil(try store.activeFinding(now: Date()), "CheckItem 变化经 task 关系映射为 task:<id>")
    }

    func test_保存通知_习惯定义变更保守撤销全部() throws {
        _ = makeService()
        // 发现只依赖某想法（与习惯无关）——保守路径也应撤销
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:anything", kind: .thought, sourceRevision: "r1", role: .support),
        ])

        insertObject("Habit", id: UUID())
        try context.save()

        waitForInvalidation()
        XCTAssertNil(try store.activeFinding(now: Date()), "定义字段参与记录版本，受影响集合不可精确 → 保守撤销全部")
    }

    // MARK: - 授权变化

    func test_授权变化_保守撤销全部() throws {
        _ = makeService()
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:anything", kind: .thought, sourceRevision: "r1", role: .support),
        ])
        XCTAssertNotNil(try store.activeFinding(now: fixedNow))

        NotificationCenter.default.post(
            name: .holoAIDataProcessingConsentDidChange,
            object: nil, userInfo: ["granted": false]
        )
        waitForInvalidation()
        XCTAssertNil(try store.activeFinding(now: Date()), "撤总授权 → 当前发现立即撤销（离线同样照撤）")
    }

    // MARK: - 独立栈过滤

    func test_非业务栈的保存通知被过滤() throws {
        let service = makeService()
        let thoughtID = UUID()
        try publishFinding(dependencies: [
            .init(sourceRef: "thought:\(thoughtID.uuidString)", kind: .thought, sourceRevision: "r1", role: .support),
        ])

        // 另一个独立容器（coordinator 不同）的保存不应触发
        let otherContainer = NSPersistentContainer(name: "Other", managedObjectModel: container.managedObjectModel)
        let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        description.type = NSInMemoryStoreType
        otherContainer.persistentStoreDescriptions = [description]
        otherContainer.loadPersistentStores { _, _ in }
        let otherContext = otherContainer.newBackgroundContext()
        otherContext.performAndWait {
            let mo = NSEntityDescription.insertNewObject(forEntityName: "Thought", into: otherContext)
            mo.setValue(UUID(), forKey: "id")
            try? otherContext.save()
        }

        // 直接验证：service 对该 ref 的精确失效是生效的（排除「没插入成功」的假阴性），
        // 而独立栈保存后短时间内发现仍在
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            XCTAssertNotNil(currentFinding(), "独立栈保存不触发失效")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        service.applyInvalidation(sourceRefs: ["thought:\(thoughtID.uuidString)"], conservative: false, now: Date())
        XCTAssertNil(try store.activeFinding(now: Date()))
    }
}
