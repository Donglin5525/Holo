//
//  MemoryObserverOutputValidator.swift
//  Holo
//
//  Observer 输出校验器：拦截非法 confidence、幻觉 evidenceRefs、suppression 命中
//

import Foundation

struct MemoryObserverValidationResult {
    var validNewMemories: [ValidatedNewMemory]
    var validHits: [MemoryHitEntry]
    var validWeakened: [WeakenedEntry]
    var rejectedEntries: [RejectedEntry]
}

struct RejectedEntry {
    var reason: String
    var rawData: String?
}

struct ValidatedNewMemory {
    var title: String
    var summary: String
    var confidence: Double
    var sensitivity: HoloMemorySensitivity
    var visibility: HoloMemoryVisibility
    var evidenceRefs: [String]
    var reasoningSummary: String
    var expiresInDays: Int
}

enum MemoryObserverOutputValidator {

    static func validateDomainOutput(
        _ data: Data,
        against package: HoloDomainObservationPackage,
        now: Date,
        extractorVersion: Int,
        promptVersion: Int
    ) -> HoloDomainMemoryValidationResult {
        HoloDomainMemoryOutputValidator.decodeAndValidate(
            data,
            against: package,
            now: now,
            extractorVersion: extractorVersion,
            promptVersion: promptVersion
        )
    }

    static func validate(
        _ output: HoloMemoryObserverOutput,
        against package: HoloObservationPackage,
        suppressionRules: [HoloMemorySuppressionRule]
    ) -> MemoryObserverValidationResult {
        var result = MemoryObserverValidationResult(
            validNewMemories: [],
            validHits: [],
            validWeakened: [],
            rejectedEntries: []
        )

        let allSignalIDs = Set(package.habitSignals.map(\.id) + package.goalSignals.map(\.id))
        let existingEpisodicIDs = Set(package.existingEpisodicMemories.map(\.id))
        let now = Date()

        // 校验新记忆
        for entry in output.newEpisodicMemories {
            // 校验 1：confidence 范围 [0.0, 1.0]
            guard entry.confidence >= 0.0, entry.confidence <= 1.0 else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "confidence \(entry.confidence) 超出 [0.0, 1.0] 范围",
                    rawData: entry.title
                ))
                continue
            }

            // 校验 2：confidence 最低阈值 0.4
            guard entry.confidence >= 0.4 else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "confidence \(entry.confidence) 低于阈值 0.4",
                    rawData: entry.title
                ))
                continue
            }

            // 校验 3：evidenceRefs 必须在输入信号中存在
            let validRefs = entry.evidenceRefs.filter { allSignalIDs.contains($0) }
            guard !validRefs.isEmpty else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "evidenceRefs 全部不在输入信号中（幻觉）",
                    rawData: entry.title
                ))
                continue
            }

            // 校验 4：expiresInDays 范围 [7, 90]
            guard entry.expiresInDays >= 7, entry.expiresInDays <= 90 else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "expiresInDays \(entry.expiresInDays) 超出 [7, 90] 范围",
                    rawData: entry.title
                ))
                continue
            }

            // 校验 5：敏感记忆 visibility 不能是 hidden
            let sensitivity = HoloMemorySensitivity(rawValue: entry.sensitivity) ?? .normal
            let visibility = HoloMemoryVisibility(rawValue: entry.visibility) ?? .suggested
            if (sensitivity == .sensitive || sensitivity == .highImpact) && visibility == .hidden {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "敏感记忆 visibility 不能是 hidden",
                    rawData: entry.title
                ))
                continue
            }

            // 校验 6：suppression 关键词匹配
            let isSuppressed = suppressionRules.contains { rule in
                guard rule.suppressedUntil > now else { return false }
                return rule.keywordGroups.contains { group in
                    group.contains { keyword in
                        entry.memoryText.contains(keyword) || entry.title.contains(keyword)
                    }
                }
            }
            guard !isSuppressed else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "命中 suppression rule（用户已拒绝过类似内容）",
                    rawData: entry.title
                ))
                continue
            }

            // 通过所有校验
            result.validNewMemories.append(ValidatedNewMemory(
                title: entry.title,
                summary: entry.memoryText,
                confidence: entry.confidence,
                sensitivity: sensitivity,
                visibility: visibility,
                evidenceRefs: validRefs,
                reasoningSummary: entry.reasoningSummary,
                expiresInDays: entry.expiresInDays
            ))
        }

        // 校验 memoryHits：episodicMemoryID 必须存在
        for hit in output.memoryHits {
            guard existingEpisodicIDs.contains(hit.episodicMemoryID) else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "memoryHit 引用了不存在的 episodicMemoryID: \(hit.episodicMemoryID)",
                    rawData: hit.episodicMemoryID
                ))
                continue
            }
            result.validHits.append(hit)
        }

        // 校验 weakened：episodicMemoryID 必须存在
        for weakened in output.weakenedOrExpiredMemories {
            guard existingEpisodicIDs.contains(weakened.episodicMemoryID) else {
                result.rejectedEntries.append(RejectedEntry(
                    reason: "weakened 引用了不存在的 episodicMemoryID: \(weakened.episodicMemoryID)",
                    rawData: weakened.episodicMemoryID
                ))
                continue
            }
            result.validWeakened.append(weakened)
        }

        return result
    }
}
