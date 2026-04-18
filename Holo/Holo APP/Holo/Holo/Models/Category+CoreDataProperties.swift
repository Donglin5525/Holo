//
//  Category+CoreDataProperties.swift
//  Holo
//
//  分类扩展 - 静态方法和预设层级数据
//  支持一级分类（parentId = nil）和二级子分类（parentId 指向父分类）
//

import Foundation
import CoreData

extension Category {
    
    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Category> {
        return NSFetchRequest<Category>(entityName: "Category")
    }
    
    // MARK: - Factory Methods
    
    /**
     创建新的分类实体
     - Parameters:
       - context: Core Data 上下文
       - name: 分类名称
       - icon: 图标资源名（Asset Catalog 中的 imageset 名称）
       - color: 十六进制颜色字符串
       - type: 交易类型（expense / income）
       - isDefault: 是否为系统预设分类
       - sortOrder: 排序权重，值越小越靠前
       - parentId: 父分类 ID，nil 表示一级分类
     - Returns: 创建好的 Category 实例
     */
    static func create(
        in context: NSManagedObjectContext,
        name: String,
        icon: String,
        color: String,
        type: String,
        isDefault: Bool = false,
        sortOrder: Int16 = 0,
        parentId: UUID? = nil,
        isSystem: Bool = false
    ) -> Category {
        let category = Category(context: context)
        category.id = UUID()
        category.name = name
        category.icon = icon
        category.color = color
        category.type = type
        category.isDefault = isDefault
        category.sortOrder = sortOrder
        category.parentId = parentId
        category.isSystem = isSystem

        return category
    }
    
    // MARK: - 层级分类数据结构
    
    /// 二级子分类定义
    typealias SubCategoryDef = (name: String, icon: String)
    
    /// 一级分类定义（包含子分类列表）
    typealias CategoryGroupDef = (
        name: String,
        color: String,
        children: [SubCategoryDef]
    )
    
    // MARK: - 支出分类层级（9 个一级 + 69 个二级）

