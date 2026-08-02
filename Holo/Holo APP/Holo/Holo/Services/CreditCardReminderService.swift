//
//  CreditCardReminderService.swift
//  Holo
//
//  信用卡还款提醒服务 - 在账单日和还款日发送本地推送
//

import Foundation
import UserNotifications

/// 信用卡还款提醒服务
///
/// 复用系统的本地推送能力（UNUserNotificationCenter），在信用卡的账单日和还款日各发一条提醒。
/// 使用 `UNCalendarNotificationTrigger` 按每月几号重复。编辑信用卡时重新调度（先移除旧的再加新的）。
final class CreditCardReminderService {
    static let shared = CreditCardReminderService()
    private init() {}

    // MARK: - 公开方法

    /// 为信用卡账户调度还款提醒（账单日 + 还款日各一条）
    /// 仅对配置了账单日/还款日的信用卡账户生效，非信用卡或未配置的会被清除。
    func scheduleReminders(for account: Account) {
        // 先移除该账户所有旧提醒
        cancelReminders(for: account)

        guard account.accountType.isCreditCard, account.hasBillingCycle else { return }

        Task {
            // 未授权时只清不建，避免积累无效请求
            guard await isAuthorized else { return }

            let prefix = identifierPrefix(for: account)
            // 账单日提醒
            await scheduleMonthlyReminder(
                identifier: "\(prefix)-billing",
                title: "信用卡账单已出",
                body: "\(account.name) 本期账单已出，请查看账单详情",
                day: Int(account.billingDay),
                hour: 9
            )
            // 还款日提醒
            await scheduleMonthlyReminder(
                identifier: "\(prefix)-due",
                title: "信用卡还款日提醒",
                body: "\(account.name) 今天是还款日，请及时还款避免逾期",
                day: Int(account.dueDay),
                hour: 9
            )
        }
    }

    /// 取消指定账户的所有还款提醒
    func cancelReminders(for account: Account) {
        let prefix = identifierPrefix(for: account)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    // MARK: - 内部

    private var isAuthorized: Bool {
        get async {
            await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    continuation.resume(returning: settings.authorizationStatus == .authorized)
                }
            }
        }
    }

    private func identifierPrefix(for account: Account) -> String {
        "holo.creditcard.\(account.id.uuidString)"
    }

    /// 按每月几号重复的提醒
    private func scheduleMonthlyReminder(
        identifier: String,
        title: String,
        body: String,
        day: Int,
        hour: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // 每月指定日 09:00 重复
        var components = DateComponents()
        components.day = day
        components.hour = hour
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 推送注册失败不影响主流程
        }
    }
}
