//
//  HabitModuleViewModel.swift
//  Holo
//
//  习惯模块状态（2026-10 交互重构）：三页签、值快照刷新、筛选固定集合、
//  页面内撤销提示。只消费 repository/coordinator 的事实，不自建业务事实。
//

import Foundation
import Combine
import SwiftUI

// MARK: - 新 UI 开关

/// 新交互整体开关（方案 §18.1）。G0–G5 默认关闭；
/// Debug/模拟器通过启动参数或 launch environment 开启；发布默认开启由东林决定。
enum HabitInteractionFeature {
    static let enabledKey = "holo.habits.interactionV1.enabled"

    /// 默认开启（东林 2026-10-06 拍板）。显式写 false 才回退旧 UI；
    /// 回退只切换界面，不删新记录、不重置偏好（方案 §18.1）。
    static var isV1Enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }
}

// MARK: - ViewModel

@MainActor
final class HabitModuleViewModel: ObservableObject {

    // MARK: 页签

    enum Tab: String, CaseIterable {
        case today
        case review
        case manage

        var displayName: String {
            switch self {
            case .today: return String(localized: "今天")
            case .review: return String(localized: "回顾")
            case .manage: return String(localized: "管理")
            }
        }

        var icon: String {
            switch self {
            case .today: return "checkmark.circle.fill"
            case .review: return "calendar"
            case .manage: return "slider.horizontal.3"
            }
        }
    }

    // MARK: 筛选

    enum TodayFilter: Equatable {
        case all
        case unrecorded
    }

    // MARK: 撤销提示

    struct UndoHint: Equatable {
        let text: String
        let receipt: HabitActionReceipt
    }

    // MARK: 行内错误

    struct InlineError: Equatable {
        let habitId: UUID
        let message: String
    }

    // MARK: 发布状态

    @Published var selectedTab: Tab = .today
    @Published private(set) var todayRows: [HabitRowSnapshot] = []
    @Published private(set) var pausedRows: [HabitRowSnapshot] = []
    @Published private(set) var archivedRows: [HabitRowSnapshot] = []
    /// 今天已记录的不同习惯数（新口径，方案 §9.1）
    @Published private(set) var recordedTodayCount: Int = 0
    /// 滚动七天每天的有效记录习惯数（与习惯去重；日期条）
    @Published private(set) var rollingSevenDayCounts: [Date: Int] = [:]
    @Published private(set) var isLoading = true
    @Published var todayFilter: TodayFilter = .all {
        didSet { recomputeFilteredRows() }
    }
    /// 「未记录」筛选本次可见的 ID 集合（进入筛选时固定；离开/跨日重算）
    private var unrecordedFilterIds: Set<UUID>?
    @Published private(set) var filteredTodayRows: [HabitRowSnapshot] = []

    /// 撤销短提示（页面内 safeAreaInset，约 7 秒）
    @Published var undoHint: UndoHint?
    /// 行内错误
    @Published var inlineError: InlineError?
    /// 需要权益的动作（View 层接 HoloPlusActionCoordinator）
    @Published var pendingEntitlement: HabitEntitlementAction?

    /// 暂停管理入口计数（今天页）
    var pausedCount: Int { pausedRows.count }

    let coordinator: HabitActionCoordinator
    private let repository: HabitRepository
    private var cancellables: Set<AnyCancellable> = []
    /// 刷新时钟：一次投影内固定（方案 §9.3）
    private(set) var projectionNow: Date = Date()

    // MARK: 初始化

    init(repository: HabitRepository = .shared,
         coordinator: HabitActionCoordinator = .shared) {
        self.repository = repository
        self.coordinator = coordinator
        bindDataChangeNotifications()
        // 仅在存储已就绪时同步投影；未就绪一律走 warmUp 异步初始化，
        // 绝不在主线程等待数据库（真机冷启动阻塞 = 打开黑屏，2026-10-06 实测）
        if repository.isReady {
            refresh()
        }
    }

    /// 异步等待存储就绪后首次刷新（容器 onAppear 调用）。
    /// 与旧 HabitListView 相同的首启模式：后台触碰 persistentContainer，就绪后回主线程。
    func warmUp() {
        if repository.isReady {
            refresh()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = CoreDataStack.shared.persistentContainer
            await MainActor.run {
                guard let self else { return }
                self.repository.setup()
                self.refresh()
            }
        }
    }