    /// 支出分类体系
    /// 按 Figma 设计稿的图标分组排列，每组颜色与设计一致
    static let expenseHierarchy: [CategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 餐饮（蓝色系 #13A4EC）━━━━━━━━━━
        (name: "餐饮", color: "#13A4EC", children: [
            (name: "早餐", icon: "sunrise.fill"),
            (name: "午餐", icon: "sun.max.fill"),
            (name: "晚餐", icon: "moon.stars.fill"),
            (name: "夜宵", icon: "moonphase.waning.crescent"),
            (name: "零食", icon: "popcorn.fill"),
            (name: "咖啡", icon: "cup.and.saucer.fill"),
            (name: "外卖", icon: "bag.fill"),
            (name: "饮品", icon: "wineglass.fill"),
            (name: "水果", icon: "carrot.fill"),
            (name: "酒水", icon: "wineglass"),
            (name: "超市", icon: "cart.fill"),
        ]),
        // ━━━━━━━━━━ 2. 交通（绿色系 #10B981）━━━━━━━━━━
        (name: "交通", color: "#10B981", children: [
            (name: "地铁", icon: "train.side.front.car"),
            (name: "打车", icon: "car.side.fill"),
            (name: "公交", icon: "bus.fill"),
            (name: "单车", icon: "bicycle"),
            (name: "加油", icon: "fuelpump.fill"),
            (name: "停车", icon: "parkingsign.circle.fill"),
            (name: "火车", icon: "train.side.rear.car"),
            (name: "机票", icon: "airplane.departure"),
            (name: "旅行", icon: "figure.walk"),
            (name: "过路费", icon: "building.columns.fill"),
        ]),
        // ━━━━━━━━━━ 3. 购物（橙色系 #F97316）━━━━━━━━━━
        (name: "购物", color: "#F97316", children: [
            (name: "服饰", icon: "hanger"),
            (name: "数码", icon: "desktopcomputer"),
            (name: "日用", icon: "basket.fill"),
            (name: "美妆", icon: "sparkles"),
            (name: "家具", icon: "sofa.fill"),
            (name: "书籍", icon: "book.fill"),
            (name: "运动", icon: "sportscourt.fill"),
            (name: "礼物", icon: "gift.fill"),
        ]),
        // ━━━━━━━━━━ 4. 娱乐（粉色系 #EC4899）━━━━━━━━━━
        (name: "娱乐", color: "#EC4899", children: [
            (name: "电影", icon: "film.fill"),
            (name: "游戏", icon: "gamecontroller.fill"),
            (name: "视频", icon: "play.tv.fill"),
            (name: "音乐", icon: "music.note.list"),
            (name: "KTV", icon: "mic.fill"),
            (name: "旅游", icon: "airplane"),
            (name: "健身", icon: "figure.run"),
        ]),
        // ━━━━━━━━━━ 5. 居住（靛蓝色系 #6366F1）━━━━━━━━━━
        (name: "居住", color: "#6366F1", children: [
            (name: "房租", icon: "key.fill"),
            (name: "房贷", icon: "banknote.fill"),
            (name: "水费", icon: "drop.fill"),
            (name: "电费", icon: "bolt.fill"),
            (name: "燃气", icon: "flame.fill"),
            (name: "物业", icon: "building.2.fill"),
            (name: "网费", icon: "wifi"),
            (name: "家电", icon: "tv.fill"),
            (name: "装修", icon: "paintbrush.fill"),
        ]),
        // ━━━━━━━━━━ 6. 医疗（玫红色系 #F43F5E）━━━━━━━━━━
        (name: "医疗", color: "#F43F5E", children: [
            (name: "就医", icon: "stethoscope"),
            (name: "药品", icon: "pill.fill"),
            (name: "体检", icon: "heart.text.square.fill"),
            (name: "健身房", icon: "dumbbell.fill"),
            (name: "保健品", icon: "leaf.fill"),
            (name: "牙齿保健", icon: "heart.circle.fill"),
            (name: "医疗用品", icon: "cross.case.fill"),
        ]),
        // ━━━━━━━━━━ 7. 学习（青色系 #06B6D4）━━━━━━━━━━
        (name: "学习", color: "#06B6D4", children: [
            (name: "课程", icon: "book.closed.fill"),
            (name: "教材", icon: "text.book.closed.fill"),
            (name: "考试", icon: "checkmark.rectangle.fill"),
            (name: "文具", icon: "pencil.line"),
            (name: "订阅", icon: "arrow.trianglehead.clockwise"),
        ]),
        // ━━━━━━━━━━ 8. 人情（琥珀色系 #F59E0B）━━━━━━━━━━
        (name: "人情", color: "#F59E0B", children: [
            (name: "红包礼金", icon: "yensign.circle.fill"),
            (name: "请客", icon: "wineglass.fill"),
            (name: "送礼", icon: "gift.fill"),
            (name: "探望", icon: "figure.walk.arrival"),
            (name: "其他", icon: "ellipsis.circle.fill"),
        ]),
        // ━━━━━━━━━━ 9. 其他（灰色系 #64748B）━━━━━━━━━━
        (name: "其他", color: "#64748B", children: [
            (name: "社交", icon: "person.2.fill"),
            (name: "宠物", icon: "pawprint.fill"),
            (name: "理发", icon: "scissors"),
            (name: "洗衣", icon: "washer.fill"),
            (name: "话费", icon: "phone.fill"),
            (name: "烟酒", icon: "smoke.fill"),
            (name: "维修", icon: "wrench.fill"),
            (name: "保险", icon: "shield.checkered"),
            (name: "还款", icon: "arrow.uturn.backward.circle.fill"),
            (name: "转账", icon: "arrow.right.circle.fill"),
            (name: "捐赠", icon: "heart.fill"),
            (name: "其他", icon: "questionmark.folder.fill"),
        ]),
    ]
    
    // MARK: - 收入分类层级（4 个一级 + 19 个二级）

