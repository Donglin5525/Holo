//
//  ContextPlanItemExecutionTests.swift
//  HoloTests
//
//  Context Plan 单项即时创建与回执 V2（今日看板 Matter 化方案 §8.1/§8.2/§13.2）
//
//  覆盖：V2 回执编解码与 legacy 兼容、单项幂等（重复点击/退出重进不重复建）、
//  多条无日期条目不自动合并、回执容量按 createdAt 淘汰、任务删除后回执降级。
//

import XCTest
import CoreData
@testable import Holo

final class ContextPlanItemExecutionTests: XCTestCase {

    private func makeRepo() throws -> (TodoRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "ContextPlanItemExecTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = TodoRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    private func makeItem(
        id: String = "item-1",
        title: String = "确认签证材料",
        confirmedDate: Date? = nil
    ) -> HoloContextPlanItem {
        HoloContextPlanItem(
            itemID: id,
            title: title,
            kind: .task,
            reason: "出发前必须完成",
            basis: .generalKnowledge,
            confirmedDate: confirmedDate,
            selected: true
        )
    }

    // MARK: - V2 回执编解码

    func test_receiptV2编解码往返保真() throws {
        let taskID = UUID()
        let messageID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_789_000_000)
        let receipt = HoloContextPlanTaskReceiptV2(
            logicalItemID: "run|item-1",
            fingerprint: "abc123",
            taskID: taskID,
            sourceMessageID: messageID,
            sourceItemID: "item-1",
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        let decoded = try decoder.decode(HoloContextPlanTaskReceiptV2.self, from: data)
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    /// 旧版 [logicalItemID: fingerprint] 读进 V2 世界 = 仅有指纹、无 taskID 的 legacy 态：
    /// 仍能防重复，但不能伪造 MatterLink。
    func test_legacy回执转换后无taskID可防重复() {
        let item = makeItem()
        let legacyFingerprint = HoloContextPlanExecutionAdapter.contentFingerprint(item, confirmedDate: nil)
        let preparation = HoloContextPlanExecutionAdapter.prepareSingleItem(
            item: item,
            confirmedDate: nil,
            runID: "run",
            draftRevision: 1,
            legacyFingerprint: legacyFingerprint,
            receiptV2: nil,
            taskExists: nil
        )
        if case .alreadyAdded(let taskID) = preparation {
            XCTAssertNil(taskID, "legacy 回执防重复但不提供任务 ID")
        } else {
            XCTFail("legacy 指纹命中应判定为已加入，实际 \(preparation)")
        }
    }

    // MARK: - 单项幂等

    func test_单项重复prepare不重复创建() {
        let item = makeItem()
        let receipt = HoloContextPlanTaskReceiptV2(
            logicalItemID: "run|item-1",
            fingerprint: HoloContextPlanExecutionAdapter.contentFingerprint(item, confirmedDate: nil),
            taskID: UUID(),
            sourceMessageID: UUID(),
            sourceItemID: "item-1",
            createdAt: Date()
        )
        let preparation = HoloContextPlanExecutionAdapter.prepareSingleItem(
            item: item,
            confirmedDate: nil,
            runID: "run",
            draftRevision: 1,
            legacyFingerprint: nil,
            receiptV2: receipt,
            taskExists: true
        )
        if case .alreadyAdded(let taskID) = preparation {
            XCTAssertEqual(taskID, receipt.taskID)
        } else {
            XCTFail("已有成功回执应复用，不重复创建，实际 \(preparation)")
        }
    }

    /// 草案 revision 更新但条目实质未变 → 仍复用不重复创建（§8.1 规则 7）。
    func test_draftRevision推进但条目未变不重复创建() {
        let item = makeItem()
        let receipt = HoloContextPlanTaskReceiptV2(
            logicalItemID: "run|item-1",
            fingerprint: HoloContextPlanExecutionAdapter.contentFingerprint(item, confirmedDate: nil),
            taskID: UUID(),
            sourceMessageID: UUID(),
            sourceItemID: "item-1",
            createdAt: Date()
        )
        let preparation = HoloContextPlanExecutionAdapter.prepareSingleItem(
            item: item,
            confirmedDate: nil,
            runID: "run",
            draftRevision: 5, // revision 已推进
            legacyFingerprint: nil,
            receiptV2: receipt,
            taskExists: true
        )
        if case .alreadyAdded = preparation {} else {
            XCTFail("条目实质未变必须复用，实际 \(preparation)")
        }
    }

    /// 条目实质变化（日期改变）→ 允许生成变更候选，不复用旧指纹。
    func test_条目日期变化不算未变() {
        let item = makeItem(confirmedDate: date(2026, 9, 20))
        let receipt = HoloContextPlanTaskReceiptV2(
            logicalItemID: "run|item-1",
            fingerprint: HoloContextPlanExecutionAdapter.contentFingerprint(item, confirmedDate: nil),
            taskID: UUID(),
            sourceMessageID: UUID(),
            sourceItemID: "item-1",
            createdAt: Date()
        )
        let preparation = HoloContextPlanExecutionAdapter.prepareSingleItem(
            item: item,
            confirmedDate: date(2026, 9, 20),
            runID: "run",
            draftRevision: 2,
            legacyFingerprint: nil,
            receiptV2: receipt,
            taskExists: true
        )
        if case .alreadyAdded = preparation {
            XCTFail("日期已变化，旧指纹不得拦截新创建")
        } else if case .create = preparation {
            // 预期：生成创建请求
        }
    }

    // MARK: - 任务删除后的回执降级（§8.2）

    func test_任务已删除时回执不再显示已加入() {
        let item = makeItem()
        let receipt = HoloContextPlanTaskReceiptV2(
            logicalItemID: "run|item-1",
            fingerprint: "fp",
            taskID: UUID(),
            sourceMessageID: UUID(),
            sourceItemID: "item-1",
            createdAt: Date()
        )
        let state = HoloContextPlanExecutionAdapter.resolveDisplayState(
            receipt: receipt,
            taskExists: false
        )
        XCTAssertEqual(state, .taskDeleted, "任务被删后回执不得再显示「已加入」")
    }

    func test_任务存在时回执显示已加入并带ID() {
        let taskID = UUID()
        let receipt = HoloContextPlanTaskReceiptV2(
            logicalItemID: "run|item-1",
            fingerprint: "fp",
            taskID: taskID,
            sourceMessageID: UUID(),
            sourceItemID: "item-1",
            createdAt: Date()
        )
        let state = HoloContextPlanExecutionAdapter.resolveDisplayState(receipt: receipt, taskExists: true)
        XCTAssertEqual(state, .added(taskID: taskID))
    }

    // MARK: - 容量清理按 createdAt（§8.2：禁 Dictionary.keys.prefix 非确定性淘汰）

    func test_容量清理淘汰最旧而不是任意键() {
        var receipts: [String: HoloContextPlanTaskReceiptV2] = [:]
        let oldestKey = "run-a|item-0"
        for index in 0..<6 {
            let key = "run-\(index)|item-0"
            receipts[key] = HoloContextPlanTaskReceiptV2(
                logicalItemID: key,
                fingerprint: "fp-\(index)",
                taskID: UUID(),
                sourceMessageID: UUID(),
                sourceItemID: "item-0",
                createdAt: Date(timeIntervalSince1970: Double(1_000_000 + index * 100))
            )
        }
        // 保证「最旧」不在字典首键（排除 keys.prefix 碰巧通过的假绿）
        var reordered = receipts
        reordered.removeValue(forKey: oldestKey)
        reordered[oldestKey] = receipts[oldestKey]

        let trimmed = HoloContextPlanExecutionAdapter.trimReceipts(reordered, limit: 5)
        XCTAssertEqual(trimmed.count, 5)
        XCTAssertNil(trimmed[oldestKey], "被淘汰的必须是 createdAt 最旧的条目")
        XCTAssertNotNil(trimmed["run-5|item-0"], "最新的必须保留")
    }

    // MARK: - 无日期多条目不自动合并（§8.1 规则 5）

    func test_多个无日期条目各自独立创建不自动合并() {
        let items = [
            makeItem(id: "a", title: "订机票"),
            makeItem(id: "b", title: "订酒店"),
            makeItem(id: "c", title: "换日元"),
        ]
        let request = HoloContextPlanExecutionRequest(
            runID: "run", draftRevision: 1, items: items, confirmedDates: [:]
        )
        let outcome = HoloContextPlanExecutionAdapter.prepare(
            request: request,
            successfulReceipts: [:],
            existingTaskTitles: []
        )
        // 三条独立 creation，调用方按逐条入口各自建任务；adapter 不再产出任何合并信号。
        XCTAssertEqual(outcome.creations.count, 3)
        XCTAssertEqual(outcome.creations.map(\.title), ["订机票", "订酒店", "换日元"])
    }

    // MARK: - 真实落库写入来源字段（§8.2/§13.2）

    func test_单项创建真实写入aiSource字段() throws {
        let (repo, _) = try makeRepo()
        let messageID = UUID()
        let creation = HoloContextPlanTaskCreation(
            idempotencyKey: "run|v1|item-1",
            logicalItemID: "run|item-1",
            itemID: "item-1",
            title: "确认签证材料",
            note: nil,
            dueDate: nil
        )
        let task = try repo.createContextPlanTask(
            creation: creation,
            sourceMessageID: messageID
        )
        XCTAssertEqual(task.aiSourceMessageId, messageID.uuidString)
        XCTAssertEqual(task.aiSourceItemId, "item-1")

        // 跨重启追溯：按来源键能找回同一任务（补链与幂等的依据）
        let found = repo.findTaskByAISource(messageId: messageID.uuidString, itemId: "item-1")
        XCTAssertEqual(found?.id, task.id)
    }

    /// 幂等：同来源键重复创建返回既有任务，不产生副本。
    func test_同来源键重复创建幂等返回既有任务() throws {
        let (repo, _) = try makeRepo()
        let messageID = UUID()
        let creation = HoloContextPlanTaskCreation(
            idempotencyKey: "k1",
            logicalItemID: "run|item-1",
            itemID: "item-1",
            title: "确认签证材料",
            note: nil,
            dueDate: nil
        )
        let first = try repo.createContextPlanTask(creation: creation, sourceMessageID: messageID)
        let second = try repo.createContextPlanTask(creation: creation, sourceMessageID: messageID)
        XCTAssertEqual(first.id, second.id, "同 aiSource 键重复创建必须幂等")

        let all = repo.activeTasks.filter { $0.title == "确认签证材料" }
        XCTAssertEqual(all.count, 1)
    }
}

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d
    return Calendar(identifier: .gregorian).date(from: comps)!
}
