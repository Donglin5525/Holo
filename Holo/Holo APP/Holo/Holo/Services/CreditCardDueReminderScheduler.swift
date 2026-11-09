//
//  CreditCardDueReminderScheduler.swift
//  Holo
//
//  信用卡还款提醒（免费档限 3 张，超出 Plus）
//  每张开启提醒的信用卡按「当期还款日 − 提前天数」排一次性通知，每卡预排未来 2 期；
//  还款日计算与账户详情页倒计时同源（BillingCycleCalculator.dueDate，
//  含账单日 25 / 还款日 5 的跨月语义与 31 号小月 cap）。文案排程时固化，
//  财务数据变化 / App 活跃时按前缀清旧重排。结构参照 BillDueReminderScheduler。
//

import Foundation
import UserNotifications
import Combine
import OSLog

@MainActor
final class CreditCardDueReminderScheduler {

    static let shared = CreditCardDueReminderScheduler()

    /// 通知标识前缀（identifier 形如 holo.ccDue.{accountId}.{期次}），重排前按前缀清旧
    private static let identifierPrefix = "holo.ccDue."

    /// 提醒时刻（一期固定早上 9:00，与周期账单提醒默认时间一致）
    private static let reminderHour = 9

    private static let logger = Logger(subsystem: "com.holo.app", category: "CCDueReminder")

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 名额判定（UI 锁定态与排程共用同一口径，勿在视图里另写计数）

    /// 免费档可开启还款提醒的信用卡张数
    static let freeTierLimit = 3

    /// 当前已开启提醒的信用卡（未归档未软删，getAccounts 稳定排序）
    static func enabledReminderAccounts() -> [Account] {
        FinanceRepository.shared.getAccounts()
            .filter { $0.accountType.isCreditCard && $0.dueReminderEnabled }
    }

    /// 能否给某张卡开启提醒（会员短路 + 免费档名额判定）。
    /// - Parameter account: 目标卡；编辑一张已开启的卡时传它自己，判定时排除自身占位
    ///   （改提前天数不该被自己的名额挡住）。
    static func canEnableReminder(for account: Account? = nil) -> Bool {
        if HoloEntitlementState.shared.isPlusActive { return true }
        return freeQuotaAllows(for: account)
    }

    /// 名额判定（不含会员短路）：视图层需要「会员状态即时刷新 + 名额快照」
    /// 时用它，弹层场景避免 body 内每帧查库。
    static func freeQuotaAllows(for account: Account? = nil) -> Bool {
        freeQuotaAllows(for: account, enabledAccounts: enabledReminderAccounts())
    }

    /// 名额判定纯函数（单测入口）。已占前 3 名额的卡始终可编辑/关闭：
    /// Plus 过期后超额时，用户才能靠关掉其中一张腾出名额，否则全部卡死。
    static func freeQuotaAllows(for account: Account?, enabledAccounts: [Account]) -> Bool {
        if let account, enabledAccounts.prefix(freeTierLimit).contains(account) { return true }
        return enabledAccounts.filter { $0 != account }.count < freeTierLimit
    }

    /// 实际排程的卡：免费档只取前 3 张（超额配置保留、提醒暂停，续费恢复）
    static func schedulableAccounts(from enabledAccounts: [Account], isPlusActive: Bool) -> [Account] {
        isPlusActive ? enabledAccounts : Array(enabledAccounts.prefix(freeTierLimit))
    }

