//
//  ReceiptBookingNotificationService.swift
//  Holo
//
//  图片快捷指令自动记账 · 非阻塞结果通知（2026-09-14 完整方案 §22.1/§23.1/§30.2）
//  通知只是增强反馈：未授权/关闭时主流程完全不受影响（铁律 8）。
//  不在快捷指令后台运行时弹授权请求；授权入口在设置页开关。
//  点击通知走 Deep Link（通知只传 ID，不塞金额/商户正文进 userInfo）。
//

import Foundation
import UserNotifications
import os.log

@MainActor
final class ReceiptBookingNotificationService {

    static let shared = ReceiptBookingNotificationService()

    /// 通知分类标识（注册并入 TodoNotificationService 的分类数组）
    static let categoryIdentifier = "RECEIPT_BOOKING"

    /// 待复核提醒押后时长（东林 2026-09-16 拍板 5 分钟）：快捷指令会打开复核页，
    /// 用户当场确认就撤回提醒不再打扰；一直未确认才到点弹出来兜底。
    static let reviewReminderDelay: TimeInterval = 5 * 60

    /// 待复核提醒的稳定标识：绑定 draftID，确认/放弃草案时按此撤回
    /// （未投递的押后提醒 + 已投递挂在通知栏的旧提醒一并清掉）
    nonisolated static func reviewReminderIdentifier(for draftID: UUID) -> String {
        "receipt-booking-review-\(draftID.uuidString)"
    }

    /// 撤回某笔草案的待复核提醒（线程安全，可在任意隔离域调用）
    nonisolated static func cancelReviewReminders(for draftID: UUID) {
        let center = UNUserNotificationCenter.current()
        let identifier = reviewReminderIdentifier(for: draftID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private let logger = Logger(subsystem: "com.holo.app", category: "ReceiptBookingNotify")

    private init() {}

    /// 用户偏好（§30.2 receiptShortcutNotificationsEnabled）：默认开，关闭只影响通知不影响主流程
    static var isUserEnabled: Bool {
        UserDefaults.standard.object(forKey: "receiptShortcutNotificationsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "receiptShortcutNotificationsEnabled")
    }

    /// 设置页开关打开时请求系统授权（App 内前台触发，不在后台 Intent 里请求）
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    /// 识别记账结束后发送结果通知（授权/偏好不满足时静默跳过）
    /// - Parameter deferredReviewReminder: 本次快捷指令会把 Holo 打开到复核页时传 true，
    ///   待复核提醒押后 `reviewReminderDelay` 再投递，期间确认/放弃即撤回。
    func notifyIfNeeded(for outcome: ReceiptBookingOutcome, deferredReviewReminder: Bool = false) async {
        guard Self.isUserEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral else {
            return
        }

        guard let request = Self.makeRequest(for: outcome, deferredReviewReminder: deferredReviewReminder) else {
            // 拒识走快捷指令自身的结果展示、用户取消无提醒价值，均不打扰通知栏
            logger.info("skip notification for outcome: \(String(describing: outcome), privacy: .public)")
            return
        }
        try? await center.add(request)
    }

    /// 纯构造通知请求（不碰通知中心，供单测锁定标识/触发器行为）；nil = 不发通知
    nonisolated static func makeRequest(
        for outcome: ReceiptBookingOutcome,
        deferredReviewReminder: Bool
    ) -> UNNotificationRequest? {
        let content = UNMutableNotificationContent()
        content.sound = .default
        var userInfo: [String: String] = [:]

        switch outcome {
        case .booked(let receipt):
            content.title = String(localized: "已记账")
            content.body = receipt.summaryText
            content.categoryIdentifier = categoryIdentifier
            userInfo["transactionID"] = receipt.transactionID.uuidString
        case .duplicate(let receipt):
            content.title = String(localized: "这张图已经记过")
            content.body = receipt.summaryText
            content.categoryIdentifier = categoryIdentifier
            userInfo["transactionID"] = receipt.transactionID.uuidString
        case .needsReview(let snapshot):
            content.title = String(localized: "有一笔账需要你确认")
            // 2026-09-19 一图多笔：一张确认卡承载全部笔，聚合一条通知不按笔轰炸
            if snapshot.items.count > 1 {
                if let total = snapshot.uniformTotalAmountText {
                    content.body = String(localized: "识别到 \(snapshot.items.count) 笔支出，共 ¥\(total)，点按逐笔确认。")
                } else {
                    content.body = String(localized: "识别到 \(snapshot.items.count) 笔收支，点按逐笔确认。")
                }
            } else {
                let amountText = snapshot.primaryItem?.amountText ?? ""
                content.body = String(localized: "金额 \(amountText) 没有自动入账，点按查看。")
            }
            content.categoryIdentifier = categoryIdentifier
            userInfo["draftID"] = snapshot.draftID.uuidString
        case .rejected:
            return nil
        case .failed(let failure):
            guard failure.reason != .failureCancelled else { return nil }
            content.title = String(localized: "记账没有成功")
            content.body = String(localized: "截图仍在照片里，可稍后重试。")
            content.categoryIdentifier = categoryIdentifier
        }

        content.userInfo = userInfo

        // 押后提醒只对待复核生效；结果类通知（已记/重复/失败）一律立即投递
        if deferredReviewReminder, case .needsReview(let snapshot) = outcome {
            return UNNotificationRequest(
                identifier: reviewReminderIdentifier(for: snapshot.draftID),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: reviewReminderDelay, repeats: false)
            )
        }
        return UNNotificationRequest(
            identifier: "receipt-booking-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
    }
}
