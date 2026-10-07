import Foundation

/// 验证动画不会误报保存、重复播放或重放已经撤回的操作。
@main
struct HoloMotionEventLedgerStandaloneTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = HoloMotionSubject(domain: .finance, id: UUID())
        let operation = UUID()
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError(message) }
        }
        func event(_ phase: HoloMotionEvent.Phase, id: UUID = operation,
                   target: HoloMotionSubject = subject, date: Date = now) -> HoloMotionEvent {
            HoloMotionEvent(operationID: id, subject: target, phase: phase, occurredAt: date)
        }
        var ledger = HoloMotionEventLedger()
        ledger.record(event(.pending))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "待确认不能播放保存成功")
        ledger.record(event(.confirmed))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: false) == nil, "被弹层遮住时不能提前消费")
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true)?.operationID == operation, "回到列表后应播放本次保存")
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "两个列表容器不能重复庆祝同一操作")
        ledger.record(event(.confirmed))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "重复成功通知不能补播")

        let failed = UUID()
        ledger.record(event(.pending, id: failed))
        ledger.record(event(.failed, id: failed))
        ledger.record(event(.confirmed, id: failed))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "失败后的迟到成功通知不能误庆祝")
        let undone = UUID()
        ledger.record(event(.confirmed, id: undone))
        ledger.record(event(.undone, id: undone))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "撤回要取消未消费的成功反馈")

        ledger.record(event(.confirmed, id: UUID()))
        expect(ledger.consume(subject, now: now, enabled: false, isVisible: true) == nil, "关闭开关应抑制效果")
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "重新开启不能补播")
        ledger.record(event(.confirmed, id: UUID()))
        expect(ledger.consume(subject, now: now.addingTimeInterval(11), enabled: true, isVisible: true) == nil, "返回页面不能播放过期记录")

        let other = HoloMotionSubject(domain: .thought, id: subject.id)
        ledger.record(event(.confirmed, id: UUID(), target: other))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "相同ID的不同模块不能串事件")
        expect(ledger.consume(other, now: now, enabled: true, isVisible: true) != nil, "想法应收到自己的事件")
        ledger.record(event(.confirmed, id: UUID()))
        ledger.discard(subject)
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "取消记录应立即停止在途反馈")

        let oldOperation = UUID()
        let latestOperation = UUID()
        ledger.record(event(.pending, id: oldOperation))
        ledger.record(event(.confirmed, id: latestOperation))
        ledger.record(event(.undone, id: oldOperation))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true)?.operationID == latestOperation, "旧操作撤回不能取消新操作的反馈")

        var policy = HoloHabitMotionDayPolicy()
        let habit = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        expect(policy.claim(habit, at: now, calendar: calendar), "首次有效记录应回应")
        expect(!policy.claim(habit, at: now.addingTimeInterval(1), calendar: calendar), "当天计数或撤回再勾选不能重复庆祝")
        expect(policy.claim(UUID(), at: now, calendar: calendar), "其他习惯有独立的首次反馈")
        expect(policy.claim(habit, at: now.addingTimeInterval(86400), calendar: calendar), "下一天可以再次回应")
        var restoredPolicy = try JSONDecoder().decode(HoloHabitMotionDayPolicy.self, from: JSONEncoder().encode(policy))
        expect(!restoredPolicy.claim(habit, at: now.addingTimeInterval(86401), calendar: calendar), "重启后撤销再勾选不能重复庆祝")
        expect(restoredPolicy.claim(habit, at: now.addingTimeInterval(172800), calendar: calendar), "重启后下一天仍可正常回应")

        let backgroundOperation = UUID()
        ledger.record(event(.confirmed, id: backgroundOperation))
        ledger.record(event(.confirmed, id: UUID(), target: other))
        ledger.discardAll()
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "后台应清理尚未挂载的记账行")
        expect(ledger.consume(other, now: now, enabled: true, isVisible: true) == nil, "后台应同时清理其他模块")
        ledger.record(event(.confirmed, id: backgroundOperation))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) == nil, "丢弃后仍须保留操作去重")
        ledger.record(event(.confirmed, id: UUID()))
        expect(ledger.consume(subject, now: now, enabled: true, isVisible: true) != nil, "回到前台的新操作可正常回应")

        var replay = HoloReplayMotionLedger()
        let request = UUID()
        expect(replay.claim(request, item: 2, requestedAt: now, now: now), "主动打开一天应展开")
        expect(!replay.claim(request, item: 2, requestedAt: now, now: now), "同一时段刷新不得重播")
        expect(replay.claim(request, item: 5, requestedAt: now, now: now), "相邻时段独立入场")
        expect(!replay.claim(request, item: 6, requestedAt: now, now: now.addingTimeInterval(2)), "懒加载新时段不能迟到入场")
        replay.cancel(request)
        expect(!replay.claim(request, item: 1, requestedAt: now, now: now), "遮挡、后台或筛选取消后不得补播")
        expect(replay.claim(UUID(), item: 2, requestedAt: now, now: now), "主动切换日期可以重新展开")
        expect(!replay.claim(UUID(), item: 2, requestedAt: now, now: now.addingTimeInterval(-1)), "时间回拨不能产生错误入场")
        let defaults = UserDefaults(suiteName: "holo.motion.tests.\(UUID().uuidString)")!
        let key = "holo.motion.testEnabled"
        expect(HoloMotionPreferencePolicy.isEnabled(key, defaults: defaults), "缺省应开启动效")
        defaults.setVolatileDomain([key: false], forName: UserDefaults.argumentDomain)
        expect(!HoloMotionPreferencePolicy.isEnabled(key, defaults: defaults), "Bool false 应关闭")
        defaults.setVolatileDomain([key: true], forName: UserDefaults.argumentDomain)
        expect(HoloMotionPreferencePolicy.isEnabled(key, defaults: defaults), "Bool true 应开启")
        defaults.setVolatileDomain([key: "NO"], forName: UserDefaults.argumentDomain)
        expect(!HoloMotionPreferencePolicy.isEnabled(key, defaults: defaults), "NO 字符串启动参数应关闭")
        defaults.setVolatileDomain([key: "YES"], forName: UserDefaults.argumentDomain)
        expect(HoloMotionPreferencePolicy.isEnabled(key, defaults: defaults), "YES 字符串启动参数应开启")
        print("PASS: \(checks) 个动效事件与跨日断言")
    }
}
