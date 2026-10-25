//
//  HoloProductAnalyticsTests.swift
//  HoloTests
//
//  产品埋点本地队列与事件名契约测试（2026-10-19 自建埋点方案）
//

import XCTest
@testable import Holo

final class HoloProductAnalyticsTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-analytics-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func makeQueue(maxQueuedEvents: Int = 1000) -> HoloProductEventQueue {
        HoloProductEventQueue(
            fileURL: tempDir.appendingPathComponent("pending.json"),
            maxQueuedEvents: maxQueuedEvents
        )
    }

    private func makeEvent(
        name: String = "module_view",
        id: String = UUID().uuidString,
        sessionId: String? = "session-test-0001"
    ) -> HoloProductPendingEvent {
        HoloProductPendingEvent(
            id: id,
            name: name,
            timestampMs: 1_700_000_000_000,
            params: ["module": "finance"],
            appVersion: "1.1.3",
            buildChannel: "release",
            sessionId: sessionId
        )
    }

    func testAppendPersistsAcrossQueueInstances() async {
        let queue = makeQueue()
        await queue.append(makeEvent(id: "evt-1"))
        await queue.append(makeEvent(id: "evt-2"))

        // 新实例从同一文件加载 = 落盘持久化成立（杀 App 后事件不丢）
        let reloaded = makeQueue()
        let events = await reloaded.prefix(100)
        XCTAssertEqual(events.map(\.id), ["evt-1", "evt-2"])
        let count = await reloaded.count()
        XCTAssertEqual(count, 2)
    }

    func testQueueCapsDroppingOldest() async {
        let queue = makeQueue(maxQueuedEvents: 20)
        for index in 0..<25 {
            await queue.append(makeEvent(id: "evt-\(index)"))
        }
        let events = await queue.prefix(50)
        XCTAssertEqual(events.count, 20)
        // 最旧的 5 条被丢弃，保底最新的
        XCTAssertEqual(events.first?.id, "evt-5")
        XCTAssertEqual(events.last?.id, "evt-24")
    }

    func testRemoveIdsDropsOnlyUploaded() async {
        let queue = makeQueue()
        await queue.append(makeEvent(id: "keep"))
        await queue.append(makeEvent(id: "drop"))
        await queue.remove(ids: ["drop"])
        let events = await queue.prefix(10)
        XCTAssertEqual(events.map(\.id), ["keep"])
    }

    func testRemoveAllClearsPersistedFile() async {
        let queue = makeQueue()
        await queue.append(makeEvent())
        await queue.removeAll()
        let reloaded = makeQueue()
        let count = await reloaded.count()
        XCTAssertEqual(count, 0)
    }

    /// 事件名契约：iOS 枚举 rawValue 必须与后端 PRODUCT_EVENT_NAMES 白名单一一对应；
    /// 不一致时后端按未知事件名拒收整批（客户端 4xx 丢弃）。此测试是双端字典的回归闸。
    func testEventNameContractMatchesBackendWhitelist() {
        let expected: Set<String> = [
            // v1（2026-10-19）
            "app_first_launch",
            "app_session_start",
            "module_view",
            "bill_created",
            "habit_checkin",
            "task_created",
            "paywall_viewed",
            "paywall_purchase_tapped",
            // v2（2026-10-25）
            "ai_conversation_started",
            "ai_message_sent",
            "ai_deep_report_requested",
            "ai_deep_report_viewed",
            "thought_created",
            "habit_created",
            "account_created",
            "receipt_booking_started",
            "export_performed",
        ]
        let actual = Set(HoloProductEventName.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }

    /// 习惯仓库被小组件 target 共享，新建/打卡经通知总线送达埋点服务：
    /// 通知名与 userInfo 键是跨 target 的隐式契约，固定在此防改名漂移
    func testHabitNotificationBusContract() {
        XCTAssertEqual(Notification.Name.holoHabitCheckinDidRecord.rawValue, "holo.habit.checkinDidRecord")
        XCTAssertEqual(Notification.Name.holoHabitDidCreate.rawValue, "holo.habit.didCreate")
    }

    /// 会话关联键（前后端链路打通）：beginNew 开新会话并立即可读；
    /// 事件构造时携带当前会话 ID
    func testAnalyticsSessionLifecycle() {
        XCTAssertNil(HoloAnalyticsSession.currentId)
        let first = HoloAnalyticsSession.beginNew()
        XCTAssertEqual(HoloAnalyticsSession.currentId, first)
        let second = HoloAnalyticsSession.beginNew()
        XCTAssertEqual(HoloAnalyticsSession.currentId, second)
        XCTAssertNotEqual(first, second)
    }
}
