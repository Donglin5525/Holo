//
//  BillDueReminderScheduler.swift
//  Holo
//
//  订阅 / 周期支出到期提醒（免费档限 3 个，超出 Plus）
//  每条开启提醒的周期项目按「下次扣款日 − 单条提前天数」排一次性通知，每项预排未来 2 期；
//  财务数据变化 / 会员状态变化 / App 活跃时按前缀清旧重排。
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

    /// 通知标识前缀（identifier 形如 holo.billDue.{projectId}.{期次}），重排前按前缀清旧
    private static let identifierPrefix = "holo.billDue."

    private static let logger = Logger(subsystem: "com.holo.app", category: "BillDueReminder")

    private var cancellables = Set<AnyCancellable>()

    /// 免费档可开启到期提醒的订阅数量上限
    static let freeTierLimit = 3

    /// 支持的单条提前天数选项
    static let leadDayOptions: [Int32] = [0, 1, 3, 7]

    // MARK: - Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            refresh()
        }
    }

    /// 全局默认提前量（天）：0 | 1 | 3 | 7（新建订阅时作为默认值）
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

    // MARK: - 名额判定（UI 撞墙门禁与排程共用同一口径）

    /// 当前已开启提醒的活跃周期项目（未暂停、未软删、有剩余期次）
    static func enabledReminderProjects() -> [SpendingProject] {
        SpendingProjectRepository.shared.allProjects()
            .filter { $0.isRecurring && !$0.isPaused && $0.hasRemainingOccurrences && $0.reminderEnabled }
    }

    /// 能否给某条订阅开启提醒（会员短路 + 免费档名额判定）。
    static func canEnableReminder(for project: SpendingProject? = nil) -> Bool {
        if HoloEntitlementState.shared.isPlusActive { return true }
        return freeQuotaAllows(for: project)
    }

    static func freeQuotaAllows(for project: SpendingProject? = nil) -> Bool {
        freeQuotaAllows(for: project, enabledProjects: enabledReminderProjects())
    }

    /// 名额判定纯函数（单测入口）。已占前 3 名额的项目始终可编辑/关闭，防止 Plus 过期后死锁。
    static func freeQuotaAllows(for project: SpendingProject?, enabledProjects: [SpendingProject]) -> Bool {
        if let project, enabledProjects.prefix(freeTierLimit).contains(project) { return true }
        return enabledProjects.filter { $0 != project }.count < freeTierLimit
    }

    /// 实际排程的订阅列表：免费档只取前 3 个（超额配置保留、提醒暂停，续费恢复）
    static func schedulableProjects(from enabledProjects: [SpendingProject], isPlusActive: Bool) -> [SpendingProject] {
        isPlusActive ? enabledProjects : Array(enabledProjects.prefix(freeTierLimit))
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.enabledKey: true,
            Self.advanceKey: 3,
            Self.hourKey: 9,
            Self.minuteKey: 0,
        ])

        NotificationCenter.default.publisher(for: .financeDataDidChange)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        HoloEntitlementState.shared.$isPlusActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry Points

    /// 开启提醒时补通知授权
    static func requestAuthorizationIfNeeded() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                _ = try? await TodoNotificationService.shared.requestAuthorization()
            case .denied:
                HoloToastCenter.shared.show(
                    String(localized: "通知权限已关闭，请在系统设置中开启后才能收到到期提醒"),
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

    /// 设置变化 / 财务数据变化时调用
    func refresh() {
        Task { await reschedule() }
    }

    // MARK: - Schedule

    private func reschedule() async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let activeProjects = Self.schedulableProjects(
            from: Self.enabledReminderProjects(),
            isPlusActive: HoloEntitlementState.shared.isPlusActive
        )
        let requests = (isEnabled && authorized)
            ? Self.makeRequests(now: Date(), projects: activeProjects, reminderTime: reminderTime)
            : []

        await removePendingRequests()

        guard !requests.isEmpty else { return }
        for request in requests {
            do {
                try await center.add(request)
            } catch {
                Self.logger.error("排订阅提醒失败 \(request.identifier, privacy: .public)：\(error.localizedDescription)")
            }
        }
    }

    /// 纯函数排程体（单测入口）：每条开启提醒的订阅预排未来 2 期，防长期不开 App 漏排。
    static func makeRequests(
        now: Date,
        projects: [SpendingProject],
        reminderTime: (hour: Int, minute: Int) = (9, 0),
        calendar: Calendar = .current
    ) -> [UNNotificationRequest] {
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return [] }

        var requests: [UNNotificationRequest] = []
        for project in projects {
            guard project.isRecurring,
                  !project.isPaused,
                  project.reminderEnabled,
                  project.hasRemainingOccurrences,
                  let firstDue = project.nextOccurrenceDate else { continue }

            let leadDays = Int(max(0, project.reminderLeadDays))
            let frequency = project.resolvedFrequency
            let remainingCap: Int? = project.maxOccurrences > 0
                ? max(0, Int(project.maxOccurrences - project.occurrencesGenerated))
                : nil

            var dueDate = firstDue
            for periodIndex in 0..<2 {
                if let remainingCap, periodIndex >= remainingCap { break }
                if let endDate = project.endDate, dueDate > endDate { break }

                let dueDayStart = calendar.startOfDay(for: dueDate)
                if let reminderDayStart = calendar.date(byAdding: .day, value: -leadDays, to: dueDayStart),
                   reminderDayStart >= tomorrowStart {
                    var comps = calendar.dateComponents([.year, .month, .day], from: reminderDayStart)
                    comps.hour = reminderTime.hour
                    comps.minute = reminderTime.minute

                    let content = UNMutableNotificationContent()
                    content.title = Self.notificationTitle(name: project.name, leadDays: leadDays)
                    content.body = Self.notificationBody(
                        amount: project.amountDecimal,
                        frequency: frequency,
                        dueDay: dueDayStart,
                        autoGenerateTransaction: project.autoGenerateTransaction
                    )
                    content.sound = .default
                    content.categoryIdentifier = TodoNotificationCategory.billDue

                    requests.append(UNNotificationRequest(
                        identifier: "\(Self.identifierPrefix)\(project.id.uuidString).\(periodIndex)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    ))
                }

                guard let next = frequency.advancing(dueDate, by: 1, calendar: calendar) else { break }
                dueDate = next
            }
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

    static func notificationTitle(name: String, leadDays: Int) -> String {
        String(localized: "\(name.holoTruncated())\(dueOffsetText(leadDays))到期")
    }

    static func notificationBody(
        amount: Decimal,
        frequency: SpendingProjectFrequency,
        dueDay: Date,
        autoGenerateTransaction: Bool
    ) -> String {
        let amountStr = amountText(amount)
        let dateStr = dueDateFormatter.string(from: dueDay)
        if autoGenerateTransaction {
            return String(localized: "\(frequency.title) \(amountStr) · \(dateStr)自动续费并记账，可提前确认是否续订")
        } else {
            return String(localized: "\(frequency.title) \(amountStr) · \(dateStr)到期，记得确认是否续订或取消")
        }
    }

    /// 扣款日在提醒时刻的相对表述
    static func dueOffsetText(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "今天")
        case 1: return String(localized: "明天")
        case 2: return String(localized: "后天")
        default: return String(localized: "\(days)天后")
        }
    }

    static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func amountText(_ amount: Decimal) -> String {
        NumberFormatter.currencyTrimmed.string(from: NSDecimalNumber(decimal: amount)) ?? ""
    }
}
