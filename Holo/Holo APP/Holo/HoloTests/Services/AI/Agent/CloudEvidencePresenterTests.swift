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
        sourceCount: Int? = 1
    ) -> HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence {
        HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence(
            kind: "metric", metricKey: "dynamic.finance_transactions.spend.music",
            dataset: dataset, group: group, value: value, unit: unit,
            formula: formula, sourceCount: sourceCount, count: nil, excerpts: nil
        )
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
}
