//
//  WeeklyReviewScheduler.swift
//  Holo
//
//  每周回顾推送滚动排期器（2026-11-07 东林拍板 · 一期本地通知）
//
//  每周四 20:30 一条「本周回顾已生成」，点击直达每周回顾页。
//  与周一晨报并存：晨报是上周结算（周一早、落今日看板小结卡），周回顾是本周进行时
//  （周四晚、落独立回顾页），职责互补。
//
//  「有记录才推」在排期时刻判定：只排「尚未过去的本周四」，本周一以来四项足迹任一 > 0
//  才排；周四已过（周五及以后打开 App）本周不再排，等下一周打开时重新判定——本地通知
//  的资格与内容在排期瞬间固化，无法在触发前一刻重算（已知约束，设计文档 UC6）。
//

import Foundation
import CoreData
import UserNotifications
import OSLog

@MainActor
final class WeeklyReviewScheduler: RollingNotificationScheduler {
    static let shared = WeeklyReviewScheduler()

    private static let enabledKey = "holo.weeklyReview.enabled"
    /// 触发时刻（东林拍板周四 20:30，一期固定，不做时间选择器）
    private static let fireWeekday = 5   // 周四（1=周日 … 7=周六）
    private static let fireHour = 20
    private static let fireMinute = 30

    private let aggregator: WeeklyReviewAggregator

    override var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            refresh()
        }
    }

    private init(aggregator: WeeklyReviewAggregator = .shared) {
        // 默认开启：一周仅一条、仅对本周有足迹的用户发送，低打扰
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        self.aggregator = aggregator
        super.init(
            identifierPrefix: "holo-weekly-review-",
            loggerCategory: "WeeklyReview",
            dataChangeNotifications: [.financeDataDidChange, .todoDataDidChange, .habitDataDidChange]
        )
    }

    override func makeRequests(now: Date) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        // 只认「当前这周的周四」：跨到下周的周四数据资格无法预判（那周还没发生），不预排
        let currentWeekStart = WeeklyReviewMath.weekStart(containing: now, calendar: calendar)

        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            guard calendar.component(.weekday, from: day) == Self.fireWeekday else { continue }
            guard WeeklyReviewMath.weekStart(containing: day, calendar: calendar) == currentWeekStart else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = Self.fireHour
            comps.minute = Self.fireMinute
            guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

            // 本周（周一至排期时刻）没有任何足迹时不排——空回顾推送只会消耗信任
            let snapshot = aggregator.makeSnapshot(now: now, calendar: calendar)
            guard snapshot.current.hasAnyActivity else { continue }

            // 文案不带具体数字：本地通知内容在排期瞬间固化，到周四数字必然滞后失真
            let content = UNMutableNotificationContent()
            content.title = String(localized: "你的本周回顾已生成")
            content.body = String(localized: "这一周你留下的痕迹，都帮你整理好了")
            content.sound = .default
            content.categoryIdentifier = TodoNotificationCategory.weeklyReview

            return [UNNotificationRequest(
                identifier: "\(identifierPrefix)\(Self.dayKey(day))",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )]
        }
        return []
    }

    private static func dayKey(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: day)
    }
}
