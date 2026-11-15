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
    /// 所属习惯当前处于暂停态（Habit.isPaused）：暂停期的打卡不构成行为证据
    ///——用户主动暂停后，缺卡不是「中断/反复」，投影时整组排除。
    var isPaused: Bool = false
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
    /// 习惯名概念上限：用户可能把习惯名建成一句话，整句进 concepts 会污染
    /// 主题聚类（ThemeIndex 以概念为聚类 key）——超 20 字截断加省略标记。
    static let conceptNameLimit = 20

    /// 打卡 → 观察：概念=习惯名（用户自建语义实体，超长句截断）、行为=打卡、
    /// 归属=本人、完成态。未完成的打卡（坏习惯/中断）同样入观察——「不再做」也是信号。
    /// 暂停中的习惯整组排除：暂停期的缺卡不是「中断/反复」，入了观察会被
    /// HabitPhaseProposer 措辞成「期间有反复」（暂停被当中断的挂账本体）。
    static func project(_ inputs: [HabitObservationInput]) -> [LifeObservation] {
        inputs.filter { !$0.isPaused }.map { record in
            let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return LifeObservation(
                domain: .habit,
                sourceRef: record.recordID,
                sourceRevision: record.revisionDigest,
                sourceKind: "checkin",
                occurredAt: record.occurredAt,
                recordedAt: record.occurredAt,
                timePrecision: .minute,
                concepts: [Self.truncatedConcept(record.habitName)],
                action: "打卡",
                attribution: .self_,
                businessState: record.isCompleted ? .done : .negation,
                coverage: nil,
                quote: note.isEmpty ? nil : note
            )
        }
    }

    /// 习惯名截断：超 20 字 → 前 20 字+省略标记（「…」）。只截概念通道，
    /// quote（备注原文）不截——备注走授权门内上送，保留可回查原句。
    static func truncatedConcept(_ name: String) -> String {
        guard name.count > conceptNameLimit else { return name }
        return String(name.prefix(conceptNameLimit)) + "…"
    }
}
