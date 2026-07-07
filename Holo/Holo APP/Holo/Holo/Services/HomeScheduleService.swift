//
//  HomeScheduleService.swift
//  Holo
//
//  首页推送通道服务
//  聚合各模块的提醒信息，在首页信号灯位置展示最该看的一条
//  接入：待办任务 / AI 洞察 / 本周观察（方案 §2.4 / §4.4）
//
//  ReminderUrgency / ReminderModule / ScheduleCandidate / ScheduleRanker 定义在
//  ScheduleRankingModels.swift（纯逻辑，可 standalone test）。
//

import SwiftUI
import Combine
import os.log

// MARK: - 数据模型

/// 推送提醒状态（跨模块通用，不可变）
struct ScheduleReminderState {
    /// 稳定标识（曝光记录 / tiebreaker，方案 §4.4）
    let id: String
    /// 紧急程度 → 决定信号灯颜色
    let urgency: ReminderUrgency
    /// 显示文案
    let message: String
    /// 来源模块
    let module: ReminderModule
    /// 点击跳转目标（nil 则不可点击）
    let deepLinkTarget: DeepLinkTarget?
}

// MARK: - HomeScheduleService

/// 首页推送通道服务
/// 聚合各模块提醒候选，按业务优先级（ScheduleRanker）展示最该看的一条
@MainActor
class HomeScheduleService: ObservableObject {

    // MARK: - Singleton

    static let shared = HomeScheduleService()

    // MARK: - Published

    /// 当前推送状态（nil 表示无提醒，信号灯隐藏）
    @Published var currentState: ScheduleReminderState?

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private let logger = Logger(subsystem: "com.holo.app", category: "HomeScheduleService")

    /// 延迟访问 TodoRepository（避免 init 时触发 Core Data I/O）
    private var repository: TodoRepository { TodoRepository.shared }

    /// 定时刷新间隔（秒）
    private static let refreshInterval: TimeInterval = 300  // 5 分钟

    /// 本周观察胶囊每日最大曝光次数（方案 §4.4，防 refresh 刷爆）
    private static let maxDailyWeeklyExposure = 3
    private static let weeklyExposureCountKey = "holo.homeSchedule.weeklyExposure.count"
    private static let weeklyExposureDateKey = "holo.homeSchedule.weeklyExposure.date"

    /// 零 I/O，遵循启动规范
    private init() {}

    // MARK: - Setup

    /// 初始化监听和定时器（在 .task 中调用）
    func setup() {
        // 首次刷新
        refresh()

        // 监听四模块数据变化（任务 + 本周观察依赖的记账/习惯/想法）
        let dataChangeNotifications: [Notification.Name] = [
            .todoDataDidChange,
            .financeDataDidChange,
            .habitDataDidChange,
            .thoughtDataDidChange
        ]
        for name in dataChangeNotifications {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refresh()
                }
                .store(in: &cancellables)
        }

        // 监听 App 回到前台
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // 定时刷新（保证跨时段后文案更新）
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    // MARK: - Refresh

    /// 聚合所有模块候选，按业务优先级取最高的一条（ScheduleRanker，方案 §4.4）
    func refresh() {
        let now = Date()
        var candidates: [ScheduleCandidate] = []
        var deepLinks: [String: DeepLinkTarget] = [:]

        func add(_ pair: (ScheduleCandidate, DeepLinkTarget?)?) {
            guard let pair else { return }
            candidates.append(pair.0)
            if let link = pair.1 {
                deepLinks[pair.0.id] = link
            }
        }

        add(buildTaskCandidate())
        add(buildInsightCandidate(now: now))
        add(buildWeeklyObservationCandidate(now: now))

        // 曝光限频：本周观察当日达上限则移除其候选（方案 §4.4）
        let exposure = weeklyExposureCount(today: now)
        if exposure.count >= Self.maxDailyWeeklyExposure {
            candidates.removeAll { $0.module == .weeklyObservation }
        }

        guard let top = ScheduleRanker.topCandidate(candidates) else {
            currentState = nil
            return
        }

        let newState = ScheduleReminderState(
            id: top.id,
            urgency: top.urgency,
            message: top.message,
            module: top.module,
            deepLinkTarget: deepLinks[top.id]
        )

        // 曝光口径：currentState 实际切换到本周观察候选才算一次曝光
        // （非 refresh 调用次数——后者被 5min 定时器 + 回前台 + 数据变化三路刷爆）
        if currentState?.id != top.id && top.module == .weeklyObservation {
            incrementWeeklyExposure(today: now)
        }
        currentState = newState
    }

    // MARK: - Task Module

