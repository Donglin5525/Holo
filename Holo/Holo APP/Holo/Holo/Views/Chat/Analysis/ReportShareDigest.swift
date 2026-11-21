//
//  ReportShareDigest.swift
//  Holo
//
//  一屏分享图的内容摘要（纯值，2026-11-20 报告改版 A 期）：
//  标题 → 导语前几句 → 最多 3 个要点（小节标题 + 首句）→ 1 条下一步。
//  只做「挑什么」，不做「怎么排」；排版在 ReportOnePageShareCard，放不下按优先级丢要点。
//

import Foundation

nonisolated struct ReportShareDigest: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var title: String
        var line: String
    }

    /// 一屏卡里的组件最简形态：进度环 / 数字卡 / 关联事项每周柱
    struct HabitBars: Equatable, Sendable {
        var name: String
        var statusLabel: String?
        var tone: HoloReportTone?
        /// 每周完成次数（旧→新，最多 8 周）
        var weekly: [Int]
    }

    var title: String
    var lede: String?
    var points: [Point]
    var nextStep: String?
    var progress: HoloReportComponent.Progress? = nil
    var tiles: [HoloReportComponent.KPITiles.Tile] = []
    var habits: [HabitBars] = []

    static let maxHabitRows = 4
    static let maxWeeks = 8

    static let maxPoints = 3
    static let ledeMaxChars = 80
    static let pointLineMaxChars = 46
    static let nextStepMaxChars = 70
    /// 新引擎 mapper 给导语后松散段落起的占位小节名，不作为要点标题
    private static let placeholderSectionTitles: Set<String> = ["开篇", "小结"]

    struct SectionInput: Equatable, Sendable {
        var title: String
        var paragraphs: [String]
    }

    static func make(
        title: String,
        lede: String?,
        sections: [SectionInput],
        conclusions: [String],
        recommendations: [(title: String, body: String)],
        components: [HoloReportComponent] = []
    ) -> ReportShareDigest {
        let trimmedLede = (lede ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ledeText = trimmedLede.isEmpty ? nil : ReportReadableText.leadSentences(trimmedLede, maxChars: ledeMaxChars)

        let points: [Point] = sections.compactMap { section -> Point? in
            let sectionTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionTitle.isEmpty, !placeholderSectionTitles.contains(sectionTitle),
                  let first = section.paragraphs.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            return Point(title: sectionTitle, line: ReportReadableText.leadSentences(first, maxChars: pointLineMaxChars))
        }

        let nextStep: String? = {
            if let conclusion = conclusions.first(where: { !$0.isEmpty }) {
                return ReportReadableText.leadSentences(conclusion, maxChars: nextStepMaxChars)
            }
            if let rec = recommendations.first {
                let body = ReportReadableText.leadSentences(rec.body, maxChars: nextStepMaxChars - rec.title.count)
                return body.isEmpty ? rec.title : "\(rec.title)：\(body)"
            }
            return nil
        }()

        var digest = ReportShareDigest(
            title: title,
            lede: ledeText,
            points: Array(points.prefix(maxPoints)),
            nextStep: nextStep
        )
        digest.applyComponents(components)
        return digest
    }

    /// 组件 → 一屏最简形态：progress 优先于数字卡；习惯逐日格压成每周次数柱
    private mutating func applyComponents(_ components: [HoloReportComponent]) {
        for component in components {
            switch component.payload {
            case .progress(let p) where progress == nil:
                progress = p
            case .kpiTiles(let p) where tiles.isEmpty:
                tiles = Array(p.tiles.prefix(3))
            case .habitStrip(let p):
                habits += p.rows.map { row in
                    HabitBars(name: row.name, statusLabel: row.statusLabel, tone: row.tone,
                              weekly: Self.weeklyCounts(row.days))
                }
            default:
                break
            }
        }
        habits = Array(habits.prefix(Self.maxHabitRows))
    }

    static func weeklyCounts(_ days: [Int]) -> [Int] {
        let weeks = stride(from: 0, to: days.count, by: 7).map { start in
            days[start..<min(start + 7, days.count)].filter { $0 > 0 }.count
        }
        return Array(weeks.suffix(maxWeeks))
    }
}
