import Foundation

/// 用户控制契约验收（方案《Holo 记忆管理独立与升级》§11.3 / §11.4）。
///
/// 1. 请求结构校验与幂等标识边界；
/// 2. 语义预检：投影 allowedActions 为唯一判据，拒绝原因可解释；
/// 3. 结果语义：保存成功才展示成功；
/// 4. 并发因果：限制优先、编辑转需核对、恢复/撤销必须见过全部限制。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryUserControlContractStandaloneTests.main()
    }
}
#endif
struct HoloMemoryUserControlContractStandaloneTests {
    private static var assertions = 0

    static func main() {
        test请求结构校验边界()
        test语义预检允许与拒绝()
        test动作映射()
        test结果成功语义()
        test并发规则限制优先()
        test并发编辑转需核对()
        test同向并发可共存()
        test因果可见性与并发判定()
        test恢复必须见过全部限制()
        print("✅ HoloMemoryUserControlContractStandaloneTests: \(assertions) assertions passed")
    }

    private static func test请求结构校验边界() {
        expect(makeRequest(operationID: " ").structuralError == .emptyOperationID, "空操作 ID 拒绝")
        expect(makeRequest(recordID: "").structuralError == .emptyRecordID, "空记录 ID 拒绝")
        expect(makeRequest(version: 0).structuralError == .invalidContentVersion, "非正版本号拒绝")
        expect(
            makeRequest(action: .correct(statement: "  ")).structuralError == .emptyCorrectionStatement,
            "纠正必须携带非空陈述"
        )
        expect(makeRequest().structuralError == nil, "合法请求通过")
    }

    private static func test语义预检允许与拒绝() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = HoloMemoryManagementProjectionContext(now: now)

