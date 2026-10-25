//
//  DiscoverySourceAdapterTests.swift
//  HoloTests
//
//  「一个发现」G2 来源适配测试：
//  1) 谓词求交真实断言——用合成 in-memory Core Data 模型（属性名与业务实体一致、
//     实体名避开业务模型防 134020 类映射冲突）评估 basePredicate 的实际过滤行为；
//  2) 想法域谓词结构断言——必含 AI 可见性（ThoughtAIAudience）子谓词 + 软删/归档排除；
//  3) 三域 sourceRevision 固定字段序的确定性与稳定性（纯静态函数，无需业务库）。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
import CoreData
@testable import Holo

@MainActor
final class DiscoverySourceAdapterTests: XCTestCase {

    /// iOS 26.3 测试宿主坑（habit-drag 档案）：MainActor 类用例内释放踩析构 double-free，钉池不释放。
    nonisolated(unsafe) private static var pinnedInstances: [AnyObject] = []

    // MARK: - 合成模型（属性名对齐业务实体；实体名错开防类映射冲突）

    private func makeShellModel() throws -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        func entity(_ name: String, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = "NSManagedObject"
            entity.properties = attributes
            return entity
        }
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        let thoughtShell = entity("G2ThoughtShell", [
            attr("id", .UUIDAttributeType),
            attr("deletedAt", .dateAttributeType, optional: true),
            attr("isSoftDeleted", .booleanAttributeType),
            attr("isArchived", .booleanAttributeType),
        ])
        let taskShell = entity("G2TaskShell", [
            attr("id", .UUIDAttributeType),
            attr("deletedFlag", .booleanAttributeType),
            attr("deletedAt", .dateAttributeType, optional: true),
            attr("archived", .booleanAttributeType),
            attr("title", .stringAttributeType),
        ])
        let habitRecordShell = entity("G2HabitRecordShell", [
            attr("id", .UUIDAttributeType),
            attr("deletedAt", .dateAttributeType, optional: true),
        ])

