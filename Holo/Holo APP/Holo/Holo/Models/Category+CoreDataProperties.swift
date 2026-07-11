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
    
    // MARK: - 支出分类层级（9 个一级 + 125 个二级）

    /// 支出分类体系
    /// 按 Figma 设计稿的图标分组排列，每组颜色与设计一致
    static let expenseHierarchy: [CategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 餐饮（蓝色系 #13A4EC）━━━━━━━━━━
        (name: "餐饮", color: "#13A4EC", children: [
            (name: "早餐", icon: "finance_breakfast"),
            (name: "午餐", icon: "finance_lunch"),
            (name: "晚餐", icon: "finance_dinner"),
            (name: "夜宵", icon: "finance_latenight"),
            (name: "零食", icon: "finance_snack"),
            (name: "咖啡", icon: "finance_coffee"),
            (name: "外卖", icon: "finance_takeout"),
            (name: "饮品", icon: "finance_drink"),
            (name: "水果", icon: "finance_fruit"),
            (name: "酒水", icon: "finance_alcohol"),
            (name: "超市", icon: "finance_supermarket"),
            (name: "火锅", icon: "finance_hotpot"),
            (name: "烧烤", icon: "finance_bbq"),
            (name: "甜品", icon: "finance_dessert"),
            (name: "啤酒", icon: "finance_beer"),
            (name: "茶饮", icon: "finance_tea"),
        ]),
        // ━━━━━━━━━━ 2. 交通（绿色系 #10B981）━━━━━━━━━━
        (name: "交通", color: "#10B981", children: [
            (name: "地铁", icon: "finance_subway"),
            (name: "打车", icon: "finance_taxi"),
            (name: "公交", icon: "finance_bus"),
            (name: "单车", icon: "finance_bicycle"),
            (name: "加油", icon: "finance_fuel"),
            (name: "充电", icon: "finance_ev_charge"),
            (name: "停车", icon: "finance_parking"),
            (name: "洗车", icon: "finance_carwash"),
            (name: "车辆保养", icon: "finance_carmaint"),
            (name: "火车", icon: "finance_train"),
            (name: "机票", icon: "finance_flight"),
            (name: "旅行", icon: "finance_travel"),
            (name: "过路费", icon: "finance_toll"),
            (name: "违章罚款", icon: "finance_fine"),
            (name: "船票", icon: "finance_ship"),
            (name: "渡轮", icon: "finance_ferry"),
            (name: "电动车", icon: "finance_scooter"),
            (name: "租车", icon: "finance_car_rent"),
        ]),
        // ━━━━━━━━━━ 3. 购物（橙色系 #F97316）━━━━━━━━━━
        (name: "购物", color: "#F97316", children: [
            (name: "服饰", icon: "finance_clothes"),
            (name: "数码", icon: "finance_digital"),
            (name: "日用", icon: "finance_daily"),
            (name: "美妆", icon: "finance_cosmetics"),
            (name: "家具", icon: "finance_furniture"),
            (name: "书籍", icon: "finance_books"),
            (name: "运动", icon: "finance_sports"),
            (name: "礼物", icon: "finance_gift"),
            (name: "鞋包", icon: "finance_shoes"),
            (name: "珠宝", icon: "finance_jewelry"),
            (name: "玩具", icon: "finance_toy"),
            (name: "宠物用品", icon: "finance_pet_supply"),
            (name: "植物花卉", icon: "finance_plant"),
            (name: "买菜", icon: "finance_food_buy"),
        ]),
        // ━━━━━━━━━━ 4. 娱乐（粉色系 #EC4899）━━━━━━━━━━
        (name: "娱乐", color: "#EC4899", children: [
            (name: "电影", icon: "finance_movie"),
            (name: "游戏", icon: "finance_game"),
            (name: "视频", icon: "finance_video"),
            (name: "音乐", icon: "finance_music"),
            (name: "KTV", icon: "finance_ktv"),
            (name: "旅游", icon: "finance_tourism"),
            (name: "住宿", icon: "finance_hotel"),
            (name: "门票", icon: "finance_ticket"),
            (name: "健身", icon: "finance_gym"),
            (name: "体育赛事", icon: "finance_sports_event"),
            (name: "演唱会", icon: "finance_concert"),
            (name: "展览", icon: "finance_exhibition"),
            (name: "SPA美容", icon: "finance_spa"),
            (name: "密室/剧本", icon: "finance_escape"),
            (name: "户外运动", icon: "finance_outdoor"),
        ]),
        // ━━━━━━━━━━ 5. 居住（靛蓝色系 #6366F1）━━━━━━━━━━
        (name: "居住", color: "#6366F1", children: [
            (name: "房租", icon: "finance_rent"),
            (name: "房贷", icon: "finance_mortgage"),
            (name: "水费", icon: "finance_water"),
            (name: "电费", icon: "finance_electricity"),
            (name: "燃气", icon: "finance_gas"),
            (name: "物业", icon: "finance_property"),
            (name: "网费", icon: "finance_internet"),
            (name: "家电", icon: "finance_appliance"),
            (name: "装修", icon: "finance_renovation"),
            (name: "家政保洁", icon: "finance_cleaning"),
            (name: "搬家", icon: "finance_moving"),
            (name: "话费", icon: "finance_phone_bill"),
            (name: "安防", icon: "finance_security"),
            (name: "洗衣", icon: "finance_laundry"),
            (name: "家具租赁", icon: "finance_furniture_rent"),
        ]),
        // ━━━━━━━━━━ 6. 医疗（玫红色系 #F43F5E）━━━━━━━━━━
        (name: "医疗", color: "#F43F5E", children: [
            (name: "就医", icon: "finance_doctor"),
            (name: "药品", icon: "finance_medicine"),
            (name: "体检", icon: "finance_checkup"),
            (name: "健身房", icon: "finance_gym"),
            (name: "保健品", icon: "finance_supplement"),
            (name: "牙齿保健", icon: "finance_dental"),
            (name: "医疗用品", icon: "finance_medical_supply"),
            (name: "住院", icon: "finance_hospital"),
            (name: "眼镜", icon: "finance_glasses"),
            (name: "心理咨询", icon: "finance_psychology"),
            (name: "康复理疗", icon: "finance_fitness_med"),
            (name: "疫苗", icon: "finance_vaccine"),
        ]),
        // ━━━━━━━━━━ 7. 学习（青色系 #06B6D4）━━━━━━━━━━
        (name: "学习", color: "#06B6D4", children: [
            (name: "课程", icon: "finance_course"),
            (name: "教材", icon: "finance_textbook"),
            (name: "考试", icon: "finance_exam"),
            (name: "文具", icon: "finance_stationery"),
            (name: "订阅", icon: "finance_subscription"),
            (name: "AI工具", icon: "finance_ai_tool"),
            (name: "软件服务", icon: "finance_software"),
            (name: "云存储", icon: "finance_cloud"),
            (name: "语言学习", icon: "finance_language"),
            (name: "乐器学习", icon: "finance_music_learn"),
            (name: "艺术培训", icon: "finance_art"),
            (name: "体育培训", icon: "finance_sport_learn"),
            (name: "证书考证", icon: "finance_certificate"),
        ]),
        // ━━━━━━━━━━ 8. 人情（琥珀色系 #F59E0B）━━━━━━━━━━
        (name: "人情", color: "#F59E0B", children: [
            (name: "红包礼金", icon: "finance_red_env"),
            (name: "请客", icon: "finance_treat"),
            (name: "送礼", icon: "finance_present"),
            (name: "探望", icon: "finance_visit"),
            (name: "育儿", icon: "finance_child"),
            (name: "赡养", icon: "finance_support"),
            (name: "其他", icon: "ellipsis.circle.fill"),
        ]),
        // ━━━━━━━━━━ 9. 其他（灰色系 #64748B）━━━━━━━━━━
        (name: "其他", color: "#64748B", children: [
            (name: "社交", icon: "finance_social"),
            (name: "宠物", icon: "finance_pet"),
            (name: "理发", icon: "finance_haircut"),
            (name: "洗衣", icon: "finance_laundry2"),
            (name: "话费", icon: "finance_phone"),
            (name: "烟酒", icon: "finance_tobacco"),
            (name: "维修", icon: "finance_repair"),
            (name: "保险", icon: "finance_insurance"),
            (name: "手续费", icon: "finance_fee"),
            (name: "税费", icon: "finance_tax"),
            (name: "罚款", icon: "finance_penalty"),
            (name: "还款", icon: "finance_repayment"),
            (name: "转账", icon: "finance_transfer"),
            (name: "快递", icon: "finance_delivery"),
            (name: "捐赠", icon: "finance_donation"),
            (name: "捐赠", icon: "finance_charity"),
            (name: "其他", icon: "questionmark.folder.fill"),
            (name: "其他支出", icon: "finance_other_exp"),
            (name: "快递费", icon: "finance_delivery"),
            (name: "慈善", icon: "finance_charity"),
        ]),
    ]
    
    // MARK: - 收入分类层级（4 个一级 + 39 个二级）

    /// 收入分类体系
    static let incomeHierarchy: [CategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 投资理财（蓝色系 #3B82F6）━━━━━━━━━━
        (name: "投资理财", color: "#3B82F6", children: [
            (name: "利息", icon: "income_interest"),
            (name: "股票", icon: "income_stock"),
            (name: "基金", icon: "income_fund"),
            (name: "房租收入", icon: "income_rent_in"),
            (name: "其他投资", icon: "income_other_invest"),
            (name: "理财", icon: "income_other_invest"),
            (name: "投资收益", icon: "income_dividend"),
            (name: "理财收益", icon: "income_other_invest"),
            (name: "数字货币", icon: "income_crypto"),
            (name: "分红", icon: "income_dividend"),
        ]),
        // ━━━━━━━━━━ 2. 工资收入（绿色系 #22C55E）━━━━━━━━━━
        (name: "工资收入", color: "#22C55E", children: [
            (name: "工资", icon: "income_salary"),
            (name: "奖金", icon: "income_bonus"),
            (name: "兼职", icon: "income_parttime"),
            (name: "项目款", icon: "income_project"),
            (name: "咨询费", icon: "income_consulting"),
            (name: "报销", icon: "income_reimburse"),
            (name: "退款", icon: "income_refund"),
            (name: "稿费版税", icon: "income_royalty"),
            (name: "佣金", icon: "income_commission"),
        ]),
        // ━━━━━━━━━━ 3. 人情来往（红色系 #EF4444）━━━━━━━━━━
        (name: "人情来往", color: "#EF4444", children: [
            (name: "红包", icon: "income_red_packet"),
            (name: "礼物", icon: "income_gift_in"),
            (name: "中奖", icon: "income_lottery"),
            (name: "转入", icon: "income_transfer_in"),
            (name: "众筹", icon: "income_crowd"),
            (name: "赞助", icon: "income_sponsor"),
        ]),
        // ━━━━━━━━━━ 4. 其他收入（紫色系 #A855F7）━━━━━━━━━━
        (name: "其他收入", color: "#A855F7", children: [
            (name: "借入", icon: "income_borrow"),
            (name: "还款收入", icon: "income_repay_in"),
            (name: "退货", icon: "income_return_goods"),
            (name: "公积金", icon: "income_provident"),
            (name: "出闲置", icon: "income_secondhand"),
            (name: "稿费", icon: "income_manuscript"),
            (name: "补贴", icon: "income_subsidy"),
            (name: "个税退税", icon: "income_tax_refund"),
            (name: "保险理赔", icon: "income_insurance_pay"),
            (name: "押金退还", icon: "income_rent_deposit"),
            (name: "奖励", icon: "income_award"),
            (name: "婚礼", icon: "finance_wedding"),
            (name: "其他收入", icon: "income_other"),
            (name: "其他", icon: "income_other"),
        ]),
    ]
    
    // MARK: - 旧图标 → SF Symbol 映射（一次性迁移用）

    /// 旧 icon_ 前缀图标名 → SF Symbol 名称
    /// 覆盖全部 97 个自定义 SVG 图标 + 11 个父类别图标
    static let legacyIconMapping: [String: String] = [
        // ━━━ 餐饮 ━━━
        "icon_breakfast": "holo.category.breakfast",
        "icon_lunch": "holo.category.lunch",
        "icon_dinner": "holo.category.dinner",
        "icon_late_snack": "moonphase.waning.crescent",
        "icon_snack": "popcorn.fill",
        "icon_coffee": "cup.and.saucer.fill",
        "icon_takeout": "bag.fill",
        "icon_beverage": "wineglass.fill",
        "icon_fruit": "holo.category.fruit",
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
        "餐饮": "cat_food",
        "交通": "cat_transport",
        "购物": "cat_shopping",
        "娱乐": "cat_entertain",
        "居住": "cat_housing",
        "医疗": "cat_medical",
        "学习": "cat_learning",
        "人情": "cat_relation",
        "其他": "cat_other_exp",
        "投资理财": "cat_inc_invest",
        "工资收入": "cat_inc_salary",
        "人情来往": "cat_inc_relation",
        "其他收入": "cat_inc_other",
    ]

    /// 查询预设分类的默认图标，用于编辑页“恢复默认图标”。
    static func defaultIconName(name: String, type: TransactionType, parentName: String?) -> String? {
        if parentName == nil, let icon = parentIconMapping[name] {
            return icon
        }

        let hierarchy = type == .expense ? expenseHierarchy : incomeHierarchy
        if let parentName {
            return hierarchy
                .first { $0.name == parentName }?
                .children
                .first { $0.name == name }?
                .icon
        }

        return hierarchy
            .flatMap(\.children)
            .first { $0.name == name }?
            .icon
    }

    // MARK: - Seed 初始化

    /**
     初始化默认分类数据（首次启动时调用）

     处理逻辑：
     1. 若无任何分类，创建完整层级
     2. 若已有层级分类（存在 parentId != nil），检查是否缺失分类，补充添加
     3. 先创建一级分类（parentId = nil），再创建二级子分类（parentId 指向父级 id）

     兼容旧数据：设备上已有 15 个扁平分类时，会补种完整层级分类，不删除旧数据
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
    private static let semanticIconMigrationFlag = "hasMigratedSemanticCategoryIcons_v1"
    private static let iconRefreshMigrationFlag = "hasMigratedRefreshedCategoryIcons_v1"
    private static let financeV3IconMigrationFlag = "hasMigratedFinanceV3CategoryIcons_v1"
    private static let financeV4IconMigrationFlag = "hasMigratedFinanceV4CategoryIcons_v1"

    /// 财务图标 v3 的默认科目映射；仅作用于系统默认分类，不覆盖用户自定义分类。
    private static let financeV3IconByCategoryName: [String: String] = [
        "早餐": "finance_breakfast", "午餐": "finance_lunch", "晚餐": "finance_dinner",
        "夜宵": "finance_latenight", "零食": "finance_snack", "咖啡": "finance_coffee",
        "外卖": "finance_takeout", "饮品": "finance_drink", "水果": "finance_fruit",
        "酒水": "finance_alcohol", "超市": "finance_supermarket", "地铁": "finance_subway",
        "打车": "finance_taxi", "公交": "finance_bus", "单车": "finance_bicycle",
        "加油": "finance_fuel", "充电": "finance_ev_charge", "停车": "finance_parking",
        "洗车": "finance_carwash", "车辆保养": "finance_carmaint", "火车": "finance_train",
        "机票": "finance_flight", "旅行": "finance_travel", "过路费": "finance_toll",
        "违章罚款": "finance_fine", "罚款": "finance_fine", "服饰": "finance_clothes",
        "数码": "finance_digital", "日用": "finance_daily", "美妆": "finance_cosmetics",
        "家具": "finance_furniture", "书籍": "finance_books", "运动": "finance_sports",
        "礼物": "finance_gift", "电影": "finance_movie", "游戏": "finance_game",
        "视频": "finance_video", "音乐": "finance_music", "KTV": "finance_ktv",
        "旅游": "finance_tourism", "住宿": "finance_hotel", "门票": "finance_ticket",
        "健身": "finance_gym", "健身房": "finance_gym", "房租": "finance_rent",
        "房贷": "finance_mortgage", "水费": "finance_water", "电费": "finance_electricity",
        "燃气": "finance_gas", "物业": "finance_property", "网费": "finance_internet",
        "家电": "finance_appliance", "装修": "finance_renovation", "家政保洁": "finance_cleaning",
        "搬家": "finance_moving", "就医": "finance_doctor", "药品": "finance_medicine",
        "体检": "finance_checkup", "保健品": "finance_supplement", "牙齿保健": "finance_dental",
        "医疗用品": "finance_medical_supply", "课程": "finance_course", "教材": "finance_textbook",
        "考试": "finance_exam", "文具": "finance_stationery", "订阅": "finance_subscription",
        "请客": "finance_treat", "红包礼金": "finance_red_packet", "红包": "finance_red_packet",
        "送礼": "finance_present", "赡养": "finance_support", "社交": "finance_social",
        "快递": "finance_express", "还款": "finance_repayment", "保险": "finance_insurance",
        "理财": "finance_investment", "投资收益": "finance_invest_return", "理财收益": "finance_wealth_return",
        "工资": "finance_salary", "奖金": "finance_bonus", "兼职": "finance_parttime",
        "报销": "finance_reimbursement", "退款": "finance_refund", "转入": "finance_transfer_in",
        "其他支出": "finance_other_expense", "其他收入": "finance_other_income",
    ]

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

        // v3: 修复语义不匹配的默认科目图标
        migrateSemanticCategoryIcons(in: context)

        // v4: 图标系统重构 — 重选 8 个语义错位图标
        migrateRefreshedCategoryIcons(in: context)

        // v5: 财务图标 v3 全量替换
        migrateFinanceV3CategoryIcons(in: context)

        // v6: 财务图标 v4（一级分类、收入图标和新增科目）全量替换
        migrateFinanceV4CategoryIcons(in: context)
    }

    /// 修复无效的 SF Symbol 名称（v1 迁移使用了不存在的图标名）
    private static func migrateInvalidSymbols(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: migrationV2Flag) else { return }

        let fixes: [String: String] = [
            "apple.meditation": "holo.category.fruit",
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

    private static func migrateSemanticCategoryIcons(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: semanticIconMigrationFlag) else { return }

        let request = Category.fetchRequest()
        request.includesSubentities = false
        guard let all = try? context.fetch(request) else { return }

        let fixes: [String: (oldIcons: Set<String>, newIcon: String)] = [
            "早餐": (["sunrise.fill", "icon_breakfast"], "holo.category.breakfast"),
            "午餐": (["sun.max.fill", "icon_lunch"], "holo.category.lunch"),
            "晚餐": (["moon.stars.fill", "icon_dinner"], "holo.category.dinner"),
            "水果": (["carrot.fill", "apple.meditation", "icon_fruit"], "holo.category.fruit"),
        ]

        var migrated = false
        for category in all where category.type == TransactionType.expense.rawValue {
            guard category.isDefault, let fix = fixes[category.name] else { continue }
            if fix.oldIcons.contains(category.icon) {
                category.icon = fix.newIcon
                migrated = true
            }
        }

        if migrated {
            do {
                try context.save()
                UserDefaults.standard.set(true, forKey: semanticIconMigrationFlag)
            } catch { }
        } else {
            UserDefaults.standard.set(true, forKey: semanticIconMigrationFlag)
        }
    }

    /// v4: 图标系统重构 — 重选 8 个语义错位图标（夜宵/旅行/过路费/美妆/房租/家政保洁/保健品/娱乐一级）
    /// 按 name + isDefault + 旧 icon 三重匹配，避免误伤同名分类（如 AI工具 也用 sparkles）或用户自定义分类
    private static func migrateRefreshedCategoryIcons(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: iconRefreshMigrationFlag) else { return }

        let request = Category.fetchRequest()
        request.includesSubentities = false
        guard let all = try? context.fetch(request) else { return }

        let fixes: [String: (oldIcons: Set<String>, newIcon: String)] = [
            // A 类：语义错位重选
            "夜宵": (["moonphase.waning.crescent"], "mug.fill"),
            "旅行": (["figure.walk"], "airplane.departure"),
            "过路费": (["building.columns.fill"], "road.lanes"),
            "美妆": (["sparkles"], "wand.and.stars"),
            "房租": (["key.fill"], "house.lodge.fill"),
            "家政保洁": (["person.2.badge.gearshape.fill"], "bubble.left.and.bubble.right.fill"),
            "保健品": (["leaf.fill"], "pill.fill"),
            "娱乐": (["music.note.list"], "theatermasks.fill"),
            // B 类：自绘图标换 SF Symbol
            "早餐": (["holo.category.breakfast"], "sunrise.fill"),
            "午餐": (["holo.category.lunch"], "fork.knife.circle.fill"),
            "晚餐": (["holo.category.dinner"], "moon.stars.fill"),
            "水果": (["holo.category.fruit"], "carrot.fill"),
            // C 类：重复图标差异化
            "请客": (["wineglass.fill"], "person.2.fill"),
            "送礼": (["gift.fill"], "shippingbox.fill"),
            "罚款": (["exclamationmark.triangle.fill"], "yensign.circle.fill"),
        ]

        var migrated = false
        for category in all where category.isDefault {
            guard let fix = fixes[category.name] else { continue }
            if fix.oldIcons.contains(category.icon) {
                category.icon = fix.newIcon
                migrated = true
            }
        }

        if migrated {
            do {
                try context.save()
                UserDefaults.standard.set(true, forKey: iconRefreshMigrationFlag)
            } catch { }
        } else {
            UserDefaults.standard.set(true, forKey: iconRefreshMigrationFlag)
        }
    }

    /// v5：将已安装设备上的默认财务科目切换到 finance v3 资源。
    private static func migrateFinanceV3CategoryIcons(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: financeV3IconMigrationFlag) else { return }

        let request = Category.fetchRequest()
        request.includesSubentities = false
        guard let all = try? context.fetch(request) else { return }

        var migrated = false
        for category in all where category.isDefault {
            let newIcon: String?
            if category.type == TransactionType.income.rawValue && category.name == "其他" {
                newIcon = "finance_other_income"
            } else {
                newIcon = financeV3IconByCategoryName[category.name]
            }
            guard let newIcon else { continue }
            if category.icon != newIcon {
                category.icon = newIcon
                migrated = true
            }
        }

        if migrated {
            do {
                try context.save()
                UserDefaults.standard.set(true, forKey: financeV3IconMigrationFlag)
            } catch { }
        } else {
            UserDefaults.standard.set(true, forKey: financeV3IconMigrationFlag)
        }
    }

    /// v6：按当前默认目录单一数据源同步已安装设备上的默认图标。
    private static func migrateFinanceV4CategoryIcons(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: financeV4IconMigrationFlag) else { return }

        let request = Category.fetchRequest()
        request.includesSubentities = false
        guard let all = try? context.fetch(request) else { return }

        var migrated = false
        for category in all where category.isDefault {
            let parentName = category.parentId.flatMap { parentID in
                all.first { $0.id == parentID }?.name
            }
            guard let newIcon = defaultIconName(
                name: category.name,
                type: category.transactionType,
                parentName: parentName
            ) else { continue }
            if category.icon != newIcon {
                category.icon = newIcon
                migrated = true
            }
        }

        if migrated {
            do {
                try context.save()
                UserDefaults.standard.set(true, forKey: financeV4IconMigrationFlag)
            } catch { }
        } else {
            UserDefaults.standard.set(true, forKey: financeV4IconMigrationFlag)
        }
    }
}
