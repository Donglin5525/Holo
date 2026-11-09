//
//  CategoryGridReorderTests.swift
//  HoloTests
//
//  「记一笔」分类宫格长按拖拽排序（2026-11-09 空间优化）行为级测试：
//  · 持久化：拖动落位 → sortOrder 写库；丢弃内存对象后经独立上下文冷读顺序保持；
//    二级排序不波及其他父级；支出/收入互不干扰；宫格不显示的 isSystem 一级不阻断落库且恒尾；
//    新增分类恒排末位（「＋新增」格恒末位的数据面）
//  · 会话：长按原地松手=打开管理页不落库；拖动换位后松手=回调完整新序；
//    手势结束兜底（@GestureState 复位）与 onEnded 幂等只收尾一次；
//    会话活跃拦截格点击、松手后防误触窗口、陈旧后自愈放行
//  · 网格几何：位移 → 目标格 index（四舍五入 / 越界夹取）
//

import XCTest
import CoreData
@testable import Holo

// iOS 26 SDK 的某模块也导出 Category 名字，与 Holo.Category 冲突；显式指回被测类型
private typealias Category = Holo.Category

@MainActor
final class CategoryGridReorderTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!

    /// 网格几何：列宽 60 + 列距 8 = 横步长 68；格高 68 + 行距 14 = 纵步长 82
    private let columnWidth: CGFloat = 60
    private let cellHeight: CGFloat = 68
    private var stepX: CGFloat { columnWidth + CategoryGridReorderFeel.columnSpacing }
    private var stepY: CGFloat { cellHeight + CategoryGridReorderFeel.rowSpacing }

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
        repo = FinanceRepository(context: context)
    }

    override func tearDown() {
        try? CoreDataTestSupport.clearAllEntities(context)
        repo = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCategory(
        _ name: String,
        type: TransactionType = .expense,
        sortOrder: Int16,
        parentId: UUID? = nil,
        isSystem: Bool = false
    ) -> Category {
        Category.create(
            in: context,
            name: name,
            icon: "tag",
            color: "#13A4EC",
            type: type.rawValue,
            isDefault: true,
            sortOrder: sortOrder,
            parentId: parentId,
            isSystem: isSystem
        )
    }

    /// 宫格同款装配：会话序 + 同层全集 → 完整序 → reorderCategories（与 AddTransactionSheet.persistCategoryOrder 一致）
    private func persist(sessionIds: [UUID], type: TransactionType, parentID: UUID?) throws {
        let siblings = try context.fetch(Category.fetchRequest()).filter {
            $0.transactionType == type && $0.deletedAt == nil && $0.parentId == parentID
        }
        let fullIds = CategoryGridReorderModel.fullSiblingOrder(sessionIds: sessionIds, siblings: siblings)
        try repo.reorderCategories(ids: fullIds, type: type, parentID: parentID)
    }

    /// 宫格可见一级名序（与宫格 topLevelCategories 同口径：排除 isSystem）
    private func visibleTopLevelNames(_ type: TransactionType) async throws -> [String] {
        try await repo.getTopLevelCategories(by: type).filter { !$0.isSystem }.map(\.name)
    }

    /// 冷读：丢弃上下文全部内存对象后重新 fetch，值只能来自 store（模拟重启后的读取路径）
    private func coldNames(type: TransactionType, parentID: UUID?) throws -> [String] {
        context.reset()
        let request = Category.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "type == %@ AND deletedAt == nil AND isSystem == NO", type.rawValue),
            parentID.map { NSPredicate(format: "parentId == %@", $0 as CVarArg) }
                ?? NSPredicate(format: "parentId == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request).map(\.name)
    }

    /// 起一个排序会话并装好几何（effectiveOrder 记录 baseline，等价宫格渲染一次）
    private func makeSession(baseline: [UUID]) -> CategoryGridReorderModel {
        let model = CategoryGridReorderModel()
        Self.pinnedModels.append(model)
        _ = model.effectiveOrder(baseline: baseline)
        model.noteGridMetrics(columnWidth: columnWidth)
        model.noteCellHeight(cellHeight)
        return model
    }

    /// 模型钉住不释放：iOS 26.3 模拟器上 @MainActor 类在用例内局部释放会踩
    /// Swift 运行时 deinit-on-executor 的 malloc double-free（.ips 栈：
    /// swift_task_deinitOnExecutorMainActorBackDeploy → TaskLocal::StopLookupScope），
    /// 与产品逻辑无关（同 HabitReorderSessionSelfHealTests 坑位记录）
    nonisolated(unsafe) private static var pinnedModels: [CategoryGridReorderModel] = []

    // MARK: - 持久化：拖动落位写库

    func test拖动落位_会话新序写库后宫格按新序展示() async throws {
        let dining = makeCategory("餐饮", sortOrder: 0)
        let transport = makeCategory("交通", sortOrder: 1)
        let shopping = makeCategory("购物", sortOrder: 2)
        try context.save()

        let model = makeSession(baseline: [dining.id, transport.id, shopping.id])
        var committed: [UUID]?
        model.onCommit = { ids, _ in committed = ids }

        // 长按「餐饮」后向右拖两格 → 落到第 3 位
        model.beginPress(id: dining.id)
        model.dragMoved(translation: CGSize(width: stepX * 2, height: 0))
        model.dragEnded()

        let ids = try XCTUnwrap(committed, "拖动换位后松手必须回调落库")
        XCTAssertEqual(ids, [transport.id, shopping.id, dining.id])
        try persist(sessionIds: ids, type: .expense, parentID: nil)

        XCTAssertEqual(transport.sortOrder, 0)
        XCTAssertEqual(shopping.sortOrder, 1)
        XCTAssertEqual(dining.sortOrder, 2)
        let names = try await visibleTopLevelNames(.expense)
        XCTAssertEqual(names, ["交通", "购物", "餐饮"], "分类管理页读同一 sortOrder 口径，顺序同样生效")
    }

    func test冷读_丢弃内存对象后经独立上下文读取顺序保持() throws {
        let dining = makeCategory("餐饮", sortOrder: 0)
        let transport = makeCategory("交通", sortOrder: 1)
        let shopping = makeCategory("购物", sortOrder: 2)
        try context.save()

        try persist(sessionIds: [shopping.id, dining.id, transport.id], type: .expense, parentID: nil)

        XCTAssertEqual(try coldNames(type: .expense, parentID: nil), ["购物", "餐饮", "交通"],
                       "顺序必须真正写进 store，而不只是改了内存对象")
    }

    // MARK: - 持久化：作用域隔离

    func test二级排序_只动本父级不波及其他父级() throws {
        let dining = makeCategory("餐饮", sortOrder: 0)
        let transport = makeCategory("交通", sortOrder: 1)
        let breakfast = makeCategory("早餐", sortOrder: 0, parentId: dining.id)
        let lunch = makeCategory("午餐", sortOrder: 1, parentId: dining.id)
        let dinner = makeCategory("晚餐", sortOrder: 2, parentId: dining.id)
        makeCategory("地铁", sortOrder: 0, parentId: transport.id)
        makeCategory("打车", sortOrder: 1, parentId: transport.id)
        try context.save()
        // 冷读会 reset 上下文、使托管对象失效：id 先取出来
        let diningId = dining.id
        let transportId = transport.id

        // 下钻「餐饮」：把「晚餐」拖到首位
        let model = makeSession(baseline: [breakfast.id, lunch.id, dinner.id])
        var committed: [UUID]?
        model.onCommit = { ids, _ in committed = ids }
        model.beginPress(id: dinner.id)
        model.dragMoved(translation: CGSize(width: -stepX * 2, height: 0))
        model.dragEnded()
        try persist(sessionIds: try XCTUnwrap(committed), type: .expense, parentID: diningId)

        XCTAssertEqual(try coldNames(type: .expense, parentID: diningId), ["晚餐", "早餐", "午餐"])
        XCTAssertEqual(try coldNames(type: .expense, parentID: transportId), ["地铁", "打车"],
                       "其他父级的二级顺序不得被波及")
        XCTAssertEqual(try coldNames(type: .expense, parentID: nil), ["餐饮", "交通"],
                       "二级排序不得改动一级顺序")
    }

    func test支出收入_各自独立排序互不干扰() throws {
        let dining = makeCategory("餐饮", sortOrder: 0)
        let transport = makeCategory("交通", sortOrder: 1)
        let salary = makeCategory("工资", type: .income, sortOrder: 0)
        let bonus = makeCategory("奖金", type: .income, sortOrder: 1)
        try context.save()
        // 冷读会 reset 上下文、使托管对象失效：id 先取出来
        let (diningId, transportId, salaryId, bonusId) = (dining.id, transport.id, salary.id, bonus.id)

        try persist(sessionIds: [transportId, diningId], type: .expense, parentID: nil)
        XCTAssertEqual(try coldNames(type: .income, parentID: nil), ["工资", "奖金"],
                       "支出排序不得改动收入顺序")

        try persist(sessionIds: [bonusId, salaryId], type: .income, parentID: nil)
        XCTAssertEqual(try coldNames(type: .income, parentID: nil), ["奖金", "工资"])
        XCTAssertEqual(try coldNames(type: .expense, parentID: nil), ["交通", "餐饮"],
                       "收入排序不得改动支出顺序")
    }

    func test隐藏系统一级_宫格可见序落库成功且系统行恒尾() throws {
        let dining = makeCategory("餐饮", sortOrder: 0)
        let transport = makeCategory("交通", sortOrder: 1)
        // 「余额调整」：isSystem 一级，宫格不显示（topLevelCategories 过滤 isSystem）
        let adjustment = makeCategory("余额调整", sortOrder: 999, isSystem: true)
        try context.save()

        // 陷阱实证：只传宫格可见格会被全量校验判「分类已变化」拒绝
        XCTAssertThrowsError(
            try repo.reorderCategories(ids: [transport.id, dining.id], type: .expense, parentID: nil)
        )

        try persist(sessionIds: [transport.id, dining.id], type: .expense, parentID: nil)
        XCTAssertEqual(transport.sortOrder, 0)
        XCTAssertEqual(dining.sortOrder, 1)
        XCTAssertEqual(adjustment.sortOrder, 2, "隐藏的系统一级追加在可见格之后")
    }

    func test新增分类_排序后仍恒排末位() async throws {
        let dining = makeCategory("餐饮", sortOrder: 0)
        let transport = makeCategory("交通", sortOrder: 1)
        let shopping = makeCategory("购物", sortOrder: 2)
        makeCategory("余额调整", sortOrder: 999, isSystem: true)
        try context.save()

        try persist(sessionIds: [shopping.id, dining.id, transport.id], type: .expense, parentID: nil)
        try await repo.addCategory(name: "宠物", icon: "pawprint", color: "#F97316", type: .expense)

        let names = try await visibleTopLevelNames(.expense)
        XCTAssertEqual(names, ["购物", "餐饮", "交通", "宠物"], "新增分类排在已排好序的末位（「＋新增」格之前）")
    }

    // MARK: - 会话：长按松手 / 拖动落位

    func test长按原地松手_打开分类管理且不落库() {
        let a = UUID(), b = UUID(), c = UUID()
        let model = makeSession(baseline: [a, b, c])
        var opened = 0
        var committed = 0
        model.onOpenManagement = { opened += 1 }
        model.onCommit = { _, _ in committed += 1 }

        model.beginPress(id: b)
        // 手指微颤（未过拖动阈值）不算拖动
        model.dragMoved(translation: CGSize(width: 3, height: -2))
        model.dragEnded()

        XCTAssertEqual(opened, 1)
        XCTAssertEqual(committed, 0)
        XCTAssertNil(model.draggingId)
        XCTAssertNil(model.order)
    }

    func test拖动但未换位_松手既不落库也不开管理页() {
        let a = UUID(), b = UUID(), c = UUID()
        let model = makeSession(baseline: [a, b, c])
        var opened = 0
        var committed = 0
        model.onOpenManagement = { opened += 1 }
        model.onCommit = { _, _ in committed += 1 }

        model.beginPress(id: a)
        model.dragMoved(translation: CGSize(width: stepX * 0.3, height: 0)) // 过阈值但不到半格
        model.dragEnded()

        XCTAssertEqual(opened, 0)
        XCTAssertEqual(committed, 0)
    }

    func test跨行拖动_二维换位到目标格() {
        let ids = (0..<10).map { _ in UUID() }
        let model = makeSession(baseline: ids)
        var committed: [UUID]?
        model.onCommit = { order, _ in committed = order }

        // 第 1 格（行 0 列 0）拖到行 1 列 2 → index 7
        model.beginPress(id: ids[0])
        model.dragMoved(translation: CGSize(width: stepX * 2, height: stepY))
        XCTAssertEqual(model.order?.firstIndex(of: ids[0]), 7, "拖拽中其余格即时让位")
        model.dragEnded()

        var expected = ids
        expected.remove(at: 0)
        expected.insert(ids[0], at: 7)
        XCTAssertEqual(committed, expected)
    }

    func test换位后视觉偏移_扣除锚点不跳变() {
        let ids = (0..<5).map { _ in UUID() }
        let model = makeSession(baseline: ids)

        model.beginPress(id: ids[0])
        model.dragMoved(translation: CGSize(width: stepX * 1.2, height: 0))

        XCTAssertEqual(model.order?.firstIndex(of: ids[0]), 1)
        XCTAssertEqual(model.dragTranslation.width, stepX * 0.2, accuracy: 0.001,
                       "换位后被拖格挂在新格位上，视觉偏移只剩手指超出新格位的部分")
    }

    // MARK: - 会话：收尾兜底与防误触

    func test手势收尾兜底_与onEnded先后到达都只收尾一次() {
        let a = UUID(), b = UUID()

        // 正常路径：onEnded 先到，@GestureState 复位后到
        let model = makeSession(baseline: [a, b])
        var commits = 0
        model.onCommit = { _, _ in commits += 1 }
        model.beginPress(id: a)
        model.dragMoved(translation: CGSize(width: stepX, height: 0))
        model.dragEnded()
        model.gestureDidFinish(id: a)
        XCTAssertEqual(commits, 1)

        // onEnded 丢失路径：只有 @GestureState 复位信号，仍能完成落位
        let lossy = makeSession(baseline: [a, b])
        var lossyCommits = 0
        lossy.onCommit = { _, _ in lossyCommits += 1 }
        lossy.beginPress(id: a)
        lossy.dragMoved(translation: CGSize(width: stepX, height: 0))
        lossy.gestureDidFinish(id: a)
        lossy.dragEnded()
        XCTAssertEqual(lossyCommits, 1)
        XCTAssertNil(lossy.draggingId)
    }

    func test会话活跃拦截格点击_陈旧后点击自愈放行() {
        let a = UUID(), b = UUID()
        let model = makeSession(baseline: [a, b])

        model.beginPress(id: a)
        XCTAssertFalse(model.admitInteraction(), "手指仍在屏上：拒绝格点击，防拖拽误触")

        // onEnded 与 @GestureState 复位都丢失：超过陈旧窗口后，下一次点击就地清场并放行
        model.test_backdateGestureActivity(by: CategoryGridReorderFeel.sessionStaleWindow + 1)
        XCTAssertTrue(model.admitInteraction())
        XCTAssertNil(model.draggingId)
    }

    func test长按松手后防误触窗口_短暂拦截格点击后恢复() {
        let a = UUID()
        let model = makeSession(baseline: [a])
        model.onOpenManagement = {}

        model.beginPress(id: a)
        model.dragEnded()
        XCTAssertFalse(model.admitInteraction(), "松手同一帧的格点击（长按松手误触）必须被拦下")

        let recovered = expectation(description: "防误触窗口结束")
        DispatchQueue.main.asyncAfter(deadline: .now() + CategoryGridReorderFeel.interactionLockWindow + 0.15) {
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 2)
        XCTAssertTrue(model.admitInteraction(), "窗口过后普通点击（选中/下钻）恢复")
    }

    func test切换Tab取消会话_不落库不开管理页() {
        let a = UUID(), b = UUID()
        let model = makeSession(baseline: [a, b])
        var opened = 0
        var commits = 0
        model.onOpenManagement = { opened += 1 }
        model.onCommit = { _, _ in commits += 1 }

        model.beginPress(id: a)
        model.dragMoved(translation: CGSize(width: stepX, height: 0))
        model.cancelDrag()
        model.dragEnded() // 迟到的 onEnded 不得复活已取消的会话

        XCTAssertEqual(opened, 0)
        XCTAssertEqual(commits, 0)
        XCTAssertNil(model.order)
    }

    // MARK: - 网格几何

    func test目标格_四舍五入到最近格位() {
        let step = CGSize(width: stepX, height: stepY)
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 0, offset: CGSize(width: stepX * 0.49, height: 0), step: step, count: 10), 0)
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 0, offset: CGSize(width: stepX * 0.51, height: 0), step: step, count: 10), 1)
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 2, offset: CGSize(width: 0, height: stepY * 1.4), step: step, count: 10), 7)
    }

    func test目标格_越界夹取到网格内() {
        let step = CGSize(width: stepX, height: stepY)
        // 向右越过末列：夹到本行末列
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 3, offset: CGSize(width: stepX * 5, height: 0), step: step, count: 10), 4)
        // 向下越过末行：夹到最后一格
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 0, offset: CGSize(width: 0, height: stepY * 5), step: step, count: 10), 9)
        // 向左上越界：夹到首格
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 6, offset: CGSize(width: -stepX * 3, height: -stepY * 2), step: step, count: 10), 0)
        // 末行不满：拖到末行空位夹到最后一格（「＋新增」格不在会话序内，不可被占）
        XCTAssertEqual(CategoryGridReorderModel.targetIndex(fromIndex: 0, offset: CGSize(width: stepX * 4, height: stepY), step: step, count: 7), 6)
    }
}
