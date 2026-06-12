//
//  DailySenseSnapshot.swift
//  Holo
//
//  每日状态雷达模型（v3）
//  3 个状态：stable / atRisk / recovering
//  结构化信号 + 状态标签替代强生活判断
//

import Foundation

// MARK: - 信号模型

/// 信号维度
enum SenseDimension: String, Codable, CaseIterable {
    case task
    case habit
    case expense
    case health

    var displayName: String {
        switch self {
        case .task: return "待办"
        case .habit: return "习惯"
        case .expense: return "消费"
        case .health: return "健康"
        }
    }
}

/// 信号等级
enum SignalLevel: String, Codable {
    case normal    // .holoSuccess 绿
    case warning   // .orange 橙
    case critical  // .holoError 红
}

/// 单维度信号
struct DailySenseSignal: Codable, Equatable {
    let dimension: SenseDimension
    let level: SignalLevel
    let text: String
}

// MARK: - 状态模型

/// 每日状态
enum DailySenseState: String, Codable {
    case stable       // 节奏不错
    case atRisk       // 节奏有点乱
    case recovering   // 节奏在找回
}

/// 状态标签。只作为副文案，不扩展主状态。
enum DailySenseTag: String, Codable, CaseIterable {
    case highPressure
    case newStage

    var displayName: String {
        switch self {
        case .highPressure: return "信号偏紧"
        case .newStage: return "出现新阶段"
        }
    }

    var safeSummary: String {
        switch self {
        case .highPressure: return "这几个信号像是一起偏紧，先不用过度解读。"
        case .newStage: return "最近有一个值得单独留意的新阶段。"
        }
    }
}

/// 每日状态快照
struct DailySenseSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    let date: Date
    let state: DailySenseState
    let signals: [DailySenseSignal]
    let tags: [DailySenseTag]
    let generatedAt: Date

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case date
        case state
        case signals
        case tags
        case generatedAt
        // Legacy keys（仅用于解码）
        case confidence
        case reasons
    }

    // MARK: - Codable（向后兼容）

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // schemaVersion 可能为空（legacy 格式）
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        date = try container.decode(Date.self, forKey: .date)
        state = try container.decode(DailySenseState.self, forKey: .state)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)

        // signals/tags 可能为空（legacy 格式）
        signals = try container.decodeIfPresent([DailySenseSignal].self, forKey: .signals) ?? []
        tags = try container.decodeIfPresent([DailySenseTag].self, forKey: .tags) ?? []

        // 忽略 legacy 字段（confidence, reasons）
        // 这些字段在 v1 中存在，但在 v2 中已废弃
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(date, forKey: .date)
        try container.encode(state, forKey: .state)
        try container.encode(signals, forKey: .signals)
        try container.encode(tags, forKey: .tags)
        try container.encode(generatedAt, forKey: .generatedAt)
    }

    // MARK: - Regular Init（当前格式）

    init(date: Date, state: DailySenseState, signals: [DailySenseSignal], tags: [DailySenseTag] = [], generatedAt: Date) {
        self.schemaVersion = Self.currentSchemaVersion
        self.date = date
        self.state = state
        self.signals = signals
        self.tags = tags
        self.generatedAt = generatedAt
    }

    init(schemaVersion: Int, date: Date, state: DailySenseState, signals: [DailySenseSignal], tags: [DailySenseTag] = [], generatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.date = date
        self.state = state
        self.signals = signals
        self.tags = tags
        self.generatedAt = generatedAt
    }

    // MARK: - Computed Properties

    /// 是否为 legacy 格式（schemaVersion < 2）
    var isLegacy: Bool { schemaVersion < 2 }

    /// 是否匹配当前 Daily Sense 规则版本
    var isCurrentSchema: Bool { schemaVersion == Self.currentSchemaVersion }

    /// 状态标题
    var stateTitle: String {
        switch state {
        case .stable: return "节奏不错"
        case .atRisk: return "节奏有点乱"
        case .recovering: return "节奏在找回"
        }
    }
}

// MARK: - Store

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

    /// 清除今日快照，供源数据变更后重新生成
    func invalidateToday() {
        let calendar = Calendar.current
        snapshots.removeAll { calendar.isDate($0.date, inSameDayAs: Date()) }
        save()
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: fileURL) else { return }
        snapshots = (try? decoder.decode([DailySenseSnapshot].self, from: data)) ?? []
        cleanup()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(snapshots) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
