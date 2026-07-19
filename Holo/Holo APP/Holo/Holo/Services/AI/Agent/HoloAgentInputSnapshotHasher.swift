//
//  HoloAgentInputSnapshotHasher.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 1（§5.1，修 P0-1）
//  稳定输入快照：canonical JSON（sortedKeys + ISO-8601 UTC + 可选值显式编码）+ CryptoKit SHA-256。
//  取代 Swift `Hasher`（每进程随机 seed，跨进程不稳定，重启后误判输入变化跳过恢复）。
//

import Foundation
import CryptoKit

/// Agent 任务的稳定输入快照：只描述「任务输入身份」，不含执行过程数据。
nonisolated struct HoloAgentInputSnapshot: Codable, Sendable, Equatable {
    /// 快照结构版本（当前 1）。
    var schemaVersion: Int
    var jobType: HoloAgentJobType
    var userQuestion: String?
    var timeRange: HoloAgentTimeRange?
    /// 证据参照时间（创建 job 时冻结，§7.3）。
    var referenceDate: Date
    /// 数据快照截止：恢复后未完成工具查询不得混入此时间之后的新数据。
    var snapshotCutoffAt: Date
    /// 工具目录版本：工具集合语义变化时递增，使旧快照自然失效。
    var toolCatalogVersion: Int

    /// 显式编码全部 key（可选值编码为 null），保证 canonical 输出与字段存在性无关。
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, jobType, userQuestion, timeRange, referenceDate, snapshotCutoffAt, toolCatalogVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(jobType, forKey: .jobType)
        try container.encode(userQuestion, forKey: .userQuestion)
        try container.encode(timeRange, forKey: .timeRange)
        try container.encode(referenceDate, forKey: .referenceDate)
        try container.encode(snapshotCutoffAt, forKey: .snapshotCutoffAt)
        try container.encode(toolCatalogVersion, forKey: .toolCatalogVersion)
    }
}

/// 稳定输入快照 hash 入口（§5.1）。
enum HoloAgentInputSnapshotHasher {

    /// 当前快照 schema 版本。
    static let currentSchemaVersion = 1
    /// 工具目录版本（现无独立目录版本概念，固定 1；工具语义变化时手工递增）。
    static let currentToolCatalogVersion = 1

    /// 从 job 构造快照：referenceDate/snapshotCutoffAt 取 job 冻结字段，旧数据 nil 时回落 createdAt。
    static func snapshot(for job: HoloAgentJob) -> HoloAgentInputSnapshot {
        HoloAgentInputSnapshot(
            schemaVersion: currentSchemaVersion,
            jobType: job.type,
            userQuestion: job.userQuestion,
            timeRange: job.timeRange,
            referenceDate: job.referenceDate ?? job.createdAt,
            snapshotCutoffAt: job.snapshotCutoffAt ?? job.createdAt,
            toolCatalogVersion: currentToolCatalogVersion
        )
    }

    /// canonical JSON：key 固定排序、日期 ISO-8601 UTC（`.iso8601` 策略恒为 GMT，不受环境时区影响）。
    static func canonicalJSONData(for snapshot: HoloAgentInputSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    /// SHA-256 → 小写 hex（64 字符）。
    static func hash(for snapshot: HoloAgentInputSnapshot) -> String {
        guard let data = try? canonicalJSONData(for: snapshot) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 从 job 直接计算稳定 hash（恢复对比与 checkpoint 落盘共用同一入口）。
    static func hash(for job: HoloAgentJob) -> String {
        hash(for: snapshot(for: job))
    }

    /// 是否为稳定格式 hash（64 位小写 hex）。
    /// 旧 Swift `Hasher` 值（十进制整数串）不满足 → 视为 legacy，不得用于拒绝恢复（§十 Phase 1 任务 2）。
    static func isStableHash(_ candidate: String) -> Bool {
        candidate.count == 64 && candidate.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// 通用 canonical SHA-256（§5.3 requestHash/responseHash 复用与输入快照同一规则：
    /// sortedKeys + ISO-8601 UTC）。编码失败返回空串（调用方视为不可用标识）。
    static func canonicalHash<T: Encodable>(for value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), !data.isEmpty else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