        // 允许：观察桶候选 + 来源可用 → 可确认。
        let candidate = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "c-1", state: .candidate), sourceAvailability: .available),
            context: context
        )
        expect(
            HoloMemoryUserControlRequestValidator.precheck(
                makeRequest(recordID: "c-1"), against: candidate
            ) == .allowed,
            "投影允许的动作通过预检"
        )

        // 拒绝：来源失效不能靠确认绕过门禁（§5.1）。
        let sourceDead = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "c-2", state: .candidate), sourceAvailability: .invalid),
            context: context
        )
        expect(
            HoloMemoryUserControlRequestValidator.precheck(
                makeRequest(recordID: "c-2"), against: sourceDead
            ) == .denied(reason: .sourceInvalid),
            "来源失效的确认被拒并给出原因"
        )

        // 拒绝：禁止性推断。
        let blocked = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "c-3", state: .active, decision: makeDecision(useLevel: .blocked))),
            context: context
        )
        expect(
            HoloMemoryUserControlRequestValidator.precheck(
                makeRequest(recordID: "c-3"), against: blocked
            ) == .denied(reason: .prohibitedInference),
            "禁止性推断的确认被拒"
        )

        // 拒绝：桶内动作不可用（观察桶无「已经过时」）。
        expect(
            HoloMemoryUserControlRequestValidator.precheck(
                makeRequest(recordID: "c-1", action: .markOutdated), against: candidate
            ) == .denied(reason: .actionNotAvailable(bucket: .observing)),
            "观察桶的过时动作被拒并携带桶信息"
        )

        // 拒绝：已删除记录不接受任何控制。
        let removed = HoloMemoryManagementProjection.project(
            .init(record: makeRecord(id: "c-4", state: .deleted)),
            context: context
        )
        expect(
            HoloMemoryUserControlRequestValidator.precheck(
                makeRequest(recordID: "c-4"), against: removed
            ) == .denied(reason: .recordRemoved),
            "删除态拒绝控制"
        )

        // undo 不走投影动作集，交由控制链判定。
        expect(
            HoloMemoryUserControlRequestValidator.precheck(
                makeRequest(recordID: "c-1", action: .undo(operationID: "op-x")), against: candidate
            ) == .allowed,
            "撤销预检放行至控制链"
        )
    }

    private static func test动作映射() {
        expect(HoloMemoryUserControlAction.confirm.eventKind == .confirmed, "confirm → confirmed")
        expect(HoloMemoryUserControlAction.correct(statement: "s").eventKind == .corrected, "correct → corrected")
        expect(HoloMemoryUserControlAction.markOutdated.eventKind == .outdated, "markOutdated → outdated")
        expect(HoloMemoryUserControlAction.markInaccurate(reason: nil).eventKind == .inaccurate, "markInaccurate → inaccurate")
        expect(HoloMemoryUserControlAction.disable.eventKind == .disabled, "disable → disabled")
        expect(HoloMemoryUserControlAction.restore.eventKind == .restored, "restore → restored")
        expect(HoloMemoryUserControlAction.forget.eventKind == .forgotten, "forget → forgotten")
        expect(
            HoloMemoryUserControlAction.forget.requiredProjectionAction == .delete,
            "forget 对应投影的 delete 操作"
        )
        expect(HoloMemoryUserControlAction.undo(operationID: "op").requiredProjectionAction == nil, "undo 无投影动作")
    }

    private static func test结果成功语义() {
        expect(HoloMemoryUserControlOutcome.applied(newContentVersion: 3, undoableOperationID: "op-1").isSuccess, "applied 算成功")
        expect(HoloMemoryUserControlOutcome.alreadyApplied.isSuccess, "幂等重试算成功")
        expect(!HoloMemoryUserControlOutcome.conflict(currentContentVersion: 5).isSuccess, "冲突不算成功")
        expect(!HoloMemoryUserControlOutcome.persistenceFailed(underlyingDescription: "e").isSuccess, "落库失败不算成功")
    }

    private static func test并发规则限制优先() {
        let confirm = makeEvent(id: "e-confirm", kind: .confirmed)
        let disable = makeEvent(id: "e-disable", kind: .disabled)
        guard case .restrictiveWins(let winner) = HoloMemoryControlEventAlgebra.resolveConcurrent(confirm, disable) else {
            fatalError("❌ 停用与确认并发应判限制优先")
        }
        expect(winner.id == "e-disable", "限制事件胜出，确认方需重新校验")
    }

    private static func test并发编辑转需核对() {
        let editA = makeEvent(id: "e-edit-a", kind: .corrected)
        let editB = makeEvent(id: "e-edit-b", kind: .corrected)
        guard case .needsReview(let events) = HoloMemoryControlEventAlgebra.resolveConcurrent(editA, editB) else {
            fatalError("❌ 两次编辑并发应转需核对")
        }
        expect(events.count == 2, "两次编辑都保留，不静默二选一")
    }

    private static func test同向并发可共存() {
        let disableA = makeEvent(id: "e-dis-a", kind: .disabled)
        let disableB = makeEvent(id: "e-dis-b", kind: .disabled)
        expect(
            HoloMemoryControlEventAlgebra.resolveConcurrent(disableA, disableB) == .compatible,
            "同向停用并发可共存，由服务层幂等合并"
        )
    }

    private static func test因果可见性与并发判定() {
        // 链：a ← b ← c（c 见过 b，b 见过 a）。
        let a = makeEvent(id: "e-a", kind: .confirmed, prior: [])
        let b = makeEvent(id: "e-b", kind: .corrected, prior: ["e-a"])
        let c = makeEvent(id: "e-c", kind: .confirmed, prior: ["e-b"])
        let all = [a, b, c]
        expect(
            HoloMemoryControlEventAlgebra.sees(c, earlierID: "e-a", allEvents: all),
            "因果闭包：c 传递可见 a"
        )
        expect(
            !HoloMemoryControlEventAlgebra.sees(a, earlierID: "e-c", allEvents: all),
            "因果有序：a 不可见后继"
        )
        expect(
            !HoloMemoryControlEventAlgebra.isConcurrent(b, c, allEvents: all),
            "链上相邻事件不并发"
        )
        let independent = makeEvent(id: "e-x", kind: .confirmed, prior: [])
        expect(
            HoloMemoryControlEventAlgebra.isConcurrent(independent, c, allEvents: all),
            "无因果关联的两事件判并发"
        )
    }

    private static func test恢复必须见过全部限制() {
        let disable1 = makeEvent(id: "e-dis-1", kind: .disabled)
        let disable2 = makeEvent(id: "e-dis-2", kind: .disabled)
        let seenAll = makeEvent(id: "e-restore-1", kind: .restored, prior: ["e-dis-1", "e-dis-2"])
        expect(
            HoloMemoryControlEventAlgebra.canLiftRestrictions(seenAll, restrictions: [disable1, disable2]),
            "见过全部限制的恢复有效"
        )
        let seenPartial = makeEvent(id: "e-restore-2", kind: .restored, prior: ["e-dis-1"])
        expect(
            !HoloMemoryControlEventAlgebra.canLiftRestrictions(seenPartial, restrictions: [disable1, disable2]),
            "没见过新限制的旧恢复不能解除它"
        )
    }

    // MARK: - Fixtures

    private static func makeRequest(
        operationID: String = "op-1",
        recordID: String = "c-1",
        version: Int = 1,
        action: HoloMemoryUserControlAction = .confirm,
        issuedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> HoloMemoryUserControlRequest {
        HoloMemoryUserControlRequest(
            operationID: operationID,
            recordID: recordID,
            expectedContentVersion: version,
            knownControlEventIDs: [],
            action: action,
            issuedAt: issuedAt
        )
    }

    private static func makeEvent(
        id: String,
        kind: HoloMemoryControlEventKind,
        prior: Set<String> = []
    ) -> HoloMemoryUserControlEvent {
        HoloMemoryUserControlEvent(
            id: id,
            targetRecordID: "rec-1",
            kind: kind,
            priorEventIDs: prior,
            basedOnContentVersion: 1,
            resultingContentVersion: 2,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            operationID: "op-\(id)"
        )
    }

    private static func makeRecord(
        id: String,
        state: HoloMemoryState,
        decision: HoloMemoryDecisionMetadataV2? = nil
    ) -> HoloMemoryRecord {
        HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            subjectKey: "subject-\(id)",
            anchorRefs: [],
            claimKind: .observedFact,
            persistenceClass: .durable,
            displaySummary: "摘要-\(id)",
            aiUseSummary: "摘要-\(id)",
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.9,
            freshnessScore: 0.8,
            scoringVersion: 1,
            scoreComputedAt: Date(timeIntervalSince1970: 1_799_900_000),
            extractorVersion: 1,
            promptVersion: 1,
            lastObservationKey: nil,
            state: state,
            sensitivity: .normal,
            userDecision: .none,
            adoptionMetadata: nil,
            recordVersion: 1,
            predecessorVersionID: nil,
            supersedesMemoryID: nil,
            createdAt: Date(timeIntervalSince1970: 1_799_900_000),
            updatedAt: Date(timeIntervalSince1970: 1_799_900_000),
            schemaVersion: 1,
            usageCount: nil,
            lastUsedAt: nil,
            personalContext: nil,
            decisionMetadata: decision.map { HoloMemoryDecisionMetadataEnvelope(v2: $0) }
        )
    }

    private static func makeDecision(
        useLevel: HoloMemoryUseLevel = .factEligible
    ) -> HoloMemoryDecisionMetadataV2 {
        HoloMemoryDecisionMetadataV2(
            policyVersion: 4,
            sourceAuthority: .structuredObservation,
            evidenceVerdict: .supported,
            impactLevel: .low,
            persistencePermission: .durable,
            useLevel: useLevel,
            attentionPolicy: .silent,
            reasonCodes: [],
            evaluatedAt: Date(timeIntervalSince1970: 1_799_000_000),
            evidenceRevision: "rev-1",
            clarification: nil
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            fatalError("❌ \(message)")
        }
    }
}
