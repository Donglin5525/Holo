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
    private let dailyReminderId = "holo-daily-reminder"

    /// 任务完成回调（用于通知操作按钮）
    var onTaskComplete: ((UUID) -> Void)?
    /// 稍后提醒回调
    var onTaskSnooze: ((UUID) -> Void)?

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
            title: "✅ 完成任务",
            options: [.foreground]
        )

        let snoozeAction = UNNotificationAction(
            identifier: TodoNotificationAction.snooze.rawValue,
            title: "⏰ 15分钟后提醒",
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

        UNUserNotificationCenter.current().setNotificationCategories([taskCategory, dailyCategory])
        Self.logger.info("已注册通知分类")
    }

    // MARK: - Schedule Notifications

    /// 为任务创建提醒
    func scheduleReminder(for task: TodoTask, reminders: [TaskReminder]) async throws {
        guard isAuthorized else {
            throw TodoNotificationError.permissionDenied
        }

        guard let dueDate = task.dueDate else { return }

        for reminder in reminders {
            try await scheduleSingleReminder(
                task: task,
                reminder: reminder,
                dueDate: dueDate
            )
        }
    }

    /// 创建单个提醒
    private func scheduleSingleReminder(
        task: TodoTask,
        reminder: TaskReminder,
        dueDate: Date
    ) async throws {
        let calendar = Calendar.current
        guard let triggerDate = calendar.date(
            byAdding: .minute,
            value: -reminder.offsetMinutes,
            to: dueDate
        ) else { return }

        // 不创建已过期的提醒
        guard triggerDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "⏰ 任务提醒"
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

        let request = UNNotificationRequest(
            identifier: "\(task.id.uuidString)-\(reminder.offsetMinutes)",
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

    // MARK: - Daily Reminder

    /// 设置每日提醒
    /// - Parameters:
    ///   - hour: 小时 (0-23)
    ///   - minute: 分钟 (0-59)
    func scheduleDailyReminder(at hour: Int, minute: Int) async throws {
        guard isAuthorized else {
            throw TodoNotificationError.permissionDenied
        }

        // 先取消现有的每日提醒
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.title = "📋 今日待办"
        content.body = "查看今天的待办事项"
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.dailyReminder

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: dailyReminderId,
            content: content,
            trigger: trigger
        )

        try await UNUserNotificationCenter.current().add(request)
        Self.logger.info("已设置每日提醒：\(hour):\(String(format: "%02d", minute))")
    }

    /// 取消每日提醒
    func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [dailyReminderId]
        )
        Self.logger.info("已取消每日提醒")
    }

    /// 检查每日提醒是否已设置
    func isDailyReminderEnabled() async -> Bool {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.contains { $0.identifier == dailyReminderId }
    }

    /// 获取每日提醒时间
    func getDailyReminderTime() async -> (hour: Int, minute: Int)? {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard let request = requests.first(where: { $0.identifier == dailyReminderId }),
              let trigger = request.trigger as? UNCalendarNotificationTrigger else {
            return nil
        }
        let dateComponents = trigger.dateComponents
        return (dateComponents.hour ?? 9, dateComponents.minute ?? 0)
    }

    // MARK: - Test Notification

    /// 发送测试通知
    func sendTestNotification() async throws {
        guard isAuthorized else {
            throw TodoNotificationError.permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = "🔔 测试通知"
        content.body = "这是一条测试通知，通知功能正常工作"
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

        if !task.completed && !task.deletedFlag {
            try await scheduleReminder(for: task, reminders: reminders)
        }
    }

    // MARK: - Handle Notification Actions

    /// 处理任务完成操作
    func handleCompleteTask(taskId: UUID) {
        Self.logger.info("处理任务完成：\(taskId.uuidString)")
        onTaskComplete?(taskId)
    }

    /// 处理稍后提醒操作
    func handleSnoozeTask(taskId: UUID) {
        Self.logger.info("处理稍后提醒：\(taskId.uuidString)")
        onTaskSnooze?(taskId)

        // 创建15分钟后的新提醒
        Task {
            await scheduleSnoozeReminder(taskId: taskId)
        }
    }

    /// 创建稍后提醒
    private func scheduleSnoozeReminder(taskId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = "⏰ 任务提醒"
        content.body = "您设置的稍后提醒"
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
            return "请在设置中开启通知权限"
        case .authorizationFailed(let error):
            return "获取通知授权失败：\(error.localizedDescription)"
        case .scheduleFailed(let error):
            return "创建提醒失败：\(error.localizedDescription)"
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
            // 直接点击通知（打开应用）→ 触发 Deep Link 跳转到任务详情
            if let taskIdString = taskIdString, let taskId = UUID(uuidString: taskIdString) {
                Self.logger.info("用户点击了任务通知，触发 Deep Link：\(taskIdString)")
                DeepLinkState.shared.pendingTaskId = taskId
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
}
