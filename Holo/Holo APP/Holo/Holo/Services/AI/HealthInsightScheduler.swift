//
//  HealthInsightScheduler.swift
//  Holo
//
//  健康洞察单飞行后台生成器（2026-11-09 后台隐性生成改造）。
//  - App 级单例：持有唯一不绑定任何视图的生成 Task，同一时刻重复触发只跑一次。
//  - 触发：App 回到前台（仅限最近 7 天访问过健康页的用户）/ 健康页出现（发起但不等待）。
//  - 门控：AI 数据处理授权未授予直接跳过（不算失败）；数据不足不调模型（Service 层）。
//  - 取消≠失败：后台租约到期视为取消，不记失败节流、不覆盖页面已显示内容。
//  - 页面只读：@Observable snapshot 由缓存种子或生成结果驱动，生成完成页面实时更新。
//

import Foundation
import Observation

@MainActor
@Observable
final class HealthInsightScheduler {

    static let shared = HealthInsightScheduler()

    /// 自动触发来源（7 天健康页访问门控只约束回到前台触发）。
    enum Trigger {
        case appBecameActive
        case healthPageAppeared
    }

    /// 页面显示用的最新快照（缓存种子或最近一次生成结果），@Observable 驱动页面实时更新。
    private(set) var snapshot: GeneratedHealthInsightSnapshot?

    private let service: HealthInsightGenerationService
    private let cache: HealthInsightCache
    private let defaults: UserDefaults
    private let now: () -> Date
    private let isConsentGranted: () -> Bool

    /// 唯一在飞的生成 Task（离开健康页不取消，退后台由系统租约续命）。
    private var generationTask: Task<Void, Never>?
    /// iOS 退后台续跑租约（macOS 上为空操作哑租约）。
    private var backgroundLease: HoloBackgroundTaskLease?

    /// 最近一次访问健康页时间（7 天门控数据源）。
    private static let lastHealthPageVisitKey = "com.holo.healthInsight.lastHealthPageVisitAt"
    /// 今日缓存 contextHash 变化后允许重新生成的最小缓存年龄（避免步数波动一天内反复生成）。
    private let staleCacheAge: TimeInterval = 6 * 3600
    /// 回到前台自动生成只服务最近 7 天内用过健康页的用户。
    private let recentVisitorWindow: TimeInterval = 7 * 24 * 3600

    init(
        service: HealthInsightGenerationService? = nil,
        cache: HealthInsightCache? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        isConsentGranted: @escaping () -> Bool = { HoloAIFeatureFlags.aiDataProcessingConsentGranted }
    ) {
        self.service = service ?? HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: HoloHealthInsightDataSource()),
            provider: HoloBackendAIProvider()
        )
        self.cache = cache ?? .shared
        self.defaults = defaults
        self.now = now
        self.isConsentGranted = isConsentGranted
    }

    // MARK: - 触发入口

    /// 按需刷新：授权门控 + 7 天访问门控（仅回前台触发）+ 单飞行，发起后立即返回不等待。
    func refreshIfNeeded(trigger: Trigger) {
        guard isConsentGranted() else { return }
        if trigger == .appBecameActive, !isRecentHealthPageVisitor() {
            return
        }
        startGeneration(ignoreFreshness: false)
    }

    /// 手动刷新：每天 3 次上限 + 失败节流共享（cache 层），绕过新鲜度规则，同样单飞行。
    func refreshManually() {
        guard isConsentGranted() else { return }
        guard generationTask == nil else { return }    // 已在生成：忽略本次，不消耗次数
        guard cache.canManualRefresh(now: now()) else { return }
        cache.recordManualRefresh(now: now())
        startGeneration(ignoreFreshness: true)
    }

    /// 健康页出现：记录访问时间，作为回前台自动生成的 7 天门控依据。
    func recordHealthPageVisit() {
        defaults.set(now().timeIntervalSince1970, forKey: Self.lastHealthPageVisitKey)
    }

    /// 页面打开时同步播种显示快照（今日缓存 → 最近缓存 → 保底文案），不发起生成、不阻塞。
    func seedSnapshotForDisplay() {
        snapshot = service.displaySeedSnapshot(now: now())
    }

    /// 手动刷新是否可用（UI 按钮禁用判断）。
    func canRefreshManually() -> Bool {
        isConsentGranted() && generationTask == nil && cache.canManualRefresh(now: now())
    }

    /// 等待在飞生成结束（测试同步用；无生成立即返回）。
    func waitUntilIdle() async {
        while let task = generationTask {
            await task.value
        }
    }

    // MARK: - 单飞行生成

    private func startGeneration(ignoreFreshness: Bool) {
        guard generationTask == nil else { return }
        backgroundLease = HoloBackgroundTaskLease(name: "com.holo.healthInsight.generation") { [weak self] in
            // 系统后台时限到期：取消在飞生成（视为取消不记失败），下次回前台重试
            self?.generationTask?.cancel()
        }
        generationTask = Task { [weak self] in
            await self?.runGeneration(ignoreFreshness: ignoreFreshness)
        }
    }

    private func runGeneration(ignoreFreshness: Bool) async {
        defer {
            generationTask = nil
            backgroundLease?.end()
            backgroundLease = nil
        }

        let now = now()
        let result = await service.generateRespectingFreshness(
            now: now,
            ignoreFreshness: ignoreFreshness,
            staleCacheAge: staleCacheAge
        )

        switch result {
        case .generated(let outcome):
            cache.save(outcome, for: Calendar.current.startOfDay(for: now), now: now)
            snapshot = outcome.snapshot
        case .skipped:
            break    // 新鲜度/节流判定无需生成：保持当前显示
        case .insufficientData(let insufficient):
            // 数据不足不是失败：无有效缓存显示时更新为诚实空态，已有缓存显示不动
            if snapshot?.status != .fresh {
                snapshot = insufficient
            }
        case .cancelled:
            break    // 取消不记失败、不覆盖缓存与页面显示
        case .failed:
            break    // 失败已记 30 分钟节流（Service 层）；页面保持已有显示
        }
    }

    // MARK: - 7 天门控

    private func isRecentHealthPageVisitor() -> Bool {
        let lastVisit = defaults.double(forKey: Self.lastHealthPageVisitKey)
        guard lastVisit > 0 else { return false }
        return now().timeIntervalSince1970 - lastVisit <= recentVisitorWindow
    }
}
