//
//  MemoryInsightScheduleSettings.swift
//  Holo
//
//  AI 回放定时提醒设置
//  每周/月提醒用户生成回放，默认关闭
//

import Foundation
import Combine

@MainActor
final class MemoryInsightScheduleSettings: ObservableObject {

    static let shared = MemoryInsightScheduleSettings()

    private let defaults = UserDefaults.standard
    private let notificationService = MemoryInsightNotificationService()

    // MARK: - Keys

    private enum Keys {
        static let weeklyReminderEnabled = "memoryInsight_weeklyReminderEnabled"
        static let weeklyReminderWeekday = "memoryInsight_weeklyReminderWeekday"
        static let weeklyReminderHour = "memoryInsight_weeklyReminderHour"
        static let monthlyReminderEnabled = "memoryInsight_monthlyReminderEnabled"
        static let monthlyReminderDay = "memoryInsight_monthlyReminderDay"
        static let monthlyReminderHour = "memoryInsight_monthlyReminderHour"
        static let backgroundAutoGenerationEnabled = "memoryInsight_backgroundAutoGenerationEnabled"
    }

    // MARK: - Published Properties

    @Published var weeklyReminderEnabled: Bool {
        didSet {
            defaults.set(weeklyReminderEnabled, forKey: Keys.weeklyReminderEnabled)
            if weeklyReminderEnabled {
                notificationService.requestAuthorization { [weak self] granted in
                    if !granted {
                        Task { @MainActor in
                            self?.weeklyReminderEnabled = false
                        }
                    } else {
                        self?.scheduleWeeklyReminder()
                    }
                }
            } else {
                notificationService.cancelWeeklyReminder()
            }
        }
    }

    @Published var weeklyReminderWeekday: Int {
        didSet {
            defaults.set(weeklyReminderWeekday, forKey: Keys.weeklyReminderWeekday)
            if weeklyReminderEnabled { scheduleWeeklyReminder() }
        }
    }

    @Published var weeklyReminderHour: Int {
        didSet {
            defaults.set(weeklyReminderHour, forKey: Keys.weeklyReminderHour)
            if weeklyReminderEnabled { scheduleWeeklyReminder() }
        }
    }

    @Published var monthlyReminderEnabled: Bool {
        didSet {
            defaults.set(monthlyReminderEnabled, forKey: Keys.monthlyReminderEnabled)
            if monthlyReminderEnabled {
                notificationService.requestAuthorization { [weak self] granted in
                    if !granted {
                        Task { @MainActor in
                            self?.monthlyReminderEnabled = false
                        }
                    } else {
                        self?.scheduleMonthlyReminder()
                    }
                }
            } else {
                notificationService.cancelMonthlyReminder()
            }
        }
    }

    @Published var monthlyReminderDay: Int {
        didSet {
            defaults.set(monthlyReminderDay, forKey: Keys.monthlyReminderDay)
            if monthlyReminderEnabled { scheduleMonthlyReminder() }
        }
    }

    @Published var monthlyReminderHour: Int {
        didSet {
            defaults.set(monthlyReminderHour, forKey: Keys.monthlyReminderHour)
            if monthlyReminderEnabled { scheduleMonthlyReminder() }
        }
    }

    @Published var backgroundAutoGenerationEnabled: Bool {
        didSet {
            defaults.set(backgroundAutoGenerationEnabled, forKey: Keys.backgroundAutoGenerationEnabled)
        }
    }

    // MARK: - Init

    private init() {
        self.weeklyReminderEnabled = defaults.object(forKey: Keys.weeklyReminderEnabled) as? Bool ?? false
        self.weeklyReminderWeekday = defaults.object(forKey: Keys.weeklyReminderWeekday) as? Int ?? 2  // 周一
        self.weeklyReminderHour = defaults.object(forKey: Keys.weeklyReminderHour) as? Int ?? 9
        self.monthlyReminderEnabled = defaults.object(forKey: Keys.monthlyReminderEnabled) as? Bool ?? false
        self.monthlyReminderDay = defaults.object(forKey: Keys.monthlyReminderDay) as? Int ?? 1
        self.monthlyReminderHour = defaults.object(forKey: Keys.monthlyReminderHour) as? Int ?? 9
        self.backgroundAutoGenerationEnabled = defaults.object(forKey: Keys.backgroundAutoGenerationEnabled) as? Bool ?? false
    }

    // MARK: - Scheduling

    private func scheduleWeeklyReminder() {
        notificationService.scheduleWeeklyReminder(
            weekday: weeklyReminderWeekday,
            hour: weeklyReminderHour
        )
    }

    private func scheduleMonthlyReminder() {
        notificationService.scheduleMonthlyReminder(
            day: monthlyReminderDay,
            hour: monthlyReminderHour
        )
    }

    // MARK: - Display Helpers

    var weeklyReminderWeekdayName: String {
        let calendar = Calendar.current
        guard calendar.weekdaySymbols.indices.contains(weeklyReminderWeekday - 1) else {
            return "周一"
        }
        return calendar.weekdaySymbols[weeklyReminderWeekday - 1]
    }
}