    /// 收入分类体系
    static let incomeHierarchy: [CategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 投资理财（蓝色系 #3B82F6）━━━━━━━━━━
        (name: "投资理财", color: "#3B82F6", children: [
            (name: "利息", icon: "percent"),
            (name: "股票", icon: "chart.line.uptrend.xyaxis"),
            (name: "房租收入", icon: "building.columns.fill"),
            (name: "其他投资", icon: "chart.pie.fill"),
        ]),
        // ━━━━━━━━━━ 2. 工资收入（绿色系 #22C55E）━━━━━━━━━━
        (name: "工资收入", color: "#22C55E", children: [
            (name: "工资", icon: "banknote.fill"),
            (name: "奖金", icon: "star.fill"),
            (name: "兼职", icon: "briefcase.fill"),
            (name: "报销", icon: "arrow.uturn.backward.circle.fill"),
            (name: "退款", icon: "arrow.counterclockwise.circle.fill"),
        ]),
        // ━━━━━━━━━━ 3. 人情来往（红色系 #EF4444）━━━━━━━━━━
        (name: "人情来往", color: "#EF4444", children: [
            (name: "红包", icon: "yensign.circle.fill"),
            (name: "礼物", icon: "gift.fill"),
            (name: "中奖", icon: "trophy.fill"),
            (name: "转入", icon: "arrow.left.circle.fill"),
        ]),
        // ━━━━━━━━━━ 4. 其他收入（紫色系 #A855F7）━━━━━━━━━━
        (name: "其他收入", color: "#A855F7", children: [
            (name: "借入", icon: "arrow.down.circle.fill"),
            (name: "还款收入", icon: "arrow.uturn.forward.circle.fill"),
            (name: "退货", icon: "shippingbox.fill"),
            (name: "公积金", icon: "building.columns.fill"),
            (name: "出闲置", icon: "arrow.3.trianglepath"),
            (name: "其他", icon: "questionmark.folder.fill"),
        ]),
    ]
    
    // MARK: - 旧图标 → SF Symbol 映射（一次性迁移用）

    /// 旧 icon_ 前缀图标名 → SF Symbol 名称
    /// 覆盖全部 97 个自定义 SVG 图标 + 11 个父类别图标
    static let legacyIconMapping: [String: String] = [
        // ━━━ 餐饮 ━━━
        "icon_breakfast": "sunrise.fill",
        "icon_lunch": "sun.max.fill",
        "icon_dinner": "moon.stars.fill",
        "icon_late_snack": "moonphase.waning.crescent",
        "icon_snack": "popcorn.fill",
        "icon_coffee": "cup.and.saucer.fill",
        "icon_takeout": "bag.fill",
        "icon_beverage": "wineglass.fill",
        "icon_fruit": "carrot.fill",
        "icon_alcohol": "wineglass",
        "icon_supermarket": "cart.fill",
        // ━━━ 交通 ━━━
        "icon_metro": "train.side.front.car",
        "icon_taxi": "car.side.fill",
        "icon_bus": "bus.fill",
        "icon_bike_share": "bicycle",
        "icon_fuel": "fuelpump.fill",
        "icon_parking": "parkingsign.circle.fill",
        "icon_train": "train.side.rear.car",
        "icon_flight": "airplane.departure",
        "icon_travel": "figure.walk",
        "icon_toll": "building.columns.fill",
        // ━━━ 购物 ━━━
        "icon_clothes": "hanger",
        "icon_digital": "desktopcomputer",
        "icon_groceries": "basket.fill",
        "icon_beauty": "sparkles",
        "icon_furniture": "sofa.fill",
        "icon_book": "book.fill",
        "icon_sport": "sportscourt.fill",
        "icon_present": "gift.fill",
        // ━━━ 娱乐 ━━━
        "icon_cinema": "film.fill",
        "icon_gaming": "gamecontroller.fill",
        "icon_video": "play.tv.fill",
        "icon_music": "music.note.list",
        "icon_ktv": "mic.fill",
        "icon_trip": "airplane",
        "icon_fitness": "figure.run",
        // ━━━ 居住 ━━━
        "icon_rent": "key.fill",
        "icon_mortgage": "banknote.fill",
        "icon_water": "drop.fill",
        "icon_electricity": "bolt.fill",
        "icon_gas": "flame.fill",
        "icon_property": "building.2.fill",
        "icon_internet": "wifi",
        "icon_appliance": "tv.fill",
        "icon_renovation": "paintbrush.fill",
        // ━━━ 医疗 ━━━
        "icon_medical": "stethoscope",
        "icon_medicine": "pill.fill",
        "icon_checkup": "heart.text.square.fill",
        "icon_gym": "dumbbell.fill",
        "icon_supplement": "leaf.fill",
        "icon_dental": "heart.circle.fill",
        "icon_medical_supply": "cross.case.fill",
        // ━━━ 学习 ━━━
        "icon_course": "book.closed.fill",
        "icon_textbook": "text.book.closed.fill",
        "icon_exam": "checkmark.rectangle.fill",
        "icon_stationery": "pencil.line",
        "icon_subscription": "arrow.trianglehead.clockwise",
        // ━━━ 人情（支出）━━━
        "icon_cash_gift": "yensign.circle.fill",
        "icon_treat": "wineglass.fill",
        "icon_gifting": "gift.fill",
        "icon_visit": "figure.walk.arrival",
        "icon_social_other": "ellipsis.circle.fill",
        // ━━━ 其他支出 ━━━
        "icon_social": "person.2.fill",
        "icon_pet": "pawprint.fill",
        "icon_barber": "scissors",
        "icon_laundry": "washer.fill",
        "icon_phone_bill": "phone.fill",
        "icon_tobacco_alcohol": "smoke.fill",
        "icon_repair": "wrench.fill",
        "icon_insurance": "shield.checkered",
        "icon_repayment": "arrow.uturn.backward.circle.fill",
        "icon_transfer_out": "arrow.right.circle.fill",
        "icon_donation": "heart.fill",
        "icon_other_exp": "questionmark.folder.fill",
        // ━━━ 投资理财（收入）━━━
        "icon_interest": "percent",
        "icon_stock": "chart.line.uptrend.xyaxis",
        "icon_rent_income": "building.columns.fill",
        "icon_invest_other": "chart.pie.fill",
        // ━━━ 工资收入 ━━━
        "icon_salary": "banknote.fill",
        "icon_bonus": "star.fill",
        "icon_parttime": "briefcase.fill",
        "icon_reimburse": "arrow.uturn.backward.circle.fill",
        "icon_refund": "arrow.counterclockwise.circle.fill",
        // ━━━ 人情来往（收入）━━━
        "icon_red_packet": "yensign.circle.fill",
        "icon_gift": "gift.fill",
        "icon_winning": "trophy.fill",
        "icon_transfer_in": "arrow.left.circle.fill",
        // ━━━ 其他收入 ━━━
        "icon_loan_in": "arrow.down.circle.fill",
        "icon_repay_in": "arrow.uturn.forward.circle.fill",
        "icon_return": "shippingbox.fill",
        "icon_housing_fund": "building.columns.fill",
        "icon_secondhand": "arrow.3.trianglepath",
        "icon_other_inc": "questionmark.folder.fill",
        // ━━━ 父类别/选择器额外图标 ━━━
        "icon_dining": "fork.knife",
        "icon_transport": "car.fill",
        "icon_shopping": "bag.fill",
        "icon_entertainment": "music.note.list",
        "icon_housing": "house.fill",
        "icon_health": "heart.text.square.fill",
        "icon_education": "book.closed.fill",
        "icon_investment": "chart.line.uptrend.xyaxis",
        "icon_other_income": "plus.circle.fill",
        "icon_other_expense": "questionmark.folder.fill",
        "icon_communication": "phone.fill",
    ]

