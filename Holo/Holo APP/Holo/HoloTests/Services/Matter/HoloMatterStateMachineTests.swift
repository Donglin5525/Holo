//
//  HoloMatterStateMachineTests.swift
//  HoloTests
//
//  Matter 状态机与纯逻辑契约（方案 §18.1 确定性测试 - 生命周期/状态维度/投影）
//
//  覆盖：
//  - 生命周期全部合法/非法迁移（§5.1 迁移表）
//  - Open Loop 语义词汇（epistemic/state/priority）
//  - 投影 stale 判定与损坏 JSON 兜底（不崩、丢弃重建）
//  - 幂等键与 logicalKey 归一化
//  - 灰度开关依赖链（§22.1）
//

import XCTest
@testable import Holo

final class HoloMatterStateMachineTests: XCTestCase {

    // MARK: - 生命周期迁移表

    func testLifecycleLegalTransitions() {
        let legal: [(HoloMatterLifecycleStatus, HoloMatterLifecycleStatus)] = [
            (.candidate, .active),
            (.candidate, .dismissed),
            (.active, .completed),
            (.completed, .active),
            (.completed, .archived),
            (.archived, .active),
        ]
        for (from, to) in legal {
            XCTAssertTrue(
                from.canTransition(to: to),
                "合法迁移被拒：\(from.rawValue) → \(to.rawValue)"
            )
        }
    }

    func testLifecycleIllegalTransitions() {
        let illegal: [(HoloMatterLifecycleStatus, HoloMatterLifecycleStatus)] = [
            (.active, .candidate),          // 不能回候选
            (.active, .archived),           // 必须先完成再归档
            (.active, .dismissed),          // 活跃事项不可 dismiss（candidate 专属）
            (.completed, .dismissed),
            (.completed, .candidate),
            (.archived, .completed),        // 归档后不可直接完成
            (.archived, .dismissed),
            (.dismissed, .active),          // 拒绝即终态（防骚扰）
            (.dismissed, .candidate),
            (.candidate, .completed),       // 候选必须先激活
            (.candidate, .archived),
        ]
        for (from, to) in illegal {
            XCTAssertFalse(
                from.canTransition(to: to),
                "非法迁移被放行：\(from.rawValue) → \(to.rawValue)"
            )
        }
        // 自迁移一律非法。
        for status in HoloMatterLifecycleStatus.allCases {
            XCTAssertFalse(status.canTransition(to: status), "自迁移非法：\(status.rawValue)")
        }
    }

    // MARK: - 未知 enum raw 兜底（不启动崩溃）

    func testDecodeMatterEnumFallsBackOnUnknownRaw() {
        let decoded: HoloMatterLifecycleStatus = decodeMatterEnum(
            HoloMatterLifecycleStatus.self, from: "zombieState", fallback: .candidate
        )
        XCTAssertEqual(decoded, .candidate)

        let nilRaw: String? = nil
        let phase: HoloMatterPhase = decodeMatterEnum(HoloMatterPhase.self, from: nilRaw, fallback: .planning)
        XCTAssertEqual(phase, .planning)

        let known: HoloMatterPhase = decodeMatterEnum(HoloMatterPhase.self, from: "waiting", fallback: .planning)
        XCTAssertEqual(known, .waiting)
    }

    // MARK: - 投影

