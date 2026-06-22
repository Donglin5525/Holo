//
//  MemoryInsightRefreshQuota.swift
//  Holo
//
//  AI 洞察刷新每日配额（一天最多 N 次，按自然日重置）
//
//  复用 UserDisplayNameSettings 的 UserDefaults 封装范式 + Date.isToday 按日判定。
//  配额在 MemoryGalleryViewModel.refreshInsight(force:) 开头消耗，
//  星图「更新」与 AI 回放「重新生成」两处入口共享同一配额池。
//

import Foundation

struct MemoryInsightRefreshQuota {

    /// 每天最多刷新次数（AI 洞察生成有成本，且一天内变化有限）。
    static let maxPerDay: Int = 2

    /// 单例。测试时可改用 init(userDefaults:) 注入独立 suite。
    static let shared = MemoryInsightRefreshQuota()

    /// 上次刷新所在自然日的时间戳（timeIntervalSince1970）。
    private static let lastDayKey = "com.holo.insight.refresh.lastDay"
    /// 当天已用次数。
    private static let countKey = "com.holo.insight.refresh.count"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// 今天已用次数。跨天（lastDay 非今天）自动视为 0。
    var usedToday: Int {
        let timestamp = userDefaults.double(forKey: Self.lastDayKey)
        guard isSameDayAsToday(timestamp) else { return 0 }
        return userDefaults.integer(forKey: Self.countKey)
    }

    /// 今天剩余次数（不低于 0）。
    var remainingToday: Int {
        max(0, Self.maxPerDay - usedToday)
    }

    /// 今天是否还能刷新。
    func canRefresh() -> Bool {
        remainingToday > 0
    }

    /// 消耗一次配额。返回是否成功；跨天自动重置后再计数。
    /// 调用方应在「真正发起 AI 生成之前」调用，保证失败不白白消耗。
    @discardableResult
    func consume() -> Bool {
        let used = usedToday
        guard used < Self.maxPerDay else { return false }
        userDefaults.set(Date().timeIntervalSince1970, forKey: Self.lastDayKey)
        userDefaults.set(used + 1, forKey: Self.countKey)
        return true
    }

    private func isSameDayAsToday(_ timestamp: TimeInterval) -> Bool {
        // timestamp == 0（未存过）时 Date(1970) 的 isToday 为 false，视为跨天，符合预期。
        Date(timeIntervalSince1970: timestamp).isToday
    }
}
