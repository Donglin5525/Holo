//
//  EffectiveRecordDayService.swift
//  Holo
//
//  有效记录日 Service：从 Finance/Todo/Habit/Thought 取数 → Aggregator 聚合 → 缓存
//  见本周观察方案 §4.3。仿 HoloWidgetSnapshotService 的"计算 + 落盘 + 通知驱动"三段式。
//
//  设计：纯逻辑在 EffectiveRecordDayAggregator（已 standalone test 覆盖）；
//  本 Service 只负责取数 + 缓存，保证首页 onAppear 不全表扫（命中 UserDefaults 缓存）。
//

import UIKit
import Combine
import CoreData
import os.log

@MainActor
final class EffectiveRecordDayService: ObservableObject {

    static let shared = EffectiveRecordDayService()

    /// 当前聚合结果（首页胶囊候选构建器 / 生成时机读取）
    @Published private(set) var currentResult: EffectiveRecordDayResult?

    /// 统计窗口：最近 N 个自然日的有效记录（覆盖养成期 + 反映近期活跃度）
    /// 不取全部历史是为了避免全表扫；新用户养成进度在头几周内即达成。
    static let lookbackDays = 60

    private static let cacheKey = "holo.weeklyObservation.effectiveRecordDay.v1"

    private let logger = Logger(subsystem: "com.holo.app", category: "EffectiveRecordDayService")
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Setup

    /// 在 HomeView .task 中调用。先读缓存避免首屏全表扫，再监听四模块数据变化 + 回前台刷新。
    func setup() {
        if let cached = readCache() {
            currentResult = cached
            logger.info("有效记录日缓存命中：\(cached.recordDayCount) 天，\(cached.coveredModules.count) 模块")
        }

        // 监听四模块数据变化（增量刷新）
        let notifications: [Notification.Name] = [
            .financeDataDidChange,
            .todoDataDidChange,
            .habitDataDidChange,
            .thoughtDataDidChange
        ]
        for name in notifications {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refresh()
                }
                .store(in: &cancellables)
        }

        // 回前台刷新
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // 拿到缓存后后台补一次全量（首次安装无缓存时直接全量）
        refresh()
    }

    // MARK: - Refresh

    /// 异步聚合四模块数据并更新缓存（currentResult 为 @Published，UI 自动更新）
    func refresh(now: Date = Date()) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.buildResult(now: now)
            self.currentResult = result
            self.writeCache(result)
        }
    }

    /// 同步等待的刷新（测试 / 需要立即拿到结果的调用方）
    func refreshAndWait(now: Date = Date()) async {
        let result = await buildResult(now: now)
        currentResult = result
        writeCache(result)
    }

    // MARK: - Build

    private func buildResult(now: Date) async -> EffectiveRecordDayResult {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -Self.lookbackDays, to: today) ?? today

        // Finance 是 async，用 async let 并行；其余 sync 直接取
        async let financeDays = collectFinanceDays(from: windowStart, to: today)
        let todoDays = collectTodoDays(from: windowStart, to: today)
        let habitDays = collectHabitDays(from: windowStart, to: today)
        let thoughtDays = collectThoughtDays(from: windowStart, to: today)

        let finance = await financeDays
        return EffectiveRecordDayAggregator.aggregate(
            financeDays: finance,
            todoDays: todoDays,
            habitDays: habitDays,
            thoughtDays: thoughtDays,
            today: now
        )
    }

    // MARK: - Collectors

    /// Finance：遍历窗口涉及月份取 DailySummary，有交易的日子（方案 §3.3「新增记账记录」）
    private func collectFinanceDays(from windowStart: Date, to today: Date) async -> Set<Date> {
        let repo = FinanceRepository.shared
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: today)
        let windowStartDay = calendar.startOfDay(for: windowStart)
        var days = Set<Date>()

        var monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: windowStart)) ?? windowStart
        var guardCount = 0
        while monthStart <= todayStart && guardCount < 4 {
            if let summaries = try? await repo.getDailySummaries(for: monthStart) {
                for (day, summary) in summaries where summary.hasTransactions {
                    let sod = calendar.startOfDay(for: day)
                    if sod >= windowStartDay && sod <= todayStart {
                        days.insert(sod)
                    }
                }
            }
            monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? todayStart
            guardCount += 1
        }
        return days
    }

    /// Todo：完成待办的日子（completedCount > 0，方案 §3.3「新增或完成待办」）
    private func collectTodoDays(from windowStart: Date, to today: Date) -> Set<Date> {
        let trend = TodoRepository.shared.getCompletionTrend(from: windowStart, to: today)
        let calendar = Calendar.current
        return Set(trend.filter { $0.completedCount > 0 }.map { calendar.startOfDay(for: $0.date) })
    }

    /// Habit：习惯打卡的日子（有记录即完成，遵循 CLAUDE.md「看记录即完成」约定）
    private func collectHabitDays(from windowStart: Date, to today: Date) -> Set<Date> {
        let records = HabitRepository.shared.getRecords(from: windowStart, to: today)
        let calendar = Calendar.current
        return Set(records.map { calendar.startOfDay(for: $0.date) })
    }

    /// Thought：有想法记录的日子（count > 0，方案 §3.3「新增想法/观点记录」）
    private func collectThoughtDays(from windowStart: Date, to today: Date) -> Set<Date> {
        let repo = ThoughtRepository(context: CoreDataStack.shared.viewContext)
        let counts = repo.getThoughtCountByDay(from: windowStart, to: today)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var days = Set<Date>()
        for (key, count) in counts where count > 0 {
            if let d = formatter.date(from: key) {
                days.insert(calendar.startOfDay(for: d))
            }
        }
        return days
    }

    // MARK: - Cache（UserDefaults 轻量持久化，方案 §4.3）

    private func writeCache(_ result: EffectiveRecordDayResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private func readCache() -> EffectiveRecordDayResult? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(EffectiveRecordDayResult.self, from: data)
    }
}