    private func bindDataChangeNotifications() {
        // 模块根容器观察：页面尚未创建时也不丢刷新；通知重复到达由 refresh 幂等吸收
        NotificationCenter.default.publisher(for: .habitDataDidChange)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: 数据刷新（批量投影，固定窗口）

    func refresh() {
        // 未就绪时静默返回（等 warmUp 异步完成后会再刷）；
        // 这里绝不能同步 setup()——会在主线程阻塞等库，页面整体卡黑
        guard repository.isReady else { return }
        projectionNow = Date()
        let calendar = Calendar.current

        let facts = repository.allRecordFacts()
        let allIds = (repository.activeHabits + repository.pausedHabits).map(\.id)
        let windows = repository.pauseWindowsByIds(allIds)
        let data = HabitPresentationProjector.buildData(
            records: facts,
            pauseWindowsByHabit: windows,
            now: projectionNow,
            calendar: calendar
        )

        todayRows = repository.activeHabits.map { habit in
            HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)
        }
        pausedRows = repository.pausedHabits.map { habit in
            HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .paused, data: data)
        }
        archivedRows = repository.fetchArchivedHabits().map { habit in
            HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .archived, data: data)
        }

        recordedTodayCount = todayRows.filter { $0.today.isRecorded }.count

        // 滚动七天：每天「有效记录的不同习惯数」（仅今天页在册习惯；与方案 §4.2 口径一致）
        rollingSevenDayCounts = HabitPresentationProjector.rollingSevenDays(data)
            .reduce(into: [Date: Int]()) { result, day in
                let count = todayRows.filter { row in
                    row.trail.first { data.dayStart($0.day) == day }?.isRecorded == true
                }.count
                result[day] = count
            }

        recomputeFilteredRows()
        isLoading = false
    }

    /// 「未记录」筛选：进入时固定本次可见集合（方案 §4.5——
    /// 本次成功后该行原位变成已记录；切筛选/离开再进/跨日才重算）
    private func recomputeFilteredRows() {
        switch todayFilter {
        case .all:
            unrecordedFilterIds = nil
            filteredTodayRows = todayRows
        case .unrecorded:
            if unrecordedFilterIds == nil {
                unrecordedFilterIds = Set(todayRows.map(\.id))
            }
            let ids = unrecordedFilterIds ?? []
            filteredTodayRows = todayRows.filter { ids.contains($0.id) }
        }
    }

    // MARK: 记录动作

    /// 今天页/详情页的记录动作入口。结果驱动快照刷新与反馈时序。
    func record(kind: HabitActionKind, habitId: UUID, note: String? = nil) async {
        inlineError = nil
        guard let result = await coordinator.perform(kind, habitId: habitId, note: note) else {
            return // 同习惯保存中：忽略重复提交
        }

        switch result {
        case .confirmed(let receipt):
            // 先刷新真实快照，再呈现反馈（方案 §12.3）
            refresh()
            showUndoHintIfNeeded(receipt: receipt)
            announceMilestoneIfCrossed(habitId: habitId)

        case .unchanged(let reason):
            refresh()
            switch reason {
            case .alreadyRecorded:
                inlineError = InlineError(habitId: habitId,
                                          message: String(localized: "这一天已经记录过了"))
            case .nothingToUndo:
                inlineError = InlineError(habitId: habitId,
                                          message: String(localized: "今天没有可撤销的记录"))
            }

        case .requiresEntitlement(let action):
            pendingEntitlement = action

        case .invalidated(let reason):
            inlineError = InlineError(habitId: habitId, message: Self.invalidatedText(reason))

        case .failed(let message):
            inlineError = InlineError(habitId: habitId, message: message)
        }
    }

    /// 页内撤销（短提示上的撤销按钮）
    func undoLast() async {
        guard let hint = undoHint else { return }
        undoHint = nil
        let result = coordinator.undo(hint.receipt)
        switch result {
        case .confirmed:
            refresh()
        case .invalidated(.recordChanged):
            inlineError = InlineError(habitId: hint.receipt.habitId,
                                      message: String(localized: "这条记录已变化，请到详情确认"))
        case .invalidated(let reason):
            inlineError = InlineError(habitId: hint.receipt.habitId,
                                      message: Self.invalidatedText(reason))
        case .unchanged:
            refresh()
        case .requiresEntitlement:
            inlineError = InlineError(habitId: hint.receipt.habitId,
                                      message: String(localized: "需要完成订阅后重试"))
        case .failed(let message):
            inlineError = InlineError(habitId: hint.receipt.habitId, message: message)
        }
    }

    /// 普通今日打卡、计数/测量新增成功后开启约 7 秒撤销窗口（方案 §11.3）
    private func showUndoHintIfNeeded(receipt: HabitActionReceipt) {
        switch receipt.kind {
        case .toggleCheckIn:
            // 仅「勾上」才给撤销；取消打卡不需要
            guard receipt.newCheckInState == true else { return }
            undoHint = UndoHint(text: String(localized: "已记录 · 撤销"), receipt: receipt)
        case .addNumeric, .increment:
            undoHint = UndoHint(text: String(localized: "已记录 · 撤销"), receipt: receipt)
        case .removeLatestNumeric, .retroactive, .updateRecord, .deleteRecord:
            // 补录/明细操作不走短提示撤销（各自有入口）
            break
        }
    }

    /// 撤销窗口自然到期（UI 计时驱动；只关提示，不影响保存事实）
    func expireUndoHint() {
        undoHint = nil
    }

    /// 真实本次记录跨过里程碑阈值 → 一次性公告并标记已展示（方案 §9.4：
    /// 升级时不集中补播历史；撤销/重做不重复播放）
    private func announceMilestoneIfCrossed(habitId: UUID) {
        guard let row = todayRows.first(where: { $0.id == habitId }),
              let streak = row.streak,
              !row.isBadHabit else { return }
        let store = HabitMilestoneStore()
        let achieved = store.achievedMilestones(habitId: habitId, streak: streak, frequency: row.frequency)
        guard let milestone = achieved.last(where: { !store.isDisplayed($0) }) else { return }
        store.markDisplayed(milestone)
        inlineError = InlineError(habitId: habitId,
                                  message: String(localized: "达成里程碑：\(milestone.displayText)"))
    }

    // MARK: 文案

    static func invalidatedText(_ reason: HabitInvalidatedReason) -> String {
        switch reason {
        case .habitUnavailable: return String(localized: "这个习惯已不可用")
        case .invalidDate: return String(localized: "这个日期不能补录")
        case .beforeCreation: return String(localized: "习惯创建前的日期不能补录")
        case .futureDate: return String(localized: "未来日期不能补录")
        case .pausedDayNotMakeup: return String(localized: "暂停日不算漏签")
        case .habitPaused: return String(localized: "习惯已暂停，恢复后即可继续记录")
        case .typeNotSupported: return String(localized: "这个习惯不支持补录")
        case .invalidValue: return String(localized: "数值无效，请检查后重试")
        case .recordChanged: return String(localized: "这条记录已变化，请到详情确认")
        case .archivedNeedsUnarchive: return String(localized: "请先取消归档再记录")
        }
    }
}
