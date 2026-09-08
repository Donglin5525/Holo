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

    // MARK: - 存量旧文案清洗

    /// 旧版翻译代码把查不到标签的字段名原样上屏（如「合计「value」= 540 次」），
    /// 修复前落库的存量报告 JSON 里带着这些英文残留。展示层渲染时过一遍本函数：
    /// 书名号内是英文标识符的，按行内数据集线索翻译成中文标签；认不出的整段移除（宁缺勿漏）。
    /// 不改落库数据，只清展示。
    static func sanitizeLegacyEnglishFields(_ text: String) -> String {
        // 行内数据集线索 → 该数据集的字段标签表（旧文案里的数据集名是说明长文，用关键词认）
        func fieldTable(for line: String) -> [String: String] {
            let hints: [(keywords: [String], dataset: String)] = [
                (["习惯", "打卡", "完成次数"], "habit.daily"),
                (["交易", "支出", "收入", "金额", "账单"], "finance.transactions"),
                (["任务"], "task.daily"),
                (["想法"], "thought.daily"),
                (["记忆"], "memory.entries"),
                (["对话", "消息"], "conversation.metadata"),
                (["档案"], "profile.items"),
                (["纪念日"], "anniversary.events"),
                (["步数", "睡眠", "站立", "活动时长"], "health.steps"),
            ]
            for hint in hints where hint.keywords.contains(where: line.contains) {
                if let table = fieldLabels[hint.dataset] { return table }
            }
            return [:]
        }
        // 跨数据集重名字段的通用兜底（value 在不同数据集含义不同，无行内线索时用中性词）
        let commonFallback = ["date": "日期", "value": "数值", "rows": "记录", "amount": "金额", "goal": "目标"]

        guard let regex = try? NSRegularExpression(pattern: "「([A-Za-z_][A-Za-z0-9_.]*)」") else { return text }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            output += String(text[text.index(text.startIndex, offsetBy: cursor)..<range.lowerBound])
            let field = String(text[nameRange])
            if let replacement = fieldTable(for: text)[field] ?? commonFallback[field] {
                output += "「\(replacement)」"
            }
            cursor = text.distance(from: text.startIndex, to: range.upperBound)
        }
        output += String(text[text.index(text.startIndex, offsetBy: cursor)...])
        return output
    }

    /// 证据池按结论引用收敛：云端执行器跨轮累积的证据是「查过什么就有什么」，
    /// 探索阶段的全量分组查询会把与结论无关的分类桶（问电费带出房租/红包礼金）
    /// 一起送进核对列表。claims.evidenceIDs 是模型对「结论用了哪些证据」的引用，
    /// 按它过滤；rows 行样本没有可引用 ID，保留「被引用指标所属数据集」的行样本
    /// （行样本是指标的逐笔核对材料）。引用缺失或过滤结果为空时保留原列表——
    /// 模型未按契约给引用时不至于把证据清空。
    static func citedEvidence(
        from evidence: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence],
        claims: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudClaim]
    ) -> [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence] {
        let citedIDs = Set(claims.flatMap { $0.evidenceIDs ?? [] }.filter { !$0.isEmpty })
        guard !citedIDs.isEmpty else { return evidence }
        let citedMetrics = evidence.filter { item in
            guard let key = item.metricKey else { return false }
            return citedIDs.contains(key)
        }
        guard !citedMetrics.isEmpty else { return evidence }
        let citedDatasets = Set(citedMetrics.compactMap(\.dataset))
        let citedDatasetRows = evidence.filter { item in
            item.kind == "rows" && item.dataset.map { citedDatasets.contains($0) } == true
        }
        return citedMetrics + citedDatasetRows
    }

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
                    financeDrilldown: financeDrilldown(
                        dataset: item.dataset, group: nil, excerpts: excerpts, evidenceID: "cloud-rows-\(index)"
                    ),
                    sourceModule: nil,
                    formula: nil,
                    baselineText: nil
                ))
            } else {
                guard let summary = metricEvidenceSummary(item) else { continue }
                let id = item.metricKey ?? "cloud-metric-\(index)"
                references.append(HoloRenderedEvidenceReference(
                    id: id,
                    summary: summary,
                    financeDrilldown: financeDrilldown(dataset: item.dataset, group: item.group, evidenceID: id),
                    sourceModule: nil,
                    formula: item.formula,
                    baselineText: nil
                ))
            }
            if references.count >= 8 { break }
        }
        return references
    }

    /// 财务交易类证据 → 账单复核下钻（与本地轨道 HoloAgentResultRenderer.financeDrilldown
    /// 同一落点 FinanceEvidenceReviewView）：分类=分组名、时间=快照窗口，
    /// 用户据此逐笔核对。复核页 keyword 会匹配分类名，分组名可直接作关键词；
    /// rows 行样本没有分组名，从摘录提取共有类别词预过滤，避免点进去是全量账单；
    /// 其他数据集暂无复核页，保持静态文本。
    private static func financeDrilldown(
        dataset: String?,
        group: String?,
        excerpts: [String]? = nil,
        evidenceID: String
    ) -> HoloRenderedFinanceDrilldown? {
        guard dataset == "finance.transactions" else { return nil }
        let end = Date()
        let start = Calendar.current.date(
            byAdding: .day,
            value: -HoloCloudAnalysisSnapshotBuilder.defaultHistoryDays,
            to: end
        ) ?? end
        let groupKeyword = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = groupKeyword?.isEmpty == false
            ? groupKeyword
            : drilldownKeyword(fromExcerpts: excerpts ?? [])
        return HoloRenderedFinanceDrilldown(
            sourceEvidenceID: evidenceID,
            label: datasetLabels[dataset ?? ""] ?? "交易明细",
            keyword: keyword,
            start: start,
            end: end,
            baselineStart: nil,
            baselineEnd: nil
        )
    }

    /// 行样本摘录 → 下钻分类关键词：摘录是执行器的人话行记录
    /// （如「7月5日 电费 6月电费 -¥136」），取「在每条摘录中都出现」且非日期/
    /// 金额形状的词（按空格分词；含数字/¥ 的词排除——日期与金额必含数字，类别与
    /// 备注被误伤时宁缺勿滤）。多摘录无共有词（混类抽样）返回 nil，下钻保持全量窗口。
    static func drilldownKeyword(fromExcerpts excerpts: [String]) -> String? {
        guard let first = excerpts.first else { return nil }
        func contentTokens(of line: String) -> [String] {
            line.split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
                guard !token.isEmpty, !token.contains("¥"), !token.contains("￥") else { return false }
                return token.contains(where: \.isNumber) == false
            }
        }
        var candidates = contentTokens(of: first)
        guard !candidates.isEmpty else { return nil }
        for line in excerpts.dropFirst() {
            let lineTokens = Set(contentTokens(of: line))
            candidates = candidates.filter { lineTokens.contains($0) }
        }
        guard let keyword = candidates.max(by: { $0.count < $1.count }), keyword.count >= 2 else { return nil }
        return keyword
    }

    /// metric 证据 → 中文口径句：`交易明细·「音乐」：合计「交易金额」= 3316 元（来源 1 条）`
    static func metricEvidenceSummary(
        _ item: HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence
    ) -> String? {
        guard let value = item.value else { return nil }
        let datasetLabel = datasetLabels[item.dataset ?? ""] ?? "数据"
        // 分组名三态：nil=未按维度分组（「全部」）；空串=分组维度取值为空
        // （如无分类交易的分组桶）→「未分类」，不能渲染成空的「」
        let trimmedGroup = item.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let group: String
        if item.group == nil {
            group = "全部"
        } else if trimmedGroup.isEmpty {
            group = "「未分类」"
        } else {
            group = "「\(trimmedGroup)」"
        }
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
