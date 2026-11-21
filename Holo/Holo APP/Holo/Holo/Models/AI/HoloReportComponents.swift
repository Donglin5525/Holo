//
//  HoloReportComponents.swift
//  Holo
//
//  深度报告数据组件契约（2026-11-20 报告改版 B 期）：
//  组件数据由后端程序从快照算出（componentComputator.js），模型不产数字；
//  anchor = -1 放报告「总」区（标题/导语之后），≥0 放第 anchor 个小节正文之后。
//  解码逐项容错：单个组件 kind 未知或 payload 坏掉只丢该组件，不拖垮整份报告。
//  方案：docs/_common/plans/2026-11-20-深度报告可读性与目标复盘改版/01-方案.md §3.1
//

import Foundation

nonisolated enum HoloReportTone: String, Codable, Equatable, Sendable {
    case good, warn, bad, neutral
}

nonisolated struct HoloReportComponent: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var anchor: Int
    var payload: Payload

    nonisolated enum Payload: Equatable, Sendable {
        case progress(Progress)
        case kpiTiles(KPITiles)
        case trendLine(TrendLine)
        case barSeries(BarSeries)
        case habitStrip(HabitStrip)
        case periodCompare(PeriodCompare)
        case gapCards(GapCards)
        case milestones(Milestones)

        var kind: String {
            switch self {
            case .progress: return "progress"
            case .kpiTiles: return "kpiTiles"
            case .trendLine: return "trendLine"
            case .barSeries: return "barSeries"
            case .habitStrip: return "habitStrip"
            case .periodCompare: return "periodCompare"
            case .gapCards: return "gapCards"
            case .milestones: return "milestones"
            }
        }
    }

    // MARK: - payload 结构

    struct Progress: Codable, Equatable, Sendable {
        struct Projection: Codable, Equatable, Sendable {
            var label: String
            var value: String
            var tone: HoloReportTone?
        }
        var title: String
        var unit: String?
        var current: Double?
        var start: Double?
        var target: Double?
        /// 0...1；无结果量时 nil（过程型 / 缺测不画虚假百分比）
        var fraction: Double?
        /// 时间进度 0...1；无截止日时 nil
        var timeFraction: Double?
        var statusLabel: String
        var tone: HoloReportTone?
        /// 结果数据过期（>7 天未观测）：进度条虚化
        var isStale: Bool?
        var caption: String?
        var projections: [Projection]?
    }

    struct KPITiles: Codable, Equatable, Sendable {
        struct Tile: Codable, Equatable, Sendable {
            var label: String
            var value: String
            var unit: String?
            var delta: String?
            var tone: HoloReportTone?
        }
        var tiles: [Tile]
    }

    struct Point: Codable, Equatable, Sendable {
        var label: String
        var value: Double
    }

    struct TrendLine: Codable, Equatable, Sendable {
        var title: String
        var unit: String?
        var points: [Point]
        /// 计划线（首尾两点值），无则不画
        var planStart: Double?
        var planEnd: Double?
        /// 从该下标起高亮（「近 3 周」区间）
        var highlightFrom: Int?
        var highlightLabel: String?
        var caption: String?
    }

    struct BarSeries: Codable, Equatable, Sendable {
        var title: String
        var unit: String?
        var bars: [Point]
        var highlightFrom: Int?
        var caption: String?
    }

    struct HabitStrip: Codable, Equatable, Sendable {
        struct Row: Codable, Equatable, Sendable {
            var name: String
            var sub: String?
            var rateText: String?
            var statusLabel: String?
            var tone: HoloReportTone?
            /// 逐日 0/1（最多 56 天，旧→新）
            var days: [Int]
        }
        var title: String?
        var rows: [Row]
        var foldedNote: String?
        var startLabel: String?
        var endLabel: String?
    }

    struct PeriodCompare: Codable, Equatable, Sendable {
        struct Side: Codable, Equatable, Sendable {
            struct Row: Codable, Equatable, Sendable {
                var label: String
                var value: String
            }
            var label: String
            var rows: [Row]
        }
        var left: Side
        var right: Side
        var caption: String?
    }

    struct GapCards: Codable, Equatable, Sendable {
        struct Card: Codable, Equatable, Sendable {
            var icon: String?
            var title: String
            var body: String
            var action: String?
        }
        var cards: [Card]
    }

    struct Milestones: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            var label: String
            var body: String
            var done: Bool?
        }
        var title: String?
        var items: [Item]
    }

    // MARK: - Codable（kind + payload 扁平信封）

    private enum CodingKeys: String, CodingKey {
        case id, kind, anchor, payload
    }

    init(id: String, anchor: Int, payload: Payload) {
        self.id = id
        self.anchor = anchor
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        anchor = try c.decodeIfPresent(Int.self, forKey: .anchor) ?? -1
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "progress": payload = .progress(try c.decode(Progress.self, forKey: .payload))
        case "kpiTiles": payload = .kpiTiles(try c.decode(KPITiles.self, forKey: .payload))
        case "trendLine": payload = .trendLine(try c.decode(TrendLine.self, forKey: .payload))
        case "barSeries": payload = .barSeries(try c.decode(BarSeries.self, forKey: .payload))
        case "habitStrip": payload = .habitStrip(try c.decode(HabitStrip.self, forKey: .payload))
        case "periodCompare": payload = .periodCompare(try c.decode(PeriodCompare.self, forKey: .payload))
        case "gapCards": payload = .gapCards(try c.decode(GapCards.self, forKey: .payload))
        case "milestones": payload = .milestones(try c.decode(Milestones.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知组件 kind=\(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(payload.kind, forKey: .kind)
        switch payload {
        case .progress(let p): try c.encode(p, forKey: .payload)
        case .kpiTiles(let p): try c.encode(p, forKey: .payload)
        case .trendLine(let p): try c.encode(p, forKey: .payload)
        case .barSeries(let p): try c.encode(p, forKey: .payload)
        case .habitStrip(let p): try c.encode(p, forKey: .payload)
        case .periodCompare(let p): try c.encode(p, forKey: .payload)
        case .gapCards(let p): try c.encode(p, forKey: .payload)
        case .milestones(let p): try c.encode(p, forKey: .payload)
        }
    }

    /// 逐项容错解码：坏组件丢弃，其余保留
    static func decodeLossy(from decoder: Decoder) -> [HoloReportComponent] {
        guard var array = try? decoder.unkeyedContainer() else { return [] }
        var result: [HoloReportComponent] = []
        while !array.isAtEnd {
            if let component = try? array.decode(HoloReportComponent.self) {
                result.append(component)
            } else {
                _ = try? array.decode(DiscardedComponent.self)
            }
        }
        return result
    }

    private struct DiscardedComponent: Decodable {}
}

/// 包一层让 Codable 结构体能对数组做逐项容错
nonisolated struct HoloReportComponentList: Codable, Equatable, Sendable {
    var items: [HoloReportComponent]

    init(_ items: [HoloReportComponent]) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        items = HoloReportComponent.decodeLossy(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(items)
    }
}