    // MARK: - 父类别图标映射

    /// 一级分类名称 → SF Symbol（用于种子数据和迁移）
    static let parentIconMapping: [String: String] = [
        "餐饮": "fork.knife",
        "交通": "car.fill",
        "购物": "bag.fill",
        "娱乐": "music.note.list",
        "居住": "house.fill",
        "医疗": "heart.text.square.fill",
        "学习": "book.closed.fill",
        "人情": "yensign.circle.fill",
        "其他": "questionmark.folder.fill",
        "投资理财": "chart.line.uptrend.xyaxis",
        "工资收入": "banknote.fill",
        "人情来往": "gift.fill",
        "其他收入": "plus.circle.fill",
    ]

    // MARK: - Seed 初始化

    /**
     初始化默认分类数据（首次启动时调用）

     处理逻辑：
     1. 若无任何分类，创建完整层级
     2. 若已有层级分类（存在 parentId != nil），检查是否缺失分类，补充添加
     3. 先创建一级分类（parentId = nil），再创建二级子分类（parentId 指向父级 id）

     兼容旧数据：设备上已有 15 个扁平分类时，会补种 12+71 个层级分类，不删除旧数据
     */
    static func seedDefaultCategories(in context: NSManagedObjectContext) {
        let request = Category.fetchRequest()
        request.includesSubentities = false
        guard let all = try? context.fetch(request) else { return }

        // 若已有二级分类，检查是否缺失分类并补充
        let hasSubCategory = all.contains { $0.parentId != nil }
        if hasSubCategory {
            seedMissingCategories(in: context, existing: all)
            return
        }

        // 无分类或仅有旧版扁平分类：补种完整层级（不删旧数据，旧交易仍指向旧分类）
        // --- 创建支出分类层级 ---
        seedHierarchy(
            expenseHierarchy,
            type: TransactionType.expense.rawValue,
            in: context
        )

        // --- 创建收入分类层级 ---
        seedHierarchy(
            incomeHierarchy,
            type: TransactionType.income.rawValue,
            in: context
        )

        try? context.save()

        // 迁移旧 icon_ 图标到 SF Symbol
        migrateLegacyIcons(in: context)

        // 确保系统分类存在
        seedSystemCategories(in: context)
    }

