import Foundation

@main
struct HoloGrowthRulesStandaloneTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = calendar.startOfDay(for: now)
        func fact(_ offset: Int, id: UUID = UUID(), manual: Bool = true) -> HoloGrowthFact {
            HoloGrowthFact(id: id, date: calendar.date(byAdding: .day, value: offset, to: day)!,
                           recordedAt: now, allowsCelebration: manual)
        }
        let duplicateID = UUID()
        let twoSameDay = HoloGrowthRules.snapshot(facts: [
            .finance: [fact(0, id: duplicateID), fact(0, id: duplicateID), fact(0)],
            .thought: [fact(0), fact(0)], .habit: [fact(0), fact(0)]
        ], now: now, calendar: calendar)
        expect(twoSameDay.recordedDays == 1, "跨模块同日只算一天")
        expect(twoSameDay.value(.finance).count == 1, "同日多笔记账不增加天数")
        expect(twoSameDay.value(.thought).count == 2, "想法按独立内容计数")
        expect(twoSameDay.value(.habit).count == 1, "同日多个习惯不增加天数")
        let thoughtDup = HoloGrowthRules.snapshot(facts: [.thought: [fact(0, id: duplicateID), fact(0, id: duplicateID)]], now: now, calendar: calendar)
        expect(thoughtDup.value(.thought).count == 1, "想法同步副本不翻倍")
        let future = HoloGrowthRules.snapshot(facts: [.finance: [fact(1), fact(-1)]], now: now, calendar: calendar)
        expect(future.value(.finance).count == 1, "未来日期不提前增加积累")
        let six = HoloGrowthRules.snapshot(facts: [.finance: (-6 ... -1).map { fact($0) }], now: now, calendar: calendar)
        let seven = HoloGrowthRules.snapshot(facts: [.finance: (-6 ... 0).map { fact($0) }], now: now, calendar: calendar)
        let oldEvents = HoloGrowthRules.reconcile([], snapshot: six)
        let newEvents = HoloGrowthRules.reconcile(oldEvents, snapshot: seven)
        expect(newEvents.filter { $0.metric == .finance }.count == 2, "七天达成仅有第一天和七天两档")
        expect(newEvents.first { $0.threshold == 7 }?.achievedAt == day, "达成日期来自排序后的业务日期")
        expect(HoloGrowthRules.celebration(previous: six, current: seven, existing: oldEvents, events: newEvents, localMetric: .finance)?.threshold == 7, "手动单日增长可轻提示")
        expect(HoloGrowthRules.celebration(previous: nil, current: seven, existing: [], events: newEvents, localMetric: .finance) == nil, "首次统计不补弹历史")
        expect(HoloGrowthRules.celebration(previous: six, current: seven, existing: oldEvents, events: newEvents, localMetric: nil) == nil, "云端同步不庆祝")
        let imported = HoloGrowthRules.snapshot(facts: [.finance: (-6 ... 0).map { fact($0, manual: false) }], now: now, calendar: calendar)
        expect(HoloGrowthRules.celebration(previous: six, current: imported, existing: oldEvents, events: newEvents, localMetric: .finance) == nil, "导入不冒充当前坚持")
        let retroactive = HoloGrowthRules.snapshot(facts: [.finance: (-7 ... -1).map { fact($0) }], now: now, calendar: calendar)
        expect(!retroactive.value(.finance).freshManualRecord, "补记过去日期不弹今天的里程碑")
        let afterDelete = HoloGrowthRules.snapshot(facts: [.finance: [fact(-6)]], now: now, calendar: calendar)
        let retained = HoloGrowthRules.reconcile(newEvents, snapshot: afterDelete)
        expect(retained.count == newEvents.count, "删除降低当前计数但保留历史")
        expect(HoloGrowthRules.reconcile(retained, snapshot: seven).count == retained.count, "删除恢复不重复颁发")
        expect(HoloGrowthRules.celebration(previous: six, current: seven, existing: newEvents, events: newEvents, localMetric: .finance) == nil, "重复跨越同档不重复提示")
        let thirty = HoloGrowthRules.snapshot(facts: [.finance: (-29 ... 0).map { fact($0) }], now: now, calendar: calendar)
        let bulkEvents = HoloGrowthRules.reconcile([], snapshot: thirty)
        expect(HoloGrowthRules.celebration(previous: six, current: thirty, existing: oldEvents, events: bulkEvents, localMetric: .finance) == nil, "批量多档增长不连弹")
        let early = HoloGrowthMilestone(metric: .finance, threshold: 7, achievedAt: day, discoveredAt: day)
        let late = HoloGrowthMilestone(metric: .finance, threshold: 7, achievedAt: nil, discoveredAt: now)
        let merged = HoloGrowthRules.reconcile([late, early, early], snapshot: seven)
        expect(merged.filter { $0.id == early.id }.count == 1, "多设备事件副本按稳定身份合并")
        expect(merged.first { $0.id == early.id }?.achievedAt == day, "未知日期不能覆盖有证据的历史日期")
        let restored = try JSONDecoder().decode(HoloGrowthMilestone.self, from: JSONEncoder().encode(early))
        expect(restored == early, "事件持久化可往返")
        let allEmpty = HoloGrowthRules.snapshot(facts: [:], now: now, calendar: calendar)
        expect(allEmpty.recordedDays == 0 && allEmpty.next == nil, "空态不推荐未使用模块")
        expect(HoloGrowthRules.reconcile([], snapshot: allEmpty).isEmpty, "清空后不会残留成就")
        expect(seven.next?.nextThreshold == 30, "下一站不重复已到达档位")
        let maxed = HoloGrowthRules.snapshot(facts: [.thought: (0..<500).map { _ in fact(0) }], now: now, calendar: calendar)
        expect(maxed.next == nil, "预设档位走完不循环推荐")
        expect(maxed.value(.thought).count == 500, "全量聚合不被页面分页截断")
        print("PASS: \(assertions) growth assertions")
    }
}
