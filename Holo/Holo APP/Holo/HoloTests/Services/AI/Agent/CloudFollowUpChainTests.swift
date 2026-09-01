//
//  CloudFollowUpChainTests.swift
//  HoloTests
//
//  云端报告追问链路（方案B）回归测试：
//  1. Compiler 云端重载：血统正确、父报告内容进上下文、强制重新取证、身份校验；
//  2. 消息库重读闭环：cloud-血统落库→重读→子报告再多也不淹没父报告（2026-09-01 review 修复的回归钉）；
//  3. 习惯行构建：goal/type/unit 随行输出（满勤误判修复的数据口径）。
//

import XCTest
import CoreData
@testable import Holo

final class CloudFollowUpChainTests: XCTestCase {

    // MARK: - 1. Compiler 云端重载

    private func cloudParent(agentResultID: String = "cloud-task-1") -> HoloRenderedAgentResult {
        var rendered = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "本期概要",
            sections: [
                HoloRenderedAgentSection(title: "发现 1", body: "近一周餐饮支出占比偏高", confidence: nil, kind: nil, interpretation: nil),
                HoloRenderedAgentSection(title: "发现 2", body: "习惯「阅读」完成 2/7 天", confidence: nil, kind: nil, interpretation: nil)
            ],
            evidenceReferences: [
                HoloRenderedEvidenceReference(
                    id: "cloud-metric-0",
                    summary: "交易明细·「餐饮」：合计「金额」= 520 元（来源 12 条）",
                    financeDrilldown: nil,
                    sourceModule: nil,
                    formula: "sum(amount)",
                    baselineText: nil
                )
            ]
        )
        rendered.agentJobID = agentResultID
        rendered.agentResultID = agentResultID
        rendered.rootUserQuestion = "分析一下我最近的情况"
        return rendered
    }

    @MainActor
    func test_compiler_cloudParent_buildsLineageAndContext() throws {
        let request = HoloAgentContinuationRequest(
            parentJobID: "cloud-task-1",
            parentResultID: "cloud-task-1",
            relation: .explain
        )
        let prepared = try HoloAgentContinuationContextCompiler.prepare(
            request: request,
            childJobID: "local-child-1",
            parentRendered: cloudParent(),
            now: Date()
        )
        // 血统：cloud- 身份进入 lineage，追问记录据此挂载
        XCTAssertEqual(prepared.lineage.parentResultID, "cloud-task-1")
        XCTAssertEqual(prepared.lineage.relation, .explain)
        XCTAssertEqual(prepared.rootUserQuestion, "分析一下我最近的情况")
        // 云端父无可复用 evidence record
        XCTAssertTrue(prepared.reusableEvidence.isEmpty)
        // 上下文：父报告结论与依据摘要都在，且明确「重新取证」口径
        let content = prepared.contextMessage.content
        XCTAssertTrue(content.contains("餐饮支出占比偏高"), "父报告结论应进入追问上下文")
        XCTAssertTrue(content.contains("合计「金额」= 520 元"), "父报告依据摘要应进入追问上下文")
        XCTAssertTrue(content.contains("必须重新调用工具查询取证"), "云端追问必须重新取证的口径指令缺失")
        XCTAssertFalse(content.contains("可以复用 payload.evidence 中列出的 evidence ID"), "云端路径不得承诺复用旧证据")
    }

    @MainActor
    func test_compiler_cloudParent_rejectsMismatchedIdentity() {
        let request = HoloAgentContinuationRequest(
            parentJobID: "cloud-task-1",
            parentResultID: "cloud-task-OTHER",
            relation: .explain
        )
        XCTAssertThrowsError(try HoloAgentContinuationContextCompiler.prepare(
            request: request,
            childJobID: "local-child-1",
            parentRendered: cloudParent(),
            now: Date()
        ))
    }

    // MARK: - 2. 消息库重读闭环（含子报告淹没回归）

    @MainActor
    func test_parentReload_survivesManyChildReports() async throws {
        let repo = ChatMessageRepository.shared
        await CoreDataStack.shared.waitUntilReady()
        let parentID = "cloud-chain-\(UUID().uuidString.prefix(8))"
        var createdMessageIDs: [UUID] = []

        do {
            // 父报告落库（模拟 finalizeCloudResult 的写路径）
            let parentMessageID = repo.addMessage(role: "assistant", content: "云端分析", intent: "query_analysis")
            createdMessageIDs.append(parentMessageID)
            repo.finalizeAgentMessage(parentMessageID, rendered: cloudParent(agentResultID: parentID), intent: "query_analysis")

            // 首次重读
            let first = await repo.loadRenderedResultByResultID(parentID)
            XCTAssertEqual(first?.agentResultID, parentID, "父报告应可按血统ID从消息库重读")

            // 落 6 条追问子报告（lineage.parentResultID = 父cloud-ID，agentResultID=本地 UUID）
            for index in 0..<6 {
                let childMessageID = repo.addMessage(role: "assistant", content: "追问\(index)", intent: "query_analysis")
                createdMessageIDs.append(childMessageID)
                var child = HoloRenderedAgentResult(
                    title: "追问报告\(index)",
                    summary: "子报告\(index)",
                    sections: [HoloRenderedAgentSection(title: "发现 1", body: "子结论\(index)", confidence: nil, kind: nil, interpretation: nil)],
                    evidenceReferences: []
                )
                child.agentJobID = UUID().uuidString
                child.agentResultID = UUID().uuidString
                child.lineage = HoloAgentLineage(
                    rootJobID: parentID,
                    rootResultID: parentID,
                    parentJobID: parentID,
                    parentResultID: parentID,
                    relationRawValue: "explain",
                    lineageDepth: 1
                )
                repo.finalizeAgentMessage(childMessageID, rendered: child, intent: "query_analysis")
            }

            // 回归点：子报告再多，父报告重读不受淹没（旧版 CONTAINS 裸ID+fetchLimit=5 会被挤掉）
            let reloaded = await repo.loadRenderedResultByResultID(parentID)
            XCTAssertEqual(reloaded?.agentResultID, parentID, "子报告数量超过旧fetchLimit后父报告仍应可重读")

            // 追问记录挂载：loadFollowUps 按父血统ID查到全部子报告
            let followUps = await repo.loadFollowUpReportsAsync(parentResultID: parentID)
            XCTAssertEqual(followUps.count, 6, "追问记录应按父血统ID挂载 6 条子报告")
        }
        // 清理：物理删除测试消息，不污染报告列表
        for messageID in createdMessageIDs {
            repo.deleteMessage(messageID)
        }
    }

    // MARK: - 3. 习惯行构建（goal/type/unit 口径字段）

    @MainActor
    func test_habitRows_carryGoalTypeUnit() async throws {
        let repo = HabitRepository.shared
        let stamp = UUID().uuidString.prefix(6)
        // 计数型：目标 3 次，今天只记 1 次 → value=1, goal=3, type=count
        let counting = try repo.createHabit(
            name: "测试喝水\(stamp)", icon: "drop", color: "#4A90D9",
            type: .numeric, targetCount: 3, unit: "次", aggregationType: .sum
        )
        try repo.addNumericRecord(for: counting, value: 1)
        // 打卡型：今天打卡 → value=1, type=check, 无 goal
        let checkin = try repo.createHabit(
            name: "测试晨读\(stamp)", icon: "book", color: "#4A90D9", type: .checkIn
        )
        _ = try repo.toggleCheckIn(for: checkin)
        // 打卡型：不打卡 → value=0 行保留
        let idle = try repo.createHabit(
            name: "测试冥想\(stamp)", icon: "moon", color: "#4A90D9", type: .checkIn
        )

        defer {
            for habit in [counting, idle, checkin] {
                repo.context.delete(habit)
            }
            try? repo.context.save()
            repo.loadActiveHabits()
        }

        let rows = await HoloDefaultCrossDomainDataSource().rows(
            source: "habit.daily",
            timeRange: HoloAgentTimeRange(label: "test", start: Calendar.current.startOfDay(for: Date()), end: Date().addingTimeInterval(86_400))
        )
        let today = Calendar.current.startOfDay(for: Date())
        func todayRow(_ name: String) -> HoloQueryRow? {
            rows.first { row in
                row.fields["habit"]?.textValue == name && Calendar.current.startOfDay(for: row.occurredAt) == today
            }
        }

        let countRow = todayRow("测试喝水\(stamp)")
        XCTAssertNotNil(countRow, "计数型习惯今天应有数据行")
        XCTAssertEqual(countRow?.fields["value"]?.numberValue, 1)
        XCTAssertEqual(countRow?.fields["goal"]?.numberValue, 3, "每日目标应随行输出")
        XCTAssertEqual(countRow?.fields["type"]?.textValue, "count")
        XCTAssertEqual(countRow?.fields["unit"]?.textValue, "次")

        let checkRow = todayRow("测试晨读\(stamp)")
        XCTAssertNotNil(checkRow)
        XCTAssertEqual(checkRow?.fields["value"]?.numberValue, 1)
        XCTAssertEqual(checkRow?.fields["type"]?.textValue, "check")
        XCTAssertNil(checkRow?.fields["goal"], "打卡型未设目标时 goal 不应出现")

        let idleRow = todayRow("测试冥想\(stamp)")
        XCTAssertNotNil(idleRow, "没打卡的打卡型习惯必须保留 value=0 行（真实语义）")
        XCTAssertEqual(idleRow?.fields["value"]?.numberValue, 0)
        XCTAssertEqual(idleRow?.fields["type"]?.textValue, "check")
    }

    // MARK: - 4. 存量旧文案清洗（修复前落库的报告带英文残留）

    func test_sanitizeLegacy_translatesKnownEnglishFields() {
        // 旧版云端报告的典型残留（东林 2026-09-01 真机反馈实测样例）
        XCTAssertEqual(
            HoloCloudEvidencePresenter.sanitizeLegacyEnglishFields("习惯每日记录·全部：合计「value」= 540 次（来源 20 条）"),
            "习惯每日记录·全部：合计「完成次数」= 540 次（来源 20 条）"
        )
        XCTAssertEqual(
            HoloCloudEvidencePresenter.sanitizeLegacyEnglishFields("习惯每日记录·「23:30 前休息」：去重计数「date」= 180 天（来源 20 条）"),
            "习惯每日记录·「23:30 前休息」：去重计数「日期」= 180 天（来源 20 条）"
        )
        // 财务行内线索 → 金额
        XCTAssertEqual(
            HoloCloudEvidencePresenter.sanitizeLegacyEnglishFields("交易明细·「音乐」：合计「amount」= 3316 元（来源 1 条）"),
            "交易明细·「音乐」：合计「金额」= 3316 元（来源 1 条）"
        )
    }

    func test_sanitizeLegacy_removesUnknownAndKeepsChinese() {
        // 认不出的英文字段：整段移除（宁缺勿漏）
        XCTAssertEqual(
            HoloCloudEvidencePresenter.sanitizeLegacyEnglishFields("口径：均值「mysteryField」= 3"),
            "口径：均值= 3"
        )
        // 中文片段与用户内容（如歌名）不受影响
        XCTAssertEqual(
            HoloCloudEvidencePresenter.sanitizeLegacyEnglishFields("已核对 2 条交易明细：8月15日 音乐 TIMA音乐盛典 -¥3316"),
            "已核对 2 条交易明细：8月15日 音乐 TIMA音乐盛典 -¥3316"
        )
        // 已是人话的新文案原样返回
        let fresh = "习惯每日记录·全部：计数「日期」= 540 天（来源 20 条）"
        XCTAssertEqual(HoloCloudEvidencePresenter.sanitizeLegacyEnglishFields(fresh), fresh)
    }
}
