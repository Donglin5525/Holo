//
//  ShadowReviewExporter.swift
//  Holo
//
//  理解引擎 M2.8：影子产出评审导出（DEBUG/实验室用，07-M2施工图）。
//
//  输出全轨迹 JSON（候选/阶段/闸判决理由/证据引用），供东林与评审查看。
//  影子期数据只在本机；导出内容即评审内容——不含金额与精确数值（观察类型本身无数值）。
//

import Foundation

nonisolated enum ShadowReviewExporter {

    struct ReviewPackage: Codable, Equatable {
        var exportedAt: Date
        var schemaVersion: Int
        var candidates: [CandidateReview]
        var themeSummary: [ThemeSummary]
    }

    struct CandidateReview: Codable, Equatable {
        var id: String
        var themeKey: String
        var stage: String
        var attempts: Int
        var lastReason: String?
        /// 认识三标记（方案 §4.2，2026-11-15）：根据什么知道 / 适用于什么时候 /
        /// 可以怎样使用。评审可见「用户自述」与「行为推断」的分层与使用范围。
        var provenance: String?
        var validity: String?
        var usage: String?
        /// 该主题当前成员观察的可读摘要（域/概念/归属，无原文无数值）。
        var evidenceDigest: [String]
    }

    struct ThemeSummary: Codable, Equatable {
        var key: String
        var domains: [String]
        var memberCount: Int
        var concepts: [String]
    }

    /// 组装评审包：台账 + 主题 + 索引证据摘要。
    static func assemble(ledger: ShadowLedger,
                         themes: [ObservationTheme],
                         index: ObservationIndex,
                         now: Date = Date()) -> ReviewPackage {
        let byID = index.observations
        let themesByKey = Dictionary(uniqueKeysWithValues: themes.map { ($0.key, $0) })

        let candidates = ledger.snapshot().map { candidate -> CandidateReview in
            let theme = themesByKey[candidate.themeKey]
            let digest: [String] = (theme?.memberIDs ?? []).compactMap { id in
                guard let obs = byID[id] else { return nil }
                return "\(obs.domain.rawValue)|\(obs.concepts.joined(separator: "/"))|\(obs.attribution.rawValue)|\(obs.businessState.rawValue)"
            }
            return CandidateReview(id: candidate.id, themeKey: candidate.themeKey,
                                   stage: candidate.stage.rawValue, attempts: candidate.attempts,
                                   lastReason: candidate.lastReason,
                                   provenance: candidate.provenance?.rawValue,
                                   validity: candidate.validity?.rawValue,
                                   usage: candidate.usage?.rawValue,
                                   evidenceDigest: digest)
        }

        let themeSummary = themes.map {
            ThemeSummary(key: $0.key, domains: $0.domains, memberCount: $0.memberIDs.count, concepts: $0.concepts)
        }
        return ReviewPackage(exportedAt: now, schemaVersion: 1,
                             candidates: candidates, themeSummary: themeSummary)
    }

    /// 导出为 JSON 数据（sortedKeys 保证同状态导出字节稳定，便于 diff 对比两轮评审）。
    static func exportJSON(_ package: ReviewPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }
}
