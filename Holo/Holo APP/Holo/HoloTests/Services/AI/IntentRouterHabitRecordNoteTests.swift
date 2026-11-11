//
//  IntentRouterHabitRecordNoteTests.swift
//  Holo
//
//  习惯打卡备注提取收紧规则单测（2026-11-11）：
//  ①纯指令清洗后为空不存（原行为）②单数字段短句照存（原行为不回归）
//  ③复合多意图句（≥2 处独立数字段）不存（烤肉 298 + 停车费 20 实报事故）
//  ④单数字段但剩余文字 >30 字不存 ⑤单数字段且 ≤30 字照存。
//

import XCTest
@testable import Holo

@MainActor
final class IntentRouterHabitRecordNoteTests: XCTestCase {

    /// ①纯指令句「打卡跑步」：去掉习惯名与指令词后为空 → 不存（原行为）
    func testPureCommandCleansToNil() {
        XCTAssertNil(IntentRouter.habitRecordNote(
            originalInput: "打卡跑步",
            habitNames: ["跑步"],
            removableTokens: []
        ))
    }

    /// ②「跑步5公里状态不错」：单个数字段 → 照存「5公里状态不错」（原行为不回归）
    func testSingleDigitRunStillStored() {
        XCTAssertEqual(
            IntentRouter.habitRecordNote(
                originalInput: "跑步5公里状态不错",
                habitNames: ["跑步"],
                removableTokens: []
            ),
            "5公里状态不错"
        )
    }

    /// ③实报复合句：既有「烤肉 298」又有「停车费 20」（两处独立数字段）→ 整段不存
    func testCompoundSentenceWithTwoDigitRunsYieldsNil() {
        let incident = "昨晚吃烤肉 298，停车费 20，记得提醒我……维生素的习惯忘记今天补上"
        XCTAssertNil(IntentRouter.habitRecordNote(
            originalInput: incident,
            habitNames: ["维生素"],
            removableTokens: []
        ))
    }

    /// ④单数字段但剩余文字超 30 字 → 不存（备注是单句上下文，不是段落）
    func testSingleDigitOverlongRemainingYieldsNil() {
        let overlong = "吃了1个苹果还有一种很贵的进口车厘子顺便又喝了一杯拿铁咖啡晚上还去健身房练了两个小时的力量"
        XCTAssertNil(IntentRouter.habitRecordNote(
            originalInput: overlong,
            habitNames: ["健身"],
            removableTokens: []
        ))
    }

    /// ⑤单数字段且剩余 ≤30 字 → 照存
    func testSingleDigitShortNoteStored() {
        XCTAssertEqual(
            IntentRouter.habitRecordNote(
                originalInput: "维生素吃了2颗有点感冒前兆",
                habitNames: ["维生素"],
                removableTokens: []
            ),
            "吃了2颗有点感冒前兆"
        )
    }
}
