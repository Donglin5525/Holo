//
//  HabitReminderScheduler.swift
//  Holo
//
//  习惯打卡提醒滚动排期器
//  每个打卡型习惯可三态设置：follow=兜底汇总 / solo=单独时间 / none=不提醒。
//  两级开关：isEnabled 总开关关掉全部；fallbackEnabled 子开关只管 follow 组汇总，
//  关掉后 solo 习惯仍按自己的时间提醒。
//  follow 组在兜底时间收一条汇总（文案带 streak 连续数据）；
//  solo 组按习惯自己的时间各一条，不进汇总——同一习惯一天最多提醒一次。
//  当天已打卡的习惯不排；数值型没有「完成」语义、不参与提醒。
//

import Foundation
import UserNotifications
import OSLog

@MainActor
final class HabitReminderScheduler: RollingNotificationScheduler {

    static let shared = HabitReminderScheduler()

    private static let enabledKey = "holo.habitReminder.enabled"
    private static let fallbackEnabledKey = "holo.habitReminder.fallbackEnabled"
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

    /// 兜底汇总子开关：只管 follow 组；solo 组（单独时间）只受总开关门控
    var fallbackEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.fallbackEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.fallbackEnabledKey)
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
            Self.fallbackEnabledKey: true,
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
        let checkIns: [(habitId: UUID, name: String, streak: Int, completedToday: Bool, mode: HabitReminderMode, time: (hour: Int, minute: Int))] = repo.getActiveHabits()
            .filter { $0.isCheckInType }
            .map { habit in
                (habitId: habit.id,
                 name: habit.name,
                 streak: repo.calculateStreakInfo(for: habit).value,
                 completedToday: repo.isTodayCompleted(for: habit),
                 mode: habit.habitReminderMode,
                 time: habit.reminderTime)
            }
        guard !checkIns.isEmpty else { return [] }

        let calendar = Calendar.current
        let fallback = reminderTime

        var requests: [UNNotificationRequest] = []
        for offset in 0..<Self.rollingDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }

            // 今天按当前打卡进度快照（全打完 → 当天不排）；
            // 未来日无法预知进度，视为都未打卡，到点时没打就是没打
            let pending = offset == 0
                ? checkIns.filter { !$0.completedToday }
                : checkIns

            // solo 组：每个单独时间的习惯一条，按习惯自己的时刻滚动排；
            // 不进兜底汇总，「同一习惯一天最多提醒一次」由分组天然保证
            for item in pending where item.mode == .solo {
                var soloComps = calendar.dateComponents([.year, .month, .day], from: day)
                soloComps.hour = item.time.hour
                soloComps.minute = item.time.minute
                guard let fireDate = calendar.date(from: soloComps), fireDate > now else { continue }

                let soloContent = UNMutableNotificationContent()
                soloContent.title = "「\(item.name.holoTruncated())」还没打卡"
                soloContent.body = item.streak >= 2
                    ? "已连续 \(item.streak) 天，今天别断了"
                    : "今天记得打卡"
                soloContent.sound = .default
                soloContent.categoryIdentifier = TodoNotificationCategory.habitReminder

                requests.append(UNNotificationRequest(
                    identifier: "holo-habit-reminder-solo-\(item.habitId.uuidString)-\(Self.dayKey(day))",
                    content: soloContent,
                    trigger: UNCalendarNotificationTrigger(dateMatching: soloComps, repeats: false)
                ))
            }

            // follow 组：兜底时间一条汇总（沿用既有单/多习惯文案）；
            // 受 fallbackEnabled 子开关门控，关掉后 solo 习惯不受影响
            guard fallbackEnabled else { continue }
            let followers = pending.filter { $0.mode == .follow }
            guard let content = Self.reminderContent(
                pending: followers.map { (name: $0.name, streak: $0.streak) }
            ) else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = fallback.hour
            comps.minute = fallback.minute
            guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

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
