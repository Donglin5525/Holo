//
//  BillDueReminderScheduler.swift
//  Holo
//
//  周期账单到期提醒（Plus 权益）
//  按各周期项目的下一期扣款日减提前量排一次性通知；文案在排程时固化，
//  财务数据变化 / App 活跃时按前缀清旧重排。账单到期不是每日滚动，
//  因此不继承 RollingNotificationScheduler，结构参照其模式独立实现。
//

import Foundation
import UserNotifications
import Combine
import OSLog

@MainActor
final class BillDueReminderScheduler {

    static let shared = BillDueReminderScheduler()

    private static let enabledKey = "holo.billDue.enabled"
    private static let advanceKey = "holo.billDue.advance"
    private static let hourKey = "holo.billDue.hour"
    private static let minuteKey = "holo.billDue.minute"

    /// 通知标识前缀（identifier 形如 holo.billDue.{projectId}），重排前按前缀清旧
    private static let identifierPrefix = "holo.billDue."

    private static let logger = Logger(subsystem: "com.holo.app", category: "BillDueReminder")

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            refresh()
        }
    }

    /// 提前量（天）：0 | 1 | 3
    var advance: Int {
        get { UserDefaults.standard.integer(forKey: Self.advanceKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.advanceKey)
            refresh()
        }
    }

    var reminderTime: (hour: Int, minute: Int) {
        get {
            (UserDefaults.standard.integer(forKey: Self.hourKey),
             UserDefaults.standard.integer(forKey: Self.minuteKey))
        }
        set {
            UserDefaults.standard.set(newValue.hour, forKey: Self.hourKey)
            UserDefaults.standard.set(newValue.minute, forKey: Self.minuteKey)
            refresh()
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.enabledKey: true,
            Self.advanceKey: 1,
            Self.hourKey: 9,
            Self.minuteKey: 0,
        ])

        NotificationCenter.default.publisher(for: .financeDataDidChange)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry Points

    /// App 启动 / 回到前台：按当前数据重排
    func handleAppActivity() async {
        await reschedule()
    }

    /// 设置变化 / 财务数据变化时调用
    func refresh() {
        Task { await reschedule() }
    }

    // MARK: - Schedule

    private func reschedule() async {
        let center = UNUserNotificationCenter.current()

        // 未授权 / 开关关闭 / 非 Plus：只清旧排期静默退出（权益变化靠下次数据变化或启动重排收敛）
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let requests = (isEnabled && authorized && HoloEntitlementState.shared.isPlusActive)
            ? makeRequests(now: Date())
            : []

        await removePendingRequests()

        guard !requests.isEmpty else { return }
        for request in requests {
            do {
                try await center.add(request)
            } catch {
                Self.logger.error("排账单提醒失败 \(request.identifier, privacy: .public)：\(error.localizedDescription)")
            }
        }
    }

    private func makeRequests(now: Date) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return [] }

        let time = reminderTime

        var requests: [UNNotificationRequest] = []
        for project in SpendingProjectRepository.shared.allProjects() {
            guard project.isRecurring,
                  !project.isPaused,
                  project.hasRemainingOccurrences,
                  let nextDue = project.nextOccurrenceDate else { continue }

            // 提醒日 = 扣款日 0 点 − 提前天数；今天或已过不追发（只排明天 0 点起）
            let dueDayStart = calendar.startOfDay(for: nextDue)
            guard let reminderDayStart = calendar.date(byAdding: .day, value: -advance, to: dueDayStart),
                  reminderDayStart >= tomorrowStart else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: reminderDayStart)
            comps.hour = time.hour
            comps.minute = time.minute

            let content = UNMutableNotificationContent()
            content.title = "\(project.name.holoTruncated())\(Self.dueOffsetText(advance))到期"
            content.body = "周期账单 \(Self.amountText(project.amountDecimal)) · \(Self.dueDateFormatter.string(from: dueDayStart))扣款，记得留足余额"
            content.sound = .default
            content.categoryIdentifier = TodoNotificationCategory.billDue

            requests.append(UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(project.id.uuidString)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            ))
        }
        return requests
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

    /// 扣款日在提醒时刻的相对表述（提醒日 = 扣款日 − advance，故相对天数即 advance）
    private static func dueOffsetText(_ days: Int) -> String {
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return "\(days)天后"
        }
    }

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static func amountText(_ amount: Decimal) -> String {
        NumberFormatter.currencyTrimmed.string(from: NSDecimalNumber(decimal: amount)) ?? ""
    }
}
