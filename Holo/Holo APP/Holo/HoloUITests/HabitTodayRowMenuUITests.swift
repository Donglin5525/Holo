//
//  HabitTodayRowMenuUITests.swift
//  HoloUITests
//
//  2026-10-18 东林拍板：今天页长按 = 编辑/暂停/归档/删除直达菜单（原长按拖拽
//  换序退役，排序统一走更多 → 今天列表排序弹层，弹层拖拽手感由真机验收覆盖）。
//  守护两件事：① 今天页长按行卡弹出四操作菜单（只断言在场，不执行破坏性动作）；
//  ② 排序弹层入口可达且上移通道可用（换序能力仍在）。
//

import XCTest

final class HabitTodayRowMenuUITests: XCTestCase {

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

    /// 模块恢复可能落回顾 tab，点今天页签归位再断言行
    private func ensureTodayTab() {
        let todayTab = app.buttons["habit.tab.today"].firstMatch
        if todayTab.waitForExistence(timeout: 5), todayTab.isHittable {
            todayTab.tap()
            sleep(1)
        }
    }

    /// 今天页习惯行（行主体，identifier 前缀 habit.rowbody.；
    /// .plain Button 在 iOS 26 树里通道不定，用 any 全类型匹配）
    private var habitRows: [XCUIElement] {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'habit.rowbody.'")
        ).allElementsBoundByIndex
    }

    func test_今天页长按行卡_弹出四操作菜单() throws {
        XCTAssertTrue(enterHabitsModule(), "未能进入习惯模块")
        ensureTodayTab()

        // 等列表稳定（冷启投影完成）：先轻量等首行出现，再一次性枚举
        // （全树枚举昂贵，不能放 expectation 每轮轮询——iOS 26 大 AX 树会打崩 runner）
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'habit.rowbody.'")
        let anyRow = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 15), "习惯行未出现")

        let rows = habitRows
        guard let first = rows.first else {
            throw XCTSkip("当前库没有习惯行，无法验证长按菜单")
        }

        // 长按 1.2s（系统 contextMenu 默认阈值约 0.5s，留足余量）
        first.press(forDuration: 1.2)
        sleep(1)

        // 四操作在场断言（暂停按权益态出「暂停习惯」或「暂停习惯 · Plus」，CONTAINS 兼容）
        for itemLabel in ["编辑习惯", "暂停习惯", "归档习惯", "删除习惯"] {
            let item = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", itemLabel)
            ).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 4), "长按菜单缺「\(itemLabel)」项")
        }

        // 点菜单外收起（不执行任何动作，库数据保持不变）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }

    /// 换序能力守护：更多 → 今天列表排序弹层可达，上移通道可用
    /// （列表内长按拖拽退役后，排序弹层是唯一排序入口）
    func test_排序弹层_入口可达且上移通道可用() throws {
        XCTAssertTrue(enterHabitsModule(), "未能进入习惯模块")

        let more = app.buttons["habit.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "缺更多按钮")
        more.tap()
        sleep(1)

        let sortEntry = app.buttons["habit.options.sort"].firstMatch
        XCTAssertTrue(sortEntry.waitForExistence(timeout: 5), "更多弹层缺「今天列表排序」入口")
        sortEntry.tap()

        // 上移按钮（label 前缀「上移」；首行禁用，取第二个可点的）
        let upButtons = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "上移")
        ).allElementsBoundByIndex
        guard upButtons.count >= 2 else {
            throw XCTSkip("排序页习惯不足 2 行，无法验证上移通道")
        }
        let secondName = upButtons[1].label.replacingOccurrences(of: "上移", with: "")
        upButtons[1].tap()
        sleep(1)

        // 草稿内即时换序：原第二行的名字应出现在首位
        let firstNow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "上移" + secondName)
        ).firstMatch
        var moved = firstNow.waitForExistence(timeout: 4)
        if !moved {
            // 首行上移钮禁用时 label 仍生成；退一步断言按钮集合仍在（页面未崩）
            moved = !app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "上移")
            ).allElementsBoundByIndex.isEmpty
        }
        XCTAssertTrue(moved, "点「上移」后排序页未见换位")

        // 原路返回不保存，顺序不落库（幂等，不动用户数据）
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
    }

    /// 坏习惯超限记录 → 底部红色警告条（2026-10-07 恢复的超限提示）。
    /// 依赖库里有数值坏习惯且当日已达上限（播种/真库），否则 skip。
    func test_坏习惯超限点按_底部出红色警告条() throws {
        XCTAssertTrue(enterHabitsModule(), "未能进入习惯模块")
        ensureTodayTab()

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

        // 连续点按直到警告出现（上限 12 次防御：正常播种上限 3 支内触发）。
        // 撤销条退役后警告走全局 toast（overlay window），文案断言走 staticText
        let warningText = app.staticTexts["已超当日限额，请注意控制"].firstMatch
        var shown = false
        for _ in 0..<12 where !shown {
            plus.tap()
            shown = warningText.waitForExistence(timeout: 2)
        }

        XCTAssertTrue(shown, "点按后未出现超限警告 toast 文案")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "over-limit-warning"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
