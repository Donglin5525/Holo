//
//  HabitReminderScheduler.swift
//  Holo
//
//  习惯打卡提醒滚动排期器
//  每晚提醒「还有哪些习惯没打卡」，文案带 streak 连续数据。
//  当天已全部打卡则不弹（App 活跃时滚动重排自然取消）；
//  只提醒打卡型习惯，数值型没有「完成」语义、暂不提醒。
//

import Foundation
import UserNotifications
import OSLog

@MainActor
final class HabitReminderScheduler: RollingNotificationScheduler {

    static let shared = HabitReminderScheduler()

    private static let enabledKey = "holo.habitReminder.enabled"
    private static let hourKey = "holo.habitReminder.hour"
    private static let minuteKey = "holo.habitReminder.minute"
    private static let rollingDays = 7

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
        // 默认开启（2026-08-18 拍板）：触发条件克制——全完成/无打卡型习惯当天不弹
        UserDefaults.standard.register(defaults: [
            Self.enabledKey: true,
            Self.hourKey: 20,
            Self.minuteKey: 30,
        ])
        super.init(
            identifierPrefix: "holo-habit-reminder-",
            loggerCategory: "HabitReminder",
            dataChangeNotifications: [.habitDataDidChange]
        )
    }

    override func makeRequests(now: Date) -> [UNNotificationRequest] {
        let repo = HabitRepository.shared
        // streak 计算要回查记录，循环外一次性算好，逐日只做过滤
        let checkIns: [(name: String, streak: Int, completedToday: Bool)] = repo.getActiveHabits()
            .filter { $0.isCheckInType }
            .map { habit in
                (name: habit.name,
                 streak: repo.calculateStreakInfo(for: habit).value,
                 completedToday: repo.isTodayCompleted(for: habit))
            }
        guard !checkIns.isEmpty else { return [] }

        let calendar = Calendar.current
        let time = reminderTime

        var requests: [UNNotificationRequest] = []
        for offset in 0..<Self.rollingDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = time.hour
            comps.minute = time.minute
            guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

            // 今天按当前打卡进度快照（全打完 → 当天不排）；
            // 未来日无法预知进度，视为都未打卡，到点时没打就是没打
            let pending = offset == 0
                ? checkIns.filter { !$0.completedToday }
                : checkIns

            guard let content = Self.reminderContent(
                pending: pending.map { (name: $0.name, streak: $0.streak) }
            ) else { continue }

            let notificationContent = UNMutableNotificationContent()
            notificationContent.title = content.title
            notificationContent.body = content.body
            notificationContent.sound = .default
            notificationContent.categoryIdentifier = TodoNotificationCategory.habitReminder

            requests.append(UNNotificationRequest(
                identifier: "holo-habit-reminder-\(Self.dayKey(day))",
                content: notificationContent,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            ))
        }
        return requests
    }

    private static func dayKey(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: day)
    }

    /// 纯函数：pending 为空返回 nil（不排）
    static func reminderContent(pending: [(name: String, streak: Int)]) -> (title: String, body: String)? {
        guard !pending.isEmpty else { return nil }
        let byStreak = pending.sorted { $0.streak > $1.streak }

        let title = pending.count == 1
            ? "\(byStreak[0].name.holoTruncated())还没打卡"
            : "\(pending.count) 个习惯还没打卡"

        let body: String
        if pending.count == 1 {
            body = byStreak[0].streak >= 2
                ? "已连续 \(byStreak[0].streak) 天，今天别断了"
                : "睡前一分钟，完成今天的打卡"
        } else {
            let names = pending.prefix(2).map { $0.name.holoTruncated() }.joined(separator: "、")
            var text = pending.count > 2 ? "\(names) 等 \(pending.count) 个" : names
            if byStreak[0].streak >= 2 {
                text += " · \(byStreak[0].name.holoTruncated())已连续 \(byStreak[0].streak) 天"
            }
            body = text
        }
        return (title, body)
    }
}
