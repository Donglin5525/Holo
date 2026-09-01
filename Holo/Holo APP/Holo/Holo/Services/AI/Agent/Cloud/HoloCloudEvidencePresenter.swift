//
//  HoloCloudEvidencePresenter.swift
//  Holo
//
//  云端异步分析（二期）——云端证据原料 → 用户可读展示。
//  metric 证据翻译成中文口径句，rows 证据用云端人话行摘录；
//  数据集/字段中文名与快照上传侧共用同一份静态目录，展示翻译不另维护一份。
//

import Foundation

nonisolated enum HoloCloudEvidencePresenter {

    /// 数据集中文名：key 为快照数据集名（finance.transactions 等）。
    /// 只取 schema.label（人看短名）；description 是写给模型的口径长文，禁止冒充展示名。
    static let datasetLabels: [String: String] = {
        var labels: [String: String] = [:]
        for catalog in HoloCloudAnalysisSnapshotBuilder.snapshotCatalogs {
            for schema in catalog.datasets {
                if let label = schema.label, !label.isEmpty {
                    labels[schema.name] = label
                }
            }
        }
        return labels
    }()

    /// 字段中文名：dataset → field → 短标签（与上传侧目录同源）。
    /// 只收录声明了 label 的字段；查不到的展示层一律省略字段名，不回退英文/长说明。
    static let fieldLabels: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for catalog in HoloCloudAnalysisSnapshotBuilder.snapshotCatalogs {
            for schema in catalog.datasets {
                let labeled = schema.fields.compactMap { field -> (String, String)? in
                    guard let label = field.label, !label.isEmpty else { return nil }
                    return (field.name, label)
                }
                result[schema.name] = Dictionary(labeled, uniquingKeysWith: { first, _ in first })
            }
        }
        return result
    }()

    static let aggregationLabels = [
        "sum": "合计", "count": "计数", "average": "均值",
        "min": "最小值", "max": "最大值", "distinctCount": "去重计数",
    ]

    /// 证据引用：metric → 中文口径句；rows → 行样本摘录。最多 8 条防长列表。
    static func evidenceReferences(
        from evidence: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence]
    ) -> [HoloRenderedEvidenceReference] {
        var references: [HoloRenderedEvidenceReference] = []
        for (index, item) in evidence.enumerated() {
            if item.kind == "rows" {
                let excerpts = (item.excerpts ?? []).filter { !$0.isEmpty }
                guard !excerpts.isEmpty else { continue }
                let label = datasetLabels[item.dataset ?? ""] ?? "数据"
                references.append(HoloRenderedEvidenceReference(
                    id: "cloud-rows-\(index)",
                    summary: "已核对 \(item.count ?? excerpts.count) 条\(label)：\(excerpts.prefix(3).joined(separator: "；"))",
                    financeDrilldown: nil,
                    sourceModule: nil,
                    formula: nil,
                    baselineText: nil
                ))
            } else {
                guard let summary = metricEvidenceSummary(item) else { continue }
                references.append(HoloRenderedEvidenceReference(
                    id: item.metricKey ?? "cloud-metric-\(index)",
                    summary: summary,
                    financeDrilldown: nil,
                    sourceModule: nil,
                    formula: item.formula,
                    baselineText: nil
                ))
            }
            if references.count >= 8 { break }
        }
        return references
    }

    /// metric 证据 → 中文口径句：`交易明细·「音乐」：合计「交易金额」= 3316 元（来源 1 条）`
    static func metricEvidenceSummary(
        _ item: HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence
    ) -> String? {
        guard let value = item.value else { return nil }
        let datasetLabel = datasetLabels[item.dataset ?? ""] ?? "数据"
        let group = item.group.map { "「\($0)」" } ?? "全部"
        var operation = "统计"
        var fieldLabel: String?
        if let formula = item.formula,
           let open = formula.firstIndex(of: "("),
           let close = formula.lastIndex(of: ")"), open < close {
            let op = String(formula[formula.startIndex..<open])
            let field = String(formula[formula.index(after: open)..<close])
            // 聚合词翻译不到回退通用词「统计」，不回退英文原文
            operation = aggregationLabels[op] ?? "统计"
            if !field.isEmpty {
                fieldLabel = fieldLabels[item.dataset ?? ""]?[field]
            }
        }
        let valueText = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
        let unit = item.unit ?? ""
        let source = item.sourceCount.map { "（来源 \($0) 条）" } ?? ""
        let fieldPart = fieldLabel.map { "「\($0)」" } ?? ""
        return "\(datasetLabel)·\(group)：\(operation)\(fieldPart)= \(valueText) \(unit)\(source)"
    }

    /// rows 证据 → 数据样例摘要（与本地轨道 dataSamplePreview 同一展示语义）
    static func dataSamplePreview(
        from evidence: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence]
    ) -> HoloRenderedDataSamplePreview? {
        guard let rows = evidence.first(where: { $0.kind == "rows" }),
              let excerpts = rows.excerpts?.filter({ !$0.isEmpty }), !excerpts.isEmpty
        else { return nil }
        return HoloRenderedDataSamplePreview(
            domainLabel: datasetLabels[rows.dataset ?? ""] ?? "数据",
            count: rows.count ?? excerpts.count,
            excerpts: Array(excerpts.prefix(10))
        )
    }
}
