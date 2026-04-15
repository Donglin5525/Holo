//
//  HomeScheduleService.swift
//  Holo
//
//  首页推送通道服务
//  聚合各模块的提醒信息，在首页信号灯位置展示最紧急的推送
//  当前接入：待办任务模块。后续可扩展：习惯、健康、财务等
//

import SwiftUI
import Combine
import os.log

// MARK: - 数据模型

/// 推送来源模块
/// 扩展新模块时：1) 添加 case  2) 在 refresh() 中添加对应查询逻辑
enum ReminderModule: String {
    case task
    // 未来扩展：
    // case habit     // 习惯打卡提醒
    // case finance   // 账单到期提醒
    // case health    // 健康数据提醒
}

/// 紧急程度（决定信号灯颜色和显示优先级）
/// 优先级从高到低：overdue > today > upcoming > pending
enum ReminderUrgency: Int, Comparable {
    case overdue  = 4  // 已过期
    case today    = 3  // 今天到期
    case upcoming = 2  // 近3天到期
    case pending  = 1  // 仅有未完成

    static func < (lhs: ReminderUrgency, rhs: ReminderUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 推送提醒状态（跨模块通用）
struct ScheduleReminderState {
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
/// 聚合各模块提醒，按优先级展示最紧急的一条
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

    // MARK: - Initialization

    /// 零 I/O，遵循启动规范
    private init() {}

    // MARK: - Setup

    /// 初始化监听和定时器（在 .task 中调用）
    func setup() {
        // 首次刷新
        refresh()

        // 监听待办数据变更
        NotificationCenter.default.publisher(for: .todoDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

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
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    // MARK: - Refresh

    /// 聚合所有模块的推送，取最高优先级的一条
    /// 扩展新模块时：在 candidates 数组中追加新模块的查询结果即可
    func refresh() {
        var candidates: [ScheduleReminderState] = []

        // ---- 待办任务模块 ----
        if let taskState = buildTaskReminderState() {
            candidates.append(taskState)
        }

        // ---- 未来扩展：其他模块 ----
        // if let habitState = buildHabitReminderState() {
        //     candidates.append(habitState)
        // }

        // 按紧急程度排序，取最高优先级
        currentState = candidates.sorted(by: { $0.urgency > $1.urgency }).first
    }

    // MARK: - Task Module

    /// 构建待办任务模块的推送状态
    /// 优先级：过期 > 今天到期 > 近3天到期 > 未完成数量
    private func buildTaskReminderState() -> ScheduleReminderState? {
        // 1. 查询已过期任务（取最紧急的一个）
        let overdueTasks = repository.getOverdueTasks()
            .sorted { ($0.effectiveDueDate ?? .distantFuture) > ($1.effectiveDueDate ?? .distantFuture) }
        if let task = overdueTasks.first {
            return ScheduleReminderState(
                urgency: .overdue,
                message: "已过期 \u{2022} \(truncateTitle(task.title ?? ""))",
                module: .task,
                deepLinkTarget: .taskDetail(taskId: task.id)
            )
        }

        // 2. 查询今天到期的任务（按时间升序取最早的一个）
        let todayTasks = repository.getTodayTasks()
            .filter { !$0.completed }
            .sorted { ($0.effectiveDueDate ?? .distantFuture) < ($1.effectiveDueDate ?? .distantFuture) }
        if let task = todayTasks.first {
            let timeStr = formatTime(task.effectiveDueDate)
            return ScheduleReminderState(
                urgency: .today,
                message: "\(timeStr) \u{2022} \(truncateTitle(task.title ?? ""))",
                module: .task,
                deepLinkTarget: .taskDetail(taskId: task.id)
            )
        }

        // 3. 查询未来 3 天到期的任务
        if let task = repository.getNextUpcomingTask(withinDays: 3) {
            let dateStr = formatRelativeDate(task.effectiveDueDate)
            let timeStr = formatTime(task.effectiveDueDate)
            return ScheduleReminderState(
                urgency: .upcoming,
                message: "\(dateStr) \(timeStr) \u{2022} \(truncateTitle(task.title ?? ""))",
                module: .task,
                deepLinkTarget: .taskDetail(taskId: task.id)
            )
        }

        // 4. 没有到期任务，统计未完成数量
        let incompleteCount = repository.getIncompleteTaskCount()
        if incompleteCount > 0 {
            return ScheduleReminderState(
                urgency: .pending,
                message: "有 \(incompleteCount) 个任务待完成",
                module: .task,
                deepLinkTarget: .tasks
            )
        }

        // 5. 全部完成
        return nil
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
        // 计算天数差
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
        case .overdue:  return .holoError      // 红色
        case .today:    return .holoSuccess     // 绿色
        case .upcoming: return .holoInfo        // 蓝色
        case .pending:  return Color(red: 245/255, green: 158/255, blue: 11/255)  // 琥珀色 #F59E0B
        }
    }
}
