//
//  ProfileChannelContractTests.swift
//  HoloTests
//
//  个人档案通道双端契约（2026-11-01 东林拍板「档案=通用指令而非备注」）：
//  用户亲写档案原文以 profileBrief 上行，后端在「用户直接阅读输出」的 purpose
//  统一注入指令级 system 消息。
//  本文件锁 iOS 侧三件事：
//  1) 携带档案的 purpose 集合与后端 PROFILE_CHANNEL_PURPOSES 一致（真源：
//     HoloBackend/src/prompts/serverPromptPolicy.js；后端侧由
//     HoloBackend/tests/profileChannel.test.js 锁定）
//  2) 网关请求体 HoloBackendChatCompletionRequest 的 profileBrief 编码契约
//     （nil 不编码键=旧后端完全兼容）
//  3) 云端上行载体（MemoryInsightContext / Cloud Snapshot）的 profileBrief 根字段
//
//  契约纪律见 docs/standards/跨端接口契约规范.md：改任一端必须同步另一端与本文件。
//

import XCTest
@testable import Holo

final class ProfileChannelContractTests: XCTestCase {

    // MARK: - 1) purpose 集合契约

    /// 与后端 PROFILE_CHANNEL_PURPOSES 逐项对齐（后端文件 serverPromptPolicy.js）。
    /// 注意 personal_context_request 由后端内部路由使用，iOS 枚举不发送，不在对齐表内。
    func testCarryingPurposesMatchBackendContract() {
        let expected: Set<String> = [
            "chat",
            "analysis",
            "insight",
            "health_insight_generation",
            "weekly_plan_generation",
            "thought_voice_summary",
            "agent_loop",
            "personal_context_planning",
            "matter_reconciliation",
            "goal_workshop",
            "matter_execution_plan",
            "today_relief_plan",
        ]
        let carrying = Set([
            HoloBackendPurpose.chat, .analysis, .insight, .agentLoop,
            .healthInsightGeneration, .weeklyPlanGeneration, .thoughtVoiceSummary,
            .personalContextPlanning, .matterReconciliation, .matterExecutionPlan,
            .goalWorkshop, .todayReliefPlan,
        ].map(\.rawValue))
        XCTAssertEqual(carrying, expected, "携带档案的 purpose 集合必须与后端 PROFILE_CHANNEL_PURPOSES 一致")

        // 结构化/萃取/核验类不得携带——那些链路明文「用户数据不可执行」
        let nonCarrying: [HoloBackendPurpose] = [
            .intent, .flexibleQueryPlanner, .replayDigest, .memoryObserver,
            .memoryDomainExtraction, .memoryCrossDomainFusion, .financeActionParser,
            .taskActionParser, .thoughtOrganization, .thoughtTaskExtraction,
            .thoughtTagConvergence, .categoryPatternInduction,
            .personalContextExtraction, .personalContextVerification,
            .billColumnMapping, .billCategorization,
        ]
        for purpose in nonCarrying {
            XCTAssertFalse(purpose.carriesProfileBrief, "\(purpose.rawValue) 不应携带档案")
        }
    }

    // MARK: - 2) 网关请求体编码契约