        model.entities = [thoughtShell, taskShell, habitRecordShell]
        return model
    }

    private func makeShellContainer() throws -> (NSPersistentContainer, NSManagedObjectContext) {
        let container = NSPersistentContainer(name: "G2AdapterShell", managedObjectModel: try makeShellModel())
        let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return (container, container.viewContext)
    }

    // MARK: - 任务域谓词（真实评估 + fetch 断言）

    func test_任务域basePredicate_软删硬删归档全部排除() throws {
        let adapter = DiscoveryTaskAdapter(context: try makeShellContainer().1)
        Self.pinnedInstances.append(adapter)
        let predicate = adapter.basePredicate()

        // 字典评估：键缺失才解析为 nil（NSNull ≠ nil）
        XCTAssertTrue(predicate.evaluate(with: ["deletedFlag": false, "archived": false]), "未删未归档任务可见")
        XCTAssertFalse(predicate.evaluate(with: ["deletedFlag": true, "archived": false]), "deletedFlag 任务必须排除")
        XCTAssertFalse(predicate.evaluate(with: ["deletedFlag": false, "deletedAt": Date(), "archived": false]), "deletedAt 任务必须排除")
        XCTAssertFalse(predicate.evaluate(with: ["deletedFlag": false, "archived": true]), "归档任务必须排除（V1 不读已归档）")
    }

    func test_任务域basePredicate_真实fetch只回可见行() throws {
        let (_, context) = try makeShellContainer()
        let adapter = DiscoveryTaskAdapter(context: context)
        Self.pinnedInstances.append(adapter)

        func insert(_ deletedFlag: Bool, _ deletedAt: Date?, _ archived: Bool) {
            let mo = NSEntityDescription.insertNewObject(forEntityName: "G2TaskShell", into: context)
            mo.setValue(UUID(), forKey: "id")
            mo.setValue(deletedFlag, forKey: "deletedFlag")
            mo.setValue(deletedAt, forKey: "deletedAt")
            mo.setValue(archived, forKey: "archived")
            mo.setValue("任务", forKey: "title")
        }
        insert(false, nil, false)   // 可见
        insert(true, nil, false)    // deletedFlag
        insert(false, Date(), false) // deletedAt
        insert(false, nil, true)    // archived
        try context.save()

        let request = NSFetchRequest<NSManagedObject>(entityName: "G2TaskShell")
        request.predicate = adapter.basePredicate()
        let rows = try context.fetch(request)
        XCTAssertEqual(rows.count, 1, "basePredicate 与 fetch 求交后只剩可见行")
    }

    // MARK: - 习惯事件域谓词

    func test_习惯事件域basePredicate_软删排除_归档习惯历史照读() throws {
        let adapter = DiscoveryHabitAdapter(context: try makeShellContainer().1)
        Self.pinnedInstances.append(adapter)
        let predicate = adapter.basePredicate()

        XCTAssertTrue(predicate.evaluate(with: [:]), "未删记录可见（归档习惯的历史记录也是真实事件）")
        XCTAssertFalse(predicate.evaluate(with: ["deletedAt": Date()]), "软删记录必须排除")
    }

    // MARK: - 想法域谓词结构（AI 可见性求交断言）

    func test_想法域basePredicate_必含AI可见性子谓词与软删归档排除() throws {
        let adapter = DiscoveryThoughtAdapter(context: try makeShellContainer().1)
        Self.pinnedInstances.append(adapter)
        let predicate = adapter.basePredicate()

        // 结构断言：AND 复合，恰好两个子谓词
        guard let compound = predicate as? NSCompoundPredicate,
              compound.compoundPredicateType == .and,
              compound.subpredicates.count == 2 else {
            return XCTFail("想法域 basePredicate 必须是两个子谓词的 AND 复合")
        }
        let subpredicates = compound.subpredicates.compactMap { $0 as? NSPredicate }
        // 子谓词之一 = AI 可见性（与 DiscoveryAccessPolicy.thoughtDomainAIRestrictedPredicate 同一格式）
        let aiPredicateFormat = DiscoveryAccessPolicy.thoughtDomainAIRestrictedPredicate.predicateFormat
        XCTAssertTrue(
            subpredicates.contains { $0.predicateFormat == aiPredicateFormat },
            "必须与 thoughtDomainAIRestrictedPredicate 求交（用户关联标签 excludeFromAI 排除）"
        )
        // 另一子谓词 = 软删/归档排除；并对其做真实评估
        guard let availability = subpredicates.first(where: { $0.predicateFormat != aiPredicateFormat }) else {
            return XCTFail("缺少软删/归档排除子谓词")
        }
        XCTAssertTrue(availability.predicateFormat.contains("deletedAt"))
        XCTAssertTrue(availability.predicateFormat.contains("isSoftDeleted"))
        XCTAssertTrue(availability.predicateFormat.contains("isArchived"))
        XCTAssertTrue(availability.evaluate(with: ["isSoftDeleted": false, "isArchived": false]))
        XCTAssertFalse(availability.evaluate(with: ["deletedAt": Date(), "isSoftDeleted": false, "isArchived": false]))
        XCTAssertFalse(availability.evaluate(with: ["isSoftDeleted": true, "isArchived": false]))
        XCTAssertFalse(availability.evaluate(with: ["isSoftDeleted": false, "isArchived": true]))
    }

    // MARK: - sourceRevision 固定字段序（确定性）

    func test_想法域revisionFields_固定字段序与确定性() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_790_864_000)
        let fields = DiscoveryThoughtAdapter.revisionFields(
            id: id, content: "正文", createdAt: createdAt, updatedAt: updatedAt,
            tagNames: ["跑步", "读书"], topicIDs: ["t-2", "t-1"]
        )
        XCTAssertEqual(fields, [
            "discovery.thought.v1",
            id.uuidString,
            "正文",
            DiscoveryThoughtAdapter.timestamp(createdAt),
            DiscoveryThoughtAdapter.timestamp(updatedAt),
            "读书,跑步",       // 标签名/主题 id 内部规范化排序（同内容不同遍历序摘要必须稳定）
            "t-1,t-2",
        ])
        // 同输入同摘要；正文变化摘要变化
        let digestA = DiscoveryContentDigest.sourceRevision(from: fields)
        let digestB = DiscoveryContentDigest.sourceRevision(from: DiscoveryThoughtAdapter.revisionFields(
            id: id, content: "正文", createdAt: createdAt, updatedAt: updatedAt,
            tagNames: ["读书", "跑步"], topicIDs: ["t-2", "t-1"]
        ))
        XCTAssertEqual(digestA, digestB)
        let digestC = DiscoveryContentDigest.sourceRevision(from: DiscoveryThoughtAdapter.revisionFields(
            id: id, content: "正文改了", createdAt: createdAt, updatedAt: updatedAt,
            tagNames: ["读书", "跑步"], topicIDs: ["t-2", "t-1"]
        ))
        XCTAssertNotEqual(digestA, digestC, "正文变化必须改变 sourceRevision")
    }

    func test_任务域revisionFields_固定字段序_子任务与状态参与版本() {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        let completedAt = Date(timeIntervalSince1970: 1_790_100_000)
        let base = DiscoveryTaskAdapter.revisionFields(
            id: id, title: "整理作品集封面", desc: nil, status: "done",
            completedAt: completedAt, dueDate: nil, goalID: nil,
            checkItemsDigest: "挑图=1", createdAt: createdAt
        )
        XCTAssertEqual(base.first, "discovery.task.v1")
        XCTAssertEqual(base[2], "整理作品集封面")
        XCTAssertEqual(base[5], DiscoveryThoughtAdapter.timestamp(completedAt))

        let digestA = DiscoveryContentDigest.sourceRevision(from: base)
        let changed = DiscoveryContentDigest.sourceRevision(from: DiscoveryTaskAdapter.revisionFields(
            id: id, title: "整理作品集封面", desc: nil, status: "todo",
            completedAt: nil, dueDate: nil, goalID: nil,
            checkItemsDigest: "挑图=0", createdAt: createdAt
        ))
        XCTAssertNotEqual(digestA, changed, "完成态/子任务变化必须改变 sourceRevision")
    }

    func test_习惯事件revisionFields_固定字段序_定义字段参与版本() {
        let recordID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let habitID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let fields = DiscoveryHabitAdapter.revisionFields(
            recordID: recordID, habitID: habitID, date: date,
            isCompleted: true, value: 2.5, note: "备注", isRetroactive: false,
            createdAt: date, habitName: "跑步", habitType: 0, unit: nil, isBadHabit: false
        )
        XCTAssertEqual(fields.first, "discovery.habitEvent.v1")
        XCTAssertEqual(fields[5], "2.5")
        XCTAssertEqual(fields[9], "跑步")

        let digestA = DiscoveryContentDigest.sourceRevision(from: fields)
        // 定义改名（不改记录本身）也必须使版本失效：定义字段参与记录 sourceRevision
        let renamed = DiscoveryContentDigest.sourceRevision(from: DiscoveryHabitAdapter.revisionFields(
            recordID: recordID, habitID: habitID, date: date,
            isCompleted: true, value: 2.5, note: "备注", isRetroactive: false,
            createdAt: date, habitName: "夜跑", habitType: 0, unit: nil, isBadHabit: false
        ))
        XCTAssertNotEqual(digestA, renamed)
        // 补签标记参与版本
        let retroactive = DiscoveryContentDigest.sourceRevision(from: DiscoveryHabitAdapter.revisionFields(
            recordID: recordID, habitID: habitID, date: date,
            isCompleted: true, value: 2.5, note: "备注", isRetroactive: true,
            createdAt: date, habitName: "跑步", habitType: 0, unit: nil, isBadHabit: false
        ))
        XCTAssertNotEqual(digestA, retroactive)
    }

    func test_习惯事件构成文_补签与数值单位() {
        let text = DiscoveryHabitAdapter.text(
            habitName: "喝水", isCheckIn: false, isCompleted: false,
            value: 3, unit: "杯", note: "下午", isRetroactive: true
        )
        XCTAssertEqual(text, "习惯「喝水」；记录 3杯；备注：下午；补签（只知道日期）")

        let checkIn = DiscoveryHabitAdapter.text(
            habitName: "跑步", isCheckIn: true, isCompleted: true,
            value: nil, unit: nil, note: nil, isRetroactive: false
        )
        XCTAssertEqual(checkIn, "习惯「跑步」；打卡")

        XCTAssertEqual(DiscoveryHabitAdapter.numberText(3), "3")
        XCTAssertEqual(DiscoveryHabitAdapter.numberText(2.5), "2.5")
        XCTAssertEqual(DiscoveryHabitAdapter.numberText(0.25), "0.25")
    }
}
