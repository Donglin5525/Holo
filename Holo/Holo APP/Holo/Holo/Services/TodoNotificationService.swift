//
//  TodoNotificationService.swift
//  Holo
//
//  待办模块通知服务
//  负责管理本地通知提醒
//

import Foundation
import UserNotifications
import Combine
import OSLog

// MARK: - Notification Category & Action Identifiers

enum TodoNotificationCategory {
    static let task = "TODO_TASK"
    static let dailyReminder = "DAILY_REMINDER"
    static let memoryInsight = "MEMORY_INSIGHT"
    static let anniversary = "ANNIVERSARY"
    static let goalRisk = "GOAL_RISK"
    static let habitReminder = "HABIT_REMINDER"
    static let weeklyBrief = "WEEKLY_BRIEF"
    static let billDue = "TODO_BILL_DUE"
    static let budgetOverrun = "TODO_BUDGET_OVERRUN"
}

enum TodoNotificationAction: String {
    case complete = "COMPLETE_TASK"
    case snooze = "SNOOZE_15"
}

/// 待办通知服务
@MainActor
class TodoNotificationService: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = TodoNotificationService()

    // MARK: - Published Properties

    @Published var isAuthorized = false
    @Published var isDenied = false

    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.holo.app", category: "TodoNotification")

    // MARK: - Initialization

    override init() {
        super.init()
        checkAuthorizationStatus()
    }

    // MARK: - Authorization

    /// 检查通知授权状态
    func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.isAuthorized = true
                    self.isDenied = false
                case .denied:
                    self.isAuthorized = false
                    self.isDenied = true
                case .notDetermined, .ephemeral:
                    self.isAuthorized = false
                    self.isDenied = false
                @unknown default:
                    self.isAuthorized = false
                    self.isDenied = false
                }
            }
        }
    }

    /// 请求通知授权
    func requestAuthorization() async throws -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            DispatchQueue.main.async {
                self.isAuthorized = granted
                self.isDenied = !granted
            }
            return granted
        } catch {
            throw TodoNotificationError.authorizationFailed(error)
        }
    }

    // MARK: - Register Categories

    /// 注册通知分类和操作按钮
    func registerNotificationCategories() {
        // 任务通知的操作按钮
        let completeAction = UNNotificationAction(
            identifier: TodoNotificationAction.complete.rawValue,
            title: String(localized: "✅ 完成任务"),
            options: [.foreground]
        )

        let snoozeAction = UNNotificationAction(
            identifier: TodoNotificationAction.snooze.rawValue,
            title: String(localized: "⏰ 延期15分钟"),
            options: []
        )

        let taskCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.task,
            actions: [completeAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )

        // 每日提醒分类（无操作按钮）
        let dailyCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.dailyReminder,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 洞察提醒分类（无操作按钮）
        let memoryInsightCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.memoryInsight,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 纪念日提醒分类（无操作按钮）
        let anniversaryCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.anniversary,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 目标风险提醒分类（无操作按钮，点击直达目标详情）
        let goalRiskCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.goalRisk,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 习惯打卡提醒（无操作按钮，点击直达习惯页）
        let habitReminderCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.habitReminder,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 周一晨报（无操作按钮，点击打开今日看板的上周小结卡）
        let weeklyBriefCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.weeklyBrief,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 周期账单到期提醒（无操作按钮，点击直达记一笔）
        let billDueCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.billDue,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // 预算超支提醒（无操作按钮，点击直达财务页）
        let budgetOverrunCategory = UNNotificationCategory(
            identifier: TodoNotificationCategory.budgetOverrun,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            taskCategory, dailyCategory, memoryInsightCategory,
            anniversaryCategory, goalRiskCategory, habitReminderCategory, weeklyBriefCategory,
            billDueCategory, budgetOverrunCategory
        ])
        Self.logger.info("已注册通知分类")
    }

    // MARK: - Schedule Notifications

    /// 为任务创建提醒
    func scheduleReminder(for task: TodoTask, reminders: [TaskReminder]) async throws {
        guard isAuthorized else {
            throw TodoNotificationError.permissionDenied
        }

        for reminder in reminders {
            // 绝对提醒（triggerDate）不需要 dueDate；相对提醒需要 dueDate 来推算
            if reminder.isAbsolute {
                try await scheduleSingleReminder(task: task, reminder: reminder, dueDate: nil)
            } else if let dueDate = task.dueDate {
                try await scheduleSingleReminder(task: task, reminder: reminder, dueDate: dueDate)
            }
        }
    }

    /// 创建单个提醒
    private func scheduleSingleReminder(
        task: TodoTask,
        reminder: TaskReminder,
        dueDate: Date?
    ) async throws {
        let calendar = Calendar.current

        // 计算触发时间：绝对模式直接用 triggerDate；相对模式用 dueDate - offsetMinutes
        let triggerDate: Date
        if let absoluteDate = reminder.triggerDate {
            triggerDate = absoluteDate
        } else {
            guard let dueDate = dueDate else { return }
            guard let calculated = calendar.date(
                byAdding: .minute,
                value: -reminder.offsetMinutes,
                to: dueDate
            ) else { return }
            triggerDate = calculated
        }

        // 不创建已过期的提醒
        guard triggerDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "⏰ 任务提醒")
        content.body = task.title
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.task
        content.userInfo = ["taskId": task.id.uuidString]

        let dateComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: false
        )

        // 用 reminder.id 作为唯一标识（绝对模式下 offsetMinutes 可能重复）
        let request = UNNotificationRequest(
            identifier: "\(task.id.uuidString)-\(reminder.id.uuidString)",
            content: content,
            trigger: trigger
        )

        try await UNUserNotificationCenter.current().add(request)
        Self.logger.info("已创建提醒：\(task.title) - \(reminder.displayTitle)")
    }

    /// 为任务创建所有提醒（使用任务存储的提醒设置）
    func scheduleReminders(for task: TodoTask) {
        let reminders = task.remindersArray
        guard !reminders.isEmpty else { return }

        Task {
            try? await scheduleReminder(for: task, reminders: reminders)
        }
    }

    // MARK: - Test Notification

    /// 发送测试通知
    func sendTestNotification() async throws {
        guard isAuthorized else {
            throw TodoNotificationError.permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "🔔 测试通知")
        content.body = String(localized: "这是一条测试通知，通知功能正常工作")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 2,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "test-notification",
            content: content,
            trigger: trigger
        )

        try await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Cancel Notifications

    /// 取消任务的所有提醒
    func cancelReminders(for task: TodoTask) async {
        let requestIdPrefix = task.id.uuidString
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()

        let taskRequestIds = requests
            .filter { $0.identifier.hasPrefix(requestIdPrefix) }
            .map { $0.identifier }

        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: taskRequestIds
        )
    }

    /// 删除任务时移除提醒
    func removeReminders(for task: TodoTask) {
        Task {
            await cancelReminders(for: task)
        }
    }

    // MARK: - Update Notifications

    /// 更新任务的提醒（先取消再重新创建）
    func updateReminders(for task: TodoTask, reminders: [TaskReminder]) async throws {
        await cancelReminders(for: task)

        if !task.completed && task.deletedAt == nil {
            try await scheduleReminder(for: task, reminders: reminders)
        }
    }

    // MARK: - Handle Notification Actions

    /// 处理任务完成操作：通知按钮的语义是「完成」——
    /// 循环任务按 UI 惯例生成下一实例，普通任务直接完成；
    /// 仓库负责保存、刷新列表并清除该任务的剩余提醒。
    func handleCompleteTask(taskId: UUID) {
        guard let task = TodoRepository.shared.findTask(by: taskId) else {
            Self.logger.warning("通知完成任务：任务不存在 \(taskId.uuidString)")
            return
        }
        do {
            if task.repeatRule != nil {
                _ = try TodoRepository.shared.completeRepeatingTask(task)
            } else {
                try TodoRepository.shared.completeTask(task)
            }
            Self.logger.info("通知完成任务成功：\(taskId.uuidString)")
        } catch {
            Self.logger.error("通知完成任务失败：\(error.localizedDescription)")
        }
    }

    /// 处理「延期15分钟」操作：真改截止时间（与 App 内延期同一落库路径，计数、提醒重排一致）。
    /// 无截止日（绝对提醒）或重复任务一期不接延期：退回纯贪睡，15 分钟后重发提醒。
    func handleSnoozeTask(taskId: UUID) {
        Self.logger.info("处理延期15分钟：\(taskId.uuidString)")

        Task { @MainActor in
            guard let task = TodoRepository.shared.findTask(by: taskId),
                  !task.completed, task.deletedAt == nil else { return }

            if task.dueDate != nil, task.repeatRule == nil,
               let newDate = Calendar.current.date(byAdding: .minute, value: 15, to: task.dueDate!) {
                do {
                    _ = try TodoRepository.shared.postpone(
                        task: task, toDate: newDate, isAllDay: task.isAllDay
                    )
                } catch {
                    Self.logger.error("通知延期失败：\(error.localizedDescription)")
                    await scheduleSnoozeReminder(taskId: taskId)
                }
            } else {
                await scheduleSnoozeReminder(taskId: taskId)
            }
        }
    }

    /// 创建稍后提醒
    private func scheduleSnoozeReminder(taskId: UUID) async {
        // 贪睡通知必须带任务名，否则用户不知道在提醒什么；
        // 任务已被完成或删除时不再打扰
        guard let task = TodoRepository.shared.findTask(by: taskId),
              !task.completed, task.deletedAt == nil else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "⏰ 稍后提醒")
        content.body = task.title
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.task
        content.userInfo = ["taskId": taskId.uuidString]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 15 * 60, // 15分钟
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "\(taskId.uuidString)-snooze",
            content: content,
            trigger: trigger
        )

        try? await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Notification Error

