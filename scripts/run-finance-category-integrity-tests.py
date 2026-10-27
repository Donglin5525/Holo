#!/usr/bin/env python3
"""仅用合成内存库验证分类父链与恢复归属，不打开真实 App 数据。"""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("category_regression", Path(__file__).with_name("run-finance-category-tests.py"))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)

TESTS = suite.TESTS.split('    @MainActor static func main() async throws {')[0] + r'''
    @MainActor static func denies(_ action: () throws -> Void, _ message: String) {
        do { try action(); fatalError(message) } catch { checks += 1 }
    }

    @MainActor static func main() async throws {
        let context = try makeContext()
        let dining = category(context, "餐饮", rank: 0)
        let shop = category(context, "购物", rank: 1)
        let systemRoot = category(context, "余额调整", rank: 2); systemRoot.isSystem = true
        let deletedRoot = category(context, "已删父", rank: 2); deletedRoot.deletedAt = Date()
        let income = category(context, "收入父", rank: 0, type: .income)
        let missingID = UUID()
        let orphan = category(context, "饮品", rank: 3, parent: missingID)
        let lunch = category(context, "午餐", rank: 4, parent: missingID)
        let recycled = category(context, "旧夜宵", rank: 5, parent: missingID); recycled.deletedAt = Date()
        let healthy = category(context, "饮品", rank: 6, parent: dining.id)
        let crossType = category(context, "跨类型", rank: 7, parent: income.id)
        let nested = category(context, "三级", rank: 8, parent: healthy.id)
        let underDeleted = category(context, "死父", rank: 9, parent: deletedRoot.id)
        let selfParent = category(context, "自引用", rank: 10); selfParent.parentId = selfParent.id
        let tx = Transaction(context: context); tx.id = UUID(); tx.category = orphan; tx.amount = 9.9; tx.note = "合成测试"
        let deletedTx = Transaction(context: context); deletedTx.id = UUID(); deletedTx.category = recycled; deletedTx.deletedAt = Date()
        try context.save()
        let all = try context.fetch(Category.fetchRequest())
        expect(!CategoryParentRepairService.targets(from: all, type: "expense").contains { $0.id == systemRoot.id }, "归属恢复不能选系统余额调整")
        let selectable = FinanceCategoryIntegrity.selectableCategories(in: all, type: "expense")
        expect(selectable.contains(healthy) && selectable.contains(dining), "完整父链可以选择")
        for invalid in [orphan, crossType, nested, underDeleted, selfParent, recycled, income] {
            expect(!selectable.contains(invalid), "孤儿、跨类型、三级、已删父和自引用不能选择")
        }
        let rootCache = [dining.id: dining, income.id: income, deletedRoot.id: deletedRoot]
        expect(FinanceCategoryIntegrity.topLevelCategory(for: healthy, roots: rootCache) == dining, "统计归入真实一级")
        for invalid in [orphan, crossType, nested, underDeleted, selfParent, recycled] {
            expect(FinanceCategoryIntegrity.topLevelCategory(for: invalid, roots: rootCache) == nil, "异常或软删分类不冒充一级")
        }
        try FinanceCategoryIntegrity.validateForBooking(healthy, in: context)
        checks += 1
        for invalid in [orphan, crossType, nested, underDeleted, selfParent, recycled, dining] {
            denies({ try FinanceCategoryIntegrity.validateForBooking(invalid, in: context) }, "无效父链不能入账")
        }
        let previews = try CategoryParentRepairService.previews(in: context, type: "expense")
        let preview = previews.first { $0.missingParentID == missingID }!
        expect(preview.activeCategoryCount == 2 && preview.items.count == 3, "同一旧父级包含活跃及回收站分类")
        expect(preview.activeTransactionCount == 1 && preview.deletedTransactionCount == 1, "预览分开计算有效和已删交易")
        let target = CategoryParentRepairTarget(id: dining.id, name: dining.name, type: dining.type)
        denies({ _ = try CategoryParentRepairService.apply(preview, to: .init(id: income.id, name: income.name, type: income.type), in: context) }, "拒绝跨类型目标")
        let oldTxID = tx.id; let oldCategoryID = orphan.id; let oldDeletedAt = recycled.deletedAt
        let updatedIDs = try CategoryParentRepairService.apply(preview, to: target, in: context)
        expect(updatedIDs.count == 3 && [orphan,lunch,recycled].allSatisfy { $0.parentId == dining.id }, "仅恢复同组父级")
        expect(tx.id == oldTxID && tx.category?.id == oldCategoryID && tx.amount == 9.9 && tx.note == "合成测试", "交易身份、分类身份与账目内容不变")
        expect(recycled.deletedAt == oldDeletedAt && deletedTx.deletedAt != nil, "回收站不被激活")
        expect(healthy.parentId == dining.id && healthy.id != orphan.id, "同名健康分类不合并")
        expect(!context.hasChanges, "修复成功已保存")
        denies({ _ = try CategoryParentRepairService.apply(preview, to: target, in: context) }, "旧预览不能重复执行")

        // 新增同组记录后旧预览必须失效。
        let nextMissing = UUID()
        let next = category(context, "待修复", rank: 0, parent: nextMissing)
        try context.save()
        let stale = try CategoryParentRepairService.previews(in: context, type: "expense").first { $0.missingParentID == nextMissing }!
        let lateTx = Transaction(context: context); lateTx.id = UUID(); lateTx.category = next
        try context.save()
        denies({ _ = try CategoryParentRepairService.apply(stale, to: target, in: context) }, "晚到交易必须重新确认影响")
        let fresh = try CategoryParentRepairService.previews(in: context, type: "expense").first { $0.missingParentID == nextMissing }!
        shop.name = "尚未保存"
        denies({ _ = try CategoryParentRepairService.apply(fresh, to: target, in: context) }, "脏 context 不连带保存其他编辑")
        shop.name = "购物"; try context.save()
        context.failNextSave = true
        denies({ _ = try CategoryParentRepairService.apply(fresh, to: target, in: context) }, "保存失败必须抛出")
        expect(next.parentId == nextMissing, "失败恢复原父级")
        try context.save()
        dining.name = "已更名"; try context.save()
        denies({ _ = try CategoryParentRepairService.apply(fresh, to: target, in: context) }, "目标更名后必须重新核对")
        dining.name = "餐饮"; try context.save()

        // 同 UUID 的冲突副本不能凭名字决定去向。
        let conflicting = category(context, "冲突名称", rank: 0, parent: nextMissing, id: next.id)
        try context.save()
        let conflictPreview = try CategoryParentRepairService.previews(in: context, type: "expense").first { $0.missingParentID == nextMissing }!
        denies({ _ = try CategoryParentRepairService.apply(conflictPreview, to: target, in: context) }, "拒绝同身份冲突副本")
        context.delete(conflicting); try context.save()

        // 独立工作 context 写回，不保存主 context 的其他编辑。
        let current = try CategoryParentRepairService.previews(in: context, type: "expense").first { $0.missingParentID == nextMissing }!
        shop.name = "其他模块编辑"
        let repository = FinanceRepository(context: context)
        try await repository.repairCategoryParent(current, target: target)
        let verifier = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        verifier.persistentStoreCoordinator = context.persistentStoreCoordinator
        let persistedShop = try verifier.fetch(Category.fetchRequest()).first { $0.id == shop.id }!
        expect(persistedShop.name == "购物" && shop.name == "其他模块编辑", "后台修复不能保存或撤销主 context 编辑")
        context.refresh(next, mergeChanges: true)
        expect(next.parentId == dining.id, "重新读取可看到修复")
        shop.name = "购物"; try context.save()

        let cache = FinanceCategoryNameCache(context: context)
        let revision = cache.revision
        orphan.parentId = shop.id; try context.save()
        try await Task.sleep(for: .milliseconds(50))
        expect(cache.revision > revision && cache.parentName(for: orphan) == "购物", "只改子分类父级也会通知账单刷新")
        expect(cache.parentName(for: crossType) == nil, "名称缓存不接受跨类型父级")
        let status = FinanceCategoryRowPresentation(note: nil, categoryName: "饮品", parentName: nil, requiresParentRepair: true)
        expect(status.requiresParentRepair && status.title == "饮品", "无备注孤儿也保留修复提示")
        print("PASS \(checks) checks：完整父链、修复预览、版本冲突、保存失败、回收站隔离与跨 context 写回")
    }
}
'''
suite.run_suite(TESTS, [suite.APP / "Models/NSManagedObject+Invalidation.swift",
                       suite.APP / "Services/Finance/FinanceCategoryIntegrity.swift",
                       suite.APP / "Services/Finance/CategoryParentRepairService.swift",
                       suite.APP / "Models/FinanceRepository+CategoryParentRepair.swift"])