    // MARK: - 系统分类

    /// 系统内置分类（不可删除/编辑）
    static let systemCategories: [(name: String, icon: String, color: String, type: String)] = [
        ("余额调整", "arrow.triangle.2.circlepath", "#94A3B8", "expense")
    ]

    /// 确保系统分类存在
    private static func seedSystemCategories(in context: NSManagedObjectContext) {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "isSystem == true")
        let existingNames = Set((try? context.fetch(request))?.map { $0.name } ?? [])

        for systemCat in systemCategories {
            if !existingNames.contains(systemCat.name) {
                _ = create(
                    in: context,
                    name: systemCat.name,
                    icon: systemCat.icon,
                    color: systemCat.color,
                    type: systemCat.type,
                    isDefault: true,
                    sortOrder: 999,
                    isSystem: true
                )
            }
        }

        try? context.save()
    }

    /**
     检查并补充缺失的分类
     - Parameters:
       - context: Core Data 上下文
       - existing: 已有的分类列表
     */
    private static func seedMissingCategories(
        in context: NSManagedObjectContext,
        existing: [Category]
    ) {
        // 构建现有分类的名称集合（按类型分组）
        let existingExpenseNames = Set(
            existing.filter { $0.type == TransactionType.expense.rawValue }
                .map { $0.name }
        )
        let existingIncomeNames = Set(
            existing.filter { $0.type == TransactionType.income.rawValue }
                .map { $0.name }
        )

        var hasChanges = false

        // 检查并补充支出分类
        for group in expenseHierarchy {
            // 检查一级分类是否存在
            if !existingExpenseNames.contains(group.name) {
                let parentIcon = parentIconMapping[group.name] ?? group.children.first?.icon ?? "questionmark.circle"
                let parent = create(
                    in: context,
                    name: group.name,
                    icon: parentIcon,
                    color: group.color,
                    type: TransactionType.expense.rawValue,
                    isDefault: true,
                    sortOrder: Int16(existing.filter { $0.type == TransactionType.expense.rawValue && $0.parentId == nil }.count),
                    parentId: nil
                )
                hasChanges = true

                // 创建子分类
                for (idx, child) in group.children.enumerated() {
                    _ = create(
                        in: context,
                        name: child.name,
                        icon: child.icon,
                        color: group.color,
                        type: TransactionType.expense.rawValue,
                        isDefault: true,
                        sortOrder: Int16(idx),
                        parentId: parent.id
                    )
                }
            } else {
                // 一级分类存在，检查子分类是否缺失
                let parent = existing.first { $0.name == group.name && $0.parentId == nil }
                if let parent = parent {
                    let existingChildNames = Set(
                        existing.filter { $0.parentId == parent.id }
                            .map { $0.name }
                    )
                    for (idx, child) in group.children.enumerated() {
                        if !existingChildNames.contains(child.name) {
                            _ = create(
                                in: context,
                                name: child.name,
                                icon: child.icon,
                                color: group.color,
                                type: TransactionType.expense.rawValue,
                                isDefault: true,
                                sortOrder: Int16(idx),
                                parentId: parent.id
                            )
                            hasChanges = true
                        }
                    }
                }
            }
        }

        // 检查并补充收入分类
        for group in incomeHierarchy {
            if !existingIncomeNames.contains(group.name) {
                let parentIcon = parentIconMapping[group.name] ?? group.children.first?.icon ?? "questionmark.circle"
                let parent = create(
                    in: context,
                    name: group.name,
                    icon: parentIcon,
                    color: group.color,
                    type: TransactionType.income.rawValue,
                    isDefault: true,
                    sortOrder: Int16(existing.filter { $0.type == TransactionType.income.rawValue && $0.parentId == nil }.count),
                    parentId: nil
                )
                hasChanges = true

                for (idx, child) in group.children.enumerated() {
                    _ = create(
                        in: context,
                        name: child.name,
                        icon: child.icon,
                        color: group.color,
                        type: TransactionType.income.rawValue,
                        isDefault: true,
                        sortOrder: Int16(idx),
                        parentId: parent.id
                    )
                }
            } else {
                let parent = existing.first { $0.name == group.name && $0.parentId == nil }
                if let parent = parent {
                    let existingChildNames = Set(
                        existing.filter { $0.parentId == parent.id }
                            .map { $0.name }
                    )
                    for (idx, child) in group.children.enumerated() {
                        if !existingChildNames.contains(child.name) {
                            _ = create(
                                in: context,
                                name: child.name,
                                icon: child.icon,
                                color: group.color,
                                type: TransactionType.income.rawValue,
                                isDefault: true,
                                sortOrder: Int16(idx),
                                parentId: parent.id
                            )
                            hasChanges = true
                        }
                    }
                }
            }
        }

        if hasChanges {
            try? context.save()
        }

        // 迁移旧 icon_ 图标到 SF Symbol
        migrateLegacyIcons(in: context)
    }
    
    /**
     根据层级定义批量创建一级 + 二级分类
     - Parameters:
       - hierarchy: 层级分类定义数组
       - type: 交易类型 rawValue
       - context: Core Data 上下文
     */
    private static func seedHierarchy(
        _ hierarchy: [CategoryGroupDef],
        type: String,
        in context: NSManagedObjectContext
    ) {
        for (groupIndex, group) in hierarchy.enumerated() {
            // 一级分类图标：使用专属映射，回退到第一个子分类图标
            let parentIcon = parentIconMapping[group.name] ?? group.children.first?.icon ?? "questionmark.circle"
            
            let parent = create(
                in: context,
                name: group.name,
                icon: parentIcon,
                color: group.color,
                type: type,
                isDefault: true,
                sortOrder: Int16(groupIndex),
                parentId: nil
            )
            
            // 创建该一级分类下的所有二级子分类
            for (childIndex, child) in group.children.enumerated() {
                _ = create(
                    in: context,
                    name: child.name,
                    icon: child.icon,
                    color: group.color,
                    type: type,
                    isDefault: true,
                    sortOrder: Int16(childIndex),
                    parentId: parent.id
                )
            }
        }
    }

    // MARK: - 旧图标迁移

    private static let migrationFlag = "hasMigratedToSFSymbols_v1"
    private static let migrationV2Flag = "hasMigratedToSFSymbols_v2"

    /// 将旧 icon_ 前缀图标名迁移为 SF Symbol
    /// 使用 UserDefaults 标记确保只执行一次，迁移失败不设标记下次自动重试
    static func migrateLegacyIcons(in context: NSManagedObjectContext) {
        // v1: 迁移 icon_ 前缀
        if !UserDefaults.standard.bool(forKey: migrationFlag) {
            let request = Category.fetchRequest()
            request.includesSubentities = false
            guard let all = try? context.fetch(request) else { return }

            var migrated = false
            for category in all {
                let iconName = category.icon
                guard iconName.hasPrefix("icon_") else { continue }

                if let sfSymbol = legacyIconMapping[iconName] ?? parentIconMapping[iconName] {
                    category.icon = sfSymbol
                    migrated = true
                }
            }

            if migrated {
                do {
                    try context.save()
                    UserDefaults.standard.set(true, forKey: migrationFlag)
                } catch { }
            } else {
                UserDefaults.standard.set(true, forKey: migrationFlag)
            }
        }

        // v2: 修复 v1 中使用了无效 SF Symbol 名称的图标
        migrateInvalidSymbols(in: context)
    }

    /// 修复无效的 SF Symbol 名称（v1 迁移使用了不存在的图标名）
    private static func migrateInvalidSymbols(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: migrationV2Flag) else { return }

        let fixes: [String: String] = [
            "apple.meditation": "carrot.fill",
            "lipstick": "sparkles",
            "couch.fill": "sofa.fill",
        ]

        let request = Category.fetchRequest()
        request.includesSubentities = false
        guard let all = try? context.fetch(request) else { return }

        var migrated = false
        for category in all {
            if let fixed = fixes[category.icon] {
                category.icon = fixed
                migrated = true
            }
        }

        if migrated {
            do {
                try context.save()
                UserDefaults.standard.set(true, forKey: migrationV2Flag)
            } catch { }
        } else {
            UserDefaults.standard.set(true, forKey: migrationV2Flag)
        }
    }
}
