//
//  HoloCloudAnalysisSnapshotBuilder.swift
//  Holo
//
//  云端异步分析（二期 M2b）——设备侧快照聚合器。
//  发起云端分析时把各数据域的结构化行数据打成一份快照 JSON（与云端查询引擎
//  的 datasets 协议对齐：{version, generatedAt, datasets:{name:{fields,rows}}}）。
//  - 取数复用 HoloDefaultCrossDomainDataSource 的统一分发（与本地 Agent 工具同一条路，
//    语义零漂移）；字段定义直接引用各工具的静态 catalog，不另维护一份。
//  - 合规边界（设计稿 2026-08-30）：健康域不进快照——涉健康的分析走本地轨道。
//  - 体积控制：默认近 180 天窗口 + 单数据集行数上限，超出按时间倒序截断，
//    适配后端 2MB 快照限制。
//

import Foundation

nonisolated enum HoloCloudAnalysisSnapshotBuilder {

    struct Snapshot: Encodable {
        struct FieldDef: Encodable {
            let name: String
            let type: String
            let unit: String?
        }
        struct Dataset: Encodable {
            let fields: [FieldDef]
            let rows: [[String: JSONValue]]
        }
        let version: Int
        let generatedAt: Date
        let historyDays: Int
        let datasets: [String: Dataset]
    }

    enum JSONValue: Encodable {
        case number(Double)
        case text(String)
        case boolean(Bool)

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let v): try c.encode(v)
            case .text(let v): try c.encode(v)
            case .boolean(let v): try c.encode(v)
            }
        }
    }

    static let defaultHistoryDays = 180
    static let maxRowsPerDataset = 2_000

    /// 进快照的数据目录：引用各工具静态定义（字段不脱节）。健康域按二期合规决策排除。
    static var snapshotCatalogs: [HoloDataCatalog] {
        [
            HoloFinanceTool.dynamicCatalog,
            HoloAgentDynamicCatalogs.task,
            HoloAgentDynamicCatalogs.habit,
            HoloAgentDynamicCatalogs.thought,
            HoloAgentDynamicCatalogs.goal,
            HoloAgentDynamicCatalogs.memory,
            HoloAgentDynamicCatalogs.conversation,
            HoloAgentDynamicCatalogs.anniversary,
            HoloAgentDynamicCatalogs.insight,
            HoloAgentDynamicCatalogs.profile,
        ]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// 聚合快照并序列化为 JSON Data（PUT body 直接使用）。
    static func buildJSON(
        now: Date = Date(),
        historyDays: Int = defaultHistoryDays,
        maxRows: Int = maxRowsPerDataset
    ) async throws -> Data {
        let start = Calendar.current.date(byAdding: .day, value: -historyDays, to: now) ?? now
        let range = HoloAgentTimeRange(label: "云端分析快照窗口", start: start, end: now)
        let source = HoloDefaultCrossDomainDataSource()

        var datasets: [String: Snapshot.Dataset] = [:]
        for catalog in snapshotCatalogs {
            for schema in catalog.datasets {
                let rows = await source.rows(source: schema.name, timeRange: range)
                guard !rows.isEmpty else { continue }
                let limited = Array(rows.sorted { $0.occurredAt > $1.occurredAt }.prefix(maxRows))
                datasets[schema.name] = Snapshot.Dataset(
                    fields: schema.fields.map {
                        Snapshot.FieldDef(name: $0.name, type: $0.type.rawValue, unit: $0.unit)
                    },
                    rows: limited.map { row in
                        var fields: [String: JSONValue] = [
                            "id": .text(row.id),
                            "occurredAt": .text(isoFormatter.string(from: row.occurredAt)),
                        ]
                        for (name, value) in row.fields {
                            switch value {
                            case .number(let v): fields[name] = .number(v)
                            case .text(let v): fields[name] = .text(v)
                            case .date(let v): fields[name] = .text(isoFormatter.string(from: v))
                            case .boolean(let v): fields[name] = .boolean(v)
                            }
                        }
                        if !row.excerpt.isEmpty { fields["excerpt"] = .text(row.excerpt) }
                        return fields
                    }
                )
            }
        }
        let snapshot = Snapshot(
            version: 1,
            generatedAt: now,
            historyDays: historyDays,
            datasets: datasets
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}
