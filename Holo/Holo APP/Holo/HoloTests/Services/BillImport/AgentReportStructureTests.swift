import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

/// v27 研报式报告结构解析回归（云端 claimID 引用式 → 渲染层文本式）
final class AgentReportStructureTests: XCTestCase {
    typealias Client = HoloCloudAnalysisClient.StatusResponse.CloudResult
    typealias Rendered = HoloRenderedReportStructure

    private func cloud(_ json: String) -> Client.CloudReportStructure? {
        let data = Data(json.utf8)
        return try? JSONDecoder().decode(Client.self, from: data).reportStructure
    }

    private let claimsJSON = #"""
    {"claims":[
      {"id":"c1","displayText":"总支出较上一可比期明显上升，结余空间收窄","type":"change"},
      {"id":"c2","displayText":"7 月起支出跳上台阶","type":"change"},
      {"id":"c3","displayText":"固定支出与车贷同源，不暂停会双记","type":"risk"}
    ]}
    """#

    private var claims: [Client.CloudClaim] {
        guard let decoded = try? JSONDecoder().decode(Client.self, from: Data(claimsJSON.utf8)), let list = decoded.claims else { return [] }
        return list
    }

    func testResolveClaimTextsAndFigureNumbering() throws {
        let structure = try XCTUnwrap(cloud(#"""
        {"reportStructure":{
          "sections":[
            {"no":"一","title":"收支总览","kicker":"两头受挤的半年",
             "paragraphClaimIDs":["c1","c2"],
             "chartHint":{"kind":"trend","dataset":"finance.transactions","caption":"图 1｜月度支出·7月起跳上台阶"},
             "notice":null},
            {"no":"二","title":"风险","kicker":null,"paragraphClaimIDs":["c9"],
             "chartHint":null,"notice":{"bodyClaimID":"c3","window":"截止 2026-10-20"}}
          ],
          "conclusionItems":[{"claimID":"c2","sub":"回看下月账单"}],
          "disclosureNotes":["· 口径：排除对账调整"]}
        }
        """#))
        let rendered = try XCTUnwrap(HoloCloudAnalysisService.renderedReportStructure(from: structure, claims: claims))
        XCTAssertEqual(rendered.sections.count, 1, "死引用段（c9 不在 claims）应整节丢弃")
        let sec = rendered.sections[0]
        XCTAssertEqual(sec.paragraphs.count, 2)
        XCTAssertTrue(sec.paragraphs[0].contains("结余空间收窄"), "段落正文=claim 的 displayText")
        XCTAssertEqual(sec.chartHint?.kind, "trend")
        XCTAssertEqual(sec.kicker, "两头受挤的半年")
        XCTAssertTrue(rendered.conclusionItems.isEmpty || rendered.conclusionItems[0].text.contains("跳上台阶"))
        XCTAssertEqual(rendered.disclosureNotes.count, 1)
    }

    func testNoticeResolvesBodyAndWindow() throws {
        let structure = try XCTUnwrap(cloud(#"""
        {"reportStructure":{
          "sections":[{"no":"一","title":"风险","kicker":null,"paragraphClaimIDs":["c3"],
            "chartHint":null,"notice":{"bodyClaimID":"c3","window":"截止 2026-10-20（还剩 2 天）"}}],
          "conclusionItems":[],"disclosureNotes":[]}}
        """#))
        let rendered = try XCTUnwrap(HoloCloudAnalysisService.renderedReportStructure(from: structure, claims: claims))
        XCTAssertEqual(rendered.sections[0].noticeBody, "固定支出与车贷同源，不暂停会双记")
        XCTAssertEqual(rendered.sections[0].noticeWindow, "截止 2026-10-20（还剩 2 天）")
    }

    func testEmptyCaptionGetsFigureNumberAndMissingStructureReturnsNil() throws {
        let structure = try XCTUnwrap(cloud(#"""
        {"reportStructure":{
          "sections":[
            {"no":"一","title":"A","kicker":null,"paragraphClaimIDs":["c1"],
             "chartHint":{"kind":"trend","dataset":"finance.transactions","caption":""},"notice":null},
            {"no":"二","title":"B","kicker":null,"paragraphClaimIDs":["c2"],
             "chartHint":{"kind":"trend","dataset":"health.sleep","caption":""},"notice":null}
          ],"conclusionItems":[],"disclosureNotes":[]}}
        """#))
        let rendered = try XCTUnwrap(HoloCloudAnalysisService.renderedReportStructure(from: structure, claims: claims))
        XCTAssertEqual(rendered.sections[0].chartHint?.caption, "图 1")
        XCTAssertEqual(rendered.sections[1].chartHint?.caption, "图 2", "图注缺省时按出现顺序编号")
        XCTAssertNil(HoloCloudAnalysisService.renderedReportStructure(from: nil, claims: claims))
        // 全部段落死引用 → nil（详情页回退原版式）
        let dead = try XCTUnwrap(cloud(#"{"reportStructure":{"sections":[{"no":"一","title":"X","kicker":null,"paragraphClaimIDs":["zz"],"chartHint":null,"notice":null}],"conclusionItems":[],"disclosureNotes":[]}}"#))
        XCTAssertNil(HoloCloudAnalysisService.renderedReportStructure(from: dead, claims: claims))
    }

    func testBoldLeadSentenceSplitsAtFirstTerminator() {
        // 有句末标点：首句与余文分属不同 run（粗细边界落在第一个句号后）
        let attr = AgentDeepReportView.boldLeadSentence("吃得少了，但每顿贵了。总额几乎没变。")
        XCTAssertEqual(attr.runs.count, 2, "首句加粗应在第一个句号处形成字重边界")
        let firstRunLength = attr.runs.first.map { run in
            attr[run.range].characters.count
        }
        XCTAssertEqual(firstRunLength, 11, "首句「吃得少了，但每顿贵了。」=10字+逗号+句号=11字符")
        // 无句末标点：整段一个 run（全 semibold）
        let noDot = AgentDeepReportView.boldLeadSentence("短句无标号")
        XCTAssertEqual(noDot.runs.count, 1)
    }
}
#endif
