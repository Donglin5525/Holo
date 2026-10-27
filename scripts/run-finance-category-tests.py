#!/usr/bin/env python3
"""用临时内存 Core Data 验证生产排序和分类索引，不访问 App 或 CloudKit。"""
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
APP = REPO / "Holo/Holo APP/Holo/Holo"

SUPPORT = r'''
import Foundation
import CoreData
import SwiftUI

enum TransactionType: String { case expense, income }
extension Color {
    static var holoPrimary: Color { .orange }
    init(hex: String) { self = .orange }
}
@objc(Transaction)
public class Transaction: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var category: Category?
    @NSManaged public var deletedAt: Date?
    @NSManaged public var amount: Double
    @NSManaged public var note: String?
}
extension Category {
    @NSManaged var deletedAt: Date?
    static func fetchRequest() -> NSFetchRequest<Category> { NSFetchRequest(entityName: "Category") }
}
@MainActor
final class FinanceRepository {
    let context: NSManagedObjectContext
    init(context: NSManagedObjectContext) { self.context = context }
}
@MainActor
final class CoreDataStack {
    static var shared: CoreDataStack { fatalError("测试禁止访问 App 单例") }
    var viewContext: NSManagedObjectContext { fatalError("测试禁止访问 App 数据") }
}
enum DuplicateRowFilter {
    static func deduplicatingCopies(_ rows: [Category]) -> [Category] {
        var ids = Set<UUID>()
        return rows.filter { ids.insert($0.id).inserted }
    }
}
extension Notification.Name {
    static let financeDataDidChange = Notification.Name("financeDataDidChange")
}
final class CategoryTestContext: NSManagedObjectContext, @unchecked Sendable {
    var failNextSave = false
    override func save() throws {
        if failNextSave {
            failNextSave = false
            throw NSError(domain: "CategorySaveFailure", code: 1)
        }
        try super.save()
    }
}
'''

