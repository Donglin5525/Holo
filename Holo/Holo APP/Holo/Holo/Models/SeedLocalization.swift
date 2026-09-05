//
//  SeedLocalization.swift
//  Holo
//
//  种子数据三语词表：新用户首启时按系统语言（zh-Hans / zh-Hant / en）种植对应语言的默认数据。
//
//  原则：
//  1. 落库值跟语言走——分类名这类数据会被展示和搜索，英文用户落 "Food & Drink"、
//     繁体用户落「餐飲」。取值方式是按 preferredLocalization 选三语常量，
//     不用 String(localized:)（那是 UI 查表，落库值会随系统语言漂移导致老数据错乱——
//     种下去那一刻是什么就是什么）。
//  2. 已落库的数据绝不重写：种子入口都有去重判断，已有就跳过。
//

import Foundation

// MARK: - 种子语言

/// App 声明的本地化语言（对应工程 knownRegions：zh-Hans / zh-Hant / en）
nonisolated enum SeedLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    private static let seedLanguageKey = "holo.seed.language.v1"

    /// 当前首选语言：preferredLocalizations 已在 App 声明的语言里按用户系统偏好
    /// 选好第一个；取不到或不认识时回退简体
    static var current: SeedLanguage {
        guard let code = Bundle.main.preferredLocalizations.first,
              let language = SeedLanguage(rawValue: code) else {
            return .simplifiedChinese
        }
        return language
    }

    /// 已固化的种子语言；未固化时按当前语言固化。
    /// 正常时序下由种子入口先调 resolveSeedLanguage(hasExistingSeedData:) 完成固化
    /// （种子入口知道库里有没有数据），这里是无数据上下文消费者的兜底读取。
    static var seedLanguage: SeedLanguage {
        resolveSeedLanguage(hasExistingSeedData: false)
    }

    /// 判定并固化种子语言（整个安装生命周期只判一次）：
    /// - 库里已有种子数据的老用户：其数据是简体种的，固化简体——
    ///   否则补种逻辑会按新语言把整套分类/账户再铺一遍（名字去重跨语言失效）；
    /// - 空库的新用户：按当前 App 语言固化，种下去那一刻是什么语言就是什么语言。
    static func resolveSeedLanguage(hasExistingSeedData: Bool) -> SeedLanguage {
        if let stored = UserDefaults.standard.string(forKey: seedLanguageKey),
           let language = SeedLanguage(rawValue: stored) {
            return language
        }
        let resolved: SeedLanguage = hasExistingSeedData ? .simplifiedChinese : .current
        UserDefaults.standard.set(resolved.rawValue, forKey: seedLanguageKey)
        return resolved
    }
}

// MARK: - 三语词条

/// 一条会落库的种子词条：三语各一份，按语言取值
nonisolated struct SeedTerm: Sendable {
    let hans: String
    let hant: String
    let english: String

    func value(for language: SeedLanguage) -> String {
        switch language {
        case .simplifiedChinese: return hans
        case .traditionalChinese: return hant
        case .english: return english
        }
    }

    /// 固化种子语言的落库值（种子定义处直接使用）。
    /// 用固化语言而非当前设备语言：种子数据是落库值，必须与库里的存量行同语言，
    /// 否则切换系统语言后会按新语言重复种植、按新名字查旧数据双双失配。
    var currentValue: String { value(for: SeedLanguage.seedLanguage) }

    /// 三语取值集合（按名字跨语言匹配用，如快速记账模板匹配用户库里的分类）
    var allValues: Set<String> { [hans, hant, english] }
}

// MARK: - 财务种子词表

