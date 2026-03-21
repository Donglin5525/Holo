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

/// 待办通知服务
@MainActor
class TodoNotificationService: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = TodoNotificationService()

    // MARK: - Published Properties

    @Published var isAuthorized = false
    @Published var isDenied = false

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
        content.categoryIdentifier = "TODO_TASK"
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
    }

    /// 为任务创建所有提醒
    func scheduleReminders(for task: TodoTask) {
        guard let dueDate = task.dueDate else { return }

        // 默认提醒时间
        let defaultReminders: [TaskReminder] = [
            TaskReminder(offsetMinutes: 1440), // 1 天前
            TaskReminder(offsetMinutes: 60),   // 1 小时前
            TaskReminder(offsetMinutes: 15)    // 15 分钟前
        ]

        Task {
            try? await scheduleReminder(for: task, reminders: defaultReminders)
        }
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

    /// 处理用户点击通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskId = response.notification.request.content.userInfo["taskId"] as? String

        if let taskId = taskId {
            // TODO: 可以触发打开任务详情的 deep link
            print("[TodoNotification] 用户点击了任务通知：\(taskId)")
        }

        completionHandler()
    }

    /// 设置代理
    func setupDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }
}
