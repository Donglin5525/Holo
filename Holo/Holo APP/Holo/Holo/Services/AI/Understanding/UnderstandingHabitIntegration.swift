//
//  UnderstandingHabitIntegration.swift
//  Holo
//
//  理解引擎 habit 域接入（2026-11-14 东林排期：只打卡不记账的用户
// 从此功能获得价值为零——把习惯打卡接为第三类观察来源）。
//
//  数据边界（工程稿 §5.2）：数值型习惯的具体 value 不进观察（本机留值），
// 只有概念（习惯名）、行为（打卡）、时间、完成态。打卡 0.7% 带备注，
// 备注作 quote 走授权门内上送。
//

import Foundation
import CoreData

// MARK: - 习惯观察输入

/// 习惯打卡观察输入（纯值快照，无 Core Data 依赖——standalone 可测）。
nonisolated struct HabitObservationInput: Sendable, Equatable {
    var recordID: String
    var habitID: String
    var habitName: String
    /// 数值型习惯：true（value 留本机不进观察）；打卡型：false。
    var isNumeric: Bool
    var isCompleted: Bool
    var note: String?
    var occurredAt: Date
    var updatedAt: Date

    /// 修订摘要只用业务字段（与财务域同口径：updatedAt 被 CloudKit 同步刷新
    /// 不得触发假变化——画像4实锤教训）。
    var revisionDigest: String {
        "\(Int(occurredAt.timeIntervalSince1970))-\(isCompleted)-\(note ?? "-")-\(habitName)"
    }
}

// MARK: - 投影器

nonisolated enum HabitObservationProjector {
    /// 打卡 → 观察：概念=习惯名（用户自建语义实体）、行为=打卡、归属=本人、
    /// 完成态。未完成的打卡（坏习惯/中断）同样入观察——「不再做」也是信号。
    static func project(_ inputs: [HabitObservationInput]) -> [LifeObservation] {
        inputs.map { record in
            let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return LifeObservation(
                domain: .habit,
                sourceRef: record.recordID,
                sourceRevision: record.revisionDigest,
                sourceKind: "checkin",
                occurredAt: record.occurredAt,
                recordedAt: record.occurredAt,
                timePrecision: .minute,
                concepts: [record.habitName],
                action: "打卡",
                attribution: .self_,
                businessState: record.isCompleted ? .done : .negation,
                coverage: nil,
                quote: note.isEmpty ? nil : note
            )
        }
    }
}