    private init() {
        // 账户自身写入由 Repository 显式 refresh；这里兜回收站恢复等走财务广播的路径
        NotificationCenter.default.publisher(for: .financeDataDidChange)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // 会员状态变化立即重排：续费恢复超额卡 / 过期降级到前 3 张
        HoloEntitlementState.shared.$isPlusActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry Points

    /// 打开还款提醒时补通知授权：未决定弹系统授权、已拒绝提示去系统设置开。
    /// 账户编辑页开关与详情页快捷开关共用。
    static func requestAuthorizationIfNeeded() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                _ = try? await TodoNotificationService.shared.requestAuthorization()
            case .denied:
                HoloToastCenter.shared.show(
                    String(localized: "通知权限已关闭，请在系统设置中开启后才能收到还款提醒"),
                    type: .info
                )
            default:
                break
            }
        }
    }

    /// App 启动 / 回到前台：按当前数据重排
    func handleAppActivity() async {
        await reschedule()
    }

    /// 提醒配置 / 账户数据变化时调用
    func refresh() {
        Task { await reschedule() }
    }

    // MARK: - Schedule

    private func reschedule() async {
        let center = UNUserNotificationCenter.current()

        // 未授权：只清旧排期静默退出（授权变化靠下次数据变化或启动重排收敛）
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional

        let requests = authorized ? makeRequests(now: Date()) : []

        await removePendingRequests()

        for request in requests {
            do {
                try await center.add(request)
            } catch {
                Self.logger.error("排信用卡还款提醒失败 \(request.identifier, privacy: .public)：\(error.localizedDescription)")
            }
        }

        let pendingCount = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
            .count
        Self.logger.notice("信用卡还款提醒重排完成：待发 \(pendingCount) 条")
    }

    /// 纯函数排程体：给定时间与账户列表产出的通知请求（单测入口）。
    /// 排程范围 = 本期 + 下一期各一条，防长期不开 App 漏排。
    static func makeRequests(now: Date, accounts: [Account]) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return [] }

        var requests: [UNNotificationRequest] = []
        for account in accounts {
            // 排程资格：开提醒 + 账单日/还款日齐全（开提醒的保存链路保证两天必写）
            guard account.dueReminderEnabled,
                  let billingDay = account.billingDayInt,
                  let dueDay = account.dueDayInt else { continue }
            let leadDays = account.dueReminderLeadDaysInt

            // 与账户详情页倒计时同源：本期周期起点 → 当期还款日，再排下一期
            let cycleRange = BillingCycleCalculator.currentCycleRange(startDay: billingDay, reference: now)
            let nextCycleStart = BillingCycleCalculator.shiftedCycleStart(cycleRange.start, startDay: billingDay, offset: 1)

            for (index, cycleStart) in [cycleRange.start, nextCycleStart].enumerated() {
                let dueDate = BillingCycleCalculator.dueDate(
                    billingDay: billingDay,
                    dueDay: dueDay,
                    cycleStart: cycleStart
                )
                let dueDayStart = calendar.startOfDay(for: dueDate)
                // 提醒日 = 还款日 0 点 − 提前天数；今天或已过不追发（只排明天 0 点起）
                guard let reminderDayStart = calendar.date(byAdding: .day, value: -leadDays, to: dueDayStart),
                      reminderDayStart >= tomorrowStart else { continue }

                var comps = calendar.dateComponents([.year, .month, .day], from: reminderDayStart)
                comps.hour = reminderHour
                comps.minute = 0

                // 插值只放简单变量：函数调用进插值抽取不出词条键，翻译会丢
                let cardName = account.name.holoTruncated()
                let offsetText = dueOffsetText(leadDays)
                let dueDateText = dueDateFormatter.string(from: dueDayStart)

                let content = UNMutableNotificationContent()
                content.title = String(localized: "\(cardName)\(offsetText)是还款日")
                content.body = String(localized: "还款日 \(dueDateText)，记得按时还款")
                content.sound = .default
                content.categoryIdentifier = TodoNotificationCategory.ccDue
                content.userInfo = ["accountId": account.id.uuidString]

                requests.append(UNNotificationRequest(
                    identifier: "\(identifierPrefix)\(account.id.uuidString).\(index)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                ))
            }
        }
        return requests
    }

    private func makeRequests(now: Date) -> [UNNotificationRequest] {
        Self.makeRequests(now: now, accounts: Self.schedulableAccounts(
            from: Self.enabledReminderAccounts(),
            isPlusActive: HoloEntitlementState.shared.isPlusActive
        ))
    }

    private func removePendingRequests() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Copy Helpers

    /// 还款日在提醒时刻的相对表述（提醒日 = 还款日 − leadDays，故相对天数即 leadDays）
    private static func dueOffsetText(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "今天")
        case 1: return String(localized: "明天")
        case 2: return String(localized: "后天")
        default: return String(localized: "\(days)天后")
        }
    }

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
