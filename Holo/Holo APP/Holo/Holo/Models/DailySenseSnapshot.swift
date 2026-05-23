//
//  DailySenseSnapshot.swift
//  Holo
//
//  每日状态雷达模型
//  3 个状态：stable / atRisk / recovering，规则引擎生成
//

import Foundation

/// 每日状态
enum DailySenseState: String, Codable {
    case stable       // 稳定
    case atRisk       // 断连风险
    case recovering   // 恢复中
}

/// 每日状态快照
struct DailySenseSnapshot: Codable, Equatable {
    let date: Date
    let state: DailySenseState
    let confidence: Double
    /// 最多 3 条原因，可追溯到真实数据
    let reasons: [String]
    let generatedAt: Date
}

/// 每日状态持久化（保留最近 7 天 JSON 数组）
final class DailySenseSnapshotStore {
    static let shared = DailySenseSnapshotStore()

    private let maxDays = 7
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo", isDirectory: true)
        return dir.appendingPathComponent("DailySenseSnapshots.json")
    }()

    private(set) var snapshots: [DailySenseSnapshot] = []

    private init() {
        load()
    }

    /// 保存今日快照（替换同日期的旧快照）
    func saveToday(_ snapshot: DailySenseSnapshot) {
        let calendar = Calendar.current
        snapshots.removeAll { calendar.isDate($0.date, inSameDayAs: snapshot.date) }
        snapshots.append(snapshot)
        cleanup()
        save()
    }

    /// 获取今日快照
    func todaySnapshot() -> DailySenseSnapshot? {
        let calendar = Calendar.current
        return snapshots.last { calendar.isDate($0.date, inSameDayAs: Date()) }
    }

    /// 获取最近 N 天快照
    func recentSnapshots(days: Int = 7) -> [DailySenseSnapshot] {
        Array(snapshots.suffix(days))
    }

    // MARK: - Private

    private func cleanup() {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -maxDays, to: Date()) ?? Date()
        snapshots = snapshots.filter { $0.date >= cutoff }
        snapshots.sort { $0.date < $1.date }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        snapshots = (try? JSONDecoder().decode([DailySenseSnapshot].self, from: data)) ?? []
        cleanup()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
