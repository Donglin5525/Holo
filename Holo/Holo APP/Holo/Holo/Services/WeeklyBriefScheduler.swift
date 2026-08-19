//
//  WeeklyBriefScheduler.swift
//  Holo
//
//  周一晨报滚动排期器
//  每周一早晨一条「上周小结」：完成任务数 · 打卡天数，有本周计划时带上第一条重点。
//  数据全部来自端上快照，通知里说的必然可兑现，不承诺未生成的内容（如 AI 回放）。
//  与 AI 回放周提醒同开时晨报优先：同日不再弹回放通知。
//

import Foundation
import CoreData
import UserNotifications
import OSLog

@MainActor
final class WeeklyBriefScheduler: RollingNotificationScheduler {

    static let shared = WeeklyBriefScheduler()

    private static let enabledKey = "holo.weeklyBrief.enabled"
    private static let hourKey = "holo.weeklyBrief.hour"
    private static let minuteKey = "holo.weeklyBrief.minute"
    /// 上周小结卡在今日看板内的「当天已关闭」标记
    static let cardDismissedDayKey = "holo.weeklyBrief.cardDismissedDay"

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
        // 默认开启：每周仅一条、数据速览必然可兑现，低打扰高价值
        UserDefaults.standard.register(defaults: [
            Self.enabledKey: true,
            Self.hourKey: 8,
            Self.minuteKey: 30,
        ])
        super.init(
            identifierPrefix: "holo-weekly-brief-",
            loggerCategory: "WeeklyBrief",
            dataChangeNotifications: [.todoDataDidChange, .habitDataDidChange]
        )
    }

    override func makeRequests(now: Date) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let time = reminderTime

        var requests: [UNNotificationRequest] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            // 周一（weekday == 2）触发
            guard calendar.component(.weekday, from: day) == 2 else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = time.hour
            comps.minute = time.minute
            guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

            // 上周没有任何记录时不排——没数据的小结只会消耗信任
            let summary = Self.lastWeekSummary(weekStartsAt: day)
            guard summary.completedTasks > 0 || summary.habitDays > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "上周小结 · 新的一周"
            content.body = Self.briefBody(summary: summary)
            content.sound = .default
            content.categoryIdentifier = TodoNotificationCategory.weeklyBrief

            requests.append(UNNotificationRequest(
                identifier: "holo-weekly-brief-\(Self.dayKey(day))",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            ))
        }
        return requests
    }

    /// 晨报与 AI 回放周提醒同开时晨报优先：移除与自己同触发日的回放通知
    override func didReschedule(scheduledRequests: [UNNotificationRequest]) async {
        guard !scheduledRequests.isEmpty else { return }
        let calendar = Calendar.current
        let briefDays = Set(scheduledRequests.map { request in
            (request.trigger as? UNCalendarNotificationTrigger).map { calendar.date(from: $0.dateComponents) ?? .distantPast }
        })

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let conflicts = pending.filter { request in
            guard request.content.categoryIdentifier == TodoNotificationCategory.memoryInsight,
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let fireDay = calendar.date(from: trigger.dateComponents) else { return false }
            return briefDays.contains(fireDay)
        }
        .map(\.identifier)
        if !conflicts.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: conflicts)
            logger.info("晨报优先：已移除同日 AI 回放周提醒 \(conflicts.count) 条")
        }
    }

    // MARK: - Summary

    /// 触发日（周一）之前 7 天的小结数据；通知文案与看板小结卡共用，保证口径一致
    static func lastWeekSummary(weekStartsAt day: Date) -> (completedTasks: Int, habitDays: Int, focus: String?) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let weekStart = calendar.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart

        // 上周完成的任务数
        let taskRequest = TodoTask.fetchRequest()
        taskRequest.predicate = NSPredicate(
            format: "completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO",
            weekStart as NSDate, dayStart as NSDate
        )
        let completedTasks = (try? CoreDataStack.shared.viewContext.count(for: taskRequest)) ?? 0

        // 上周有打卡记录的不同天数
        let records = HabitRepository.shared.getRecords(from: weekStart, to: dayStart)
        let habitDays = Set(records.map { calendar.startOfDay(for: $0.date) }).count

        // 触发日所在周的计划重点（周日晚生成的下周计划此时已可查到）
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: dayStart) ?? dayStart
        let focus = LifePlanRepository.shared
            .fetchPlans(periodStartIn: dayStart, weekEnd)
            .first?
            .priorities
            .sorted { $0.priorityRank < $1.priorityRank }
            .first?
            .outcome

        return (completedTasks, habitDays, focus)
    }

    static func briefBody(summary: (completedTasks: Int, habitDays: Int, focus: String?)) -> String {
        var body = "完成 \(summary.completedTasks) 件事 · 打卡 \(summary.habitDays) 天"
        if let focus = summary.focus, !focus.isEmpty {
            body += "｜本周重点：\(focus.holoTruncated(to: 14))"
        }
        return body
    }

    private static func dayKey(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: day)
    }
}