    private func encodeBody(_ request: HoloBackendChatCompletionRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testGatewayRequestEncodesProfileBriefWhenPresent() throws {
        let request = HoloBackendChatCompletionRequest(
            purpose: HoloBackendPurpose.chat.rawValue,
            messages: [.user("你好")],
            stream: false,
            responseFormat: nil,
            profileBrief: "称呼我为东林"
        )
        let body = try encodeBody(request)
        XCTAssertEqual(body["profileBrief"] as? String, "称呼我为东林", "档案原文必须原样上行为顶层字段")
        XCTAssertEqual(body["purpose"] as? String, "chat")
    }

    func testGatewayRequestOmitsProfileBriefKeyWhenAbsent() throws {
        // 旧后端不认识多余键也能兼容的前提：nil 时不编码该键
        let request = HoloBackendChatCompletionRequest(
            purpose: HoloBackendPurpose.chat.rawValue,
            messages: [.user("你好")],
            stream: false,
            responseFormat: nil
        )
        let body = try encodeBody(request)
        XCTAssertNil(body["profileBrief"], "空档案不得编码 profileBrief 键")
    }

    // MARK: - 3) 云端上行载体契约

    /// 周期回放快照（context JSON）根字段：后端 cloudAnalysisExecutor 从
    /// JSON.parse(contextJSON).profileBrief 读取并注入指令级 system 消息。
    func testMemoryInsightContextEncodesProfileBriefRootKey() throws {
        let context = Self.minimalInsightContext(profileBrief: "称呼我为东林\n- 职业：产品经理")
        let data = try JSONEncoder().encode(context)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["profileBrief"] as? String, "称呼我为东林\n- 职业：产品经理")
        XCTAssertNil(object["personalProfileContext"], "旧字段 personalProfileContext 已退役，不得再编码")
    }

    private static func minimalInsightContext(profileBrief: String?) -> MemoryInsightContext {
        MemoryInsightContext(
            periodType: .weekly,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 100),
            generatedAt: Date(timeIntervalSince1970: 50),
            localeIdentifier: "zh_CN",
            finance: MemoryInsightFinanceContext(
                totalExpense: 0, totalIncome: 0, topCategories: [], dailyExpenses: [],
                previousPeriodExpense: 0, budgetPerformance: nil, anomalyDescriptions: [],
                weekdayWeekendSpending: nil, semanticSummary: nil
            ),
            habits: MemoryInsightHabitContext(
                activeHabitCount: 0, completedRecordCount: 0,
                previousPeriodCompletedRecordCount: 0, streaks: [],
                averageCompletionRate: nil, topPerformingHabits: [], strugglingHabits: [],
                habitPerformanceSummaries: [], habitCategoryCompletionSummaries: []
            ),
            tasks: MemoryInsightTaskContext(
                completedCount: 0, overdueCount: 0, importantCompletedTasks: [],
                totalCount: 0, completionRate: 0, highPriorityCompletionRate: nil,
                dailyCompletionTrend: [], dueInPeriod: 0, createdInPeriod: 0,
                completedInPeriod: 0, newOverdueInPeriod: 0, carriedOverBacklogCount: 0,
                activeBacklogCount: 0, periodCompletionScopeNote: ""
            ),
            thoughts: MemoryInsightThoughtContext(
                totalCount: 0, recentSnippets: [], textContents: [],
                moodDistribution: [:], topTags: [],
                thoughtSentimentSummary: ThoughtSentimentSummary(negativeRatio: nil, source: "none")
            ),
            milestones: [],
            crossModuleCorrelations: [],
            monthlyInsightDigests: [],
            anomalies: [],
            profileBrief: profileBrief
        )
    }

    /// 深度分析快照根字段：后端从 snapshot.profileBrief 读取。
    func testCloudSnapshotEncodesProfileBriefRootKey() throws {
        let snapshot = HoloCloudAnalysisSnapshotBuilder.Snapshot(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 0),
            historyDays: 30,
            datasets: [:],
            answerTask: nil,
            financeEvidenceLedger: nil,
            crossDomainCheckup: nil,
            financeSemantics: nil,
            personalSituationBrief: nil,
            goalScope: nil,
            goalReview: nil,
            profileBrief: "称呼我为东林"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["profileBrief"] as? String, "称呼我为东林")

        var without = snapshot
        without.profileBrief = nil
        let nilData = try encoder.encode(without)
        let nilObject = try XCTUnwrap(JSONSerialization.jsonObject(with: nilData) as? [String: Any])
        XCTAssertNil(nilObject["profileBrief"], "空档案快照不编码该键（旧后端兼容）")
    }
}
