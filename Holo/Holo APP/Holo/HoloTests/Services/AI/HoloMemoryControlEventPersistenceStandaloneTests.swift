import CoreData
import Foundation

/// M03-b 持久化验收：迁移前自动快照 / 控制事件存储 / 写前先行事务与崩溃重放。
///
/// 1. 快照：模型不兼容先拍快照再迁移；快照失败拒绝迁移（原库不动）；兼容不拍；
/// 2. 事件存储：JSON 往返、operationID 幂等、随记录落同域库（健康事件不进普通库）；
/// 3. 事务：写前先行三步、版本冲突不覆盖、崩溃（只有事件没改记录）按事件重放收敛、
///    放宽事件未见全部限制时不解除（限制优先）。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryControlEventPersistenceStandaloneTests.main()
    }
}
#endif
struct HoloMemoryControlEventPersistenceStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test迁移触发快照且数据存活()
        try await test快照失败拒绝迁移()
        try await test兼容库不拍快照()
        try await test事件存取往返与幂等()
        try await test事件随记录落敏感库()
        try await test事务写前先行全链路()
        try await test版本冲突不覆盖()
        try await test崩溃后按事件重放收敛()
        try await test放宽事件未见全部限制时不解除()
        print("✅ HoloMemoryControlEventPersistenceStandaloneTests: \(assertionCount) assertions passed")
    }

    // MARK: - 快照

    private static func test迁移触发快照且数据存活() async throws {
        let dir = makeTempDir("snap-migrate")
        try await seedLegacyStore(in: dir)

        let controller = try HoloMemoryPersistenceController(directoryURL: dir)
        let snapshots = snapshotDirectories(in: dir, container: "HoloMemoryMain")
        expect(snapshots.count == 1, "检测到模型变化应恰好拍一份快照，实际 \(snapshots.count)")
        let copied = snapshots[0].appendingPathComponent("HoloMemoryMain.sqlite")
        let size = (try? FileManager.default.attributesOfItem(atPath: copied.path))?[.size] as? Int ?? 0
        expect(size > 0, "快照库文件非空")

        // 迁移后旧记录仍可读（stableID 计数不丢）。
        let context = controller.mainContainer.newBackgroundContext()
        let count = try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            return try context.count(for: request)
        }
        expect(count == 1, "迁移后旧数据存活")

        // 同模型二次打开：不再新增快照。
        _ = try HoloMemoryPersistenceController(directoryURL: dir)
        expect(snapshotDirectories(in: dir, container: "HoloMemoryMain").count == 1, "兼容库不重复拍快照")
    }

    private static func test快照失败拒绝迁移() async throws {
        let dir = makeTempDir("snap-refuse")
        try await seedLegacyStore(in: dir)
        // 阻断快照目录创建：在 MigrationSnapshots 位置预放一个普通文件。
        let blocker = dir.appendingPathComponent("MigrationSnapshots")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())

        var threw = false
        do {
            _ = try HoloMemoryPersistenceController(directoryURL: dir)
        } catch {
            threw = true
        }
        expect(threw, "快照失败必须拒绝迁移（硬保证 1：没有保险不搬家）")
        // 原库未被加载器改动：仍可用旧模型打开。
        let legacy = try openLegacyStore(in: dir)
        expect(true, "拒绝迁移后原库保持可打开（未抛错即通过）")
    }

    private static func test兼容库不拍快照() async throws {
        let dir = makeTempDir("snap-fresh")
        _ = try HoloMemoryPersistenceController(directoryURL: dir)
        let snapshots = snapshotDirectories(in: dir, container: "HoloMemoryMain")
        expect(snapshots.isEmpty, "全新安装无旧库，不拍快照")
    }

    // MARK: - 事件存储

    private static func test事件存取往返与幂等() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        let record = try makeRecord(anchor: "coffee-preference", evidence: "chat-1")
        try await repository.upsert(record, observationKey: nil)

        let event = makeEvent(
            recordID: record.id,
            kind: .disabled,
            prior: ["evt-earlier"],
            operationID: "op-disable-1"
        )
        let inserted = try await store.append(event)
        expect(inserted, "首次写入成功")

        let reinserted = try await store.append(event)
        expect(!reinserted, "同 operationID 重试幂等，不重复写入")

        let events = try await store.events(forRecordID: record.id)
        expect(events.count == 1, "查回一条")
        expect(events[0] == event, "priorEventIDs JSON 往返等值")
        let latest = try await store.latestEventID(forRecordID: record.id)
        expect(latest == event.id, "最新事件 ID 正确")

        try await store.markApplied(eventID: event.id, at: Date())
        let outstanding = try await store.outstandingEvents()
        expect(outstanding.isEmpty, "标记完成后无待重放事件")
    }

    private static func test事件随记录落敏感库() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        // 健康域证据 → 记录落敏感库（requiresSensitiveLocalStorage 规则）。
        let health = try makeRecord(anchor: "sleep-trend", evidence: "health-1", sourceDomain: .health)
        try await repository.upsert(health, observationKey: nil)

        let event = makeEvent(recordID: health.id, kind: .disabled, prior: [], operationID: "op-h-1")
        _ = try await store.append(event)

        let sensitiveCount = try await eventRowCount(controller.sensitiveContainer)
        let mainCount = try await eventRowCount(controller.mainContainer)
        expect(sensitiveCount == 1, "敏感记录的事件落敏感库")
        expect(mainCount == 0, "敏感事件不得进入普通同步库（§9.3）")
    }

    // MARK: - 事务与重放

    private static func test事务写前先行全链路() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        let transaction = HoloMemoryUserControlTransaction(repository: repository, eventStore: store)

        let record = try makeRecord(anchor: "running-evening", evidence: "chat-2")
        try await repository.upsert(record, observationKey: nil)

        var mutated = record
        mutated.state = .suppressed
        mutated.userDecision = .rejected
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = try await transaction.apply(
            request: HoloMemoryUserControlRequest(
                operationID: "op-disable-run",
                recordID: record.id,
                expectedContentVersion: record.recordVersion,
                action: .disable,
                issuedAt: now
            ),
            mutatedRecord: mutated,
            event: makeEvent(recordID: record.id, kind: .disabled, prior: [], operationID: "op-disable-run", at: now),
            now: now
        )
        expect(outcome.isSuccess, "事务成功")

        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .suppressed && after?.userDecision == .rejected, "记录状态已落库")
        let outstanding = try await store.outstandingEvents()
        expect(outstanding.isEmpty, "事务完成态无待重放事件")
    }

    private static func test版本冲突不覆盖() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        let transaction = HoloMemoryUserControlTransaction(repository: repository, eventStore: store)

        let record = try makeRecord(anchor: "stale-edit", evidence: "chat-3")
        try await repository.upsert(record, observationKey: nil)

        var mutated = record
        mutated.displaySummary = "基于过期版本的编辑"
        let outcome = try await transaction.apply(
            request: HoloMemoryUserControlRequest(
                operationID: "op-stale",
                recordID: record.id,
                expectedContentVersion: record.recordVersion + 5, // 他端已推进版本
                action: .correct(statement: "x"),
                issuedAt: Date()
            ),
            mutatedRecord: mutated,
            event: makeEvent(recordID: record.id, kind: .corrected, prior: [], operationID: "op-stale"),
            now: Date()
        )
        guard case .conflict = outcome else {
            fatalError("❌ 版本不符应返回 conflict")
        }
        let after = try await repository.fetch(id: record.id)
        expect(after?.displaySummary == record.displaySummary, "冲突时不覆盖新版本（§11.3）")
        let outstanding = try await store.outstandingEvents()
        expect(outstanding.isEmpty, "冲突路径不落事件")
    }

    private static func test崩溃后按事件重放收敛() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        let transaction = HoloMemoryUserControlTransaction(repository: repository, eventStore: store)

        let record = try makeRecord(anchor: "crash-replay", evidence: "chat-4")
        try await repository.upsert(record, observationKey: nil)

        // 崩溃模拟：只有事件落库（①步成功），记录未改（②步没到）。
        _ = try await store.append(
            makeEvent(recordID: record.id, kind: .inaccurate, prior: [], operationID: "op-crash")
        )
        let outstanding = try await store.outstandingEvents()
        expect(outstanding.count == 1, "崩溃后存在待重放事件")

        let settled = try await HoloMemoryControlEventReconciler.reconcile(
            outstanding: outstanding,
            transaction: transaction,
            repository: repository
        )
        expect(settled == 1, "重放收敛一条")
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .suppressed && after?.userDecision == .rejected, "判错意图经重放生效（未完成限制意图被识别）")
        let drained = try await store.outstandingEvents()
        expect(drained.isEmpty, "重放后无悬挂事件")
    }

    private static func test放宽事件未见全部限制时不解除() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let store = HoloMemoryControlEventStore(controller: controller)
        let transaction = HoloMemoryUserControlTransaction(repository: repository, eventStore: store)

        let record = try makeRecord(anchor: "relax-guard", evidence: "chat-5")
        try await repository.upsert(record, observationKey: nil)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // 并发两事件：停用（另一端）与确认（本端，没见过停用）。
        let disable = makeEvent(recordID: record.id, kind: .disabled, prior: [],
                                operationID: "op-d", at: base)
        let confirm = makeEvent(recordID: record.id, kind: .confirmed, prior: [],
                                operationID: "op-c", at: base.addingTimeInterval(10))
        _ = try await store.append(disable)
        _ = try await store.append(confirm)

        _ = try await HoloMemoryControlEventReconciler.reconcile(
            outstanding: try await store.outstandingEvents(),
            transaction: transaction,
            repository: repository
        )
        let after = try await repository.fetch(id: record.id)
        expect(after?.state == .suppressed, "未见过停用的确认不能解除限制（限制优先）")
        let outstanding = try await store.outstandingEvents()
        expect(outstanding.isEmpty, "被保守跳过的确认也已标记完成，不留悬挂")
    }

    // MARK: - Fixtures

    private static func makeTempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-m03b-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 用「上一版模型」（无 ControlEvent 实体）建库并写一条记录，复现真实升级路径。
    private static func seedLegacyStore(in dir: URL) async throws {
        let container = try openLegacyStore(in: dir)
        let context = container.newBackgroundContext()
        try await context.perform {
            let mo = HoloMemoryRecordMO(context: context)
            mo.stableID = "legacy-record-1"
            mo.recordData = Data()
            mo.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            mo.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try context.save()
        }
        // 释放文件句柄，交给新模型加载。
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    @discardableResult
    private static func openLegacyStore(in dir: URL) throws -> NSPersistentContainer {
        let model = HoloMemoryManagedObjectModelFactory.makeModel(
            excludingEntityNames: ["HoloMemoryControlEventMO"]
        )
        let container = NSPersistentContainer(name: "HoloMemoryMain", managedObjectModel: model)
        let description = NSPersistentStoreDescription(
            url: dir.appendingPathComponent("HoloMemoryMain.sqlite")
        )
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        var error: Error?
        container.loadPersistentStores { _, loadError in error = loadError }
        if let error { throw error }
        return container
    }

    private static func snapshotDirectories(in dir: URL, container: String) -> [URL] {
        let root = dir.appendingPathComponent("MigrationSnapshots")
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("\(container)-") }
    }

    private static func eventRowCount(_ container: NSPersistentContainer) async throws -> Int {
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
            return try context.count(for: request)
        }
    }

    private static func makeEvent(
        recordID: String,
        kind: HoloMemoryControlEventKind,
        prior: Set<String>,
        operationID: String,
        at: Date = Date(timeIntervalSince1970: 1_799_000_000)
    ) -> HoloMemoryUserControlEvent {
        HoloMemoryUserControlEvent(
            id: "evt-\(operationID)",
            targetRecordID: recordID,
            kind: kind,
            priorEventIDs: prior,
            basedOnContentVersion: 1,
            resultingContentVersion: 1,
            occurredAt: at,
            operationID: operationID
        )
    }

    /// 与仓库集成测试同构的合法记录（stableID 过校验；健康来源 → 敏感库）。
    private static func makeRecord(
        anchor: String,
        evidence: String,
        sourceDomain: HoloMemoryDomain? = nil
    ) throws -> HoloMemoryRecord {
        let domain: HoloMemoryDomain = sourceDomain ?? .conversation
        let anchorRef = try HoloMemoryAnchorRef(type: .userTheme, value: anchor)
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: .recurringPattern,
            anchors: [anchorRef]
        )
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor,
            anchorRefs: [anchorRef],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "\(anchor) 的阶段结论",
            aiUseSummary: "用户近期呈现 \(anchor)",
            prohibitedInferences: [],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: evidence,
                kind: .entityRef,
                sourceDomain: domain,
                lineageKey: "lineage-\(evidence)",
                sourceID: evidence,
                revisionDigest: "revision-\(evidence)",
                observedAt: now
            )],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: sourceDomain == .health ? .sensitive : .normal,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }
}
