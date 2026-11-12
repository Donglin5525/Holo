//
//  ObservationProjectors.swift
//  Holo
//
//  理解引擎 M2.1：域投影器（finance/thought 首批样板，07-M2施工图）。
//
//  输入是「快照」而非仓库直连——与 MemorySignalDataAdapter 的 Input 模式一致，
//  单测不需要 Core Data。数据源适配（从 FinanceRepository/Thought 取数组装 Input）
//  由运行时侧负责，投影器保持纯函数。
//

import Foundation

// MARK: - 财务域投影

/// 财务观察输入（无金额——金额按数据边界不进理解引擎）。
nonisolated struct FinanceObservationInput: Sendable, Equatable {
    var id: String
    var note: String?
    var occurredAt: Date
    var recordedAt: Date
    var updatedAt: Date
    var isRefund: Bool
    var categoryName: String?

    /// 修订摘要：内容+类目+更新时间派生（与信号通道口径一致）。
    var revisionDigest: String {
        "\(Int(updatedAt.timeIntervalSince1970))-\(note ?? "-")-\(categoryName ?? "-")"
    }
}

/// 财务投影：备注 → 概念/归属/补账标记。规则全部词法可测。
nonisolated enum FinanceObservationProjector {
    static func project(_ inputs: [FinanceObservationInput]) -> [LifeObservation] {
        inputs.map { tx in
            let note = tx.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let (precision, coverage): (ObservationTimePrecision, ObservationCoverageNote?)
            if Self.isBatchBackfill(occurredAt: tx.occurredAt, recordedAt: tx.recordedAt) {
                (precision, coverage) = (.midnightDefault,
                    ObservationCoverageNote(kind: .batchBackfill, note: "补账：发生时间为默认午夜"))
            } else {
                (precision, coverage) = (Calendar.current.isDate(tx.occurredAt, inSameDayAs: tx.recordedAt)
                    ? (.minute, nil)
                    : (.day, nil))
            }
            return LifeObservation(
                domain: .finance,
                sourceRef: tx.id,
                sourceRevision: tx.revisionDigest,
                sourceKind: "transaction",
                occurredAt: tx.occurredAt,
                recordedAt: tx.recordedAt,
                timePrecision: precision,
                concepts: concepts(fromNote: note, categoryName: tx.categoryName),
                action: note.isEmpty ? nil : "购买",
                attribution: attribution(fromNote: note),
                businessState: tx.isRefund ? .negation : .plain,
                coverage: coverage,
                quote: note.isEmpty ? nil : note
            )
        }
    }

    /// 概念提取：按空白切词，丢含数字/量纲的 token（「猫粮 5kg」→「猫粮」），保留类目名。
    static func concepts(fromNote note: String, categoryName: String?) -> [String] {
        var result: [String] = []
        if !note.isEmpty {
            result += note.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { token in
                    !token.isEmpty && token.rangeOfCharacter(from: .decimalDigits) == nil
                }
        }
        if let category = categoryName, !category.isEmpty, !result.contains(category) {
            result.append(category)
        }
        return Array(result.prefix(4))
    }

    /// 归属：显式代办词法（「帮/替 + 带买购」「代购」）→ proxy；其余不猜（M1.6 教训）。
    static func attribution(fromNote note: String) -> ObservationAttribution {
        if note.contains("代购") { return .proxy }
        for verb in ["带的", "带点", "帮忙带", "帮带", "带一份", "帮买", "替买", "帮购", "帮拿"] where note.contains(verb) {
            return .proxy
        }
        if note.contains("帮") && note.contains("带") { return .proxy }
        return .unknown
    }

    /// 补账判定：发生时间为零点整（系统默认午夜）且记录时刻不是同一零点——
    /// 用户极少真在零点整分秒不差地记录（M1.1 caseB-backfill 同款：当天晚上补记，
    /// 发生时间落当天 00:00 默认值）。零点整当场记录无法与默认值区分，保守标记。
    static func isBatchBackfill(occurredAt: Date, recordedAt: Date) -> Bool {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute, .second], from: occurredAt)
        guard comps.hour == 0 && comps.minute == 0 && comps.second == 0 else { return false }
        return occurredAt != recordedAt
    }
}

// MARK: - 想法域投影

/// 想法观察输入（AI 派生内容由调用侧标记，投影器不猜）。
nonisolated struct ThoughtObservationInput: Sendable, Equatable {
    var id: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var isAIDerived: Bool

    var revisionDigest: String {
        "\(Int(updatedAt.timeIntervalSince1970))-\(Self.stableHash(text))"
    }

    /// FNV-1a：hashValue 跨进程不稳定（Swift 文档明确），索引持久化比较必须用稳定摘要。
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

nonisolated enum ThoughtObservationProjector {
    static func project(_ inputs: [ThoughtObservationInput]) -> [LifeObservation] {
        inputs.map { note in
            LifeObservation(
                domain: .thought,
                sourceRef: note.id,
                sourceRevision: note.revisionDigest,
                sourceKind: "userNote",
                occurredAt: note.createdAt,
                recordedAt: note.createdAt,
                timePrecision: .minute,
                concepts: [],            // 概念提取归 M2.2 主题层（原句全量保留可回查）
                action: nil,
                attribution: .self_,     // 想法模块默认本人书写；AI 摘要走 isAIDerived 标记
                businessState: note.isAIDerived ? .derived : .quote,
                coverage: nil,
                quote: note.text
            )
        }
    }
}
