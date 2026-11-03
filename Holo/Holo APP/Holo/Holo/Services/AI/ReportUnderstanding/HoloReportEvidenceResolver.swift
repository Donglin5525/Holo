//
//  HoloReportEvidenceResolver.swift
//  Holo
//
//  写库前的证据独立性裁决与增量分类（README §6.2/§6.6，验收 R04/R05/R15/R16/R31）。
//  - 同 aggregateDefinition（指标口径）且观测窗重叠 → 独立性 unknown：
//    证据保留但不提升置信（不虚增独立支持，R04）；
//  - 窗口无法识别（任一侧为 nil）→ 保守按重叠处理（R05）；
//  - 同口径同窗但数值冲突 → 该命题置 disputed，不静默覆盖（R15）；
//  - 纯重复（无新 lineageKey）不写库：不刷新支持时间、不抬版本（§6.2）。
//

import Foundation

nonisolated enum HoloReportEvidenceResolver {

    struct Resolution: Sendable {
        var record: HoloMemoryRecord
        var increment: HoloReportFindingIncrement
        var shouldUpsert: Bool
        /// 新证据中存在独立性 unknown（窗口重叠/未知）的条数——影子统计单独计。
        var independenceUnknownCount: Int
    }

    static func resolve(
        incoming: HoloMemoryRecord,
        existing: HoloMemoryRecord?,
        now: Date = Date()
    ) -> Resolution {
        guard let existing else {
            return Resolution(
                record: incoming,
                increment: .newProposition,
                shouldUpsert: true,
                independenceUnknownCount: 0
            )
        }

        let existingLineages = Set(existing.evidenceRefs.map(\.lineageKey))
        let newEvidence = incoming.evidenceRefs.filter { !existingLineages.contains($0.lineageKey) }

        // 纯重复：无新证据 → 不写库（不刷新支持时间/不抬版本）
        guard !newEvidence.isEmpty else {
            return Resolution(
                record: incoming,
                increment: .pureDuplicate,
                shouldUpsert: false,
                independenceUnknownCount: 0
            )
        }

        var resolved = incoming
        var unknownCount = 0
        var conflictDetected = false

        for evidence in newEvidence {
            let definition = evidence.aggregateDefinition ?? ""
            let counterparts = existing.evidenceRefs.filter {
                ($0.aggregateDefinition ?? "") == definition && !definition.isEmpty
            }
            guard !counterparts.isEmpty else { continue }
            if let conflict = counterparts.first(where: {
                windowsEqual($0, evidence) && valueConflicts($0, evidence)
            }) {
                _ = conflict
                conflictDetected = true
                continue
            }
            if counterparts.contains(where: { windowsOverlap($0, evidence) }) {
                unknownCount += 1
            }
        }

        // 独立性 unknown：证据保留但置信不提升（不虚增独立支持）
        if unknownCount > 0 {
            resolved.confidenceScore = min(
                resolved.confidenceScore,
                existing.confidenceScore
            )
        }
        // R15：同口径同窗数值冲突 → 置 disputed（不可用于当前回答，回源核查）
        if conflictDetected {
            resolved.state = .disputed
            resolved.confidenceScore = min(resolved.confidenceScore, 0.4)
        }

        // 增量五分类（§6.6）
        let increment: HoloReportFindingIncrement
        let unavailableStates: Set<HoloMemoryState> = [.candidate, .invalidated, .archived, .superseded]
        if conflictDetected {
            increment = .conditionOrWindowChange
        } else if unavailableStates.contains(existing.state), resolved.state == .active {
            increment = .madeUsable
        } else if resolved.claimKind == .phaseShift, windowsDisjoint(existing: existing, incoming: incoming) {
            // 阶段变化：上月困难/本月恢复 → 同命题新阶段，不是矛盾（R16）
            increment = .conditionOrWindowChange
        } else if unknownCount > 0 {
            increment = .conditionOrWindowChange
        } else {
            increment = .newIndependentEvidence
        }

        return Resolution(
            record: resolved,
            increment: increment,
            shouldUpsert: true,
            independenceUnknownCount: unknownCount
        )
    }

    // MARK: - 窗口与数值比较

    private static func windowsOverlap(
        _ lhs: HoloMemoryEvidenceRef,
        _ rhs: HoloMemoryEvidenceRef
    ) -> Bool {
        // 任一侧窗口未知 → 保守视为重叠（独立性 unknown，R05）
        guard let lStart = lhs.validFrom, let lEnd = lhs.validTo,
              let rStart = rhs.validFrom, let rEnd = rhs.validTo else {
            return true
        }
        return lStart <= rEnd && rStart <= lEnd
    }

    private static func windowsEqual(
        _ lhs: HoloMemoryEvidenceRef,
        _ rhs: HoloMemoryEvidenceRef
    ) -> Bool {
        guard let lStart = lhs.validFrom, let lEnd = lhs.validTo,
              let rStart = rhs.validFrom, let rEnd = rhs.validTo else {
            return false
        }
        return lStart == rStart && lEnd == rEnd
    }

    /// 数值冲突判定：同口径同窗但摘要携带的数值不一致（>0.5% 或绝对 0.01）。
    /// 摘要格式由 extractor 的 materialSummary 固定（"key · dataset · 123.00元 · n=…"）。
    private static func valueConflicts(
        _ lhs: HoloMemoryEvidenceRef,
        _ rhs: HoloMemoryEvidenceRef
    ) -> Bool {
        guard let lValue = numericValue(in: lhs.summary),
              let rValue = numericValue(in: rhs.summary) else {
            return false
        }
        let tolerance = max(abs(lValue) * 0.005, 0.01)
        return abs(lValue - rValue) > tolerance
    }

    /// 从受控摘要格式提取首个数值（材料值），提取不到返回 nil（不判冲突）。
    static func numericValue(in summary: String?) -> Double? {
        guard let summary else { return nil }
        let parts = summary.components(separatedBy: " · ")
        // 格式：metricKey · dataset · <value><unit> · n=<count>
        guard parts.count >= 3 else { return nil }
        let valuePart = parts[2]
        let digits = valuePart.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    private static func windowsDisjoint(
        existing: HoloMemoryRecord,
        incoming: HoloMemoryRecord
    ) -> Bool {
        guard let existingEnd = existing.validTo, let incomingStart = incoming.validFrom else {
            return false
        }
        return incomingStart > existingEnd
    }
}
