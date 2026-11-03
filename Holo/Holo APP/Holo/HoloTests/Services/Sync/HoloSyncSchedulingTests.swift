import XCTest
@testable import Holo

/// 2026-10-09 掉帧治理第一批（C1/C2/C3a）调度语义钉死：
/// - C1 云同步事件三态判定（started/failed/succeeded、export 忽略）
/// - C2 副本扫描单工作者门禁（force 不绕 in-flight、pending 补做、旧回调失效）
/// - C3a 修复落库精准域通知（实体→域映射、域外兜底全六域）
final class HoloSyncSchedulingTests: XCTestCase {

    // MARK: - C1：CloudImportRelay.classify

    private func makeEvent(
        kind: CloudSyncEventInput.Kind,
        ended: Bool = true,
        succeeded: Bool = true,
        hasError: Bool = false
    ) -> CloudSyncEventInput {
        CloudSyncEventInput(
            identifier: UUID(),
            kind: kind,
            endDate: ended ? Date() : nil,
            succeeded: succeeded,
            hasError: hasError
        )
    }

    func testClassifyStartedWhenNotEnded() {
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .import, ended: false)), .started)
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .setup, ended: false)), .started)
    }

    func testClassifySucceededVariants() {
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .import)), .importSucceeded)
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .setup)), .setupSucceeded)
    }

    func testClassifyExportIgnoredEvenWhenSucceeded() {
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .export)), .ignored)
    }

    func testClassifyFailedVariants() {
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .import, succeeded: false)), .failed)
        // succeeded=true 但带 error：按失败处理（防御组合，不冒称成功）
        XCTAssertEqual(CloudImportRelay.classify(makeEvent(kind: .import, hasError: true)), .failed)
    }

    // MARK: - C2：DuplicateScanGate

    func testScanGateFirstForceStarts() {
        var gate = DuplicateScanGate(minScanInterval: 60)
        guard case .start = gate.request(force: true, now: Date()) else {
            return XCTFail("首次 force 请求应放行开跑")
        }
        XCTAssertTrue(gate.isScanning)
    }

    func testScanGateForceCannotBypassInFlight() {
        var gate = DuplicateScanGate(minScanInterval: 60)
        let t0 = Date()
        guard case .start(let runID) = gate.request(force: true, now: t0) else {
            return XCTFail("首次 force 请求应放行开跑")
        }
        // in-flight 是硬门禁：force 与普通请求都只能挂 pending，绝不放第二份扫描
        XCTAssertEqual(gate.request(force: true, now: t0.addingTimeInterval(1)), .markPending)
        XCTAssertEqual(gate.request(force: false, now: t0.addingTimeInterval(2)), .markPending)
        XCTAssertTrue(gate.isRunning(runID: runID))
    }

    func testScanGateCooldownDropsNonForce() {
        var gate = DuplicateScanGate(minScanInterval: 60)
        let t0 = Date()
        guard case .start(let first) = gate.request(force: true, now: t0) else {
            return XCTFail("首次 force 应放行")
        }
        _ = gate.finish(runID: first, now: t0.addingTimeInterval(1))
        XCTAssertFalse(gate.isScanning)
        // 冷却期内：非 force 丢弃（remote-change 上游会再触发，丢一轮无损）
        XCTAssertEqual(gate.request(force: false, now: t0.addingTimeInterval(10)), .dropped)
        XCTAssertFalse(gate.isScanning)
        // 冷却期满：非 force 放行
        guard case .start = gate.request(force: false, now: t0.addingTimeInterval(61)) else {
            return XCTFail("冷却期满非 force 应放行")
        }
    }

    func testScanGateFinishWithPendingStartsNextRun() {
        var gate = DuplicateScanGate(minScanInterval: 60)
        let t0 = Date()
        guard case .start(let first) = gate.request(force: true, now: t0) else {
            return XCTFail("首次 force 应放行")
        }
        _ = gate.request(force: false, now: t0.addingTimeInterval(1))   // in-flight 期间的新变化
        guard case .start(let second) = gate.finish(runID: first, now: t0.addingTimeInterval(2)) else {
            return XCTFail("有 pending 时结束应立即补开新一轮")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(gate.isRunning(runID: second))
        XCTAssertFalse(gate.pendingRescan)
    }

    func testScanGateFinishWithoutPendingGoesIdle() {
        var gate = DuplicateScanGate(minScanInterval: 60)
        let t0 = Date()
        guard case .start(let first) = gate.request(force: true, now: t0) else {
            return XCTFail("首次 force 应放行")
        }
        XCTAssertEqual(gate.finish(runID: first, now: t0.addingTimeInterval(1)), .dropped)
        XCTAssertFalse(gate.isScanning)
    }

    func testScanGateStaleFinishDoesNotClearNewRun() {
        var gate = DuplicateScanGate(minScanInterval: 60)
        let t0 = Date()
        guard case .start(let first) = gate.request(force: true, now: t0) else {
            return XCTFail("首次 force 应放行")
        }
        _ = gate.request(force: false, now: t0.addingTimeInterval(1))
        guard case .start(let second) = gate.finish(runID: first, now: t0.addingTimeInterval(2)) else {
            return XCTFail("有 pending 时结束应补开新一轮")
        }
        // 过期的 first 完成回调不得清掉 second 的在途状态
        XCTAssertEqual(gate.finish(runID: first, now: t0.addingTimeInterval(3)), .dropped)
        XCTAssertTrue(gate.isRunning(runID: second))
        XCTAssertFalse(gate.isRunning(runID: first))
    }

    // MARK: - C3a：GlobalDuplicateRepair.domainNotifications

    func testDomainNotificationsEmptyWhenNoRemoval() {
        XCTAssertTrue(GlobalDuplicateRepair.domainNotifications(for: [:]).isEmpty)
    }

    func testDomainNotificationsSingleDomain() {
        XCTAssertEqual(
            GlobalDuplicateRepair.domainNotifications(for: ["Transaction": 2]),
            [.financeDataDidChange]
        )
    }

    func testDomainNotificationsMultiDomain() {
        let result = Set(GlobalDuplicateRepair.domainNotifications(for: ["TodoTask": 1, "Habit": 1, "HabitRecord": 2]))
        XCTAssertEqual(result, Set([Notification.Name.todoDataDidChange, Notification.Name.habitDataDidChange]))
    }

    func testDomainNotificationsUnknownEntityFallsBackToAllSix() {
        let result = GlobalDuplicateRepair.domainNotifications(for: ["HoloMatter": 1])
        XCTAssertEqual(Set(result), Set(GlobalDuplicateRepair.allDomainNotifications))
        // 混合：含域外实体时整体退回全六域（宁可多刷不丢刷新）
        let mixed = GlobalDuplicateRepair.domainNotifications(for: ["TodoTask": 1, "ChatMessage": 1])
        XCTAssertEqual(Set(mixed), Set(GlobalDuplicateRepair.allDomainNotifications))
    }
}
