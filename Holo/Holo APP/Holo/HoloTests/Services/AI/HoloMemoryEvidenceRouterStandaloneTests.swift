import Foundation

/// 记忆证据路由验收（记忆中心来源行点击修复，2026-10-25）。
///
/// 1. sourceID 按 HoloLifeSourceKeys 规范解析：带域前缀的剥前缀，存量裸 UUID 回落证据自身 sourceDomain 判域；
/// 2. 可达性只取决于「sourceID 是否指向一个有详情页的实体记录」——证据 kind 不参与判定，
///    聚合快照（无单一出处）与 habit 打卡（UUID 指向打卡而非习惯本身）不可直达，弹出处预览；
/// 3. 前缀域与证据域不一致时前缀优先：前缀是萃取写入时的真值（与 liveText 回查同口径）。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryEvidenceRouterStandaloneTests.main()
    }
}
#endif
struct HoloMemoryEvidenceRouterStandaloneTests {
    private static var assertions = 0

    static func main() {
        test带前缀任务证据直达任务详情()
        test存量裸UUID按证据域路由()
        test打卡证据不可直达()
        test无详情页域走出处预览()
        test聚合快照与缺失来源不可直达()
        test前缀域优先于证据域()
        test非法SourceID不可直达()
        print("✅ HoloMemoryEvidenceRouterStandaloneTests: \(assertions) assertions passed")
    }

    /// 本次修复的原始案例形态：个人情境萃取证据 task:UUID + explicitUserStatement，
    /// 旧路由因「裸 UUID 解析失败 + kind 不在枚举内」双双落空，必须直达任务详情。
    private static func test带前缀任务证据直达任务详情() {
        let uuid = UUID(uuidString: "9AEFC071-6C33-44A5-A398-41D77B55EC64")!
        let evidence = makeEvidence(
            kind: .explicitUserStatement,
            domain: .task,
            sourceID: "task:\(uuid.uuidString)"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: evidence) == .taskDetail(taskId: uuid),
            "task:UUID + explicitUserStatement 直达任务详情"
        )
    }

    /// 存量域记忆证据是裸 UUID（无前缀信息），域只能取自 sourceDomain。
    private static func test存量裸UUID按证据域路由() {
        let uuid = UUID(uuidString: "3F6FBB51-B252-4833-AEF7-716AE1491354")!
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .task, sourceID: uuid.uuidString))
                == .taskDetail(taskId: uuid),
            "裸 UUID + task 域直达任务详情"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .finance, sourceID: uuid.uuidString))
                == .transactionDetail(transactionId: uuid),
            "裸 UUID + finance 域直达交易详情"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .explicitUserStatement, domain: .thought, sourceID: uuid.uuidString))
                == .thoughtDetail(thoughtId: uuid),
            "裸 UUID + thought 域直达想法详情"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .habit, sourceID: "habit:\(uuid.uuidString)"))
                == .habitDetail(habitId: uuid),
            "habit:UUID 直达习惯详情"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .goal, sourceID: "goal:\(uuid.uuidString)"))
                == .goalDetail(goalId: uuid),
            "goal:UUID 直达目标详情"
        )
    }

    private static func test打卡证据不可直达() {
        let uuid = UUID(uuidString: "CAE7A097-7586-446B-8033-A2F5518B42BB")!
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .habit, sourceID: "habit-checkin:\(uuid.uuidString)"))
                == nil,
            "打卡 UUID 指向 HabitRecord 而非 Habit，不可直达，弹出处预览"
        )
    }

    private static func test无详情页域走出处预览() {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .conversation, sourceID: "conversation:\(uuid.uuidString)"))
                == nil,
            "对话消息无详情页，弹出处预览"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .health, sourceID: uuid.uuidString))
                == nil,
            "健康域无详情页"
        )
    }

    private static func test聚合快照与缺失来源不可直达() {
        let uuid = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .aggregateSnapshot, domain: .task, sourceID: "task:\(uuid.uuidString)"))
                == nil,
            "聚合快照没有单一出处，保持纯展示"
        )
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .task, sourceID: nil))
                == nil,
            "无 sourceID 的证据不可直达"
        )
    }

    private static func test前缀域优先于证据域() {
        let uuid = UUID(uuidString: "AAAAAAA1-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .profile, sourceID: "task:\(uuid.uuidString)"))
                == .taskDetail(taskId: uuid),
            "前缀是萃取写入真值，与前缀冲突的证据域让位"
        )
    }

    private static func test非法SourceID不可直达() {
        expect(
            HoloMemoryEvidenceRouter.deepLinkTarget(for: makeEvidence(kind: .entityRef, domain: .task, sourceID: "task:not-a-uuid"))
                == nil,
            "剥前缀后不是合法 UUID 的 sourceID 不可直达"
        )
    }

    private static func makeEvidence(
        kind: HoloMemoryEvidenceKind,
        domain: HoloMemoryDomain,
        sourceID: String?
    ) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: "ev-test",
            kind: kind,
            sourceDomain: domain,
            lineageKey: sourceID ?? "lineage",
            sourceID: sourceID,
            revisionDigest: "rev-1",
            observedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            fatalError("❌ \(message)")
        }
    }
}
