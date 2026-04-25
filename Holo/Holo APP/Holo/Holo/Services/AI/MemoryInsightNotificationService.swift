//
//  MemoryInsightNotificationService.swift
//  Holo
//
//  记忆洞察本地通知管理
//  负责请求权限、安排和取消周/月提醒通知
//

import Foundation
import UserNotifications
import os.log

final class MemoryInsightNotificationService {

    // MARK: - Notification Identifiers

    private enum Identifiers {
        static let weeklyReminder = "holo.memoryInsight.weeklyReminder"
        static let monthlyReminder = "holo.memoryInsight.monthlyReminder"
    }

    // MARK: - Authorization

    /// 请求通知权限
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// 检查当前通知权限状态
    func checkAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }

    // MARK: - Weekly Reminder

    /// 安排每周提醒
    /// - Parameters:
    ///   - weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
    ///   - hour: 小时 (0-23)
    func scheduleWeeklyReminder(weekday: Int, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = "本周记忆已准备好"
        content.body = "打开 Holo，让 AI 帮你生成一份本周回放。"
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.weekday = weekday
        dateComponents.hour = hour
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: Identifiers.weeklyReminder,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightNotification")
                logger.error("安排周提醒失败：\(error.localizedDescription)")
            }
        }
    }

    /// 取消每周提醒
    func cancelWeeklyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Identifiers.weeklyReminder])
    }

    // MARK: - Monthly Reminder

    /// 安排每月提醒
    /// - Parameters:
    ///   - day: 每月几号 (1-31)
    ///   - hour: 小时 (0-23)
    func scheduleMonthlyReminder(day: Int, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = "本月记忆已准备好"
        content.body = "打开 Holo，让 AI 帮你生成一份本月回放。"
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.day = day
        dateComponents.hour = hour
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: Identifiers.monthlyReminder,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightNotification")
                logger.error("安排月提醒失败：\(error.localizedDescription)")
            }
        }
    }

    /// 取消每月提醒
    func cancelMonthlyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Identifiers.monthlyReminder])
    }
}