TESTS = r'''
import Foundation
import CoreData

@main
struct FinanceCategoryRegressionTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }

    @MainActor static func makeContext() throws -> CategoryTestContext {
        let model = NSManagedObjectModel()
        let category = NSEntityDescription()
        category.name = "Category"
        category.managedObjectClassName = NSStringFromClass(Category.self)
        func attribute(_ name: String, _ type: NSAttributeType, _ optional: Bool = false,
                       _ defaultValue: Any? = nil) -> NSAttributeDescription {
            let value = NSAttributeDescription()
            value.name = name; value.attributeType = type
            value.isOptional = optional; value.defaultValue = defaultValue
            return value
        }
        category.properties = [
            attribute("id", .UUIDAttributeType), attribute("name", .stringAttributeType),
            attribute("icon", .stringAttributeType), attribute("color", .stringAttributeType),
            attribute("type", .stringAttributeType), attribute("isDefault", .booleanAttributeType, false, false),
            attribute("sortOrder", .integer16AttributeType, false, 0),
            attribute("parentId", .UUIDAttributeType, true),
            attribute("isSystem", .booleanAttributeType, false, false),
            attribute("importBatchId", .UUIDAttributeType, true), attribute("deletedAt", .dateAttributeType, true)
        ]
        let transaction = NSEntityDescription()
        transaction.name = "Transaction"
        transaction.managedObjectClassName = NSStringFromClass(Transaction.self)
        transaction.properties = [attribute("id", .UUIDAttributeType),
            attribute("deletedAt", .dateAttributeType, true), attribute("amount", .doubleAttributeType, false, 0),
            attribute("note", .stringAttributeType, true)]
        let txCategory = NSRelationshipDescription()
        txCategory.name = "category"; txCategory.destinationEntity = category
        txCategory.minCount = 0; txCategory.maxCount = 1; txCategory.isOptional = true
        let transactions = NSRelationshipDescription()
        transactions.name = "transactions"; transactions.destinationEntity = transaction
        transactions.minCount = 0; transactions.maxCount = 0; transactions.isOptional = true
        txCategory.inverseRelationship = transactions; transactions.inverseRelationship = txCategory
        category.properties.append(transactions); transaction.properties.append(txCategory)
        model.entities = [category, transaction]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil,
                                           at: nil, options: nil)
        let context = CategoryTestContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    @MainActor static func category(_ context: NSManagedObjectContext, _ name: String,
                                    rank: Int16, type: TransactionType = .expense,
                                    parent: UUID? = nil, id: UUID = UUID()) -> Category {
        let value = Category(context: context)
        value.id = id; value.name = name; value.icon = "tag"; value.color = "#F46D38"
        value.type = type.rawValue; value.sortOrder = rank; value.parentId = parent
        return value
    }

    @MainActor static func reject(_ repository: FinanceRepository, ids: [UUID],
                                  type: TransactionType = .expense, parent: UUID? = nil) {
        do {
            try repository.reorderCategories(ids: ids, type: type, parentID: parent)
            fatalError("不完整或跨分组的排序必须拒绝")
        } catch FinanceCategoryOrderingError.categoriesChanged { checks += 1 }
        catch { fatalError("错误类型不符：\(error)") }
    }

    @MainActor static func main() async throws {
        let context = try makeContext()
        let repository = FinanceRepository(context: context)
        let a = category(context, "餐饮", rank: 20)
        let b = category(context, "交通", rank: 30)
        let c = category(context, "系统分类", rank: 999); c.isSystem = true
        let duplicateB = category(context, "交通", rank: 50, id: b.id)
        let income = category(context, "工资", rank: 40, type: .income)
        let deleted = category(context, "已删除", rank: 80); deleted.deletedAt = Date()
        let lunch = category(context, "午餐", rank: 10, parent: a.id)
        let dinner = category(context, "晚餐", rank: 20, parent: a.id)
        let taxi = category(context, "打车", rank: 30, parent: b.id)
        let tx = Transaction(context: context); tx.id = UUID(); tx.category = lunch
        income.sortOrder = -5
        expect(Category.precedesInUserOrder(a, income), "全量分类仍按收支类型分组")
        income.sortOrder = 40
        try context.save()

        try repository.reorderCategories(ids: [c.id, a.id, b.id], type: .expense, parentID: nil)
        expect(c.sortOrder == 0 && a.sortOrder == 1 && b.sortOrder == 2, "一级顺序应持久化")
        expect(duplicateB.sortOrder == 2, "同 ID 的同步副本必须一起改顺序")
        expect(income.sortOrder == 40, "支出排序不能影响收入")
        expect(deleted.sortOrder == 80, "排序不能影响回收站分类")
        expect(lunch.sortOrder == 10 && taxi.sortOrder == 30, "一级移动不改二级顺序")
        expect(lunch.parentId == a.id && tx.category == lunch, "历史记账及父子归属不能变化")
        expect(c.isSystem, "系统只读分类可以排序但不改属性")

        income.name = "未保存的名称"
        try repository.reorderCategories(ids: [c.id, a.id, b.id], type: .expense, parentID: nil)
        expect(income.hasChanges, "原位放回不应触发无意义保存")
        income.name = "工资"

        reject(repository, ids: [a.id, b.id])
        reject(repository, ids: [a.id, b.id, b.id])
        reject(repository, ids: [a.id, b.id, income.id])
        reject(repository, ids: [a.id, b.id, lunch.id])
        expect(a.sortOrder == 1 && b.sortOrder == 2, "无效排序不得部分修改")

        try repository.reorderCategories(ids: [dinner.id, lunch.id], type: .expense, parentID: a.id)
        expect(dinner.sortOrder == 0 && lunch.sortOrder == 1, "二级应按当前父级单独排序")
        expect(taxi.sortOrder == 30 && a.sortOrder == 1, "二级排序不影响其他父级及一级")
        reject(repository, ids: [lunch.id, taxi.id], parent: a.id)
        do {
            try repository.reorderCategories(ids: Array(repeating: a.id, count: 32769),
                                             type: .expense, parentID: nil)
            fatalError("超出排序字段范围必须拒绝")
        } catch FinanceCategoryOrderingError.tooManyCategories { checks += 1 }

        income.name = "其他模块尚未保存的名称"
        context.failNextSave = true
        do {
            try repository.reorderCategories(ids: [b.id, a.id, c.id], type: .expense, parentID: nil)
            fatalError("模拟保存失败必须抛出")
        } catch {
            expect(a.sortOrder == 1 && b.sortOrder == 2 && c.sortOrder == 0,
                   "保存失败只恢复排序")
            expect(duplicateB.sortOrder == 2, "失败时同步副本也应恢复")
            expect(income.name == "其他模块尚未保存的名称" && income.hasChanges,
                   "不能全局 rollback 吞掉其他编辑")
        }
        try context.save()
        let reopened = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reopened.persistentStoreCoordinator = context.persistentStoreCoordinator
        let reloaded = try reopened.fetch(Category.fetchRequest())
        expect(reloaded.first { $0.id == a.id }?.sortOrder == 1, "换上下文后顺序仍在")
        let tieA = category(context, "同序一", rank: 100,
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let tieB = category(context, "同序二", rank: 100,
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        expect(Category.precedesInUserOrder(tieA, tieB), "同权重需要稳定次序")
        try context.save()

        let cache = FinanceCategoryNameCache(context: context)
        expect(cache.names[a.id] == "餐饮", "索引应包含活跃父分类")
        expect(cache.names[lunch.id] == nil && cache.names[deleted.id] == nil,
               "索引不能把二级或回收站当父分类")
        a.name = "外出餐饮"; try context.save()
        try await Task.sleep(for: .milliseconds(30))
        expect(cache.names[a.id] == "外出餐饮", "编辑分类名称后索引刷新")
        a.deletedAt = Date(); try context.save()
        try await Task.sleep(for: .milliseconds(30))
        expect(cache.names[a.id] == nil, "父分类软删后不能保留旧路径")

        let named = FinanceCategoryRowPresentation(note: "楼下简餐", categoryName: "午餐", parentName: "餐饮")
        expect(named.title == "楼下简餐" && named.parentName == "餐饮" && named.categoryName == "午餐",
               "有名称时二级分类仍要展示")
        let unnamed = FinanceCategoryRowPresentation(note: nil, categoryName: "午餐", parentName: "餐饮")
        expect(unnamed.title == "午餐" && unnamed.parentName == "餐饮" && unnamed.categoryName == nil,
               "无名称时分类作为标题，不重复二级名称")
        let whitespace = FinanceCategoryRowPresentation(note: " \n ", categoryName: "午餐", parentName: "餐饮")
        expect(whitespace == unnamed, "空白名称不能挤掉分类标题")
        let missing = FinanceCategoryRowPresentation(note: "待整理", categoryName: nil, parentName: nil)
        expect(missing.title == "待整理" && missing.categoryName == String(localized: "未分类"),
               "没有分类时如实显示未分类")
        let root = FinanceCategoryRowPresentation(note: "旧记录", categoryName: "餐饮", parentName: nil)
        expect(root.categoryName == "餐饮" && root.parentName == nil, "旧一级分类不能伪造二级")
        let orphan = FinanceCategoryRowPresentation(note: "消费", categoryName: "午餐", parentName: nil)
        expect(orphan.categoryName == "午餐" && orphan.parentName == nil, "父分类未同步时保留真实二级")
        print("PASS \(checks) checks：分类排序、分组隔离、失败恢复、历史归属、名称缓存与展示规则")
    }
}
'''

def run_suite(test_source=TESTS, extra_sources=()):
    with tempfile.TemporaryDirectory(prefix="holo-finance-category-") as directory:
        work = Path(directory)
        support = work / "CategoryTestSupport.swift"
        tests = work / "CategoryRegressionTests.swift"
        support.write_text(SUPPORT)
        tests.write_text(test_source)
        binary = work / "category-tests"
        sources = [APP / "Models/Category.swift", APP / "Models/FinanceRepository+CategoryOrdering.swift",
                   APP / "Models/Finance/FinanceCategoryRowPresentation.swift",
                   APP / "Services/Finance/FinanceCategoryNameCache.swift", support, tests, *extra_sources]
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(work / "modules"),
                        *map(str, sources), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)

if __name__ == "__main__":
    run_suite()
