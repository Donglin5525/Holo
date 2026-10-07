//
//  HabitDragReorderUITests.swift
//  HoloUITests
//
//  2026-10-07 今天页长按拖拽排序：
//  长按首行拖过次行 → 两行顺序互换（AX 树断言）；前两行被分组标题隔开时 skip
//  （跨组拖拽本就不支持）；断言后反向拖回保持测试幂等。
//  手感（抬起/触觉/吸附）无法 AX 断言，由真机验收清单覆盖。
//

import XCTest

final class HabitDragReorderUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.terminate() // 冷启：清掉上一用例残留的页面状态
        app.launch()
    }

    /// 首页 → 习惯模块（入口可能在滚动位/横幅下，失败回顶重试一次）
    @discardableResult
    private func enterHabitsModule() -> Bool {
        for attempt in 0..<2 {
            for label in ["习惯", "習慣"] {
                let match = app.buttons[label].firstMatch
                if match.waitForExistence(timeout: 10) {
                    match.tap()
                    if app.otherElements["habit.tab.review"].firstMatch.waitForExistence(timeout: 8)
                        || app.buttons["habit.tab.review"].firstMatch.waitForExistence(timeout: 8) {
                        return true
                    }
                }
            }
            if attempt == 0 { app.swipeDown(velocity: .fast); sleep(1) }
        }
        return false
    }

    /// 今天页习惯行（行主体，identifier 前缀 habit.rowbody.；
    /// .plain Button 在 iOS 26 树里通道不定，用 any 全类型匹配）
    private var habitRows: [XCUIElement] {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'habit.rowbody.'")
        ).allElementsBoundByIndex
    }

    private func rowName(_ row: XCUIElement) -> String {
        // label 形如「查看X今天的记录」；名字是稳定性断言键
        row.label
    }

    func test_长按拖拽_首行拖过次行_顺序互换() throws {
        XCTAssertTrue(enterHabitsModule(), "未能进入习惯模块")

        // 等列表稳定（冷启投影完成）
        let appeared = NSPredicate(format: "count >= 2")
        expectation(for: appeared, evaluatedWith: habitRows)
        waitForExpectations(timeout: 15)

        let rows = habitRows
        guard rows.count >= 2 else {
            throw XCTSkip("当前库习惯行不足 2 行，无法验证拖拽换序")
        }

        let firstName = rowName(rows[0])
        let secondName = rowName(rows[1])

        // 前两行被「本周与本月」分组标题隔开 = 跨组场景（拖拽不支持跨组），skip
        if let divider = app.staticTexts["本周与本月"].firstMatch.exists ? app.staticTexts["本周与本月"].firstMatch : nil,
           divider.isHittable {
            let firstBottom = rows[0].frame.maxY
            let secondTop = rows[1].frame.minY
            if divider.frame.minY > firstBottom, divider.frame.minY < secondTop {
                throw XCTSkip("前两行分属不同分组（每日/周月），跨组拖拽不在支持范围")
            }
        }

        // 长按 0.9s（> 激活阈值 0.45s）拖到次行中心（跨过半行触发换位）
        rows[0].press(forDuration: 0.9, thenDragTo: rows[1])
        sleep(2) // 等让位动画与落库广播刷新

        let after = habitRows
        XCTAssertGreaterThanOrEqual(after.count, 2, "拖拽后行数不应减少")
        XCTAssertEqual(rowName(after[0]), secondName, "拖拽后次行应升至首位")
        XCTAssertEqual(rowName(after[1]), firstName, "拖拽后首行应降至次位")

        // 幂等恢复：把（现在的）次行拖回首位，顺序还原；软断言不阻塞主结论
        if after.count >= 2 {
            after[1].press(forDuration: 0.9, thenDragTo: after[0])
            sleep(2)
        }
    }
}