    /// 构建待办任务候选（优先级：过期 > 今天到期 > 近3天 > 未完成数量）
    private func buildTaskCandidate() -> (ScheduleCandidate, DeepLinkTarget?)? {
        // 1. 已过期任务
        let overdueTasks = repository.getOverdueTasks()
            .sorted { ($0.effectiveDueDate ?? .distantFuture) > ($1.effectiveDueDate ?? .distantFuture) }
        if let task = overdueTasks.first {
            return (
                ScheduleCandidate(
                    id: "task:\(task.id.uuidString)",
                    urgency: .overdue,
                    module: .task,
                    message: "已过期 \u{2022} \(truncateTitle(task.title))",
                    protectionUntil: nil
                ),
                .taskDetail(taskId: task.id)
            )
        }

        // 2. 今天到期
        let todayTasks = repository.getTodayTasks()
            .filter { !$0.completed }
            .sorted { ($0.effectiveDueDate ?? .distantFuture) < ($1.effectiveDueDate ?? .distantFuture) }
        if let task = todayTasks.first {
            let timeStr = formatTime(task.effectiveDueDate)
            return (
                ScheduleCandidate(
                    id: "task:\(task.id.uuidString)",
                    urgency: .today,
                    module: .task,
                    message: "\(timeStr) \u{2022} \(truncateTitle(task.title))",
                    protectionUntil: nil
                ),
                .taskDetail(taskId: task.id)
            )
        }

        // 3. 未来 3 天到期
        if let task = repository.getNextUpcomingTask(withinDays: 3) {
            let dateStr = formatRelativeDate(task.effectiveDueDate)
            let timeStr = formatTime(task.effectiveDueDate)
            return (
                ScheduleCandidate(
                    id: "task:\(task.id.uuidString)",
                    urgency: .upcoming,
                    module: .task,
                    message: "\(dateStr) \(timeStr) \u{2022} \(truncateTitle(task.title))",
                    protectionUntil: nil
                ),
                .taskDetail(taskId: task.id)
            )
        }

        // 4. 未完成数量
        let incompleteCount = repository.getIncompleteTaskCount()
        if incompleteCount > 0 {
            return (
                ScheduleCandidate(
                    id: "task:pending",
                    urgency: .pending,
                    module: .task,
                    message: "有 \(incompleteCount) 个任务待完成",
                    protectionUntil: nil
                ),
                .tasks
            )
        }

        return nil
    }

    // MARK: - Insight Module

    /// 构建 AI 洞察候选（普通回放提醒，优先级低于任务）
    /// weekly 周期交给 buildWeeklyObservationCandidate 统一处理，避免重复候选。
    private func buildInsightCandidate(now: Date) -> (ScheduleCandidate, DeepLinkTarget?)? {
        let insightRepo = MemoryInsightRepository()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        let periods: [(periodType: MemoryInsightPeriodType, start: Date, end: Date, isFallback: Bool)] = {
            var result: [(periodType: MemoryInsightPeriodType, start: Date, end: Date, isFallback: Bool)] = []
            // 今日
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                result.append((.daily, today, tomorrow, false))
            }
            // 本月 / 上月（自动回退）。weekly 跳过（见上方注释）
            let (monthStart, monthEnd, monthFallback) = MemoryInsightContextBuilder.effectivePeriodRange(
                periodType: .monthly, referenceDate: now
            )
            result.append((.monthly, monthStart, monthEnd, monthFallback))
            return result
        }()

