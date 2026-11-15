//
//  ProjectionFixesTests.swift
//  Holo
//
//  投影层工程挂账修复回归锁（2026-11-15）。
//
//  锁定的产品口径：
//  ① 习惯名超长句截断：用户把习惯名建成一句话，整句进 concepts 会污染主题
//     聚类（ThemeIndex 以概念为聚类 key）——超 20 字截断加省略标记，quote 不截；
//  ② 暂停习惯不投影：用户暂停习惯后，暂停期缺卡被引擎当成「中断/反复」证据
//     ——「暂停被当中断」措辞风险。Habit 实体有 isPaused 字段，取数带标记、
//     投影层整组排除；
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct ProjectionFixesTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        testHabitNameTruncation()
        testPausedHabitExcluded()
        print("ProjectionFixesTests: \(assertions) assertions passed")
    }

    static func habitInput(_ ref: String, name: String, at: Date, note: String? = nil, isPaused: Bool = false) -> HabitObservationInput {
        HabitObservationInput(recordID: ref, habitID: "habit-\(ref)", habitName: name, isNumeric: false,
                              isCompleted: true, note: note, isPaused: isPaused, occurredAt: at, updatedAt: at)
    }

    // MARK: 1. 习惯名超长句截断

    static func testHabitNameTruncation() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)

        // 超长句习惯名（一句话建习惯）：概念截到 20 字 + 省略标记，不整句进聚类
        let longName = "每天晚上十一点前放下手机去睡觉并且不再刷短视频"
        let long = HabitObservationProjector.project([habitInput("c1", name: longName, at: at)])[0]
        expect(long.concepts == ["每天晚上十一点前放下手机去睡觉并且不再刷" + "…"],
               "超长习惯名：概念=前20字+省略标记")
        expect(long.concepts[0].count == 21, "截断概念长度=20字+1个省略符")

        // quote 通道不截断：超长备注原样保留（授权门内上送、可回查）
        let longNote = "今天加班到十点才想起来打卡，路上有点堵车但坚持下来了没有找借口"
        let noted = HabitObservationProjector.project([habitInput("c2", name: "夜跑", at: at, note: longNote)])[0]
        expect(noted.quote == longNote, "quote 通道不截断（备注原样保留）")
        expect(noted.concepts == ["夜跑"], "短习惯名不受截断影响")

        // 边界：恰好 20 字不截
        let exact = String(repeating: "戒", count: 20)
        let edge = HabitObservationProjector.project([habitInput("c3", name: exact, at: at)])[0]
        expect(edge.concepts == [exact], "恰好20字不截断（无省略标记）")

        // 直接词法单测：21 字截、20 字不截
        expect(HabitObservationProjector.truncatedConcept(String(repeating: "戒", count: 21))
               == String(repeating: "戒", count: 20) + "…", "21字→20字+省略标记")
        expect(HabitObservationProjector.truncatedConcept("戒烟") == "戒烟", "短名原样返回")
    }

    // MARK: 2. 暂停习惯不投影（「暂停被当中断」措辞风险）

    static func testPausedHabitExcluded() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)

        // 混合输入：活跃习惯照投影，暂停习惯整组排除
        let mixed = [
            habitInput("p1", name: "夜跑", at: at),
            habitInput("p2", name: "夜跑", at: at.addingTimeInterval(86_400), isPaused: true),
            habitInput("p3", name: "冥想", at: at, isPaused: true),
        ]
        let out = HabitObservationProjector.project(mixed)
        expect(out.count == 1 && out[0].sourceRef == "p1",
               "暂停习惯整组不投影（只有活跃习惯的打卡进观察）")

        // 全暂停 → 空投影
        expect(HabitObservationProjector.project([habitInput("p4", name: "夜跑", at: at, isPaused: true)]).isEmpty,
               "全部暂停 → 空观察")

        // 联动（挂账本体形状）：习惯当前暂停中，90 天窗口内 15 次历史打卡整组排除
        // → 观察为空 → HabitPhaseProposer 无证据可提，不产任何「进行中/反复」理解
        //（若照投影，15 次打卡足水位，恢复前的断档还会被措辞成「期间有反复」）。
        let paused15 = (1...15).map {
            habitInput("q\($0)", name: "戒烟", at: at.addingTimeInterval(Double($0) * 86_400), isPaused: true)
        }
        let pausedObs = HabitObservationProjector.project(paused15)
        expect(pausedObs.isEmpty, "暂停习惯的 15 次历史打卡整组排除")
        let proposals = HabitPhaseProposer().propose(themeKey: "戒烟", members: pausedObs,
                                                     now: at.addingTimeInterval(16 * 86_400))
        expect(proposals.isEmpty, "暂停中习惯零提案——引擎不对暂停期产出任何理解")
    }
}
