//
//  RollingNotificationScheduler.swift
//  Holo
//
//  滚动通知排期基类：本地通知文案在排程时固化，无法随数据实时变化，
//  因此核心模式是「App 活跃 / 数据变化时，按前缀清理旧排期并滚动重排」。
//  每日早报 / 习惯提醒 / 周一晨报共用这套骨架，子类只提供排期内容。
//

import Foundation
import UserNotifications
import Combine
import OSLog

@MainActor
class RollingNotificationScheduler {

    let identifierPrefix: String
    let logger: Logger

    private var cancellables = Set<AnyCancellable>()

    init(
        identifierPrefix: String,
        loggerCategory: String,
        dataChangeNotifications: [Notification.Name] = []
    ) {
        self.identifierPrefix = identifierPrefix
        self.logger = Logger(subsystem: "com.holo.app", category: loggerCategory)

        for name in dataChangeNotifications {
            NotificationCenter.default.publisher(for: name)
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refresh()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Subclass Hooks

    /// 总开关（子类接设置存储；关闭时 reschedule 只清理不排期）
    var isEnabled: Bool { true }

    /// 生成本次要排的通知（子类实现；返回空 = 本次不排任何通知）
    func makeRequests(now: Date) -> [UNNotificationRequest] { [] }

    /// App 活跃钩子：一次性迁移等逻辑（子类可选实现）
    func onAppActivity() async {}

    /// 重排完成后的扩展点（如清理与新通知同日的冲突通知）
    func didReschedule(scheduledRequests: [UNNotificationRequest]) async {}

    // MARK: - Rolling Reschedule

    /// App 启动 / 回到前台：迁移钩子 + 滚动重排
    func handleAppActivity() async {
        await onAppActivity()
        await reschedule()
    }

    /// 设置变化 / 数据变化时调用
    func refresh() {
        Task { await reschedule() }
    }

    func reschedule() async {
        let center = UNUserNotificationCenter.current()

        // 权限未授权或开关关闭：清掉旧排期静默退出
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let requests = (isEnabled && authorized) ? makeRequests(now: Date()) : []

        // 清掉旧排期，按当前数据快照重排
        await removePendingRequests()

        guard !requests.isEmpty else { return }
        for request in requests {
            do {
                try await center.add(request)
            } catch {
                logger.error("排通知失败 \(request.identifier, privacy: .public)：\(error.localizedDescription)")
            }
        }
        await didReschedule(scheduledRequests: requests)
    }

    func removePendingRequests() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

// MARK: - Notification Text Helpers

extension String {
    /// 通知文案截断：任务/习惯名过长时截断，保证通知栏一行内可读
    func holoTruncated(to limit: Int = 12) -> String {
        count > limit ? String(prefix(limit)) + "…" : self
    }
}
