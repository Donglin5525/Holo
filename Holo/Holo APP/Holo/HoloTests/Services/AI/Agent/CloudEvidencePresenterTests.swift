//
//  CloudEvidencePresenterTests.swift
//  Holo
//
//  云端分析证据翻译（2026-08-31 验收修复）：
//  metric 口径句中文化、rows 行样本上屏、字段/数据集翻译与快照目录同源。
//

import XCTest
@testable import Holo

final class CloudEvidencePresenterTests: XCTestCase {

    private func metric(
        dataset: String? = "finance.transactions",
        group: String? = "音乐",
        value: Double? = 3316,
        unit: String? = "元",
        formula: String? = "sum(amount)",
        sourceCount: Int? = 1,
        metricKey: String? = "dynamic.finance_transactions.spend.music"
    ) -> HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence {
        HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "metric", metricKey: metricKey,
            dataset: dataset, group: group, value: value, unit: unit,
            formula: formula, sourceCount: sourceCount, count: nil, excerpts: nil
        )
    }

    private func rowsEvidence(dataset: String?) -> HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence {
        HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "rows", metricKey: nil, dataset: dataset, group: nil,
            value: nil, unit: nil, formula: nil, sourceCount: nil, count: 1,
            excerpts: ["8月15日 电费 -¥260"]
        )
    }

    private func claim(
        _ evidenceIDs: [String]
    ) -> HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudClaim {
        .init(summary: nil, displayText: "发现", evidenceIDs: evidenceIDs)
    }

    func test_metric口径句_中文翻译() {
        let summary = HoloCloudEvidencePresenter.metricEvidenceSummary(metric())
        // 2026-09-01 口径修复：数据集/字段展示名改用 schema.label 短标签（「交易明细」「金额」），
        // 不再拿写给模型的说明长文（「收入与支出交易明细」「交易金额=每日次数/测量值…」）冒充
        XCTAssertEqual(summary, "交易明细·「音乐」：合计「金额」= 3316 元（来源 1 条）")
    }

    func test_metric无分组与无formula的兜底() {
        let noGroup = HoloCloudEvidencePresenter.metricEvidenceSummary(metric(group: nil))
        XCTAssertTrue(noGroup?.contains("·全部：") == true)
        let noFormula = HoloCloudEvidencePresenter.metricEvidenceSummary(metric(formula: nil))
        XCTAssertTrue(noFormula?.contains("统计") == true)
        let noValue = HoloCloudEvidencePresenter.metricEvidenceSummary(metric(value: nil))
        XCTAssertNil(noValue)
    }

    func test_metric小数值保留两位() {
        let summary = HoloCloudEvidencePresenter.metricEvidenceSummary(metric(value: 102.567, unit: "元"))
        XCTAssertTrue(summary?.contains("= 102.57 元") == true)
    }

    func test_rows行样本证据与数据样例() {
        let rows = HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "rows", metricKey: nil, dataset: "finance.transactions", group: nil,
            value: nil, unit: nil, formula: nil, sourceCount: nil, count: 2,
            excerpts: ["8月15日 音乐 TIMA音乐盛典 -¥3316", "8月21日 音乐 专辑 -¥120"]
        )
        let references = HoloCloudEvidencePresenter.evidenceReferences(from: [rows])
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references[0].summary, "已核对 2 条交易明细：8月15日 音乐 TIMA音乐盛典 -¥3316；8月21日 音乐 专辑 -¥120")

        let preview = HoloCloudEvidencePresenter.dataSamplePreview(from: [rows])
        XCTAssertEqual(preview?.domainLabel, "交易明细")
        XCTAssertEqual(preview?.count, 2)
        XCTAssertEqual(preview?.excerpts.first, "8月15日 音乐 TIMA音乐盛典 -¥3316")
    }

    func test_证据引用上限8条与空rows过滤() {
        var items: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence] = []
        for index in 0..<12 {
            items.append(metric(group: "分类\(index)", sourceCount: index))
        }
        items.append(HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "rows", metricKey: nil, dataset: nil, group: nil,
            value: nil, unit: nil, formula: nil, sourceCount: nil, count: nil, excerpts: nil
        ))
        let references = HoloCloudEvidencePresenter.evidenceReferences(from: items)
        XCTAssertEqual(references.count, 8)
    }

    // MARK: - 证据按结论引用收敛（2026-09-08 问电费带出房租/红包礼金修复）

    func test_citedEvidence_只保留被引用指标与其数据集行样本() {
        let electricity = metric(
            group: "电费", value: 1090, sourceCount: 6,
            metricKey: "dynamic.finance_transactions.spend.dianfei"
        )
        let rent = metric(
            group: "房租", value: 28000, sourceCount: 6,
            metricKey: "dynamic.finance_transactions.spend.fangzu"
        )
        let pool = [
            rent,
            electricity,
            rowsEvidence(dataset: "finance.transactions"),
            rowsEvidence(dataset: "habit.daily"),
        ]
        let cited = HoloCloudEvidencePresenter.citedEvidence(
            from: pool,
            claims: [claim(["dynamic.finance_transactions.spend.dianfei"])]
        )
        // 房租桶（未被结论引用）剔除；行样本保留结论所属数据集（逐笔核对材料）
        XCTAssertEqual(cited.compactMap { $0.metricKey }, ["dynamic.finance_transactions.spend.dianfei"])
        XCTAssertEqual(
            cited.filter { $0.kind == "rows" }.compactMap { $0.dataset },
            ["finance.transactions"]
        )
    }

    func test_citedEvidence_引用缺失或全不匹配时保留原列表() {
        let pool = [metric(), rowsEvidence(dataset: "finance.transactions")]
        // 模型未按契约给引用 → 不至于清空证据
        XCTAssertEqual(HoloCloudEvidencePresenter.citedEvidence(from: pool, claims: []).count, 2)
        // 引用 ID 与证据池完全对不上 → 保留原列表兜底
        XCTAssertEqual(
            HoloCloudEvidencePresenter.citedEvidence(from: pool, claims: [claim(["不存在的id"])]).count,
            2
        )
    }

    func test_metric空分组名渲染未分类() {
        // 无分类交易的分组桶：空串分组名不得渲染成空的「」
        XCTAssertTrue(metricEvidenceSummaryContains(metric(group: ""), "·「未分类」："))
        XCTAssertTrue(metricEvidenceSummaryContains(metric(group: "  "), "「未分类」"))
    }

    private func metricEvidenceSummaryContains(
        _ item: HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence,
        _ fragment: String
    ) -> Bool {
        HoloCloudEvidencePresenter.metricEvidenceSummary(item)?.contains(fragment) == true
    }

    // MARK: - 云端证据下钻账单复核（2026-09-08 证据不可点修复）

    func test_财务metric证据构造账单复核下钻() {
        let references = HoloCloudEvidencePresenter.evidenceReferences(from: [metric(group: "电费")])
        let drilldown = references.first?.financeDrilldown
        XCTAssertNotNil(drilldown, "云端财务证据应与本地轨道一样可点按核对")
        XCTAssertEqual(drilldown?.keyword, "电费")
        XCTAssertEqual(drilldown?.label, "交易明细")
        XCTAssertEqual(drilldown?.sourceEvidenceID, "dynamic.finance_transactions.spend.music")
        // 时间窗 = 快照口径（近 180 天）
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: drilldown!.start, to: drilldown!.end).day,
            180
        )
    }

    func test_非财务数据集证据保持静态() {
        let references = HoloCloudEvidencePresenter.evidenceReferences(
            from: [metric(dataset: "habit.daily", group: nil)]
        )
        XCTAssertNil(references.first?.financeDrilldown)
    }

    func test_rows证据从摘录提取共有分类词预过滤() {
        // 实测事故形态：点行样本证据落全量账单列表，用户得自己翻——共有类别词
        // 应作为下钻关键词，直达该分类明细
        let rows = HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "rows", metricKey: nil, dataset: "finance.transactions", group: nil,
            value: nil, unit: nil, formula: nil, sourceCount: nil, count: 2,
            excerpts: ["7月5日 电费 6月电费 -¥136", "8月3日 电费 7月电费 -¥128"]
        )
        let references = HoloCloudEvidencePresenter.evidenceReferences(from: [rows])
        XCTAssertEqual(references.first?.financeDrilldown?.keyword, "电费")
    }

    func test_rows摘录无共有词时下钻保持全量() {
        let mixed = HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "rows", metricKey: nil, dataset: "finance.transactions", group: nil,
            value: nil, unit: nil, formula: nil, sourceCount: nil, count: 2,
            excerpts: ["7月5日 电费 -¥136", "8月3日 房租 -¥2590"]
        )
        let references = HoloCloudEvidencePresenter.evidenceReferences(from: [mixed])
        XCTAssertNil(references.first?.financeDrilldown?.keyword, "混类抽样不得猜关键词，下钻保持全量窗口")
    }

    func test_摘录关键词提取排除日期金额与无共有词() {
        // 日期（含数字）与金额（含¥）必须被排除，剩唯一的共有类别词
        XCTAssertEqual(
            HoloCloudEvidencePresenter.drilldownKeyword(
                fromExcerpts: ["7月5日 电费 6月电费 -¥136", "8月3日 电费 7月电费 -¥128"]
            ),
            "电费"
        )
        XCTAssertNil(HoloCloudEvidencePresenter.drilldownKeyword(fromExcerpts: []))
        XCTAssertNil(HoloCloudEvidencePresenter.drilldownKeyword(fromExcerpts: ["2026-09-08"]))
        // 单字候选不作为关键词（宁缺勿滤）
        XCTAssertNil(
            HoloCloudEvidencePresenter.drilldownKeyword(fromExcerpts: ["7月5日 电 费 -¥136", "8月3日 电 费 -¥128"])
        )
    }
}
