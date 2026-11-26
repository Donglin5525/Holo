//
//  SubscriptionDueReminderTests.swift
//  HoloTests
//
//  覆盖固定支出订阅升级的核心纯逻辑：
//  1. 周 / 月 / 季 / 年四种周期的月均折算与日期推进
//  2. 到期提醒免费档限 3 个名额判定与 Plus 放行/降级
//  3. 单项目提前量（0/1/3/7 天）未来 2 期预排与自动记账/仅提醒文案区分
//

import XCTest
import CoreData
#if canImport(UIKit)
import UIKit
#endif
@testable import Holo

@MainActor
final class SubscriptionDueReminderTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        try await super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
    }

    override func tearDown() async throws {
        try? CoreDataTestSupport.clearAllEntities(context)
        context = nil
        try await super.tearDown()
    }

    // MARK: - 1. 多周期月均折算与日期推进

    func testFrequencyMonthlyAmountConversion() {
        XCTAssertEqual(SpendingProjectFrequency.monthly.monthlyAmount(from: 100), 100)
        XCTAssertEqual(SpendingProjectFrequency.quarterly.monthlyAmount(from: 90), 30)
        XCTAssertEqual(SpendingProjectFrequency.yearly.monthlyAmount(from: 1200), 100)
        // 周付：12 元/周 * 52 / 12 = 52 元/月
        XCTAssertEqual(SpendingProjectFrequency.weekly.monthlyAmount(from: 12), 52)
    }

    func testFrequencyAdvancingDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let base = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!

        let nextWeek = SpendingProjectFrequency.weekly.advancing(base, by: 1, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: nextWeek), DateComponents(year: 2026, month: 1, day: 22))

        let nextMonth = SpendingProjectFrequency.monthly.advancing(base, by: 1, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: nextMonth), DateComponents(year: 2026, month: 2, day: 15))

        let nextQuarter = SpendingProjectFrequency.quarterly.advancing(base, by: 1, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: nextQuarter), DateComponents(year: 2026, month: 4, day: 15))

        let nextYear = SpendingProjectFrequency.yearly.advancing(base, by: 1, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: nextYear), DateComponents(year: 2027, month: 1, day: 15))
    }

    // MARK: - 2. 免费 3 个提醒名额与 Plus 放行

    func testFreeTierQuotaAllowsUpToThreeAndBlocksFourth() {
        let p1 = makeProject(name: "Claude Pro", amount: 145)
        let p2 = makeProject(name: "Netflix", amount: 45)
        let p3 = makeProject(name: "iCloud+", amount: 21)
        let p4 = makeProject(name: "Spotify", amount: 30)

        // 已开 2 个，新项目允许
        XCTAssertTrue(BillDueReminderScheduler.freeQuotaAllows(for: nil, enabledProjects: [p1, p2]))
        // 已开 3 个，第 4 个拦截
        XCTAssertFalse(BillDueReminderScheduler.freeQuotaAllows(for: nil, enabledProjects: [p1, p2, p3]))
        XCTAssertFalse(BillDueReminderScheduler.freeQuotaAllows(for: p4, enabledProjects: [p1, p2, p3]))
        // 已占名额的前 3 个始终允许编辑/关闭
        XCTAssertTrue(BillDueReminderScheduler.freeQuotaAllows(for: p2, enabledProjects: [p1, p2, p3]))

        // 排程裁剪：免费只排前 3，Plus 全部排
        XCTAssertEqual(BillDueReminderScheduler.schedulableProjects(from: [p1, p2, p3, p4], isPlusActive: false).count, 3)
        XCTAssertEqual(BillDueReminderScheduler.schedulableProjects(from: [p1, p2, p3, p4], isPlusActive: true).count, 4)
    }

    // MARK: - 3. 未来 2 期预排与自动记账 / 仅提醒文案区分

    func testMakeRequestsSchedulesTwoPeriodsAndDistinguishesAutoBookCopy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
        let nextDue = calendar.date(from: DateComponents(year: 2026, month: 11, day: 29))!

        let autoBookSub = makeProject(
            name: "Claude Pro",
            amount: 145,
            frequency: .monthly,
            nextDue: nextDue,
            autoGenerate: true,
            reminderEnabled: true,
            leadDays: 3
        )
        let manualSub = makeProject(
            name: "Netflix",
            amount: 45,
            frequency: .monthly,
            nextDue: nextDue,
            autoGenerate: false,
            reminderEnabled: true,
            leadDays: 1
        )

        let requests = BillDueReminderScheduler.makeRequests(
            now: now,
            projects: [autoBookSub, manualSub],
            reminderTime: (9, 0),
            calendar: calendar
        )

        // 每条预排 2 期，共 4 条通知
        XCTAssertEqual(requests.count, 4)

        let claudeFirst = requests.first { $0.identifier.contains(autoBookSub.id.uuidString) && $0.identifier.hasSuffix(".0") }
        XCTAssertNotNil(claudeFirst)
        XCTAssertTrue(claudeFirst?.content.title.contains("3天后到期") == true)
        XCTAssertTrue(claudeFirst?.content.body.contains("自动续费并记账") == true)

        let netflixFirst = requests.first { $0.identifier.contains(manualSub.id.uuidString) && $0.identifier.hasSuffix(".0") }
        XCTAssertNotNil(netflixFirst)
        XCTAssertTrue(netflixFirst?.content.title.contains("明天到期") == true)
        XCTAssertTrue(netflixFirst?.content.body.contains("确认是否续订或取消") == true)
    }

    // MARK: - 4. 品牌图标目录与名称自动匹配

    func testBrandIconCatalogKeywordMatching() {
        XCTAssertEqual(SubscriptionBrandIconCatalog.match(for: "Claude Pro")?.id, "sub_claude")
        XCTAssertEqual(SubscriptionBrandIconCatalog.match(for: "网飞家庭组")?.id, "sub_netflix")
        XCTAssertEqual(SubscriptionBrandIconCatalog.match(for: "爱奇艺黄金会员")?.id, "sub_iqiyi")
        XCTAssertEqual(SubscriptionBrandIconCatalog.match(for: "iCloud+ 200GB")?.id, "sub_icloud")
        XCTAssertEqual(SubscriptionBrandIconCatalog.match(for: "B站大会员")?.id, "sub_bilibili")
        XCTAssertEqual(SubscriptionBrandIconCatalog.match(for: "淘宝88VIP")?.id, "sub_taobao88vip")
        XCTAssertNil(SubscriptionBrandIconCatalog.match(for: "房租"))
    }

    func testAllBrandIconsLoadableFromAssetCatalog() {
        XCTAssertEqual(SubscriptionBrandIconCatalog.all.count, 36)
        #if canImport(UIKit)
        for brand in SubscriptionBrandIconCatalog.all {
            XCTAssertNotNil(UIImage(named: brand.id), "Asset Catalog 缺少订阅品牌图标：\(brand.id)")
        }
        #endif
    }

    // MARK: - 5. 幂等同步防死循环回归（2026-11-26 财务卡死根治）

    func testSyncRecurringProjectsDoesNotPostNotificationWhenNothingChanged() throws {
        // 清空数据后连续调用两次 syncRecurringProjects，第二次无任何变更，不应发 .financeDataDidChange
        try SpendingProjectRepository.shared.syncRecurringProjects()

        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .financeDataDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try SpendingProjectRepository.shared.syncRecurringProjects()
        XCTAssertEqual(notificationCount, 0, "无变更时 syncRecurringProjects 不得广播 financeDataDidChange，否则会与视图监听形成主线程死循环")
    }

    // MARK: - Helpers

    private func makeProject(
        name: String,
        amount: Decimal,
        frequency: SpendingProjectFrequency = .monthly,
        nextDue: Date = Date().addingTimeInterval(86400 * 10),
        autoGenerate: Bool = true,
        reminderEnabled: Bool = true,
        leadDays: Int32 = 3
    ) -> SpendingProject {
        let project = SpendingProject(context: context)
        project.id = UUID()
        project.name = name
        project.kind = SpendingProjectKind.recurring.rawValue
        project.amount = NSDecimalNumber(decimal: amount)
        project.frequency = frequency.rawValue
        project.startDate = nextDue
        project.nextOccurrenceDate = nextDue
        project.isPaused = false
        project.autoGenerateTransaction = autoGenerate
        project.reminderEnabled = reminderEnabled
        project.reminderLeadDays = leadDays
        project.maxOccurrences = 0
        project.occurrencesGenerated = 0
        project.plannedLifespanDays = 0
        project.usageCount = 0
        project.usageDayCount = 0
        project.createdAt = Date()
        project.updatedAt = Date()
        return project
    }
}
