//
//  ThoughtClassificationFeedbackStoreStandaloneTests.swift
//  Holo
//
//  P1 反馈事件存储 standalone 测试（项目惯例：swiftc 直接编译运行）
//  覆盖：写入重载、LRU 上限、损坏重建、接受率聚合、destroy
//
//  Run:
//  swiftc "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtTagNormalizer.swift" \
//        "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtOrganizationPresentationPolicy.swift" \
//        "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtClassificationFeedbackStore.swift" \
//        "Holo/Holo APP/Holo/HoloTests/Services/AI/ThoughtClassificationFeedbackStoreStandaloneTests.swift" \
//        -o /tmp/holo_feedback_store_tests && /tmp/holo_feedback_store_tests
//

import Foundation

@main
struct ThoughtClassificationFeedbackStoreStandaloneTests {

    static var failures: [String] = []
    static var total = 0

    static func main() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-standalone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // MARK: 写入与重载
        do {
            let store = ThoughtClassificationFeedbackStore(directory: directory)
            await store.append(makeEvent(action: .confirm, tag: "客户沟通"))
            await store.append(makeEvent(action: .rejectCurrent, tag: "复盘"))

            let reloaded = ThoughtClassificationFeedbackStore(directory: directory)
            let events = await reloaded.allEvents()
            expectEqual(events.count, 2, "持久化后重载应读到 2 条")
            expectEqual(events.first?.action, .confirm, "首条应为 confirm")
            expectEqual(events.first?.tagKey, ThoughtTagNormalizer.key("客户沟通"), "tagKey 应归一化")
        }

        // MARK: LRU 上限
        do {
            let store = ThoughtClassificationFeedbackStore(directory: directory)
            for index in 0..<(ThoughtClassificationFeedbackStore.maxEvents + 50) {
                await store.append(makeEvent(occurredAt: Date(timeIntervalSince1970: TimeInterval(index))))
            }
            let events = await store.allEvents()
            expectEqual(events.count, ThoughtClassificationFeedbackStore.maxEvents, "应裁剪到上限")
            expectEqual(
                Int(events.first?.occurredAt.timeIntervalSince1970 ?? -1),
                50,
                "最旧 50 条应被淘汰"
            )
        }

        // MARK: 损坏重建
        do {
            let store = ThoughtClassificationFeedbackStore(directory: directory)
            await store.append(makeEvent())
            try? "not-a-json{{{".data(using: .utf8)!
                .write(to: directory.appendingPathComponent("classification-feedback.json"))

            let reloaded = ThoughtClassificationFeedbackStore(directory: directory)
            let events = await reloaded.allEvents()
            expectEqual(events.count, 0, "损坏文件应从空重建")
            await reloaded.append(makeEvent(action: .retry))
            let after = await reloaded.allEvents()
            expectEqual(after.count, 1, "重建后可继续写入")
        }

        // MARK: 接受率聚合
        do {
            let store = ThoughtClassificationFeedbackStore(directory: directory)
            await store.append(makeEvent(action: .confirm))
            await store.append(makeEvent(action: .confirm))
            await store.append(makeEvent(action: .rejectCurrent))
            await store.append(makeEvent(action: .suppressGlobal))
            await store.append(makeEvent(action: .retry))  // retry 不计入接受率

            let summary = await store.acceptanceSummary()
            expectEqual(summary.confirmed, 2, "确认数应为 2")
            expectEqual(summary.rejected, 2, "拒绝数应为 2")
            expectTrue(abs(summary.acceptanceRate - 0.5) < 0.001, "接受率应为 50%")
        }

        // MARK: destroy
        do {
            let store = ThoughtClassificationFeedbackStore(directory: directory)
            await store.append(makeEvent())
            await store.destroy()
            let events = await store.allEvents()
            expectEqual(events.count, 0, "destroy 后应为空")
            expectFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("classification-feedback.json").path),
                "destroy 后文件应删除"
            )
        }

        // MARK: 汇总
        if failures.isEmpty {
            print("✅ ThoughtClassificationFeedbackStore standalone：全部 \(total) 项断言通过")
        } else {
            print("❌ 失败 \(failures.count)/\(total)：")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }

    private static func makeEvent(
        action: ThoughtClassificationFeedbackAction = .confirm,
        tag: String = "客户沟通",
        occurredAt: Date = Date()
    ) -> ThoughtClassificationFeedbackEvent {
        ThoughtClassificationFeedbackEvent(
            id: UUID(),
            thoughtId: UUID(),
            tagKey: ThoughtTagNormalizer.key(tag),
            action: action,
            wasRecognizedTag: false,
            topicConfidence: 0.8,
            semanticCandidatesUsed: false,
            occurredAt: occurredAt,
            policyVersion: ThoughtOrganizationPresentationPolicy.version
        )
    }

    private static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        total += 1
        if lhs != rhs { failures.append("\(message)：\(lhs) != \(rhs)") }
    }

    private static func expectTrue(_ value: Bool, _ message: String) {
        total += 1
        if !value { failures.append(message) }
    }

    private static func expectFalse(_ value: Bool, _ message: String) {
        expectTrue(!value, message)
    }
}
