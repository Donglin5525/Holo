//
//  ThoughtEditingSessionRegistryTests.swift
//  HoloTests
//
//  编辑会话登记（2026-11-16 主题归类时机根治）：登记/注销/引用计数/全局在途判定。
//  MainActor 类按仓库范式走方法级 @MainActor + async（同步测试析构 malloc 崩是已记坑）。
//

import XCTest
@testable import Holo

final class ThoughtEditingSessionRegistryTests: XCTestCase {

    @MainActor
    func test_beginEnd_marksEditingOnlyWithinSession() async {
        let registry = ThoughtEditingSessionRegistry()
        let id = UUID()
        XCTAssertFalse(registry.isEditing(id))
        XCTAssertFalse(registry.hasActiveSession)

        registry.beginEditing(id)
        XCTAssertTrue(registry.isEditing(id))
        XCTAssertTrue(registry.hasActiveSession)

        registry.endEditing(id)
        XCTAssertFalse(registry.isEditing(id))
        XCTAssertFalse(registry.hasActiveSession)
    }

    @MainActor
    func test_overlappingSessions_refCountUntilLastEnd() async {
        let registry = ThoughtEditingSessionRegistry()
        let id = UUID()
        registry.beginEditing(id)
        registry.beginEditing(id)
        registry.endEditing(id)
        XCTAssertTrue(registry.isEditing(id), "仍有一个编辑器实例在途，不算编辑结束")

        registry.endEditing(id)
        XCTAssertFalse(registry.isEditing(id))
        XCTAssertFalse(registry.hasActiveSession)
    }

    @MainActor
    func test_distinctSessions_areIndependent() async {
        let registry = ThoughtEditingSessionRegistry()
        let a = UUID(), b = UUID()
        registry.beginEditing(a)
        registry.beginEditing(b)
        registry.endEditing(a)
        XCTAssertFalse(registry.isEditing(a))
        XCTAssertTrue(registry.isEditing(b), "b 的会话不受 a 收口影响")
        XCTAssertTrue(registry.hasActiveSession)
    }

    @MainActor
    func test_endUnknownId_isNoop() async {
        let registry = ThoughtEditingSessionRegistry()
        registry.endEditing(UUID())
        XCTAssertFalse(registry.hasActiveSession)
    }

    @MainActor
    func test_receiptWindow_withinAndExpired() async {
        let registry = ThoughtEditingSessionRegistry()
        let id = UUID()
        var now = Date()
        registry.nowProvider = { now }
        registry.beginEditing(id)
        registry.endEditing(id)
        XCTAssertTrue(registry.isWithinReceiptWindow(id), "刚结束编辑在回执时效窗口内")

        now = now.addingTimeInterval(ThoughtEditingSessionRegistry.receiptWindow + 60)
        XCTAssertFalse(registry.isWithinReceiptWindow(id), "超窗后不再算「刚写完」，回执不该弹")
    }

    @MainActor
    func test_receiptWindow_neverEdited_isFalse() async {
        let registry = ThoughtEditingSessionRegistry()
        XCTAssertFalse(registry.isWithinReceiptWindow(UUID()), "从未编辑过的想法不产生回执资格")
    }

    @MainActor
    func test_receiptWindow_refCount_lastEndWins() async {
        let registry = ThoughtEditingSessionRegistry()
        let id = UUID()
        var now = Date()
        registry.nowProvider = { now }
        registry.beginEditing(id)
        registry.beginEditing(id)
        registry.endEditing(id)
        XCTAssertFalse(registry.isWithinReceiptWindow(id), "仍有一个实例在途，还没到「写完」时刻")

        now = now.addingTimeInterval(60)
        registry.endEditing(id)
        XCTAssertTrue(registry.isWithinReceiptWindow(id), "最后一个实例退出才算编辑结束")
    }
}
