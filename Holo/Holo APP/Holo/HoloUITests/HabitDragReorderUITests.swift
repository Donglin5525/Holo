//
//  HabitDragReorderUITests.swift
//  HoloUITests
//
//  2026-10-07 今天页长按拖拽排序（当日东林拍板去掉每日/周月分组，单一连续列表自由拖）：
//  长按首行拖过次行 → 两行顺序互换（AX 树断言）；断言后反向拖回保持测试幂等。
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

        // 等列表稳定（冷启投影完成）：先轻量等首行出现，再一次性枚举
        // （全树枚举昂贵，不能放 expectation 每轮轮询——iOS 26 大 AX 树会打崩 runner）
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'habit.rowbody.'")
        let anyRow = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 15), "习惯行未出现")

        let rows = habitRows
        guard rows.count >= 2 else {
            throw XCTSkip("当前库习惯行不足 2 行，无法验证拖拽换序")
        }

        let firstName = rowName(rows[0])
        let secondName = rowName(rows[1])

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

    /// 坏习惯超限记录 → 底部红色警告条（2026-10-07 恢复的超限提示）。
    /// 依赖库里有数值坏习惯且当日已达上限（播种/真库），否则 skip。
    func test_坏习惯超限点按_底部出红色警告条() throws {
        XCTAssertTrue(enterHabitsModule(), "未能进入习惯模块")

        // 找数值坏习惯行：行主体 label 形如「查看X今天的记录」；再取行内 + 钮
        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH 'habit.rowbody.'")
        let rows = app.descendants(matching: .any).matching(rowPredicate).allElementsBoundByIndex
        var incrementButton: XCUIElement?
        for row in rows {
            guard let uuid = row.identifier.split(separator: ".").last else { continue }
            let button = app.buttons["habit.row.\(uuid).increment"].firstMatch
            if button.exists {
                incrementButton = button
                break
            }
        }

        // 没有数值行时无法触发计数超限，skip（对数据鲁棒）
        guard let plus = incrementButton else {
            throw XCTSkip("当前库无数值型习惯行，无法验证超限警告条")
        }

        // 连续点按直到警告条出现（上限 12 次防御：正常播种上限 3 支内触发）。
        // 反馈条容器是 contain 模式（label 不聚合文本），文案断言走内部 staticText
        let warningText = app.staticTexts["已超当日限额，请注意控制"].firstMatch
        var shown = false
        for _ in 0..<12 where !shown {
            plus.tap()
            shown = warningText.waitForExistence(timeout: 2)
        }

        XCTAssertTrue(shown, "点按后未出现超限警告条文案")
        XCTAssertTrue(app.otherElements["habit.feedback.container"].firstMatch.exists
                      || app.buttons["habit.feedback.undo"].firstMatch.exists,
                      "警告条容器/撤销按钮应存在")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "over-limit-warning"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