/// 财务科目种子定名表（简 / 繁 / 英）。
/// 繁体按 OpenCC 字级转换手写（「转账」取台湾常用字「轉帳」），
/// 英文取常见财务科目 Title Case。
nonisolated enum FinanceSeedVocabulary {
    // ━━━━━━━━━━ 一级分类（支出 9 个） ━━━━━━━━━━
    static let dining = SeedTerm(hans: "餐饮", hant: "餐飲", english: "Food & Drink")
    static let transportation = SeedTerm(hans: "交通", hant: "交通", english: "Transportation")
    static let shopping = SeedTerm(hans: "购物", hant: "購物", english: "Shopping")
    static let entertainment = SeedTerm(hans: "娱乐", hant: "娛樂", english: "Entertainment")
    static let housing = SeedTerm(hans: "居住", hant: "居住", english: "Housing")
    static let healthcare = SeedTerm(hans: "医疗", hant: "醫療", english: "Healthcare")
    /// 支出层级的一级「学习」（英文按常用财务科目定名 Education）
    static let learning = SeedTerm(hans: "学习", hant: "學習", english: "Education")
    /// 支出层级的一级「人情」（红包/请客/送礼，英文定名 Social & Gifts 与「其他」组二级 Social 区分）
    static let socialGifts = SeedTerm(hans: "人情", hant: "人情", english: "Social & Gifts")
    /// 支出层级的兜底一级「其他」（「待分类」「余额调整」的挂靠父级）
    static let other = SeedTerm(hans: "其他", hant: "其他", english: "Other")
    static let otherExpense = SeedTerm(hans: "其他支出", hant: "其他支出", english: "Other Expenses")

    // ━━━━━━━━━━ 一级分类（收入 4 个） ━━━━━━━━━━
    static let investmentAndFinance = SeedTerm(hans: "投资理财", hant: "投資理財", english: "Investment")
    static let salaryIncome = SeedTerm(hans: "工资收入", hant: "工資收入", english: "Salary Income")
    /// 收入层级的一级「人情来往」（红包/礼物/中奖等）
    static let socialIncome = SeedTerm(hans: "人情来往", hant: "人情來往", english: "Social Income")
    static let otherIncome = SeedTerm(hans: "其他收入", hant: "其他收入", english: "Other Income")

    // ━━━━━━━━━━ 通用科目名（词表定名参考，多处共用） ━━━━━━━━━━
    static let education = SeedTerm(hans: "教育", hant: "教育", english: "Education")
    static let social = SeedTerm(hans: "社交", hant: "社交", english: "Social")
    static let travel = SeedTerm(hans: "旅行", hant: "旅行", english: "Travel")
    static let pets = SeedTerm(hans: "宠物", hant: "寵物", english: "Pets")
    static let salary = SeedTerm(hans: "工资", hant: "工資", english: "Salary")
    static let bonus = SeedTerm(hans: "奖金", hant: "獎金", english: "Bonus")
    static let investment = SeedTerm(hans: "投资", hant: "投資", english: "Investment")
    static let redEnvelope = SeedTerm(hans: "红包", hant: "紅包", english: "Red Envelope")
    static let transfer = SeedTerm(hans: "转账", hant: "轉帳", english: "Transfer")

    // ━━━━━━━━━━ 内置 catalog / 快速记账模板共用的二级科目 ━━━━━━━━━━
    static let breakfast = SeedTerm(hans: "早餐", hant: "早餐", english: "Breakfast")
    static let lunch = SeedTerm(hans: "午餐", hant: "午餐", english: "Lunch")
    static let dinner = SeedTerm(hans: "晚餐", hant: "晚餐", english: "Dinner")
    static let lateNightSnack = SeedTerm(hans: "夜宵", hant: "夜宵", english: "Late Night Snack")
    static let taxi = SeedTerm(hans: "打车", hant: "打車", english: "Taxi")
    static let subway = SeedTerm(hans: "地铁", hant: "地鐵", english: "Subway")
    static let bus = SeedTerm(hans: "公交", hant: "公交", english: "Bus")
    static let reimbursement = SeedTerm(hans: "报销", hant: "報銷", english: "Reimbursement")
    static let refund = SeedTerm(hans: "退款", hant: "退款", english: "Refund")
    static let clothing = SeedTerm(hans: "服饰", hant: "服飾", english: "Clothing")
    static let dailyNecessities = SeedTerm(hans: "日用", hant: "日用", english: "Daily Necessities")
    static let movies = SeedTerm(hans: "电影", hant: "電影", english: "Movies")

    // ━━━━━━━━━━ 系统分类 ━━━━━━━━━━
    /// 对账用的系统分类「余额调整」（ensureBalanceAdjustmentCategory 同词表查重）
    static let balanceAdjustment = SeedTerm(hans: "余额调整", hant: "餘額調整", english: "Balance Adjustment")
    /// 无法可靠归类时的兜底分类（ensurePendingCategory 按种子语言落库）
    static let pending = SeedTerm(hans: "待分类", hant: "待分類", english: "Uncategorized")
    static let needsReview = SeedTerm(hans: "待确认", hant: "待確認", english: "Needs Review")

    // ━━━━━━━━━━ 默认账户 ━━━━━━━━━━
    static let cash = SeedTerm(hans: "现金", hant: "現金", english: "Cash")
    /// 微信是品牌名，繁体同形
    static let weChatPay = SeedTerm(hans: "微信", hant: "微信", english: "WeChat Pay")
    static let alipay = SeedTerm(hans: "支付宝", hant: "支付寶", english: "Alipay")
    static let savingsCard = SeedTerm(hans: "储蓄卡", hant: "儲蓄卡", english: "Savings Card")
    static let creditCard = SeedTerm(hans: "信用卡", hant: "信用卡", english: "Credit Card")
}