    func testProjectionStaleWhenRevisionDrifts() {
        var projection = HoloMatterProjectionV1(
            matterID: UUID(),
            sourceMatterRevision: 5,
            summary: "筹备期",
            attention: .needsAttention,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertFalse(projection.isStale(currentRevision: 5))
        XCTAssertTrue(projection.isStale(currentRevision: 6))

        projection.staleReason = "来源已更新"
        XCTAssertTrue(projection.isStale(currentRevision: 7))
    }

    func testProjectionRoundtripEncoding() throws {
        let projection = HoloMatterProjectionV1(
            matterID: UUID(),
            sourceMatterRevision: 3,
            summary: "住宿订了一半",
            attention: .onTrack,
            nextAction: HoloMatterNextAction(
                kind: .openLoopAction,
                entityID: "loop-1",
                title: "确认签证材料",
                reason: "临近处理窗口"
            ),
            evidenceRefs: [HoloMatterEvidenceRef(entityType: "todoTask", entityID: "task-9")],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let json = try XCTUnwrap(projection.encodeJSON())
        let decoded = HoloMatterProjectionV1.decode(from: json, matterRevision: 3)
        XCTAssertEqual(decoded, projection)
    }

    func testProjectionDecodeRejectsCorruptedJSON() {
        XCTAssertNil(HoloMatterProjectionV1.decode(from: "{not json", matterRevision: 1))
        XCTAssertNil(HoloMatterProjectionV1.decode(from: nil, matterRevision: 1))
        XCTAssertNil(HoloMatterProjectionV1.decode(from: "", matterRevision: 1))
    }

    func testProjectionDecodeRejectsUnknownSchemaVersion() throws {
        let future = """
        {"schemaVersion":99,"matterID":"\(UUID().uuidString)","sourceMatterRevision":1,
         "summary":"x","attention":"onTrack","evidenceRefs":[],
         "generatedAt":"2026-09-11T00:00:00Z"}
        """
        XCTAssertNil(HoloMatterProjectionV1.decode(from: future, matterRevision: 1))
    }

    // MARK: - 幂等键

    func testIdempotencyKeysAreDeterministic() {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000")!
        let matterID = UUID(uuidString: "11111111-BBBB-CCCC-DDDD-EEEEFFFF0000")!
        let loopID = UUID(uuidString: "22222222-BBBB-CCCC-DDDD-EEEEFFFF0000")!

        XCTAssertEqual(
            HoloMatterIdempotencyKey.activate(contextPlanMessageID: messageID),
            HoloMatterIdempotencyKey.activate(contextPlanMessageID: messageID)
        )
        XCTAssertEqual(
            HoloMatterIdempotencyKey.link(matterID: matterID, entityType: .todoTask, entityID: "t1"),
            "link:\(matterID.uuidString):todoTask:t1"
        )
        XCTAssertEqual(
            HoloMatterIdempotencyKey.resolve(matterID: matterID, openLoopID: loopID, sourceRevision: "7"),
            HoloMatterIdempotencyKey.resolve(matterID: matterID, openLoopID: loopID, sourceRevision: "7")
        )
        // 不同来源 → 不同键。
        XCTAssertNotEqual(
            HoloMatterIdempotencyKey.activate(contextPlanMessageID: messageID),
            HoloMatterIdempotencyKey.activate(contextPlanMessageID: UUID())
        )
    }

    func testNormalizeLogicalKeyCollapsesVariants() {
        XCTAssertEqual(
            HoloMatterRepository.normalizeLogicalKey("猫咪由谁照顾？"),
            HoloMatterRepository.normalizeLogicalKey(" 猫咪由谁照顾 ")
        )
        XCTAssertEqual(
            HoloMatterRepository.normalizeLogicalKey("Hotel Booking"),
            HoloMatterRepository.normalizeLogicalKey("hotel booking")
        )
        // 空串安全。
        XCTAssertEqual(HoloMatterRepository.normalizeLogicalKey("  "), "")
    }

    // MARK: - Mutation Proposal 契约

    func testProposalCodableRoundtripWithAllMutationKinds() throws {
        let loopID = UUID()
        let proposal = HoloMatterMutationProposal(
            proposalID: "p-1",
            matterID: UUID(),
            baseMatterRevision: 12,
            mutations: [
                .addSuggestedOpenLoop(HoloMatterOpenLoopDraft(logicalKey: "k", title: "买转换插头")),
                .setOpenLoopState(openLoopID: loopID, state: .resolved),
                .proposeLink(HoloMatterLinkDraft(entityType: .thought, entityID: "th-1", role: .resource)),
            ],
            ambiguities: [HoloMatterAmbiguity(
                id: "amb-1",
                question: "东京还是京都？",
                options: [
                    HoloMatterAmbiguityOption(id: "o1", title: "东京住宿", openLoopID: loopID),
                    HoloMatterAmbiguityOption(id: "o2", title: "京都住宿"),
                ]
            )]
        )

        let data = try JSONEncoder.holoMatter.encode(proposal)
        let decoded = try JSONDecoder.holoMatter.decode(HoloMatterMutationProposal.self, from: data)
        XCTAssertEqual(decoded, proposal)
    }

    // MARK: - 灰度默认值（2026-09-13 拍板：基础三件套默认开）

    func testBaseFlagsDefaultOnAndLaterPhasesDefaultOff() {
        UserDefaults.standard.removeObject(forKey: HoloMatterRolloutPolicy.Flag.matterStorageEnabled.rawValue)
        UserDefaults.standard.removeObject(forKey: HoloMatterRolloutPolicy.Flag.matterActivationEnabled.rawValue)
        UserDefaults.standard.removeObject(forKey: HoloMatterRolloutPolicy.Flag.matterScopedChatEnabled.rawValue)
        UserDefaults.standard.removeObject(forKey: HoloMatterRolloutPolicy.Flag.matterInferredAssociationEnabled.rawValue)
        UserDefaults.standard.removeObject(forKey: HoloMatterRolloutPolicy.Flag.matterInterventionEnabled.rawValue)

        XCTAssertTrue(HoloMatterRolloutPolicy.storageEnabled, "存储层应默认开")
        XCTAssertTrue(HoloMatterRolloutPolicy.activationEnabled, "激活入口应默认开")
        XCTAssertTrue(HoloMatterRolloutPolicy.scopedChatEnabled, "事情内对话应默认开")
        XCTAssertFalse(HoloMatterRolloutPolicy.inferredAssociationEnabled, "外部关联推荐按方案节奏默认关")
        XCTAssertFalse(HoloMatterRolloutPolicy.interventionEnabled, "主动通知按方案节奏默认关")

        // 用户显式关闭 → 尊重设置
        UserDefaults.standard.set(false, forKey: HoloMatterRolloutPolicy.Flag.matterActivationEnabled.rawValue)
        XCTAssertFalse(HoloMatterRolloutPolicy.activationEnabled)
        UserDefaults.standard.removeObject(forKey: HoloMatterRolloutPolicy.Flag.matterActivationEnabled.rawValue)
    }
}
