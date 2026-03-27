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
        parentId: UUID? = nil
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
            (name: "早餐", icon: "icon_breakfast"),
            (name: "午餐", icon: "icon_lunch"),
            (name: "晚餐", icon: "icon_dinner"),
            (name: "夜宵", icon: "icon_late_snack"),
            (name: "零食", icon: "icon_snack"),
            (name: "咖啡", icon: "icon_coffee"),
            (name: "外卖", icon: "icon_takeout"),
            (name: "饮品", icon: "icon_beverage"),
            (name: "水果", icon: "icon_fruit"),
            (name: "酒水", icon: "icon_alcohol"),
            (name: "超市", icon: "icon_supermarket"),
        ]),
        // ━━━━━━━━━━ 2. 交通（绿色系 #10B981）━━━━━━━━━━
        (name: "交通", color: "#10B981", children: [
            (name: "地铁", icon: "icon_metro"),
            (name: "打车", icon: "icon_taxi"),
            (name: "公交", icon: "icon_bus"),
            (name: "单车", icon: "icon_bike_share"),
            (name: "加油", icon: "icon_fuel"),
            (name: "停车", icon: "icon_parking"),
            (name: "火车", icon: "icon_train"),
            (name: "机票", icon: "icon_flight"),
            (name: "旅行", icon: "icon_travel"),
            (name: "过路费", icon: "icon_toll"),
        ]),
        // ━━━━━━━━━━ 3. 购物（橙色系 #F97316）━━━━━━━━━━
        (name: "购物", color: "#F97316", children: [
            (name: "服饰", icon: "icon_clothes"),
            (name: "数码", icon: "icon_digital"),
            (name: "日用", icon: "icon_groceries"),
            (name: "美妆", icon: "icon_beauty"),
            (name: "家具", icon: "icon_furniture"),
            (name: "书籍", icon: "icon_book"),
            (name: "运动", icon: "icon_sport"),
            (name: "礼物", icon: "icon_present"),
        ]),
        // ━━━━━━━━━━ 4. 娱乐（粉色系 #EC4899）━━━━━━━━━━
        (name: "娱乐", color: "#EC4899", children: [
            (name: "电影", icon: "icon_cinema"),
            (name: "游戏", icon: "icon_gaming"),
            (name: "视频", icon: "icon_video"),
            (name: "音乐", icon: "icon_music"),
            (name: "KTV", icon: "icon_ktv"),
            (name: "旅游", icon: "icon_trip"),
            (name: "健身", icon: "icon_fitness"),
        ]),
        // ━━━━━━━━━━ 5. 居住（靛蓝色系 #6366F1）━━━━━━━━━━
        (name: "居住", color: "#6366F1", children: [
            (name: "房租", icon: "icon_rent"),
            (name: "房贷", icon: "icon_mortgage"),
            (name: "水费", icon: "icon_water"),
            (name: "电费", icon: "icon_electricity"),
            (name: "燃气", icon: "icon_gas"),
            (name: "物业", icon: "icon_property"),
            (name: "网费", icon: "icon_internet"),
            (name: "家电", icon: "icon_appliance"),
            (name: "装修", icon: "icon_renovation"),
        ]),
        // ━━━━━━━━━━ 6. 医疗（玫红色系 #F43F5E）━━━━━━━━━━
        (name: "医疗", color: "#F43F5E", children: [
            (name: "就医", icon: "icon_medical"),
            (name: "药品", icon: "icon_medicine"),
            (name: "体检", icon: "icon_checkup"),
            (name: "健身房", icon: "icon_gym"),
            (name: "保健品", icon: "icon_supplement"),
            (name: "牙齿保健", icon: "icon_dental"),
            (name: "医疗用品", icon: "icon_medical_supply"),
        ]),
        // ━━━━━━━━━━ 7. 学习（青色系 #06B6D4）━━━━━━━━━━
        (name: "学习", color: "#06B6D4", children: [
            (name: "课程", icon: "icon_course"),
            (name: "教材", icon: "icon_textbook"),
            (name: "考试", icon: "icon_exam"),
            (name: "文具", icon: "icon_stationery"),
            (name: "订阅", icon: "icon_subscription"),
        ]),
        // ━━━━━━━━━━ 8. 人情（琥珀色系 #F59E0B）━━━━━━━━━━
        (name: "人情", color: "#F59E0B", children: [
            (name: "红包礼金", icon: "icon_cash_gift"),
            (name: "请客", icon: "icon_treat"),
            (name: "送礼", icon: "icon_gifting"),
            (name: "探望", icon: "icon_visit"),
            (name: "其他", icon: "icon_social_other"),
        ]),
        // ━━━━━━━━━━ 9. 其他（灰色系 #64748B）━━━━━━━━━━
        (name: "其他", color: "#64748B", children: [
            (name: "社交", icon: "icon_social"),
            (name: "宠物", icon: "icon_pet"),
            (name: "理发", icon: "icon_barber"),
            (name: "洗衣", icon: "icon_laundry"),
            (name: "话费", icon: "icon_phone_bill"),
            (name: "烟酒", icon: "icon_tobacco_alcohol"),
            (name: "维修", icon: "icon_repair"),
            (name: "保险", icon: "icon_insurance"),
            (name: "还款", icon: "icon_repayment"),
            (name: "转账", icon: "icon_transfer_out"),
            (name: "捐赠", icon: "icon_donation"),
            (name: "其他", icon: "icon_other_exp"),
        ]),
    ]
    
    // MARK: - 收入分类层级（4 个一级 + 19 个二级）

    /// 收入分类体系
    static let incomeHierarchy: [CategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 投资理财（蓝色系 #3B82F6）━━━━━━━━━━
        (name: "投资理财", color: "#3B82F6", children: [
            (name: "利息", icon: "icon_interest"),
            (name: "股票", icon: "icon_stock"),
            (name: "房租收入", icon: "icon_rent_income"),
            (name: "其他投资", icon: "icon_invest_other"),
        ]),
        // ━━━━━━━━━━ 2. 工资收入（绿色系 #22C55E）━━━━━━━━━━
        (name: "工资收入", color: "#22C55E", children: [
            (name: "工资", icon: "icon_salary"),
            (name: "奖金", icon: "icon_bonus"),
            (name: "兼职", icon: "icon_parttime"),
            (name: "报销", icon: "icon_reimburse"),
            (name: "退款", icon: "icon_refund"),
        ]),
        // ━━━━━━━━━━ 3. 人情来往（红色系 #EF4444）━━━━━━━━━━
        (name: "人情来往", color: "#EF4444", children: [
            (name: "红包", icon: "icon_red_packet"),
            (name: "礼物", icon: "icon_gift"),
            (name: "中奖", icon: "icon_winning"),
            (name: "转入", icon: "icon_transfer_in"),
        ]),
        // ━━━━━━━━━━ 4. 其他收入（紫色系 #A855F7）━━━━━━━━━━
        (name: "其他收入", color: "#A855F7", children: [
            (name: "借入", icon: "icon_loan_in"),
            (name: "还款收入", icon: "icon_repay_in"),
            (name: "退货", icon: "icon_return"),
            (name: "公积金", icon: "icon_housing_fund"),
            (name: "出闲置", icon: "icon_secondhand"),
            (name: "其他", icon: "icon_other_inc"),
        ]),
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
                let parentIcon = group.children.first?.icon ?? "questionmark.circle"
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
                let parentIcon = group.children.first?.icon ?? "questionmark.circle"
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
            // 一级分类图标：暂用其第一个子分类的图标
            let parentIcon = group.children.first?.icon ?? "questionmark.circle"
            
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
}
