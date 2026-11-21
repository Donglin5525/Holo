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

    func testEmphasizedParagraphBoldsOnlyShortLeadSentence() {
        // 短首句（≤28 字）+ 后面还有话：首句作主题句加粗，粗细边界落在第一个句号后
        let attr = AgentDeepReportView.emphasizedParagraph("吃得少了，但每顿贵了。总额几乎没变。")
        XCTAssertEqual(attr.runs.count, 2, "短首句加粗应在第一个句号处形成字重边界")
        let firstRunLength = attr.runs.first.map { run in
            attr[run.range].characters.count
        }
        XCTAssertEqual(firstRunLength, 11, "首句「吃得少了，但每顿贵了。」=10字+逗号+句号=11字符")
        // 单句段：不加粗（避免整段加粗）
        let single = AgentDeepReportView.emphasizedParagraph("短句无标号")
        XCTAssertEqual(single.runs.count, 1)
        // 长首句（>28 字）不整句加粗，只强调数字：「94 个」「47 天」「1 个」各成一个粗体 run
        let long = AgentDeepReportView.emphasizedParagraph("本期完成 94 个任务，分布在 47 天，其中高优先级只有 1 个，整体节奏没有掉档。后面还有一句。")
        XCTAssertEqual(long.runs.count, 7, "3 个数字强调 run + 4 段常规 run")
    }

    // MARK: - 报告数据组件（2026-11-20 报告改版）跨端契约

    /// 字面量 = 后端 goalComponents/componentComputator + mapper.anchorComponents 真实输出（覆盖 8 种 kind），
    /// 后端组件结构改动时用 /tmp/gen-fixture.mjs 同款脚本重新生成并替换。
    private let componentsFixture = #"""
    {"reportComponents":[{"id":"c1","kind":"progress","anchor":-1,"payload":{"title":"目标进度 · 体重","unit":"kg","current":75.4,"start":78,"target":72,"fraction":0.43,"timeFraction":0.531043956043956,"statusLabel":"略落后","tone":"warn","isStale":false,"caption":"起点 78kg（9/1） · 目标 72kg（1/31）","projections":[{"label":"按整体节奏","value":"约 2/16 达成","tone":"warn"},{"label":"按最近 3 周节奏","value":"约 4/12 达成","tone":"warn"}]}},{"id":"c2","kind":"trendLine","anchor":0,"payload":{"title":"每周平均体重","unit":"kg","points":[{"label":"9/26","value":77.3},{"label":"10/3","value":77},{"label":"10/10","value":76.6},{"label":"10/17","value":76.2},{"label":"10/24","value":75.9},{"label":"10/31","value":75.6},{"label":"11/7","value":75.5},{"label":"11/14","value":75.4}],"planStart":76.8,"planEnd":74.8,"highlightFrom":5,"caption":"近 3 周明显变慢"}},{"id":"c3","kind":"habitStrip","anchor":1,"payload":{"title":"关联习惯 · 每格 1 天，每组 1 周","rows":[{"name":"健身","sub":"约每周 2 次","rateText":"16 天","statusLabel":"掉档","tone":"bad","days":[1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,0]},{"name":"深蹲","sub":"约每周 2 次","rateText":"16 天","statusLabel":"跟随健身","tone":"neutral","days":[1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,0]},{"name":"俯卧撑","sub":"约每周 5.3 次","rateText":"42 天","statusLabel":"稳","tone":"good","days":[1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,0]}],"foldedNote":null,"startLabel":"9/25","endLabel":"今天"}},{"id":"c4","kind":"kpiTiles","anchor":-1,"payload":{"tiles":[{"label":"健身","value":"16","unit":"天","delta":"近 3 周 ↓44%","tone":"bad"},{"label":"深蹲","value":"16","unit":"天","delta":"近 3 周 ↓44%","tone":"bad"},{"label":"俯卧撑","value":"42","unit":"天","delta":"近 3 周 ↓7%","tone":"warn"}]}},{"id":"c5","kind":"periodCompare","anchor":1,"payload":{"left":{"label":"前 5 周","rows":[{"label":"健身","value":"2.4 次/周"},{"label":"深蹲","value":"2.4 次/周"},{"label":"体重","value":"-0.3 kg/周"}]},"right":{"label":"近 3 周","rows":[{"label":"健身","value":"1.3 次/周"},{"label":"深蹲","value":"1.3 次/周"},{"label":"体重","value":"-0.2 kg/周"}]},"caption":"同一个人、两种节奏下的对比"}},{"id":"c6","kind":"gapCards","anchor":2,"payload":{"cards":[{"icon":"🍱","title":"没有饮食记录","body":"减重有一大半取决于吃，这部分没有数据，体重变化的原因只能从运动和作息看。","action":"＋ 关联一个记录饮食的习惯"}]}},{"id":"c7","kind":"milestones","anchor":-1,"payload":{"title":"再记录多久能看出什么","items":[{"label":"今天","body":"能看到每个习惯有没有开始做","done":true},{"label":"第 14 天 · 11/29","body":"结果每周记录 2 次以上，就能判断方向"},{"label":"第 21 天 · 12/6","body":"能判断哪个习惯稳、哪个在掉，并给出完成预测"}]}},{"id":"c8","kind":"barSeries","anchor":2,"payload":{"title":"每月完成任务","unit":"个","bars":[{"label":"7月","value":2},{"label":"8月","value":12},{"label":"9月","value":12},{"label":"10月","value":14},{"label":"11月","value":8,"partial":true}],"caption":"11月还没过完"}}]}
    """#

    func testReportComponentsDecodeAllKindsFromBackendOutput() throws {
        let decoded = try JSONDecoder().decode(Client.self, from: Data(componentsFixture.utf8))
        let components = try XCTUnwrap(decoded.reportComponents).items
        let kinds = Set(components.map(\.payload.kind))
        XCTAssertEqual(kinds, ["progress", "trendLine", "habitStrip", "kpiTiles", "periodCompare", "gapCards", "milestones", "barSeries"])
        guard case .progress(let progress)? = components.first(where: { $0.payload.kind == "progress" })?.payload else {
            return XCTFail("缺进度组件")
        }
        XCTAssertEqual(progress.current, 75.4)
        XCTAssertEqual(components.first(where: { $0.payload.kind == "progress" })?.anchor, -1, "进度在「总」区")
        guard case .habitStrip(let strip)? = components.first(where: { $0.payload.kind == "habitStrip" })?.payload else {
            return XCTFail("缺习惯条")
        }
        XCTAssertEqual(strip.rows.first?.days.count, 56)
    }

    func testReportComponentsLossyDecodeKeepsGoodItems() throws {
        let json = #"""
        {"reportComponents":[
          {"id":"c1","kind":"unknownKind","anchor":0,"payload":{}},
          {"id":"c2","kind":"kpiTiles","anchor":-1,"payload":{"tiles":[{"label":"健身","value":"15","unit":"天"}]}},
          {"id":"c3","kind":"habitStrip","anchor":1,"payload":{"rows":"坏掉的"}}
        ]}
        """#
        let decoded = try JSONDecoder().decode(Client.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.reportComponents?.items.map(\.id), ["c2"], "未知 kind 与坏 payload 只丢自己")
    }

    func testRenderedResultRoundTripKeepsComponents() throws {
        let decoded = try JSONDecoder().decode(Client.self, from: Data(componentsFixture.utf8))
        var rendered = HoloRenderedAgentResult(title: "t", summary: "", sections: [], evidenceReferences: [])
        rendered.reportComponents = decoded.reportComponents
        let data = try JSONEncoder().encode(rendered)
        let restored = try JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)
        XCTAssertEqual(restored.components.count, 8, "落库再读回组件不丢")
        XCTAssertEqual(restored.components, rendered.components)
    }

    // MARK: - 对话问目标路由（2026-11-20 报告改版 D 期）

    func testGoalQuestionIntent() {
        XCTAssertTrue(ChatGoalReviewIntent.isGoalQuestion("我最近的目标完成的怎么样？", scenarioID: nil), "真机原问句")
        XCTAssertTrue(ChatGoalReviewIntent.isGoalQuestion("随便问问", scenarioID: "goal"), "显式目标场景")
        XCTAssertFalse(ChatGoalReviewIntent.isGoalQuestion("这个月花了多少钱", scenarioID: nil))
        XCTAssertFalse(ChatGoalReviewIntent.isGoalQuestion("帮我定个目标", scenarioID: nil), "没有问进展不拦")
    }

    func testMentionedGoalPrefersLongestTitle() {
        let a = UUID(), b = UUID()
        let goals = [(id: a, title: "减肥"), (id: b, title: "减肥到 65")]
        XCTAssertEqual(ChatGoalReviewIntent.mentionedGoalID(in: "减肥到 65 的目标怎么样", goals: goals), b)
        XCTAssertEqual(ChatGoalReviewIntent.mentionedGoalID(in: "减肥目标进展如何", goals: goals), a)
        XCTAssertNil(ChatGoalReviewIntent.mentionedGoalID(in: "目标怎么样", goals: goals))
    }
}
#endif
