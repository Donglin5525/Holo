//
//  HealthInsightCache.swift
//  Holo
//
//  健康洞察缓存与刷新控制。
//  - 存储用 JSON 文件（P7：snapshot 含 evidence 数组较大，不用 UserDefaults）。
//  - 缓存 key：healthInsight.generated.v1.<yyyy-MM-dd>。
//  - contextHash 只取稳定摘要哈希（P6），promptVersion 变化也触发刷新（N4）。
//  - 失败 30 分钟节流，自动生成与手动刷新共享（P8）。
//  - 手动刷新每天最多 3 次。
//  - 保留最近 7 天，超出清理（P7）。
//

import Foundation

/// 缓存条目：snapshot + 判断刷新所需的稳定摘要。
struct HealthInsightCacheEntry: Codable {
    var snapshot: GeneratedHealthInsightSnapshot
    var contextHash: String
    var promptVersion: Int?
    var appVersion: String
    var savedAt: Date
}

@MainActor
final class HealthInsightCache {

    static let shared = HealthInsightCache()

    private let directory: URL
    private let defaults: UserDefaults
    private let filePrefix = "healthInsight.generated.v1"

    private let failureThrottleInterval: TimeInterval = 30 * 60   // 30 分钟
    private let maxManualRefreshPerDay = 3
    private let retentionDays = 7

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? caches
        self.defaults = defaults
    }

    // MARK: - Snapshot 存取

    func save(_ outcome: HealthInsightGenerationOutcome, for date: Date, now: Date = Date()) {
        let entry = HealthInsightCacheEntry(
            snapshot: outcome.snapshot,
            contextHash: Self.hash(outcome.contextHashInput),
            promptVersion: outcome.promptVersion,
            appVersion: Self.appVersion(),
            savedAt: now
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: date), options: .atomic)
        cleanupOldEntries(now: now)
    }

    func loadSnapshot(for date: Date) -> GeneratedHealthInsightSnapshot? {
        loadEntry(for: date)?.snapshot
    }

    /// 是否需要刷新：无缓存 / contextHash 变化 / promptVersion 变化（N4）。
    func needsRefresh(for date: Date, contextHashInput: String, currentPromptVersion: Int?) -> Bool {
        guard let entry = loadEntry(for: date) else { return true }
        if entry.contextHash != Self.hash(contextHashInput) { return true }
        if let current = currentPromptVersion, let cached = entry.promptVersion, current != cached {
            return true
        }
        return false
    }

    private func loadEntry(for date: Date) -> HealthInsightCacheEntry? {
        guard let data = try? Data(contentsOf: fileURL(for: date)) else { return nil }
        return try? JSONDecoder().decode(HealthInsightCacheEntry.self, from: data)
    }

    private func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("\(filePrefix).\(Self.dayKey(from: date)).json")
    }

    // MARK: - 失败节流（自动生成与手动刷新共享，P8）

    func recordFailure(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.failureKey)
    }

    func isThrottled(now: Date = Date()) -> Bool {
        let last = defaults.double(forKey: Self.failureKey)
        guard last > 0 else { return false }
        return now.timeIntervalSince1970 - last < failureThrottleInterval
    }

    // MARK: - 手动刷新计数（6.3）

    func recordManualRefresh(now: Date = Date()) {
        if Self.dayKey(from: now) != manualRefreshDayKey() {
            defaults.set(1, forKey: Self.manualCountKey)
            defaults.set(Self.dayKey(from: now), forKey: Self.manualDateKey)
        } else {
            defaults.set(defaults.integer(forKey: Self.manualCountKey) + 1, forKey: Self.manualCountKey)
        }
    }

    func canManualRefresh(now: Date = Date()) -> Bool {
        if isThrottled(now: now) { return false }   // P8：共享失败节流
        if Self.dayKey(from: now) != manualRefreshDayKey() { return true }
        return defaults.integer(forKey: Self.manualCountKey) < maxManualRefreshPerDay
    }

    // MARK: - 清理（P7：保留 7 天）

    private func cleanupOldEntries(now: Date) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return
        }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? now
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Helpers

    private static let failureKey = "com.holo.healthInsight.lastFailure"
    private static let manualCountKey = "com.holo.healthInsight.manualRefreshCount"
    private static let manualDateKey = "com.holo.healthInsight.manualRefreshDate"

    private func manualRefreshDayKey() -> String {
        defaults.string(forKey: Self.manualDateKey) ?? ""
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// djb2 hash（非安全用途，仅判断 context 是否变化）。
    private static func hash(_ input: String) -> String {
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
