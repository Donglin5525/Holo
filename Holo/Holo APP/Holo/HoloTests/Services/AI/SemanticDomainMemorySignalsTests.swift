import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try SemanticDomainMemorySignalsTests.main()
    }
}
#endif
struct SemanticDomainMemorySignalsTests {
    private static var assertions = 0

    static func main() throws {
        testHealthUsesAggregateOnlyAndTreatsMissingAsMissing()
        testThoughtSeparatesOriginalStanceAndAISummary()
        testTaskThresholdPreventsPsychologicalInference()
        testTaskBacklogIncludesTasksWithoutDeadlines()
        testTaskCompletionCountDoesNotClaimStableRhythm()
        try testConversationOnlyAcceptsExplicitUserStatements()
        print("SemanticDomainMemorySignalsTests: \(assertions) assertions passed")
    }

    private static func testHealthUsesAggregateOnlyAndTreatsMissingAsMissing() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let signals = HealthMemorySignalBuilder.build(from: [
            .init(
                metricKey: "sleep-duration", displayName: "睡眠时长",
                average: nil, minimum: nil, maximum: nil, sampleCount: 0,
                windowStart: now.addingTimeInterval(-7 * 86_400), windowEnd: now,
                revisionDigest: "missing"
            ),
            .init(
                metricKey: "steps", displayName: "步数",
                average: 8_000, minimum: 4_000, maximum: 12_000, sampleCount: 7,
                windowStart: now.addingTimeInterval(-7 * 86_400), windowEnd: now,
                revisionDigest: "health-r1"
            )
        ])
        expect(signals.count == 1, "健康缺失数据应被跳过，不能当成异常")
        guard let signal = signals.first else { fatalError("健康聚合信号缺失") }
        expect(signal.evidence.kind == .aggregateSnapshot && signal.evidence.sourceID == nil,
               "健康记忆只能保存 aggregate snapshot，不能复制原始样本 ID")
        expect(signal.prohibitedInferences.contains(where: { $0.contains("医疗诊断") }),
               "健康信号必须禁止医疗诊断")
        expect(signal.prohibitedInferences.contains(where: { $0.contains("sensitiveLocal") }),
               "健康派生记忆必须标记为本机敏感存储")
    }

    private static func testThoughtSeparatesOriginalStanceAndAISummary() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let casual = ThoughtMemoryInput(
            id: "thought-casual", originalText: "今天随便想了想", explicitStance: nil,
            aiSummary: "一次普通随想", topic: "日常", revisionDigest: "r1", createdAt: now
        )
        let explicit = ThoughtMemoryInput(
            id: "thought-stance", originalText: "我原话是更看重长期价值",
            explicitStance: "明确看重长期价值", aiSummary: "用户表达长期主义倾向",
            topic: "长期价值", revisionDigest: "r2", createdAt: now
        )
        let signals = ThoughtMemorySignalBuilder.build(from: [casual, explicit])
        expect(signals.count == 1, "一次普通随想不得升级为观点记忆")
        guard let signal = signals.first else { fatalError("明确观点信号缺失") }
        expect(signal.userText == explicit.originalText, "用户原话必须单独保留")
        expect(signal.explicitUserStance == explicit.explicitStance, "明确立场必须与原话区分")
        expect(signal.aiSummary == explicit.aiSummary, "AI 摘要必须标记为派生表达")
        expect(signal.evidence.kind == .explicitUserStatement && signal.evidence.sourceID == explicit.id,
               "观点证据必须回到用户原始观点实体，AI 摘要不能作证据")
        expect(signal.prohibitedInferences.contains(where: { $0.contains("人格") }),
               "单次观点不得升级为人格标签")
    }

    private static func testTaskThresholdPreventsPsychologicalInference() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let overdue = (0..<5).map { index in
            TaskMemoryInput(
                id: "task-\(index)", title: "任务 \(index)", typeKey: "work",
                completed: false, createdAt: now.addingTimeInterval(-10 * 86_400),
                dueAt: now.addingTimeInterval(-Double(index + 1) * 86_400), completedAt: nil,
                revisionDigest: "r\(index)"
            )
        }
        expect(TaskMemorySignalBuilder.build(from: Array(overdue.prefix(2)), now: now).isEmpty,
               "少量逾期不得形成任务记忆")
        let signals = TaskMemorySignalBuilder.build(from: overdue, now: now)
        expect(signals.contains(where: { $0.id == "task-backlog" }), "达到阈值后可提炼积压模式")
        expect(signals.allSatisfy { signal in
            signal.prohibitedInferences.contains(where: { $0.contains("心理") && $0.contains("能力") })
        }, "任务信号必须禁止心理和能力推断")
        expect(signals.allSatisfy { $0.evidence.kind == .aggregateSnapshot },
               "任务节奏只使用本地聚合，不把标题明细直接交给 AI")
    }

    private static func testTaskBacklogIncludesTasksWithoutDeadlines() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let openWithoutDeadlines = (0..<12).map { index in
            TaskMemoryInput(
                id: "open-\(index)", title: "未完成任务 \(index)", typeKey: "inbox",
                completed: false, createdAt: now.addingTimeInterval(-20 * 86_400),
                dueAt: nil, completedAt: nil, revisionDigest: "open-r\(index)"
            )
        }
        let signals = TaskMemorySignalBuilder.build(from: openWithoutDeadlines, now: now)
        guard let backlog = signals.first(where: { $0.id == "task-open-backlog" }) else {
            fatalError("无截止时间任务积压信号缺失")
        }
        expect(backlog.numericFacts["openCount"] == 12, "未完成任务必须进入积压总数")
        expect(backlog.numericFacts["withoutDueDateCount"] == 12,
               "没有截止时间的任务必须单独计数")
        expect(backlog.numericFacts["overdueCount"] == 0,
               "没有截止时间不得被误算为逾期")
        expect(!signals.contains(where: { $0.id == "task-backlog" }),
               "没有截止时间时不得伪造逾期积压")
        expect(backlog.prohibitedInferences.contains(where: {
            $0.contains("无法判断是否逾期") && $0.contains("节奏稳定")
        }), "任务信号必须阻止把无截止时间解释为按时完成")
    }

    private static func testTaskCompletionCountDoesNotClaimStableRhythm() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let completed = (0..<6).map { index in
            TaskMemoryInput(
                id: "completed-\(index)", title: "完成任务 \(index)", typeKey: "work",
                completed: true, createdAt: now.addingTimeInterval(-20 * 86_400),
                dueAt: nil,
                completedAt: now.addingTimeInterval(-Double(index % 3) * 86_400),
                revisionDigest: "completed-r\(index)"
            )
        }
        let signals = TaskMemorySignalBuilder.build(from: completed, now: now)
        guard let activity = signals.first(where: { $0.id == "task-completion-activity" }) else {
            fatalError("近期完成活动信号缺失")
        }
        expect(!signals.contains(where: { $0.id == "task-completion-rhythm" }),
               "完成总数不能继续冒充稳定节奏")
        expect(activity.numericFacts["activeCompletionDayCount"] == 3,
               "完成活动必须暴露实际活跃天数")
        expect(activity.prohibitedInferences.contains(where: { $0.contains("节奏稳定") }),
               "完成活动必须明确禁止仅凭总数推断稳定节奏")
    }

    private static func testConversationOnlyAcceptsExplicitUserStatements() throws {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let profileAnchor = try HoloMemoryAnchorRef(type: .profile, value: "communication-style")
        let inputs: [ConversationMemoryInput] = [
            .init(
                id: "assistant-1", role: .assistant, statementKind: .explicitPreference,
                text: "AI 猜用户喜欢简洁", revisionDigest: "a1", createdAt: now,
                profileAnchor: profileAnchor
            ),
            .init(
                id: "user-casual", role: .user, statementKind: .casual,
                text: "今天天气不错", revisionDigest: "u1", createdAt: now,
                profileAnchor: nil
            ),
            .init(
                id: "user-pref", role: .user, statementKind: .explicitPreference,
                text: "以后回答我尽量简洁", revisionDigest: "u2", createdAt: now,
                profileAnchor: profileAnchor
            )
        ]
        let signals = ConversationMemorySignalBuilder.build(from: inputs)
        expect(signals.count == 1, "AI 回复和普通闲聊永远不能成为对话记忆证据")
        guard let signal = signals.first else { fatalError("用户明确偏好信号缺失") }
        expect(signal.evidence.sourceDomain == .conversation && signal.evidence.sourceID == "user-pref",
               "对话证据必须来自用户消息稳定 ID")
        expect(signal.anchors.contains(where: { $0.type == .profile }),
               "Profile 只可作为表达锚点附加")
        expect(!signal.evidence.lineageKey.contains("profile"),
               "Profile 不得冒充对话证据或被后台静默改写")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }
}
