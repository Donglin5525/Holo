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

    /// 二级子分类定义（解析后：落库名 + 图标）
    typealias SubCategoryDef = (name: String, icon: String)

    /// 一级分类定义（解析后：落库名 + 颜色 + 子分类列表）
    typealias CategoryGroupDef = (
        name: String,
        color: String,
        children: [SubCategoryDef]
    )

    /// 二级子分类定义（词条形态：名字三语，按固化种子语言解析成落库名）
    typealias LocalizedSubCategoryDef = (term: SeedTerm, icon: String)

    /// 一级分类定义（词条形态）
    typealias LocalizedCategoryGroupDef = (
        term: SeedTerm,
        color: String,
        children: [LocalizedSubCategoryDef]
    )

    // MARK: - 支出分类层级（9 个一级 + 125 个二级）

    /// 支出分类体系（词条形态：新用户首启按种子语言种植对应语种的科目名；
    /// 常用科目名复用 FinanceSeedVocabulary 词条，其余就地内联）
    /// 按 Figma 设计稿的图标分组排列，每组颜色与设计一致
    static let localizedExpenseHierarchy: [LocalizedCategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 餐饮（蓝色系 #13A4EC）━━━━━━━━━━
        (term: FinanceSeedVocabulary.dining, color: "#13A4EC", children: [
            (term: FinanceSeedVocabulary.breakfast, icon: "finance_breakfast"),
            (term: FinanceSeedVocabulary.lunch, icon: "finance_lunch"),
            (term: FinanceSeedVocabulary.dinner, icon: "finance_dinner"),
            (term: FinanceSeedVocabulary.lateNightSnack, icon: "finance_latenight"),
            (term: SeedTerm(hans: "零食", hant: "零食", english: "Snacks"), icon: "finance_snack"),
            (term: SeedTerm(hans: "咖啡", hant: "咖啡", english: "Coffee"), icon: "finance_coffee"),
            (term: SeedTerm(hans: "外卖", hant: "外賣", english: "Takeout"), icon: "finance_takeout"),
            (term: SeedTerm(hans: "饮品", hant: "飲品", english: "Drinks"), icon: "finance_drink"),
            (term: SeedTerm(hans: "水果", hant: "水果", english: "Fruit"), icon: "finance_fruit"),
            (term: SeedTerm(hans: "酒水", hant: "酒水", english: "Alcohol"), icon: "finance_alcohol"),
            (term: SeedTerm(hans: "超市", hant: "超市", english: "Supermarket"), icon: "finance_supermarket"),
            (term: SeedTerm(hans: "火锅", hant: "火鍋", english: "Hotpot"), icon: "finance_hotpot"),
            (term: SeedTerm(hans: "烧烤", hant: "燒烤", english: "BBQ"), icon: "finance_bbq"),
            (term: SeedTerm(hans: "甜品", hant: "甜品", english: "Dessert"), icon: "finance_dessert"),
            (term: SeedTerm(hans: "啤酒", hant: "啤酒", english: "Beer"), icon: "finance_beer"),
            (term: SeedTerm(hans: "茶饮", hant: "茶飲", english: "Tea"), icon: "finance_tea"),
        ]),
        // ━━━━━━━━━━ 2. 交通（绿色系 #10B981）━━━━━━━━━━
        (term: FinanceSeedVocabulary.transportation, color: "#10B981", children: [
            (term: FinanceSeedVocabulary.subway, icon: "finance_subway"),
            (term: FinanceSeedVocabulary.taxi, icon: "finance_taxi"),
            (term: FinanceSeedVocabulary.bus, icon: "finance_bus"),
            (term: SeedTerm(hans: "单车", hant: "單車", english: "Bike Share"), icon: "finance_bicycle"),
            (term: SeedTerm(hans: "加油", hant: "加油", english: "Fuel"), icon: "finance_fuel"),
            (term: SeedTerm(hans: "充电", hant: "充電", english: "EV Charging"), icon: "finance_ev_charge"),
            (term: SeedTerm(hans: "停车", hant: "停車", english: "Parking"), icon: "finance_parking"),
            (term: SeedTerm(hans: "洗车", hant: "洗車", english: "Car Wash"), icon: "finance_carwash"),
            (term: SeedTerm(hans: "车辆保养", hant: "車輛保養", english: "Car Maintenance"), icon: "finance_carmaint"),
            (term: SeedTerm(hans: "火车", hant: "火車", english: "Train"), icon: "finance_train"),
            (term: SeedTerm(hans: "机票", hant: "機票", english: "Flights"), icon: "finance_flight"),
            (term: FinanceSeedVocabulary.travel, icon: "finance_travel"),
            (term: SeedTerm(hans: "过路费", hant: "過路費", english: "Toll"), icon: "finance_toll"),
            (term: SeedTerm(hans: "违章罚款", hant: "違章罰款", english: "Traffic Fine"), icon: "finance_fine"),
            (term: SeedTerm(hans: "船票", hant: "船票", english: "Boat Ticket"), icon: "finance_ship"),
            (term: SeedTerm(hans: "渡轮", hant: "渡輪", english: "Ferry"), icon: "finance_ferry"),
            (term: SeedTerm(hans: "电动车", hant: "電動車", english: "E-bike"), icon: "finance_scooter"),
            (term: SeedTerm(hans: "租车", hant: "租車", english: "Car Rental"), icon: "finance_car_rent"),
        ]),
        // ━━━━━━━━━━ 3. 购物（橙色系 #F97316）━━━━━━━━━━
        (term: FinanceSeedVocabulary.shopping, color: "#F97316", children: [
            (term: FinanceSeedVocabulary.clothing, icon: "finance_clothes"),
            (term: SeedTerm(hans: "数码", hant: "數碼", english: "Electronics"), icon: "finance_digital"),
            (term: FinanceSeedVocabulary.dailyNecessities, icon: "finance_daily"),
            (term: SeedTerm(hans: "美妆", hant: "美妝", english: "Beauty"), icon: "finance_cosmetics"),
            (term: SeedTerm(hans: "家具", hant: "家具", english: "Furniture"), icon: "finance_furniture"),
            (term: SeedTerm(hans: "书籍", hant: "書籍", english: "Books"), icon: "finance_books"),
            (term: SeedTerm(hans: "运动", hant: "運動", english: "Sports"), icon: "finance_sports"),
            (term: SeedTerm(hans: "礼物", hant: "禮物", english: "Gifts"), icon: "finance_gift"),
            (term: SeedTerm(hans: "鞋包", hant: "鞋包", english: "Shoes & Bags"), icon: "finance_shoes"),
            (term: SeedTerm(hans: "珠宝", hant: "珠寶", english: "Jewelry"), icon: "finance_jewelry"),
            (term: SeedTerm(hans: "玩具", hant: "玩具", english: "Toys"), icon: "finance_toy"),
            (term: SeedTerm(hans: "宠物用品", hant: "寵物用品", english: "Pet Supplies"), icon: "finance_pet_supply"),
            (term: SeedTerm(hans: "植物花卉", hant: "植物花卉", english: "Plants & Flowers"), icon: "finance_plant"),
            (term: SeedTerm(hans: "买菜", hant: "買菜", english: "Groceries"), icon: "finance_food_buy"),
        ]),
        // ━━━━━━━━━━ 4. 娱乐（粉色系 #EC4899）━━━━━━━━━━
        (term: FinanceSeedVocabulary.entertainment, color: "#EC4899", children: [
            (term: FinanceSeedVocabulary.movies, icon: "finance_movie"),
            (term: SeedTerm(hans: "游戏", hant: "遊戲", english: "Games"), icon: "finance_game"),
            (term: SeedTerm(hans: "视频", hant: "視頻", english: "Video"), icon: "finance_video"),
            (term: SeedTerm(hans: "音乐", hant: "音樂", english: "Music"), icon: "finance_music"),
            (term: SeedTerm(hans: "KTV", hant: "KTV", english: "KTV"), icon: "finance_ktv"),
            (term: SeedTerm(hans: "旅游", hant: "旅遊", english: "Vacation"), icon: "finance_tourism"),
            (term: SeedTerm(hans: "住宿", hant: "住宿", english: "Accommodation"), icon: "finance_hotel"),
            (term: SeedTerm(hans: "门票", hant: "門票", english: "Tickets"), icon: "finance_ticket"),
            (term: SeedTerm(hans: "健身", hant: "健身", english: "Fitness"), icon: "finance_gym"),
            (term: SeedTerm(hans: "体育赛事", hant: "體育賽事", english: "Sports Events"), icon: "finance_sports_event"),
            (term: SeedTerm(hans: "演唱会", hant: "演唱會", english: "Concerts"), icon: "finance_concert"),
            (term: SeedTerm(hans: "展览", hant: "展覽", english: "Exhibitions"), icon: "finance_exhibition"),
            (term: SeedTerm(hans: "SPA美容", hant: "SPA美容", english: "SPA"), icon: "finance_spa"),
            (term: SeedTerm(hans: "密室/剧本", hant: "密室/劇本", english: "Escape Room"), icon: "finance_escape"),
            (term: SeedTerm(hans: "户外运动", hant: "戶外運動", english: "Outdoor Sports"), icon: "finance_outdoor"),
        ]),
        // ━━━━━━━━━━ 5. 居住（靛蓝色系 #6366F1）━━━━━━━━━━
        (term: FinanceSeedVocabulary.housing, color: "#6366F1", children: [
            (term: SeedTerm(hans: "房租", hant: "房租", english: "Rent"), icon: "finance_rent"),
            (term: SeedTerm(hans: "房贷", hant: "房貸", english: "Mortgage"), icon: "finance_mortgage"),
            (term: SeedTerm(hans: "水费", hant: "水費", english: "Water Bill"), icon: "finance_water"),
            (term: SeedTerm(hans: "电费", hant: "電費", english: "Electricity Bill"), icon: "finance_electricity"),
            (term: SeedTerm(hans: "燃气", hant: "燃氣", english: "Gas Bill"), icon: "finance_gas"),
            (term: SeedTerm(hans: "物业", hant: "物業", english: "Property Management"), icon: "finance_property"),
            (term: SeedTerm(hans: "网费", hant: "網費", english: "Internet Bill"), icon: "finance_internet"),
            (term: SeedTerm(hans: "家电", hant: "家電", english: "Home Appliances"), icon: "finance_appliance"),
            (term: SeedTerm(hans: "装修", hant: "裝修", english: "Renovation"), icon: "finance_renovation"),
            (term: SeedTerm(hans: "家政保洁", hant: "家政保潔", english: "Housekeeping"), icon: "finance_cleaning"),
            (term: SeedTerm(hans: "搬家", hant: "搬家", english: "Moving"), icon: "finance_moving"),
            (term: SeedTerm(hans: "话费", hant: "話費", english: "Phone Bill"), icon: "finance_phone_bill"),
            (term: SeedTerm(hans: "安防", hant: "安防", english: "Security"), icon: "finance_security"),
            (term: SeedTerm(hans: "洗衣", hant: "洗衣", english: "Laundry"), icon: "finance_laundry"),
            (term: SeedTerm(hans: "家具租赁", hant: "家具租賃", english: "Furniture Rental"), icon: "finance_furniture_rent"),
        ]),
        // ━━━━━━━━━━ 6. 医疗（玫红色系 #F43F5E）━━━━━━━━━━
        (term: FinanceSeedVocabulary.healthcare, color: "#F43F5E", children: [
            (term: SeedTerm(hans: "就医", hant: "就醫", english: "Doctor Visit"), icon: "finance_doctor"),
            (term: SeedTerm(hans: "药品", hant: "藥品", english: "Medicine"), icon: "finance_medicine"),
            (term: SeedTerm(hans: "体检", hant: "體檢", english: "Health Checkup"), icon: "finance_checkup"),
            (term: SeedTerm(hans: "健身房", hant: "健身房", english: "Gym"), icon: "finance_gym"),
            (term: SeedTerm(hans: "保健品", hant: "保健品", english: "Supplements"), icon: "finance_supplement"),
            (term: SeedTerm(hans: "牙齿保健", hant: "牙齒保健", english: "Dental Care"), icon: "finance_dental"),
            (term: SeedTerm(hans: "医疗用品", hant: "醫療用品", english: "Medical Supplies"), icon: "finance_medical_supply"),
            (term: SeedTerm(hans: "住院", hant: "住院", english: "Hospitalization"), icon: "finance_hospital"),
            (term: SeedTerm(hans: "眼镜", hant: "眼鏡", english: "Glasses"), icon: "finance_glasses"),
            (term: SeedTerm(hans: "心理咨询", hant: "心理諮詢", english: "Counseling"), icon: "finance_psychology"),
            (term: SeedTerm(hans: "康复理疗", hant: "康復理療", english: "Physiotherapy"), icon: "finance_fitness_med"),
            (term: SeedTerm(hans: "疫苗", hant: "疫苗", english: "Vaccination"), icon: "finance_vaccine"),
        ]),
        // ━━━━━━━━━━ 7. 学习（青色系 #06B6D4）━━━━━━━━━━
        (term: FinanceSeedVocabulary.learning, color: "#06B6D4", children: [
            (term: SeedTerm(hans: "课程", hant: "課程", english: "Courses"), icon: "finance_course"),
            (term: SeedTerm(hans: "教材", hant: "教材", english: "Textbooks"), icon: "finance_textbook"),
            (term: SeedTerm(hans: "考试", hant: "考試", english: "Exams"), icon: "finance_exam"),
            (term: SeedTerm(hans: "文具", hant: "文具", english: "Stationery"), icon: "finance_stationery"),
            (term: SeedTerm(hans: "订阅", hant: "訂閱", english: "Subscriptions"), icon: "finance_subscription"),
            (term: SeedTerm(hans: "AI工具", hant: "AI工具", english: "AI Tools"), icon: "finance_ai_tool"),
            (term: SeedTerm(hans: "软件服务", hant: "軟件服務", english: "Software"), icon: "finance_software"),
            (term: SeedTerm(hans: "云存储", hant: "雲存儲", english: "Cloud Storage"), icon: "finance_cloud"),
            (term: SeedTerm(hans: "语言学习", hant: "語言學習", english: "Language Learning"), icon: "finance_language"),
            (term: SeedTerm(hans: "乐器学习", hant: "樂器學習", english: "Music Lessons"), icon: "finance_music_learn"),
            (term: SeedTerm(hans: "艺术培训", hant: "藝術培訓", english: "Art Training"), icon: "finance_art"),
            (term: SeedTerm(hans: "体育培训", hant: "體育培訓", english: "Sports Training"), icon: "finance_sport_learn"),
            (term: SeedTerm(hans: "证书考证", hant: "證書考證", english: "Certifications"), icon: "finance_certificate"),
        ]),
        // ━━━━━━━━━━ 8. 人情（琥珀色系 #F59E0B）━━━━━━━━━━
        (term: FinanceSeedVocabulary.socialGifts, color: "#F59E0B", children: [
            (term: SeedTerm(hans: "红包礼金", hant: "紅包禮金", english: "Cash Gifts"), icon: "finance_red_env"),
            (term: SeedTerm(hans: "请客", hant: "請客", english: "Treats"), icon: "finance_treat"),
            (term: SeedTerm(hans: "送礼", hant: "送禮", english: "Gift Giving"), icon: "finance_present"),
            (term: SeedTerm(hans: "探望", hant: "探望", english: "Visits"), icon: "finance_visit"),
            (term: SeedTerm(hans: "育儿", hant: "育兒", english: "Childcare"), icon: "finance_child"),
            (term: SeedTerm(hans: "赡养", hant: "贍養", english: "Family Support"), icon: "finance_support"),
            (term: FinanceSeedVocabulary.other, icon: "ellipsis.circle.fill"),
        ]),
        // ━━━━━━━━━━ 9. 其他（灰色系 #64748B）━━━━━━━━━━
        (term: FinanceSeedVocabulary.other, color: "#64748B", children: [
            (term: FinanceSeedVocabulary.social, icon: "finance_social"),
            (term: FinanceSeedVocabulary.pets, icon: "finance_pet"),
            (term: SeedTerm(hans: "理发", hant: "理髮", english: "Haircut"), icon: "finance_haircut"),
            (term: SeedTerm(hans: "洗衣", hant: "洗衣", english: "Laundry"), icon: "finance_laundry2"),
            (term: SeedTerm(hans: "话费", hant: "話費", english: "Phone Bill"), icon: "finance_phone"),
            (term: SeedTerm(hans: "烟酒", hant: "煙酒", english: "Tobacco & Alcohol"), icon: "finance_tobacco"),
            (term: SeedTerm(hans: "维修", hant: "維修", english: "Repairs"), icon: "finance_repair"),
            (term: SeedTerm(hans: "保险", hant: "保險", english: "Insurance"), icon: "finance_insurance"),
            (term: SeedTerm(hans: "手续费", hant: "手續費", english: "Fees"), icon: "finance_fee"),
            (term: SeedTerm(hans: "税费", hant: "稅費", english: "Taxes"), icon: "finance_tax"),
            (term: SeedTerm(hans: "罚款", hant: "罰款", english: "Fines"), icon: "finance_penalty"),
            (term: SeedTerm(hans: "还款", hant: "還款", english: "Repayment"), icon: "finance_repayment"),
            (term: FinanceSeedVocabulary.transfer, icon: "finance_transfer"),
            (term: SeedTerm(hans: "快递", hant: "快遞", english: "Express Delivery"), icon: "finance_delivery"),
            (term: SeedTerm(hans: "捐赠", hant: "捐贈", english: "Donation"), icon: "finance_donation"),
            (term: SeedTerm(hans: "捐赠", hant: "捐贈", english: "Donation"), icon: "finance_charity"),
            (term: FinanceSeedVocabulary.other, icon: "questionmark.folder.fill"),
            (term: FinanceSeedVocabulary.otherExpense, icon: "finance_other_exp"),
            (term: SeedTerm(hans: "快递费", hant: "快遞費", english: "Shipping Fees"), icon: "finance_delivery"),
            (term: SeedTerm(hans: "慈善", hant: "慈善", english: "Charity"), icon: "finance_charity"),
        ]),
    ]

    /// 按固化种子语言解析后的支出层级（种子执行 / 图标回查 / 复活修复共用同一数据源）
    static var expenseHierarchy: [CategoryGroupDef] {
        resolveHierarchy(localizedExpenseHierarchy)
    }
    
    // MARK: - 收入分类层级（4 个一级 + 39 个二级）

    /// 收入分类体系（词条形态，三语）
    static let localizedIncomeHierarchy: [LocalizedCategoryGroupDef] = [
        // ━━━━━━━━━━ 1. 投资理财（蓝色系 #3B82F6）━━━━━━━━━━
        (term: FinanceSeedVocabulary.investmentAndFinance, color: "#3B82F6", children: [
            (term: SeedTerm(hans: "利息", hant: "利息", english: "Interest"), icon: "income_interest"),
            (term: SeedTerm(hans: "股票", hant: "股票", english: "Stocks"), icon: "income_stock"),
            (term: SeedTerm(hans: "基金", hant: "基金", english: "Funds"), icon: "income_fund"),
            (term: SeedTerm(hans: "房租收入", hant: "房租收入", english: "Rental Income"), icon: "income_rent_in"),
            (term: SeedTerm(hans: "其他投资", hant: "其他投資", english: "Other Investments"), icon: "income_other_invest"),
            (term: SeedTerm(hans: "理财", hant: "理財", english: "Wealth Management"), icon: "income_other_invest"),
            (term: SeedTerm(hans: "投资收益", hant: "投資收益", english: "Investment Returns"), icon: "income_dividend"),
            (term: SeedTerm(hans: "理财收益", hant: "理財收益", english: "Wealth Returns"), icon: "income_other_invest"),
            (term: SeedTerm(hans: "数字货币", hant: "數字貨幣", english: "Crypto"), icon: "income_crypto"),
            (term: SeedTerm(hans: "分红", hant: "分紅", english: "Dividends"), icon: "income_dividend"),
        ]),
        // ━━━━━━━━━━ 2. 工资收入（绿色系 #22C55E）━━━━━━━━━━
        (term: FinanceSeedVocabulary.salaryIncome, color: "#22C55E", children: [
            (term: FinanceSeedVocabulary.salary, icon: "income_salary"),
            (term: FinanceSeedVocabulary.bonus, icon: "income_bonus"),
            (term: SeedTerm(hans: "兼职", hant: "兼職", english: "Part-time"), icon: "income_parttime"),
            (term: SeedTerm(hans: "项目款", hant: "項目款", english: "Project Income"), icon: "income_project"),
            (term: SeedTerm(hans: "咨询费", hant: "諮詢費", english: "Consulting"), icon: "income_consulting"),
            (term: FinanceSeedVocabulary.reimbursement, icon: "income_reimburse"),
            (term: FinanceSeedVocabulary.refund, icon: "income_refund"),
            (term: SeedTerm(hans: "稿费版税", hant: "稿費版稅", english: "Royalties"), icon: "income_royalty"),
            (term: SeedTerm(hans: "佣金", hant: "佣金", english: "Commission"), icon: "income_commission"),
        ]),
        // ━━━━━━━━━━ 3. 人情来往（红色系 #EF4444）━━━━━━━━━━
        (term: FinanceSeedVocabulary.socialIncome, color: "#EF4444", children: [
            (term: FinanceSeedVocabulary.redEnvelope, icon: "income_red_packet"),
            (term: SeedTerm(hans: "礼物", hant: "禮物", english: "Gifts"), icon: "income_gift_in"),
            (term: SeedTerm(hans: "中奖", hant: "中獎", english: "Lottery"), icon: "income_lottery"),
            (term: SeedTerm(hans: "转入", hant: "轉入", english: "Transfer In"), icon: "income_transfer_in"),
            (term: SeedTerm(hans: "众筹", hant: "眾籌", english: "Crowdfunding"), icon: "income_crowd"),
            (term: SeedTerm(hans: "赞助", hant: "贊助", english: "Sponsorship"), icon: "income_sponsor"),
        ]),
        // ━━━━━━━━━━ 4. 其他收入（紫色系 #A855F7）━━━━━━━━━━
        (term: FinanceSeedVocabulary.otherIncome, color: "#A855F7", children: [
            (term: SeedTerm(hans: "借入", hant: "借入", english: "Borrowed"), icon: "income_borrow"),
            (term: SeedTerm(hans: "还款收入", hant: "還款收入", english: "Repayment In"), icon: "income_repay_in"),
            (term: SeedTerm(hans: "退货", hant: "退貨", english: "Returns"), icon: "income_return_goods"),
            (term: SeedTerm(hans: "公积金", hant: "公積金", english: "Housing Fund"), icon: "income_provident"),
            (term: SeedTerm(hans: "出闲置", hant: "出閒置", english: "Secondhand Sale"), icon: "income_secondhand"),
            (term: SeedTerm(hans: "稿费", hant: "稿費", english: "Manuscript Fees"), icon: "income_manuscript"),
            (term: SeedTerm(hans: "补贴", hant: "補貼", english: "Allowance"), icon: "income_subsidy"),
            (term: SeedTerm(hans: "个税退税", hant: "個稅退稅", english: "Tax Refund"), icon: "income_tax_refund"),
            (term: SeedTerm(hans: "保险理赔", hant: "保險理賠", english: "Insurance Claims"), icon: "income_insurance_pay"),
            (term: SeedTerm(hans: "押金退还", hant: "押金退還", english: "Deposit Refund"), icon: "income_rent_deposit"),
            (term: SeedTerm(hans: "奖励", hant: "獎勵", english: "Awards"), icon: "income_award"),
            (term: SeedTerm(hans: "婚礼", hant: "婚禮", english: "Wedding"), icon: "finance_wedding"),
            (term: FinanceSeedVocabulary.otherIncome, icon: "income_other"),
            (term: FinanceSeedVocabulary.other, icon: "income_other"),
        ]),
    ]

    /// 按固化种子语言解析后的收入层级
    static var incomeHierarchy: [CategoryGroupDef] {
        resolveHierarchy(localizedIncomeHierarchy)
    }

    /// 把词条形态的层级解析成当前种子语言的落库名层级
    private static func resolveHierarchy(
        _ hierarchy: [LocalizedCategoryGroupDef]
    ) -> [CategoryGroupDef] {
        let language = SeedLanguage.seedLanguage
        return hierarchy.map { group in
            (
                name: group.term.value(for: language),
                color: group.color,
                children: group.children.map { child in
                    (name: child.term.value(for: language), icon: child.icon)
                }
            )
        }
    }
    
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

    /// 一级分类名称 → SF Symbol（用于种子数据和迁移）。
    /// 词条三语取值全部建键：老数据的简体名与新种子的繁体/英文名都能查到。
    static let parentIconMapping: [String: String] = {
        let groupIcons: [(SeedTerm, String)] = [
            (FinanceSeedVocabulary.dining, "cat_food"),
            (FinanceSeedVocabulary.transportation, "cat_transport"),
            (FinanceSeedVocabulary.shopping, "cat_shopping"),
            (FinanceSeedVocabulary.entertainment, "cat_entertain"),
            (FinanceSeedVocabulary.housing, "cat_housing"),
            (FinanceSeedVocabulary.healthcare, "cat_medical"),
            (FinanceSeedVocabulary.learning, "cat_learning"),
            (FinanceSeedVocabulary.socialGifts, "cat_relation"),
            (FinanceSeedVocabulary.other, "cat_other_exp"),
            (FinanceSeedVocabulary.investmentAndFinance, "cat_inc_invest"),
            (FinanceSeedVocabulary.salaryIncome, "cat_inc_salary"),
            (FinanceSeedVocabulary.socialIncome, "cat_inc_relation"),
            (FinanceSeedVocabulary.otherIncome, "cat_inc_other"),
        ]
        var mapping: [String: String] = [:]
        for (term, icon) in groupIcons {
            for name in term.allValues {
                mapping[name] = icon
            }
        }
        return mapping
    }()

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

        // 先固化种子语言再读层级：库里已有分类 = 老用户，其数据是简体种的，
        // 固化简体（否则补种逻辑按新语言再铺一套跨语言去重失效的分类）；
        // 空库 = 新用户，按当前 App 语言固化
        SeedLanguage.resolveSeedLanguage(hasExistingSeedData: !all.isEmpty)

        // 若已有二级分类，检查是否缺失分类并补充
        let hasSubCategory = all.contains { $0.parentId != nil }
        if hasSubCategory {
            seedMissingCategories(in: context, existing: all)
            return
        }

        // 无分类或仅有旧版扁平分类：补种完整层级（不删旧数据，旧交易仍指向旧分类）
        // 真正种了数据才记录种子时刻（SeedRevivalRepair 的老用户铁证判定基准）
        SeedRevivalRepair.recordSeedMoment()
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

    /// 系统内置分类（不可删除/编辑），名字按固化种子语言落库
    static var systemCategories: [(name: String, icon: String, color: String, type: String)] {
        [
            (
                FinanceSeedVocabulary.balanceAdjustment.value(for: .seedLanguage),
                "arrow.triangle.2.circlepath",
                "#94A3B8",
                "expense"
            )
        ]
    }

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

    // MARK: - 云同步重复修复

    /**
     修复「首启动种子 + CloudKit 恢复旧数据」并存造成的重复分类

     卸载重装后，首启动种子先写入本地，iCloud 随后把卸载前的分类同步回来，
     同名同类型的层级分类会出现两套。分类没有 createdAt，无法按创建时间区分，
     改用挂靠数据判定：种子行没有任何交易/子分类/预算/支出项目挂靠，
     用户在用的旧分类必然有挂靠。保留有挂靠的一行，重复行把数据改挂过去后删除。
     回收站里已软删的行不动，按回收规则自然过期。数据干净时零写入。
     */
    static func repairDuplicateCategories(in context: NSManagedObjectContext) {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.includesSubentities = false
        guard let all = try? context.fetch(request), !all.isEmpty else { return }

        // 先去重一级分类（重复的父级会带出整棵重复子树），把重复父级下的
        // 子分类 parentId 改挂到保留行；再去重二级分类时两套子分类才能归到同组。
        var didChange = dedupeCategories(
            all.filter { $0.parentId == nil },
            siblings: all,
            in: context
        )
        didChange = dedupeCategories(
            all.filter { $0.parentId != nil },
            siblings: all,
            in: context
        ) || didChange

        if didChange {
            try? context.save()
        }
    }

    /// 按（类型 + 名称 + 父级）分组去重，保留应留下的一行，其余改挂数据后删除
    private static func dedupeCategories(
        _ categories: [Category],
        siblings: [Category],
        in context: NSManagedObjectContext
    ) -> Bool {
        struct GroupKey: Hashable {
            let type: String
            let name: String
            let parentId: UUID?
        }

        var grouped: [GroupKey: [Category]] = [:]
        for category in categories {
            let key = GroupKey(type: category.type, name: category.name, parentId: category.parentId)
            grouped[key, default: []].append(category)
        }

        var didChange = false
        for group in grouped.values where group.count > 1 {
            let sorted = group.sorted { compareCanonical($0, $1, siblings: siblings, in: context) }
            let canonical = sorted[0]
            for duplicate in sorted.dropFirst() {
                repointCategoryAttachments(from: duplicate, to: canonical, siblings: siblings, in: context)
                context.delete(duplicate)
                didChange = true
            }
        }
        return didChange
    }

    /// 保留行排序：有挂靠数据 > 系统分类 > sortOrder 小 > id 稳定兜底
    private static func compareCanonical(
        _ lhs: Category,
        _ rhs: Category,
        siblings: [Category],
        in context: NSManagedObjectContext
    ) -> Bool {
        let lhsInUse = hasAttachments(lhs, siblings: siblings, in: context)
        let rhsInUse = hasAttachments(rhs, siblings: siblings, in: context)
        if lhsInUse != rhsInUse { return lhsInUse }
        if lhs.isSystem != rhs.isSystem { return lhs.isSystem }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// 分类是否有数据挂靠（交易关系 / 子分类 / 预算 / 支出项目）
    private static func hasAttachments(
        _ category: Category,
        siblings: [Category],
        in context: NSManagedObjectContext
    ) -> Bool {
        if let transactions = category.transactions, !transactions.isEmpty { return true }
        if siblings.contains(where: { $0.parentId == category.id }) { return true }

        let budgetRequest = Budget.fetchRequest()
        budgetRequest.predicate = NSPredicate(format: "categoryId == %@", category.id as CVarArg)
        budgetRequest.fetchLimit = 1
        if ((try? context.fetch(budgetRequest))?.isEmpty) == false { return true }

        let projectRequest = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
        projectRequest.predicate = NSPredicate(format: "categoryId == %@", category.id as CVarArg)
        projectRequest.fetchLimit = 1
        if ((try? context.fetch(projectRequest))?.isEmpty) == false { return true }

        return false
    }

    /// 把挂靠在重复分类上的数据改挂到保留行，删除后不留悬空引用
    private static func repointCategoryAttachments(
        from duplicate: Category,
        to canonical: Category,
        siblings: [Category],
        in context: NSManagedObjectContext
    ) {
        (duplicate.transactions ?? []).forEach { $0.category = canonical }
        siblings.filter { $0.parentId == duplicate.id }.forEach { $0.parentId = canonical.id }

        let budgetRequest = Budget.fetchRequest()
        budgetRequest.predicate = NSPredicate(format: "categoryId == %@", duplicate.id as CVarArg)
        (try? context.fetch(budgetRequest))?.forEach { $0.categoryId = canonical.id }

        let projectRequest = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
        projectRequest.predicate = NSPredicate(format: "categoryId == %@", duplicate.id as CVarArg)
        (try? context.fetch(projectRequest))?.forEach { $0.categoryId = canonical.id }
    }
}
