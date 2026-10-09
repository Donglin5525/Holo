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
/// Equatable（2026-10-09 C3b）：相同状态不重复发布，避免首页无谓重算
struct ScheduleReminderState: Equatable {
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
    /// 是否已启动（R08，2026-10-04 体检）：setup 由 HomeView.task 调用，而首页会随根页
    /// switch 切换反复重建——无幂等保护时监听和 Timer 逐次累积（越切越慢、重复刷新、耗电）。
    /// 服务是单例，一个进程只需一套监听 + 一个 Timer。
    private var isObserving = false
    private let logger = Logger(subsystem: "com.holo.app", category: "HomeScheduleService")

    /// 延迟访问 TodoRepository（避免 init 时触发 Core Data I/O）
    private var repository: TodoRepository { TodoRepository.shared }

    /// 定时刷新间隔（秒）
    private static let refreshInterval: TimeInterval = 300  // 5 分钟

    /// 零 I/O，遵循启动规范
    private init() {}

    // MARK: - Setup

    /// 初始化监听和定时器（在 .task 中调用）；幂等——重复调用无任何副作用（R08）
    func setup() {
        guard !isObserving else { return }
        isObserving = true

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
                    self?.requestMergedRefresh()
                }
                .store(in: &cancellables)
        }

        /// 监听 App 回到前台
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshNow(source: "foreground")
            }
            .store(in: &cancellables)

        // 定时刷新（保证跨时段后文案更新）；换 Timer 前先销毁旧的（旧 Timer 仍挂在 RunLoop 上）
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNow(source: "timer")
            }
        }
    }

    // MARK: - 展示生命周期与合并刷新（2026-10-09 C3b）

    /// 首页展示可见性（HomeView 驱动）：不可见时不重建候选、只记脏，
    /// 恢复可见补一次刷新。currentState 的唯一消费者是首页信号灯 UI；
    /// ChatViewModel / MemoryInsightBackgroundService 的 refresh() 调用
    /// 同样被门控，效果在回到首页时生效即可。
    private var isPresentationVisible = true
    private var hasPendingRefreshWhileHidden = false

    /// 幂等入口：HomeView 可见性变化时调用（可见 = 首页无模块遮挡、无覆盖层）
    func setPresentationVisible(_ visible: Bool) {
        guard visible != isPresentationVisible else { return }
        isPresentationVisible = visible
        if visible, hasPendingRefreshWhileHidden {
            hasPendingRefreshWhileHidden = false
            logger.debug("信号灯恢复可见，补一次延迟刷新")
            refreshNow(source: "restore")
        }
    }

    /// 四域通知合并窗口：窗口内多次通知只重算一次（一轮修复/同步风暴
    /// 原会把首页候选连算四次）。首个通知起 200ms 定时，窗口内后续通知
    /// 合并进同一轮且不延长——连续风暴下最多延迟 200ms，不会无限推迟。
    private static let mergeWindow: Duration = .milliseconds(200)
    private var mergedRefreshTask: Task<Void, Never>?
    private var mergedSignalCount = 0

    private func requestMergedRefresh() {
        guard mergedRefreshTask == nil else {
            mergedSignalCount += 1
            return
        }
        mergedSignalCount = 1
        mergedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mergeWindow)
            guard let self else { return }
            self.mergedRefreshTask = nil
            let merged = self.mergedSignalCount
            self.mergedSignalCount = 0
            self.refreshNow(source: "merged(\(merged))")
        }
    }

    // MARK: - Refresh

    /// 聚合所有模块候选，按业务优先级取最高的一条（ScheduleRanker，方案 §4.4）。
    /// 外部手动调用入口；通知驱动路径走 requestMergedRefresh 合并后到这里。
    func refresh() {
        refreshNow(source: "manual")
    }

    /// 真正构建候选并发布：隐藏门控（不重建投影，只记脏）+ 相等跳过发布。
    private func refreshNow(source: String) {
        guard isPresentationVisible else {
            hasPendingRefreshWhileHidden = true
            logger.debug("信号灯刷新延迟到恢复可见（source=\(source, privacy: .public)）")
            return
        }
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

        guard let top = ScheduleRanker.topCandidate(candidates) else {
            if currentState != nil {
                currentState = nil
            }
            return
        }

        let newState = ScheduleReminderState(
            id: top.id,
            urgency: top.urgency,
            message: top.message,
            module: top.module,
            deepLinkTarget: deepLinks[top.id]
        )

        if currentState == newState {
            logger.debug("信号灯无变化，跳过发布（source=\(source, privacy: .public)）")
            return
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
                    message: String(localized: "已过期 \u{2022} \(truncateTitle(task.title))"),
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
            // 全天任务表达“今天”，不能把统一截止边界 23:59 当成用户设置的具体时刻。
            let timeStr = task.isAllDay ? String(localized: "今天") : formatTime(task.effectiveDueDate)
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
                    message: String(localized: "有 \(incompleteCount) 个任务待完成"),
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
               insight.insightStatus == .ready || insight.insightStatus == .stale,
               insight.readAt == nil {
                let title = insight.title
                let periodLabel: String
                switch periodType {
                case .daily: periodLabel = String(localized: "今日")
                case .monthly: periodLabel = isFallback ? String(localized: "上月") : String(localized: "本月")
                case .quarterly: periodLabel = isFallback ? String(localized: "上季度") : String(localized: "本季度")
                case .custom: periodLabel = String(localized: "自定义周期")
                case .weekly: periodLabel = isFallback ? String(localized: "上周") : String(localized: "本周")
                }
                return (
                    ScheduleCandidate(
                        id: "insight:\(periodType.rawValue):\(insight.id.uuidString)",
                        urgency: .pending,
                        module: .insight,
                        message: String(localized: "\(periodLabel)洞察：\(title)"),
                        protectionUntil: nil
                    ),
                    // 与周观察胶囊同构：带具体洞察 id，由 ChatView 直接打开回放卡片
                    .memoryInsight(insightId: insight.id)
                )
            }
        }
        return nil
    }

    // MARK: - Weekly Observation Module（方案 §2.1 / §2.4 / §4.4）

    /// 仅投递上一完整周已生成且未消费的洞察。
    private func buildWeeklyObservationCandidate(now: Date) -> (ScheduleCandidate, DeepLinkTarget?)? {
        let period = WeeklyObservationPeriod.previousCompletedWeek(containing: now)
        let repository = MemoryInsightRepository()
        guard let insight = try? repository.fetchInsight(
            periodType: .weekly,
            start: period.start,
            end: period.end
        ), WeeklyObservationDeliveryPolicy.shouldDeliver(
            status: insight.status,
            readAt: insight.readAt,
            insightPeriodStart: insight.periodStart,
            targetPeriodStart: period.start
        ) else {
            return nil
        }

        let title = insight.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = title.isEmpty
            ? String(localized: "上周洞察已准备好")
            : String(localized: "上周洞察：\(truncateTitle(title))")
        return (
            ScheduleCandidate(
                id: "weekly:\(insight.id.uuidString)",
                urgency: .newInsight,
                module: .weeklyObservation,
                message: message,
                protectionUntil: nil
            ),
            .memoryInsight(insightId: insight.id)
        )
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
            return String(localized: "明天")
        }
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfDate = calendar.startOfDay(for: date)
        let daysDiff = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0
        switch daysDiff {
        case 2: return String(localized: "后天")
        case 3: return String(localized: "大后天")
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
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
