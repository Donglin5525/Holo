//
//  DailyBriefScheduler.swift
//  Holo
//
//  每日早报滚动排期器
//  每次滚动重排未来 7 天的早报，让文案带上当天任务摘要
//  （今天到期 / 已过期）。当天没有相关任务则不排——安静也是一种服务。
//

import Foundation
import UserNotifications
import OSLog

@MainActor
final class DailyBriefScheduler: RollingNotificationScheduler {

    static let shared = DailyBriefScheduler()

    private static let enabledKey = "holo.dailyBrief.enabled"
    private static let hourKey = "holo.dailyBrief.hour"
    private static let minuteKey = "holo.dailyBrief.minute"
    /// 旧「每日提醒」迁移标记：与 enabledKey 分开，区分「迁移后主动关掉」与「从未开启」
    private static let migratedKey = "holo.dailyBrief.migrated"
    private static let legacyDailyReminderId = "holo-daily-reminder"

    private static let rollingDays = 7
    private static let identifierPrefix = "holo-daily-brief-"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
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
        super.init(
            identifierPrefix: Self.identifierPrefix,
            loggerCategory: "DailyBrief",
            dataChangeNotifications: [.todoDataDidChange]
        )
    }

    override func onAppActivity() async {
        await migrateLegacyDailyReminderIfNeeded()
    }

    override func makeRequests(now: Date) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let time = reminderTime
        let tasks = TodoRepository.shared.activeTasks

        var requests: [UNNotificationRequest] = []
        for offset in 0..<Self.rollingDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = time.hour
            comps.minute = time.minute
            guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

            guard let brief = Self.briefContent(for: day, tasks: tasks) else { continue }

            let content = UNMutableNotificationContent()
            content.title = brief.title
            content.body = brief.body
            content.sound = .default
            content.categoryIdentifier = TodoNotificationCategory.dailyReminder

            requests.append(UNNotificationRequest(
                identifier: Self.identifierPrefix + Self.dayFormatter.string(from: day),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            ))
        }
        return requests
    }

    // MARK: - Migration

    /// 旧版「每日提醒」是一条 repeats 循环通知（固定废话文案）。
    /// 若仍存在：读出其时刻继承到早报并开启；无论是否存在都清掉残留。
    private func migrateLegacyDailyReminderIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        if let legacy = pending.first(where: { $0.identifier == Self.legacyDailyReminderId }),
           let trigger = legacy.trigger as? UNCalendarNotificationTrigger {
            defaults.set(true, forKey: Self.enabledKey)
            defaults.set(trigger.dateComponents.hour ?? 8, forKey: Self.hourKey)
            defaults.set(trigger.dateComponents.minute ?? 0, forKey: Self.minuteKey)
            logger.info("已迁移旧每日提醒为早报：\(trigger.dateComponents.hour ?? 8):\(trigger.dateComponents.minute ?? 0)")
        }
        center.removePendingNotificationRequests(withIdentifiers: [Self.legacyDailyReminderId])
    }

    // MARK: - Brief Content

    /// 生成某天的早报文案；当天既无「今天到期」也无「已过期」的未完成任务时返回 nil（不排）。
    /// 纯函数：输入当天日期与任务快照，便于测试。
    static func briefContent(for day: Date, tasks: [TodoTask]) -> (title: String, body: String)? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let open = tasks.filter { !$0.completed && !$0.deletedFlag }
        let dueToday = open.filter { task in
            guard let due = task.dueDate else { return false }
            return due >= dayStart && due < dayEnd
        }
        // 已过期：截至该日仍没完成（按排程时刻快照判断，未来完成会在下次重排时自然消失）
        let overdue = open.filter { task in
            guard let due = task.dueDate else { return false }
            return due < dayStart
        }
        .sorted { ($0.dueDate ?? dayStart) < ($1.dueDate ?? dayStart) }

        if dueToday.isEmpty && overdue.isEmpty { return nil }

        if !dueToday.isEmpty {
            // 「最要紧」= 当天最早截止
            let primary = dueToday.min { ($0.dueDate ?? dayEnd) < ($1.dueDate ?? dayEnd) }
            var body = ""
            if let primary {
                let name = primary.title.holoTruncated()
                if let due = primary.dueDate, !primary.isAllDay {
                    body = "最要紧：\(name)（\(timeFormatter.string(from: due)) 截止）"
                } else {
                    body = "最要紧：\(name)"
                }
            }
            if !overdue.isEmpty {
                body += " · \(overdue.count) 件已过期"
            } else if dueToday.count > 1 {
                body += " · 还有 \(dueToday.count - 1) 件"
            }
            return ("早上好，今天 \(dueToday.count) 件事", body)
        }

        // 只有过期任务
        let parts = overdue.prefix(2).map { task -> String in
            let dueStart = calendar.startOfDay(for: task.dueDate ?? dayStart)
            let days = max(1, calendar.dateComponents([.day], from: dueStart, to: dayStart).day ?? 1)
            return "「\(task.title.holoTruncated())」拖了 \(days) 天"
        }
        var body = parts.joined(separator: "、")
        if overdue.count > 2 {
            body += " 等 \(overdue.count) 件"
        }
        return ("\(overdue.count) 件任务已过期", body + "，今天清一件？")
    }

}