        for (periodType, start, end, isFallback) in periods {
            if let insight = try? insightRepo.fetchInsight(periodType: periodType, start: start, end: end),
               insight.insightStatus == .ready || insight.insightStatus == .stale {
                let title = insight.title
                let periodLabel: String
                switch periodType {
                case .daily: periodLabel = "今日"
                case .monthly: periodLabel = isFallback ? "上月" : "本月"
                case .quarterly: periodLabel = isFallback ? "上季度" : "本季度"
                case .custom: periodLabel = "自定义周期"
                case .weekly: periodLabel = isFallback ? "上周" : "本周"
                }
                return (
                    ScheduleCandidate(
                        id: "insight:\(periodType.rawValue):\(insight.id.uuidString)",
                        urgency: .pending,
                        module: .insight,
                        message: "\(periodLabel)洞察：\(title)",
                        protectionUntil: nil
                    ),
                    .memoryGallery
                )
            }
        }
        return nil
    }

    // MARK: - Weekly Observation Module（方案 §2.1 / §2.4 / §4.4）

    /// 构建本周观察候选（统一入口，承载养成 / 授权 / 未读 / 失败 / 就绪状态）
    private func buildWeeklyObservationCandidate(now: Date) -> (ScheduleCandidate, DeepLinkTarget?)? {
        // 未授权 → 授权引导（pending 级，不强压任务）
        if !HoloAIFeatureFlags.aiDataProcessingConsentGranted {
            return (
                ScheduleCandidate(
                    id: "weekly:consent",
                    urgency: .pending,
                    module: .weeklyObservation,
                    message: "开启 HoloAI 生成本周观察",
                    protectionUntil: nil
                ),
                .ai(voiceInput: false)
            )
        }

        // 取最新 weekly 观察记录（不限本周；胶囊与 ChatView 卡片共用同一条，避免两边查询范围不一致）
        let insight = MemoryInsightRepository().fetchLatestReadyInsight(periodType: .weekly)

        // 有未读 weekly insight → newInsight（P0，24h 保护期，方案 §2.4 / §7.5）
        if let insight = insight,
           insight.insightStatus == .ready || insight.insightStatus == .stale,
           insight.readAt == nil {
            let protection = insight.generatedAt.addingTimeInterval(24 * 3600)
            let message: String
            switch insight.observationStageEnum {
            case .light3d: message = "第一条观察已准备好"
            case .full7d:  message = "本周观察已准备好"
            }
            return (
                ScheduleCandidate(
                    id: "weekly:\(insight.id.uuidString)",
                    urgency: .newInsight,
                    module: .weeklyObservation,
                    message: message,
                    protectionUntil: protection
                ),
                .ai(voiceInput: false)
            )
        }

        // 养成进度候选（基于有效记录日）
        let result = EffectiveRecordDayService.shared.currentResult
        if let result = result {
            switch result.eligibility {
            case .nurturing:
                return (
                    ScheduleCandidate(
                        id: "weekly:nurturing",
                        urgency: .pending,
                        module: .weeklyObservation,
                        message: weeklyNurturingMessage(result: result),
                        protectionUntil: nil
                    ),
                    .ai(voiceInput: false)
                )
            case .lightReady, .fullReady:
                // 达标但无未读 insight：失败 → 重试；否则普通提醒
                if let insight = insight, insight.insightStatus == .failed {
                    return (
                        ScheduleCandidate(
                            id: "weekly:failed",
                            urgency: .pending,
                            module: .weeklyObservation,
                            message: "本周观察待重试",
                            protectionUntil: nil
                        ),
                        .ai(voiceInput: false)
                    )
                }
                return (
                    ScheduleCandidate(
                        id: "weekly:ready",
                        urgency: .pending,
                        module: .weeklyObservation,
                        message: "本周观察已准备好",
                        protectionUntil: nil
                    ),
                    .ai(voiceInput: false)
                )
            }
        }

        // 有效记录日尚未计算（Service 未刷新）→ 不生成候选，等下次 refresh
        return nil
    }

    /// 养成期文案（方案 §2.1）
    private func weeklyNurturingMessage(result: EffectiveRecordDayResult) -> String {
        if result.recordDayCount == 0 {
            return "Holo 正在认识你"
        }
        return result.nurturingHint
    }

    // MARK: - Exposure Limit（方案 §4.4，跨会话持久化）

    /// 当日本周观察曝光计数（跨日自动重置）
    private func weeklyExposureCount(today: Date) -> (count: Int, date: Date) {
        let defaults = UserDefaults.standard
        let storedDate = defaults.object(forKey: Self.weeklyExposureDateKey) as? Date ?? .distantPast
        let count = defaults.integer(forKey: Self.weeklyExposureCountKey)
        if !Calendar.current.isDate(storedDate, inSameDayAs: today) {
            return (0, today)
        }
        return (count, storedDate)
    }

    private func incrementWeeklyExposure(today: Date) {
        let defaults = UserDefaults.standard
        let (count, date) = weeklyExposureCount(today: today)
        defaults.set(count + 1, forKey: Self.weeklyExposureCountKey)
        defaults.set(date, forKey: Self.weeklyExposureDateKey)
    }

    // MARK: - Formatting

    /// 格式化时间为 HH:mm（遵循编码规范：DateFormatter + zh_CN）
    private func formatTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 格式化相对日期（明天/后天/大后天）
    private func formatRelativeDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInTomorrow(date) {
            return "明天"
        }
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfDate = calendar.startOfDay(for: date)
        let daysDiff = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0
        switch daysDiff {
        case 2: return "后天"
        case 3: return "大后天"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }

    /// 截断标题（防止胶囊过长）
    private func truncateTitle(_ title: String) -> String {
        if title.count > 12 {
            return String(title.prefix(12)) + "…"
        }
        return title
    }
}

// MARK: - Urgency Color Extension

extension ReminderUrgency {
    /// 信号灯颜色
    var indicatorColor: Color {
        switch self {
        case .overdue:    return .holoError      // 红色
        case .today:      return .holoSuccess     // 绿色
        case .upcoming:   return .holoInfo        // 蓝色
        case .pending:    return Color(red: 245/255, green: 158/255, blue: 11/255)  // 琥珀色 #F59E0B
        case .newInsight: return .holoPrimary     // 新观察：主题色（区别于任务红/绿/蓝）
        }
    }
}
