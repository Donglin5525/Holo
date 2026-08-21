//
//  HoloAgentPauseNotifier.swift
//  Holo
//
//  Agent 执行状态可信信号 — 暂停对冲通知。
//
//  背景：iOS 26 Continued Processing 被系统收回执行权时，系统锁屏卡片只能以
//  setTaskCompleted(success: false) 的「失败样式」收场并永久留在锁屏上，
//  而用户任务实际是「已暂停、回前台自动继续」。两条信号矛盾且锁屏先入为主，
//  用户会把「容量暂停」读成「分析失败」（2026-08-21 20:07 事故）。
//
//  对冲手段：系统收回执行的瞬间（进程仍有数秒存活窗口）补发一条本地通知，
//  用准确术语直接否定失败读法。同一 job 的通知用固定 identifier 覆盖式更新，
//  反复息屏不会累积一串「暂停」通知。点击通知打开 App 后由 Chat 页兜底恢复拉起任务。
//

import Foundation
import UserNotifications

nonisolated enum HoloAgentPauseNotifier {

    private static let identifierPrefix = "holo.agent.pause."

    /// 暂停对冲通知。expiration 处理路径里同步投递（async fire-and-forget），
    /// 无通知权限时系统静默丢弃，不影响暂停落盘主流程。
    static func notifyPaused(
        jobID: String,
        reason: HoloAgentWaitReason,
        completedRounds: Int,
        totalRounds: Int
    ) {
        let content = UNMutableNotificationContent()
        content.title = "深度分析已暂停，未失败"
        let progress = totalRounds > 0 ? "已完成 \(completedRounds)/\(totalRounds) 轮，" : ""
        switch reason {
        case .systemCapacity, .backgroundTimeExpired:
            content.body = "系统暂时收回了后台执行时间。\(progress)点按回到 Holo 将自动继续分析。"
        case .deviceUnlock, .protectedData, .network:
            content.body = "\(progress)条件恢复后会自动继续分析。"
        case .userPaused, .inputChanged:
            content.body = "\(progress)回到 Holo 后可继续这次分析。"
        }
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: identifierPrefix + jobID,
            content: content,
            trigger: nil
        )
        // 立即投递（无 trigger）；identifier 按 job 固定，多轮暂停只保留最新一条。
        Task {
            let granted = await authorizationGranted()
            guard granted else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// job 到达终态（完成/真失败/取消）后清除可能残留的暂停通知，
    /// 避免「通知说暂停、卡片说完成」的新一轮矛盾。
    static func clearPausedNotice(jobID: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            let granted = await authorizationGranted()
            guard granted else { return }
            center.removePendingNotificationRequests(withIdentifiers: [identifierPrefix + jobID])
            center.removeDeliveredNotifications(withIdentifiers: [identifierPrefix + jobID])
        }
    }

    private static func authorizationGranted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
}
