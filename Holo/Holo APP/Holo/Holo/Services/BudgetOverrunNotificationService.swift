//
//  BudgetOverrunNotificationService.swift
//  Holo
//
//  预算超支提醒（免费）
//  财务数据变化 / App 活跃时即时检查：预算新进入超支且未提醒过 → 发一条即时通知；
//  回到线内清「已提醒」标记（再超再提醒），叠加「每日全局最多 1 条」防轰炸。
//

import Foundation
import UserNotifications
import Combine
import OSLog

@MainActor
final class BudgetOverrunNotificationService {

    static let shared = BudgetOverrunNotificationService()

    private static let enabledKey = "holo.budgetOverrun.enabled"
    /// 每预算「已提醒超支」标记前缀，完整 key 形如 holo.budgetOverrun.state.{budgetId}
    private static let stateKeyPrefix = "holo.budgetOverrun.state."
    /// 每日全局 1 条的上次发送日（yyyy-MM-dd）
    private static let lastGlobalDayKey = "holo.budgetOverrun.lastGlobalDay"

    private static let logger = Logger(subsystem: "com.holo.app", category: "BudgetOverrunNotify")

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            refresh()
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])

        NotificationCenter.default.publisher(for: .financeDataDidChange)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry Points

    /// App 启动 / 回到前台：检查一次
    func handleAppActivity() async {
        await checkAndNotify()
    }

    /// 设置变化 / 财务数据变化时调用
    func refresh() {
        Task { await checkAndNotify() }
    }

    // MARK: - Check & Notify

    func checkAndNotify() async {
        let center = UNUserNotificationCenter.current()

        // 未授权或总开关关闭：清空频控状态静默退出（重新开启后从干净状态开始）
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        guard isEnabled && authorized else {
            clearFrequencyState()
            return
        }

        let budgetRepository = BudgetRepository.shared
        var statuses: [BudgetStatus] = []
        for account in FinanceRepository.shared.getAccounts(includeArchived: false) {
            for budget in budgetRepository.getBudgets(forAccount: account.id) {
                if let status = budgetRepository.computeBudgetStatus(budget: budget) {
                    statuses.append(status)
                }
            }
        }

        // 回到线内 → 清「已提醒超支」标记（下次再超会重新提醒）
        for status in statuses where status.progress < 1.0 {
            setNotified(false, for: status.id)
        }

        // 每日全局最多 1 条：今天已发过直接返回，不动任何标记
        // （同日其他预算新超支时不置位，明日检查仍可提醒它）
        let today = Self.dayFormatter.string(from: Date())
        guard UserDefaults.standard.string(forKey: Self.lastGlobalDayKey) != today else { return }

        // 新进入超支（超支且未提醒过）的候选里，取超出比例最大者
        let candidates = statuses.filter { status in
            status.isOverBudget && !Self.isNotified(status.id)
        }
        guard let worst = candidates.max(by: { $0.progress < $1.progress }) else { return }

        let content = UNMutableNotificationContent()
        content.title = "「\(Self.displayName(for: worst.budget))」预算超支了"
        let overPercent = Int((worst.progress - 1.0) * 100)
        content.body = "已花 \(Self.amountText(worst.spentAmount)) · 预算 \(Self.amountText(worst.budgetAmount))（超出\(overPercent)%），回到线内前不再提醒"
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.budgetOverrun

        // 即时通知，无追排/撤销需求，标识只需保证不与既有待发通知冲突
        let request = UNNotificationRequest(
            identifier: "holo.budgetOverrun.\(worst.id.uuidString).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            setNotified(true, for: worst.id)
            UserDefaults.standard.set(today, forKey: Self.lastGlobalDayKey)
            Self.logger.info("已发送预算超支提醒：\(worst.id.uuidString, privacy: .public)")
        } catch {
            Self.logger.error("发送预算超支提醒失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Frequency State

    private static func isNotified(_ budgetId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: stateKeyPrefix + budgetId.uuidString)
    }

    private func setNotified(_ value: Bool, for budgetId: UUID) {
        UserDefaults.standard.set(value, forKey: Self.stateKeyPrefix + budgetId.uuidString)
    }

    private func clearFrequencyState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.stateKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.lastGlobalDayKey)
    }

    // MARK: - Copy Helpers

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 预算显示名：总预算固定文案，分类预算用分类名
    private static func displayName(for budget: Budget) -> String {
        guard let categoryId = budget.categoryId else { return "本月总预算" }
        return BudgetRepository.shared.findCategory(by: categoryId)?.name ?? "未知分类"
    }

    private static func amountText(_ amount: Decimal) -> String {
        NumberFormatter.currencyTrimmed.string(from: NSDecimalNumber(decimal: amount)) ?? ""
    }
}
