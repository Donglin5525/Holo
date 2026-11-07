//
//  DeepReportResultContractTests.swift
//  Holo
//
//  深度报告 C 方案契约测试（2026-11-07 设计 docs/_common/plans/2026-11-07-深度分析C方案正式设计）：
//  后端新引擎（task_type=deep_report，engine=deep-report-v1）把自由文本报告映射进
//  现有 CloudResult 契约——旧版 App 直接渲染、零改动。本文件锁定接缝：
//  JSON 字面量逐字段抄自后端 mapper（HoloBackend/src/agent/deepReport/mapper.js mapReportToResult），
//  禁止为了让测试变绿而单方面修改字面量迁就 iOS 模型；改任一端必须同步另一端与本文件。
//  覆盖：解码保真 / 叙事编排（导语=narrativeSummary，段落=claims）/
//  reportStructure 小节引用 / 证据 rows 形态（事实清单）与 claims.evidenceIDs 对拍 /
//  warnings 为空不产生「已撤回」提示 / taskRange 必填。
//

import XCTest
@testable import Holo

final class DeepReportResultContractTests: XCTestCase {

    // 后端 mapper 输出形状的最小样本（标题 + 导语 + 两个小节各一段 + 数据说明 + 两条事实证据）
    private let engineJSON = """
    {"result": {
      "title": "东京之后：日常开销没变，健身停了一周",
      "narrativeSummary": "东林，这 30 天整体平稳，要接上的只有健身。",
      "keyInsight": null,
      "reportStructure": {
        "sections": [
          {"no": "一", "title": "钱包", "kicker": null, "paragraphClaimIDs": ["p1", "p2"], "chartHint": null, "notice": null},
          {"no": "二", "title": "身体", "kicker": null, "paragraphClaimIDs": ["p3"], "chartHint": null, "notice": null}
        ],
        "conclusionItems": [],
        "disclosureNotes": ["睡眠、步数本次没有数据，不能判断。"]
      },
      "claims": [
        {"id": "p1", "type": "observation", "displayText": "账面上比之前 30 天少花了将近 2 万，其中 1.86 万是东京旅行结束了。", "evidenceIDs": [], "metricAssertions": [], "confidence": 0.9},
        {"id": "p2", "type": "observation", "displayText": "刨掉旅行，日常开销只少了 600 多。", "evidenceIDs": [], "metricAssertions": [], "confidence": 0.9},
        {"id": "p3", "type": "observation", "displayText": "健身停了 7 天，放在你过去半年的规律里不算反常。", "evidenceIDs": [], "metricAssertions": [], "confidence": 0.9}
      ],
      "reasoning": "",
      "evidence": [
        {"kind": "rows", "metricKey": "F001", "dataset": "facts", "count": 1, "excerpts": ["本期支出合计 15321.96 元，共 68 笔。"]},
        {"kind": "rows", "metricKey": "F004", "dataset": "facts", "count": 1, "excerpts": ["剔除项目后的日常支出：本期 15321.96 元，上期 15933.40 元。"]}
      ],
      "warnings": [],
      "goalScope": null, "goalAdjustmentDraft": null,
      "snapshotCoverage": {"finance.transactions": {"totalRows": 593, "providedRows": 593, "truncated": false, "coveredFrom": null}},
      "snapshotCutoffAt": "2026-11-07T04:00:00.000Z",
      "taskRange": {"label": "问句指定：最近30天", "start": 1791388800, "end": 1793971200},
      "completedAt": "2026-11-07T04:05:00.000Z",
      "engine": "deep-report-v1"
    }}
    """

    private func decodeResult() throws -> HoloCloudAnalysisClient.StatusResponse.CloudResult {
        struct Wrapper: Decodable {
            let result: HoloCloudAnalysisClient.StatusResponse.CloudResult
        }
        return try JSONDecoder().decode(Wrapper.self, from: Data(engineJSON.utf8)).result
    }

    func test_解码保真_字段齐全且taskRange必填() throws {
        let result = try decodeResult()
        XCTAssertEqual(result.title, "东京之后：日常开销没变，健身停了一周")
        XCTAssertEqual(result.narrativeSummary, "东林，这 30 天整体平稳，要接上的只有健身。")
        XCTAssertEqual(result.claims?.count, 3)
        XCTAssertEqual(result.claims?.first?.id, "p1")
        XCTAssertEqual(result.claims?.first?.displayText?.hasPrefix("账面上") , true)
        XCTAssertEqual(result.taskRange?.label, "问句指定：最近30天")
        XCTAssertEqual(result.taskRange?.start ?? 0, 1791388800, accuracy: 0.5)
        // engine 是服务端留痕键（deep-report-v1），iOS 模型不声明它——
        // 解码成功本身即证明多余键被忽略（CloudResult 无 engine 成员）
        XCTAssertEqual(result.warnings ?? [], [], "新引擎不发撤回类 warnings")
    }

    func test_叙事编排_导语优先且段落进sections() throws {
        let result = try decodeResult()
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertEqual(composed.narrativeSummary, "东林，这 30 天整体平稳，要接上的只有健身。", "导语段必须是 narrativeSummary")
        XCTAssertEqual(composed.sections.count, 3, "每个段落 claim 都要成为 section")
        XCTAssertFalse(composed.sections.contains { $0.body.contains("导语") }, "导语段不得重复进 claims")
    }

    func test_小节映射_reportStructure引用全部成立() throws {
        let result = try decodeResult()
        let rendered = HoloCloudAnalysisService.renderedReportStructure(from: result.reportStructure, claims: result.claims ?? [])
        XCTAssertNotNil(rendered, "小节引用全部可解析，报告走研报版式")
        XCTAssertEqual(rendered?.sections.count, 2)
        XCTAssertEqual(rendered?.sections.first?.title, "钱包")
        XCTAssertEqual(rendered?.sections.first?.paragraphs.count, 2)
        XCTAssertEqual(rendered?.sections.last?.paragraphs.first?.hasPrefix("健身停了"), true)
        XCTAssertEqual(rendered?.disclosureNotes, ["睡眠、步数本次没有数据，不能判断。"])
    }

    func test_证据形态_事实全集直通不重复() throws {
        let result = try decodeResult()
        let pool = result.evidence ?? []
        XCTAssertEqual(pool.count, 2, "后端只下发被引用的事实（F001/F004）作为证据全集")
        // claims.evidenceIDs 为空（后端防双通道重复的设计）→ citedEvidence 直通保留全集
        let cited = HoloCloudEvidencePresenter.citedEvidence(from: pool, claims: result.claims ?? [])
        XCTAssertEqual(cited.count, 2, "引用过滤直通：不丢也不重复")
        let references = HoloCloudEvidencePresenter.evidenceReferences(from: cited)
        XCTAssertEqual(references.count, 2, "依据页两条，一条不重复")
        XCTAssertTrue(references.allSatisfy { !$0.summary.isEmpty })
    }

    func test_范围行_无截断无撤回提示() throws {
        let result = try decodeResult()
        // answerScope 为服务私有：撤回提示的映射由 verificationNote 锁定（与云端叙事契约测试同通道）
        XCTAssertNil(HoloCloudAnalysisService.verificationNote(for: result.warnings ?? []), "新引擎 warnings 为空，不产生任何范围行提示")
        XCTAssertEqual(result.snapshotCoverage?["finance.transactions"]?.truncated, false, "未截断不提示")
        XCTAssertEqual(result.taskRange?.label, "问句指定：最近30天", "范围行展示冻结窗")
    }
}