enum TodoNotificationError: LocalizedError {
    case permissionDenied
    case authorizationFailed(Error)
    case scheduleFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "请在设置中开启通知权限")
        case .authorizationFailed(let error):
            return String(localized: "获取通知授权失败：\(error.localizedDescription)")
        case .scheduleFailed(let error):
            return String(localized: "创建提醒失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenter Delegate

extension TodoNotificationService: UNUserNotificationCenterDelegate {

    /// 处理前台收到的通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 远程推送（云端分析完成）：前台时轮询每 5 秒领取结果，无需横幅打扰，静默即可；
        // 点按通知回前台的路径不受影响（scenePhase 恢复链自动领取）
        if notification.request.trigger is UNPushNotificationTrigger {
            completionHandler([])
            return
        }
        // 前台也显示横幅和声音
        completionHandler([.banner, .sound])
    }

    /// 处理用户点击通知或操作按钮
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let taskIdString = userInfo["taskId"] as? String

        switch response.actionIdentifier {
        case TodoNotificationAction.complete.rawValue:
            // 点击"完成任务"按钮
            if let taskIdString = taskIdString, let taskId = UUID(uuidString: taskIdString) {
                handleCompleteTask(taskId: taskId)
            }

        case TodoNotificationAction.snooze.rawValue:
            // 点击"15分钟后提醒"按钮
            if let taskIdString = taskIdString, let taskId = UUID(uuidString: taskIdString) {
                handleSnoozeTask(taskId: taskId)
            }

        case UNNotificationDefaultActionIdentifier:
            // 直接点击通知（打开应用）→ 按 category 触发对应的 Deep Link
            let category = response.notification.request.content.categoryIdentifier
            switch category {
            case TodoNotificationCategory.task:
                if let taskIdString = taskIdString, let taskId = UUID(uuidString: taskIdString) {
                    Self.logger.info("任务通知 Deep Link：\(taskIdString)")
                    DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
                }
            case TodoNotificationCategory.dailyReminder:
                Self.logger.info("每日提醒 Deep Link")
                DeepLinkState.shared.navigate(to: .dailyReminder)
            case TodoNotificationCategory.memoryInsight:
                Self.logger.info("洞察通知 Deep Link")
                let period = WeeklyObservationPeriod.previousCompletedWeek(containing: Date())
                // 不在此处 markRead：已读由 ChatView 打开回放卡片时落（与首页胶囊同口径），
                // 点通知没看到内容时胶囊仍在。
                if let insight = try? MemoryInsightRepository().fetchInsight(
                    periodType: .weekly,
                    start: period.start,
                    end: period.end
                ) {
                    DeepLinkState.shared.navigate(to: .memoryInsight(insightId: insight.id))
                } else {
                    DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false))
                }
            case TodoNotificationCategory.goalRisk:
                if let goalIdString = userInfo["goalId"] as? String, let goalId = UUID(uuidString: goalIdString) {
                    Self.logger.info("目标风险通知 Deep Link：\(goalIdString)")
                    DeepLinkState.shared.navigate(to: .goalDetail(goalId: goalId))
                }
            case TodoNotificationCategory.anniversary:
                if let anniversaryIdString = userInfo["anniversaryId"] as? String,
                   let anniversaryId = UUID(uuidString: anniversaryIdString) {
                    Self.logger.info("纪念日通知 Deep Link：\(anniversaryIdString)")
                    DeepLinkState.shared.navigate(to: .anniversaryDetail(anniversaryId: anniversaryId))
                }
            case TodoNotificationCategory.habitReminder:
                Self.logger.info("习惯提醒 Deep Link")
                DeepLinkState.shared.navigate(to: .habits)
            case TodoNotificationCategory.weeklyBrief:
                Self.logger.info("周一晨报 Deep Link")
                DeepLinkState.shared.navigate(to: .weeklyBrief)
            case TodoNotificationCategory.billDue:
                Self.logger.info("账单到期通知 Deep Link")
                DeepLinkState.shared.navigate(to: .addTransaction)
            case TodoNotificationCategory.budgetOverrun:
                Self.logger.info("预算超支通知 Deep Link")
                DeepLinkState.shared.navigate(to: .finance)
            default:
                break
            }

        default:
            break
        }

        completionHandler()
    }

    /// 设置代理
    func setupDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - 纪念日提醒

    /// 纪念日通知的纯值快照（不依赖 Core Data 上下文，跨线程安全）
    struct AnniversaryReminderPayload {
        let id: UUID
        let title: String
        let date: Date
        let repeatYearly: Bool
        let isLunar: Bool
        let reminderDaysBefore: Int16
        let reminderEnabled: Bool
        /// 自原始日期至今的总天数（里程碑通知用）
        let totalDaysSinceStart: Int

        init(_ a: Anniversary) {
            id = a.id
            title = a.title
            date = a.date
            repeatYearly = a.repeatYearly
            isLunar = a.isLunar
            reminderDaysBefore = a.reminderDaysBefore
            reminderEnabled = a.reminderEnabled
            totalDaysSinceStart = a.totalDaysSinceStart
        }
    }

    /// 为一条纪念日排全部通知：提醒（可选）+ 里程碑（默认开启）
    func scheduleAnniversaryNotifications(for payload: AnniversaryReminderPayload) async {
        await scheduleAnniversaryReminder(for: payload)
        scheduleAnniversaryMilestone(for: payload)
    }

    /// 取消一条纪念日的全部通知（提醒 + 里程碑）
    func cancelAnniversaryNotifications(for anniversaryId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [anniversaryReminderId(anniversaryId), anniversaryMilestoneId(anniversaryId)]
        )
        Self.logger.info("已取消纪念日通知：\(anniversaryId)")
    }

    /// 为纪念日调度本地通知。
    /// - 每年重复（公历）：按 DateComponents(month, day) 排一条每年触发的通知
    /// - 每年重复（农历）：农历日期每年对应的公历日不同，排一次性通知，由冷启动全量重排兜底
    /// - 不重复：按具体日期排一条一次性通知
    func scheduleAnniversaryReminder(for payload: AnniversaryReminderPayload) async {
        guard payload.reminderEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current

        // 每年重复时取下一个周年（农历按农历月日推算）；否则取原始日期
        let baseDate: Date
        if payload.repeatYearly {
            baseDate = payload.isLunar
                ? ChineseLunarCalendar.nextLunarOccurrence(of: payload.date, onOrAfter: Date())
                : Self.nextYearlyOccurrence(of: payload.date)
        } else {
            baseDate = payload.date
        }
        let baseComp = calendar.dateComponents([.year, .month, .day], from: baseDate)

        // 提前 N 天的触发日期
        let triggerOffset = -Int(payload.reminderDaysBefore)
        guard let rawTrigger = calendar.date(from: baseComp),
              let triggerDate = calendar.date(byAdding: .day, value: triggerOffset, to: rawTrigger) else { return }
        // 若触发日已过，不排（避免立即触发历史通知）
        guard triggerDate > Date() else { return }

        let triggerComp = calendar.dateComponents([.year, .month, .day, .hour], from: triggerDate)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        if payload.reminderDaysBefore == 0 {
            content.body = payload.repeatYearly ? String(localized: "今天是\(payload.title)") : String(localized: "\(payload.title) 就是今天")
        } else {
            content.body = String(localized: "\(payload.title) 还有 \(payload.reminderDaysBefore) 天后")
        }
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.anniversary
        content.userInfo = ["anniversaryId": payload.id.uuidString]

        if payload.repeatYearly && !payload.isLunar {
            // 每年重复（公历）：只取 month/day/hour，repeats=true
            var repeatComp = DateComponents()
            repeatComp.month = triggerComp.month
            repeatComp.day = triggerComp.day
            repeatComp.hour = triggerComp.hour ?? 9
            let trigger = UNCalendarNotificationTrigger(dateMatching: repeatComp, repeats: true)
            let request = UNNotificationRequest(identifier: anniversaryReminderId(payload.id), content: content, trigger: trigger)
            do {
                try await center.add(request)
                Self.logger.info("已调度每年重复纪念日通知：\(payload.title)")
            } catch {
                Self.logger.error("调度纪念日通知失败：\(error.localizedDescription)")
            }
        } else {
            // 不重复 / 农历重复：一次性通知（农历每年公历日不同，冷启动全量重排兜底）
            let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComp, repeats: false)
            let request = UNNotificationRequest(identifier: anniversaryReminderId(payload.id), content: content, trigger: trigger)
            do {
                try await center.add(request)
                Self.logger.info("已调度纪念日通知：\(payload.title)")
            } catch {
                Self.logger.error("调度纪念日通知失败：\(error.localizedDescription)")
            }
        }
    }

    /// 里程碑通知：只排「下一个里程碑」当天 9:00 一条（100/365/520/1000/2000/3650 天）。
    /// 一次性通知，由冷启动全量重排滚动续排。
    private func scheduleAnniversaryMilestone(for payload: AnniversaryReminderPayload) {
        let info = AnniversaryMilestoneInfo(totalDays: payload.totalDaysSinceStart)
        guard let threshold = info.nextThreshold else { return }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: payload.date)
        guard let milestoneDay = calendar.date(byAdding: .day, value: threshold, to: start),
              milestoneDay > Date() else { return }

        var comps = calendar.dateComponents([.year, .month, .day], from: milestoneDay)
        comps.hour = 9

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = String(localized: "今天是「\(payload.title)」的第 \(threshold) 天 ✦")
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.anniversary
        content.userInfo = ["anniversaryId": payload.id.uuidString]

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: anniversaryMilestoneId(payload.id), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        Self.logger.info("已调度里程碑通知：\(payload.title) 第\(threshold)天")
    }

    /// 计算某日期在未来的下一个周年（含今年未到的）
    static func nextYearlyOccurrence(of date: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let originalDay = calendar.startOfDay(for: date)
        let origComp = calendar.dateComponents([.month, .day], from: originalDay)
        let nowYear = calendar.dateComponents([.year], from: Date()).year ?? 0

        var comp = DateComponents()
        comp.year = nowYear
        comp.month = origComp.month
        comp.day = origComp.day
        guard let thisYear = calendar.date(from: comp) else { return originalDay }
        if calendar.startOfDay(for: thisYear) >= today {
            return thisYear
        }
        comp.year = nowYear + 1
        return calendar.date(from: comp) ?? originalDay
    }

    /// 纪念日通知 ID
    private func anniversaryReminderId(_ id: UUID) -> String {
        "holo-anniversary-\(id.uuidString)"
    }

    /// 纪念日里程碑通知 ID
    private func anniversaryMilestoneId(_ id: UUID) -> String {
        "holo-anniversary-milestone-\(id.uuidString)"
    }
}
