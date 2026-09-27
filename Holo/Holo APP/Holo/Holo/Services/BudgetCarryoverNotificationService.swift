//
//  BudgetCarryoverNotificationService.swift
//  Holo
//
//  严格预算模式 · 月初结转回执（2026-09-27 方案一期）
//
//  通知通道：排一条「下一个 1 号 09:00」的日历通知，内容为当前周期超支预估
//  （排期时点定格，财务数据变化即同标识符重排覆盖；无超支预估则移除待发）。
//  数字的实时准确性由看板横幅与预算详情页承担，通知只是入口——
//  排期后月末再记账导致的预估偏低属可接受窗口（超支只增不减）。
//
//  横幅通道：结转指纹 =（账户, 周期起点, 结转额）集合的稳定序列化；
//  指纹变化（新月结转生效）即新回执待读，已读标记 UserDefaults + iCloud 云备份。
//

import Foundation
import UserNotifications
import Combine
import OSLog

@MainActor
final class BudgetCarryoverNotificationService {

    static let shared = BudgetCarryoverNotificationService()

    static let categoryIdentifier = "TODO_BUDGET_CARRYOVER"
    private static let requestPrefix = "holo.budgetCarryover."
    private static let logger = Logger(subsystem: "com.holo.app", category: "BudgetCarryoverNotify")

    private var cancellables = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: .financeDataDidChange)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &cancellables)
    }

    // MARK: - Entry Points

    /// App 启动 / 回到前台：重排一次（授权或数据可能在后台期间变化）
    func handleAppActivity() async {
        reschedule()
    }

    func reschedule() {
        Task { await rescheduleAsync() }
    }

    private func rescheduleAsync() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional

        let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        var estimate = Decimal.zero
        var effectiveTotal = Decimal.zero
        for account in accounts {
            guard FinanceBudgetSettings.shared.isEnabled(for: account.id),
                  let budget = BudgetRepository.shared.getTotalBudget(forAccount: account.id, period: .month),
                  let status = BudgetRepository.shared.computeBudgetStatus(budget: budget) else {
                continue
            }
            // 结转判定与 BudgetRepository.carryoverDeduction 同口径：按上一期原始预算判定，
            // 此处是它在当前周期上的预估（spent − 原始额度，只取超出部分）
            estimate += max(0, status.spentAmount - status.budgetAmount)
            effectiveTotal += status.effectiveAmount
        }

        guard authorized, estimate > 0 else {
            Self.removePendingRequests(center: center)
            return
        }

        let fireDate = Self.nextCarryoverFireDate(after: Date())
        let content = UNMutableNotificationContent()
        content.title = String(localized: "上月超支已结转")
        content.body = String(localized: "上个月超支 \(Self.amountText(estimate))，本月预算额度已调整为 \(Self.amountText(effectiveTotal))。数字摆在这里，这个月我们一起对齐。")
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        // 标识符含目标周期：跨月后重排目标自动变为下下月，已触发的历史标识符不会被复活
        let request = UNNotificationRequest(
            identifier: Self.requestPrefix + Self.monthStamp(for: fireDate),
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
        } catch {
            Self.logger.error("结转回执通知排期失败：\(error.localizedDescription)")
        }
    }

    private static func removePendingRequests(center: UNUserNotificationCenter) {
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - 纯函数（单测入口）

    /// 下一个结转回执触发时刻：1 号 09:00。
    /// 当天恰为 1 号且未到 09:00 → 今天 09:00；否则下月 1 号 09:00。
    static func nextCarryoverFireDate(after date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        let todayAtNine = calendar.date(from: components) ?? date
        if calendar.isDate(date, equalTo: todayAtNine, toGranularity: .day), date < todayAtNine {
            return todayAtNine
        }
        let nextMonthFirst = calendar.date(
            byAdding: .month, value: 1,
            to: calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        ) ?? date
        var firstComponents = calendar.dateComponents([.year, .month], from: nextMonthFirst)
        firstComponents.day = 1
        firstComponents.hour = 9
        firstComponents.minute = 0
        return calendar.date(from: firstComponents) ?? date
    }

    /// 排期标识符的周期戳（yyyy-MM，指通知触发的那个月）
    static func monthStamp(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    /// 结转指纹：全部严格账户（预算ID, 周期起点, 结转额）的稳定序列化。
    /// 任一账户进入新周期或结转额变化 → 指纹变化 → 横幅重新展示；
    /// 空集合（无严格账户或全无结转）返回 nil = 无回执可读。
    static func carryoverFingerprint<S: Sequence>(
        _ entries: S
    ) -> String? where S.Element == (id: UUID, periodStart: Date, deduction: Decimal) {
        let carrying = entries
            .filter { $0.deduction > 0 }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !carrying.isEmpty else { return nil }
        return carrying
            .map { "\($0.id.uuidString)|\($0.periodStart.timeIntervalSince1970)|\($0.deduction)" }
            .joined(separator: ";")
    }

    // MARK: - 横幅已读标记

    private static let readKey = "financeBudget.strictMode.receiptReadFingerprint"
    nonisolated static let cloudBackupKey = "financeBudget.strictMode.receipt.read.v1"

    static func isReceiptRead(_ fingerprint: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: readKey) == fingerprint
    }

    /// 写入已读指纹；defaults/cloudSync 参数仅单测注入用
    static func setReceiptRead(_ fingerprint: String, defaults: UserDefaults = .standard, cloudSync: Bool = true) {
        defaults.set(fingerprint, forKey: readKey)
        // 云上行：已读状态随账户走，换机/重装不重弹旧回执
        if cloudSync {
            UserPreferenceRepository.shared.set(fingerprint, forKey: cloudBackupKey)
        }
    }

    func markReceiptRead(_ fingerprint: String) {
        Self.setReceiptRead(fingerprint)
    }

    /// 本次安装没读过任何回执时，从云端快照恢复（重装找回场景）
    @discardableResult
    func restoreFromCloudIfClean() -> Bool {
        if UserDefaults.standard.string(forKey: Self.readKey) != nil { return false }
        guard let restored = UserPreferenceRepository.shared.value(forKey: Self.cloudBackupKey),
              !restored.isEmpty else {
            return false
        }
        UserDefaults.standard.set(restored, forKey: Self.readKey)
        return true
    }

    // MARK: - Copy Helpers

    private static func amountText(_ amount: Decimal) -> String {
        NumberFormatter.compactCurrency(amount)
    }
}
