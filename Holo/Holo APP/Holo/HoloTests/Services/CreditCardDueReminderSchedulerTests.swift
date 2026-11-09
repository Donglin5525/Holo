//
//  CreditCardDueReminderSchedulerTests.swift
//  HoloTests
//
//  信用卡还款提醒：排程日期（与账户详情页倒计时同源）、免费 3 张名额、点击路由。
//

import XCTest
import CoreData
import UserNotifications
@testable import Holo

@MainActor
final class CreditCardDueReminderSchedulerTests: XCTestCase {

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

    // MARK: - Helpers

    private func makeCard(
        name: String = "测试卡",
        billingDay: Int? = 5,
        dueDay: Int? = 25,
        enabled: Bool = true,
        leadDays: Int16 = 1
    ) -> Account {
        let account = Account.create(in: context, name: name, type: AccountType.creditCard.rawValue)
        account.billingDay = billingDay.map { NSNumber(value: $0) }
        account.dueDay = dueDay.map { NSNumber(value: $0) }
        account.dueReminderEnabled = enabled
        account.dueReminderLeadDays = leadDays
        return account
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func fireTimes(_ requests: [UNNotificationRequest]) -> [String] {
        requests.map { request in
            let c = (request.trigger as! UNCalendarNotificationTrigger).dateComponents
            return "\(c.year!)-\(c.month!)-\(c.day!) \(c.hour!):\(c.minute!)"
        }
    }

    private func requests(_ card: Account, now: Date) -> [UNNotificationRequest] {
        CreditCardDueReminderScheduler.makeRequests(now: now, accounts: [card])
    }

    // MARK: - 模型默认值

    func test_newAccount_reminderOffByDefault_leadOneDay() async {
        let account = Account.create(in: context, name: "新卡", type: AccountType.creditCard.rawValue)
        XCTAssertFalse(account.dueReminderEnabled)
        XCTAssertEqual(account.dueReminderLeadDays, 1)
    }

    // MARK: - 排程日期

    func test_dueDay31_capsToFebruaryMonthEnd() async {
        let card = makeCard(billingDay: 5, dueDay: 31, leadDays: 1)
        // 本期还款日 1/31 已过；下一期还款日 cap 到 2/28，提前 1 天 = 2/27
        XCTAssertEqual(fireTimes(requests(card, now: date(2027, 2, 1))), ["2027-2-27 9:0"])
    }

    func test_dueBeforeBilling_fallsInNextMonth() async {
        let card = makeCard(billingDay: 25, dueDay: 5, leadDays: 1)
        // 11/9 所在周期从 10/25 起，本期还款日 11/5 已过；下一期 12/5，提前 1 天 = 12/4
        XCTAssertEqual(fireTimes(requests(card, now: date(2026, 11, 9))), ["2026-12-4 9:0"])
    }

    func test_matchesDetailPageCountdownDate() async {
        let now = date(2026, 11, 30)
        let card = makeCard(billingDay: 20, dueDay: 10, leadDays: 0)

        // 详情页倒计时的算法：本期周期起点 → 当期还款日
        let range = BillingCycleCalculator.currentCycleRange(startDay: 20, reference: now)
        let detailDue = BillingCycleCalculator.dueDate(billingDay: 20, dueDay: 10, cycleStart: range.start)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: detailDue)

        let times = fireTimes(requests(card, now: now))
        XCTAssertEqual(times.first, "\(c.year!)-\(c.month!)-\(c.day!) 9:0")
        XCTAssertEqual(times, ["2026-12-10 9:0", "2027-1-10 9:0"])
    }

    func test_leadDays_crossMonthBoundary() async {
        let card = makeCard(billingDay: 20, dueDay: 2, leadDays: 3)
        XCTAssertEqual(
            fireTimes(requests(card, now: date(2026, 11, 21))),
            ["2026-11-29 9:0", "2026-12-30 9:0"]
        )
    }

    func test_reminderDayIsToday_notResent() async {
        let card = makeCard(billingDay: 5, dueDay: 25, leadDays: 0)
        XCTAssertEqual(fireTimes(requests(card, now: date(2026, 11, 25))), ["2026-12-25 9:0"])
    }

    func test_skipsDisabledAndUnconfiguredCards() async {
        let disabled = makeCard(enabled: false)
        let noDueDay = makeCard(dueDay: nil)
        let noBillingDay = makeCard(billingDay: nil)
        XCTAssertTrue(CreditCardDueReminderScheduler.makeRequests(
            now: date(2026, 11, 9),
            accounts: [disabled, noDueDay, noBillingDay]
        ).isEmpty)
    }

    func test_eachCardSchedulesIndependently() async {
        let cardA = makeCard(name: "A卡")
        let cardB = makeCard(name: "B卡", enabled: false)
        let result = CreditCardDueReminderScheduler.makeRequests(now: date(2026, 11, 9), accounts: [cardA, cardB])

        XCTAssertFalse(result.isEmpty)
        for request in result {
            XCTAssertTrue(request.identifier.hasPrefix("holo.ccDue.\(cardA.id.uuidString)."))
            XCTAssertEqual(request.content.categoryIdentifier, TodoNotificationCategory.ccDue)
            XCTAssertEqual(request.content.userInfo["accountId"] as? String, cardA.id.uuidString)
        }
    }

    // MARK: - 免费 3 张名额

    func test_freeQuota_fourthCardBlocked_releasedAfterTurningOneOff() async {
        let cards = (0..<4).map { makeCard(name: "卡\($0)") }
        let enabledThree = Array(cards.prefix(3))

        XCTAssertFalse(CreditCardDueReminderScheduler.freeQuotaAllows(for: nil, enabledAccounts: enabledThree))
        XCTAssertFalse(CreditCardDueReminderScheduler.freeQuotaAllows(for: cards[3], enabledAccounts: enabledThree))
        XCTAssertTrue(CreditCardDueReminderScheduler.freeQuotaAllows(for: cards[0], enabledAccounts: enabledThree),
                      "已开启的卡编辑自己不该被自己的名额挡住")
        XCTAssertTrue(CreditCardDueReminderScheduler.freeQuotaAllows(for: cards[3], enabledAccounts: Array(cards.prefix(2))),
                      "关掉一张后名额释放")
    }

    func test_plusExpired_topThreeStayEditable_restPaused_resumeOnRenewal() async {
        let cards = (0..<5).map { makeCard(name: "卡\($0)") }

        XCTAssertTrue(CreditCardDueReminderScheduler.freeQuotaAllows(for: cards[1], enabledAccounts: cards),
                      "超额时前 3 张仍可改/关，否则用户无法腾名额")
        XCTAssertFalse(CreditCardDueReminderScheduler.freeQuotaAllows(for: cards[4], enabledAccounts: cards))
        XCTAssertEqual(CreditCardDueReminderScheduler.schedulableAccounts(from: cards, isPlusActive: false), Array(cards.prefix(3)))
        XCTAssertEqual(CreditCardDueReminderScheduler.schedulableAccounts(from: cards, isPlusActive: true), cards)
    }

    // MARK: - 点击路由

    func test_tapNotification_routesToAccountDetail() async {
        let accountId = UUID()
        DeepLinkState.shared.pendingTarget = nil

        let target = TodoNotificationService.routeDefaultActionTap(
            category: TodoNotificationCategory.ccDue,
            userInfo: ["accountId": accountId.uuidString]
        )

        XCTAssertEqual(target, "accountDetail")
        XCTAssertEqual(DeepLinkState.shared.pendingTarget, .accountDetail(accountId: accountId))
        DeepLinkState.shared.pendingTarget = nil
    }
}
