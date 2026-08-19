//
//  GoalNotificationService.swift
//  Holo
//
//  目标风险本地通知：截止临近 / 长期停滞时排一次性提醒
//  iOS 本地通知文案在排程时固定，因此核心是重排时机：
//  App 启动 + 前台目标写操作（goalDataDidChange）后全量重排
//

import Foundation
import UserNotifications
import Combine
import OSLog

@MainActor
final class GoalNotificationService {

    static let shared = GoalNotificationService()

    /// UI 调用方在目标写操作成功后调用（仓库不 post，hosted 测试才能直接覆盖仓库写方法）
    static func broadcastGoalDataChange() {
        NotificationCenter.default.post(name: .goalDataDidChange, object: nil)
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "GoalNotification")

    /// 通知 identifier 前缀：重排时按前缀清理全部待发目标通知
    private static let identifierPrefix = "holo-goal-risk-"
    /// 风险提醒统一触发时段：上午 10 点
    private static let triggerHour = 10
    /// 同一目标同一类提醒的最小重复间隔
    private static let minRepeatInterval: TimeInterval = 7 * 24 * 3600

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 前台目标写操作（新增/编辑/删除/关联/状态切换）后延迟全量重排；
        // 目标打卡、任务完成等高频动作不经过 GoalRepository，不触发
        NotificationCenter.default.publisher(for: .goalDataDidChange)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rescheduleAll()
            }
            .store(in: &cancellables)
    }

    // MARK: - Reschedule

    /// 全量重排（App 启动 / 目标数据变更后调用）
    func rescheduleAll() {
        Task { await reschedule() }
    }

    private func reschedule() async {
        let center = UNUserNotificationCenter.current()

        // 权限未授权时静默清理并跳过（proactiveNudge 仍在 AI 话术层生效）
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            await removeAllPendingRequests()
            return
        }

        // 清掉旧排期，按当前数据重排
        let pending = await center.pendingNotificationRequests()
        let staleIds = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        if !staleIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIds)
        }

        struct Candidate {
            let goal: Goal
            let assessment: GoalRiskAssessment
            let triggerDate: Date
            /// 排序优先级：截止风险 < 停滞；同类内更紧急（剩余天数少/停滞更久）在前
            let priority: (Int, TimeInterval)
        }

        let calendar = Calendar.current
        let now = Date()
        var candidates: [Candidate] = []

        for goal in GoalRepository.shared.activeGoals() where goal.proactiveNudge && goal.allowAIContext {
            guard let assessment = GoalRiskEvaluator.assess(goal: goal, now: now),
                  let triggerDate = Self.triggerDate(for: assessment.kind, deadline: goal.deadline, now: now),
                  triggerDate > now else { continue }
            let priority: (Int, TimeInterval)
            switch assessment.kind {
            case .deadline(let daysRemaining, _):
                priority = (0, TimeInterval(daysRemaining))
            case .stagnant:
                priority = (1, goal.createdAt.timeIntervalSince1970)
            }
            candidates.append(Candidate(
                goal: goal,
                assessment: assessment,
                triggerDate: triggerDate,
                priority: priority
            ))
        }

        // 每日全局上限 1 条：同一触发日只保留风险最高者（截止 > 停滞）
        candidates.sort { $0.priority < $1.priority }
        var scheduledDays = Set<Date>()
        for candidate in candidates {
            let day = calendar.startOfDay(for: candidate.triggerDate)
            guard scheduledDays.insert(day).inserted else { continue }

            // 同一目标同一类提醒 7 天内不重复
            let recordKey = Self.lastTriggerKey(goalId: candidate.goal.id, kind: candidate.assessment.kind)
            if let last = defaults.object(forKey: recordKey) as? Date,
               candidate.triggerDate > last,
               candidate.triggerDate.timeIntervalSince(last) < Self.minRepeatInterval {
                // 近 7 天内已排过同类提醒：若原排期尚未触发，用最新文案补回（重排开始时已被清理）
                if last > now {
                    schedule(goal: candidate.goal, assessment: candidate.assessment, triggerDate: last)
                    scheduledDays.insert(calendar.startOfDay(for: last))
                }
                continue
            }

            schedule(goal: candidate.goal, assessment: candidate.assessment, triggerDate: candidate.triggerDate)
            defaults.set(candidate.triggerDate, forKey: recordKey)
            Self.logger.info("已排目标风险提醒：\(candidate.goal.title)")
        }
    }

    /// 触发时间：
    /// - 截止风险：deadline 前 3 天上午 10 点；剩余 ≤3 天则次日上午 10 点
    /// - 停滞：次日上午 10 点
    private static func triggerDate(for kind: GoalRiskKind, deadline: Date?, now: Date) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        func hour10(on day: Date) -> Date? {
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = triggerHour
            return calendar.date(from: comps)
        }
        func nextDayTrigger() -> Date? {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return hour10(on: tomorrow)
        }

        var date: Date?
        switch kind {
        case .deadline(let daysRemaining, _):
            if daysRemaining > 3, let deadline,
               let reminderDay = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: deadline)) {
                date = hour10(on: reminderDay)
            } else if daysRemaining == 0 {
                // 截止日当天只在上午 10 点前还能补提醒，过后即过期不再排
                date = hour10(on: today)
            } else {
                date = nil
            }
        case .stagnant:
            date = nil
        }
        // 计算出的时间点已过（如今天是 deadline-3 但已过上午 10 点）则顺延到次日
        guard let date, date > now else { return nextDayTrigger() }
        return date
    }

    // MARK: - Schedule

    private func schedule(goal: Goal, assessment: GoalRiskAssessment, triggerDate: Date) {
        let calendar = Calendar.current
        let content = UNMutableNotificationContent()
        // 标题按风险场景化，让通知栏一眼可辨（量化目标与普通目标措辞区分）
        switch assessment.kind {
        case .deadline(let daysRemaining, _):
            if goal.isQuantitative {
                content.title = "⚠️ 按当前速度赶不上"
            } else {
                content.title = daysRemaining == 0 ? "⏳ 目标今天截止" : "⏳ \(daysRemaining) 天后截止"
            }
        case .stagnant:
            content.title = "💤 目标停了两周"
        }
        content.body = assessment.summary
        content.sound = .default
        content.categoryIdentifier = TodoNotificationCategory.goalRisk
        content.userInfo = ["goalId": goal.id.uuidString]

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + goal.id.uuidString + "-" + assessment.kind.identifierKey,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("排目标风险提醒失败：\(error.localizedDescription)")
            }
        }
    }

    /// 清理全部待发的目标风险通知（权限被拒 / 目标不再命中风险时由全量重排兜底）
    private func removeAllPendingRequests() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Dedup Records

    /// 同一目标同一类提醒最近一次的触发时间（按 goalId+kind 记 UserDefaults，不侵入 Goal 模型）
    private static func lastTriggerKey(goalId: UUID, kind: GoalRiskKind) -> String {
        "goalRiskLastTrigger.\(goalId.uuidString).\(kind.identifierKey)"
    }
}
