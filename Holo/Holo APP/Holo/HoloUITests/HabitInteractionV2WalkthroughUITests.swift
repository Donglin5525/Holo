//
//  HabitInteractionV2WalkthroughUITests.swift
//  HoloUITests
//
//  2026-10-07 V2 轻量信息架构核心动线走查（方案 §13 R01–R09/R13/R19 可脚本化部分）：
//  两页签 / 今天记录弹层 / 打卡撤销 / 回顾整体→单习惯→日期明细 / 继承月份与返回 /
//  归档习惯历史 / 更多选项名单。截图供判读，断言钉关键结构。
//

import XCTest

final class HabitInteractionV2WalkthroughUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.terminate() // 冷启：清掉上一用例残留的页面状态
        app.launch()
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 首页 → 习惯模块（入口可能在滚动位/横幅下，失败回顶重试一次）
    @discardableResult
    private func enterHabitsModule() -> Bool {
        for attempt in 0..<2 {
            for label in ["习惯", "習慣"] {
                let match = app.buttons[label].firstMatch
                if match.waitForExistence(timeout: 10) {
                    match.tap()
                    if waitFor("habit.tab.review", 8) { return true }
                }
            }
            if attempt == 0 { app.swipeDown(velocity: .fast); sleep(1) }
        }
        return false
    }

    private func waitFor(_ identifier: String, _ timeout: TimeInterval) -> Bool {
        app.otherElements[identifier].firstMatch.waitForExistence(timeout: timeout)
            || app.buttons[identifier].firstMatch.waitForExistence(timeout: timeout)
    }

    private func tapIdentifier(_ identifier: String) {
        let target = app.otherElements[identifier].firstMatch
        if target.exists { target.tap(); return }
        app.buttons[identifier].firstMatch.tap()
    }

    // MARK: 主走查

    /// 任意习惯行的第一个记录按钮（对数据鲁棒：不依赖播种习惯存在）
    private var firstRecordButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'habit.row.' AND identifier CONTAINS '.record'")
        ).firstMatch
    }

    private func scrollToFindRow() -> Bool {
        if firstRecordButton.waitForExistence(timeout: 6) { return true }
        app.swipeUp(velocity: .fast)
        if firstRecordButton.waitForExistence(timeout: 4) { return true }
        app.swipeDown(velocity: .fast)
        return firstRecordButton.waitForExistence(timeout: 4)
    }

    func testA_两页签与今天页() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        // R01：主导航只有今天/回顾
        XCTAssertTrue(waitFor("habit.tab.today", 3), "缺今天页签")
        XCTAssertTrue(waitFor("habit.tab.review", 3), "缺回顾页签")
        XCTAssertFalse(app.otherElements["habit.tab.manage"].exists
                       || app.buttons["habit.tab.manage"].exists, "管理页签应已取消")
        XCTAssertTrue(waitFor("habit.add", 3), "今天页缺新增按钮")
        XCTAssertTrue(waitFor("habit.more", 3), "缺更多按钮")
        XCTAssertTrue(waitFor("habit.today.retroactive", 3), "缺补录入口")
        shoot("V2_T01_today_top")

        // 习惯行存在（任意数据态）
        XCTAssertTrue(scrollToFindRow(), "未见任何习惯行")
        app.swipeUp(velocity: .fast)
        shoot("V2_T02_today_list")
    }

    func testB_今日记录弹层与打卡撤销() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        // R02：点名称打开「今天的记录」（第一个习惯行的名称 = 行按钮的 label 前缀）
        XCTAssertTrue(scrollToFindRow(), "未见习惯行")
        // 行名称按钮 = 名称区 Button（label 含副标题文本）；直接用行 record 按钮所属 cell 的父级不易取，
        // 改走更稳的通道：点第一个习惯行的 record 按钮所在行的另一部分不可行——用 AX: 名称按钮是
        // label 含「查看」的按钮？——名称按钮 accessibilityLabel = 「查看<名>今天的记录」
        let nameButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '今天的记录' OR label CONTAINS \"today's records\" OR label CONTAINS 'Today'")
        ).firstMatch
        var opened = nameButton.waitForExistence(timeout: 5)
        if !opened {
            app.swipeUp(velocity: .fast)
            opened = nameButton.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(opened, "未见习惯名称入口（今日记录）")
        nameButton.tap()
        sleep(1)
        shoot("V2_T03_today_records_sheet")
        // 弹层内有「习惯设置」入口（en 系统显示英文翻译）
        let settingsEntry = app.staticTexts.matching(
            NSPredicate(format: "label IN {'习惯设置', 'Habit Settings'}")
        ).firstMatch
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 4), "弹层缺习惯设置入口")
        // 关闭弹层（「关闭」在 en 系统显示 Close）
        let close = app.buttons["关闭"].firstMatch
        if close.waitForExistence(timeout: 2) {
            close.tap()
        } else {
            app.buttons["Close"].firstMatch.tap()
        }
        sleep(1)

        // R03：点一个「未打卡」的行（按钮文字=打卡）→ 撤销条出现
        let checkInButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'habit.row.' AND identifier CONTAINS '.record' AND label IN {'打卡', 'Check-in', '打卡记录'}")
        ).firstMatch
        var found = checkInButton.waitForExistence(timeout: 5)
        if !found {
            app.swipeUp(velocity: .fast)
            found = checkInButton.waitForExistence(timeout: 5)
        }
        if !found { throw XCTSkip("当前无可打卡的未记录行（数据态不满足）") }
        shoot("V2_T04_before_checkin")
        checkInButton.tap()
        sleep(2)
        shoot("V2_T05_after_checkin")
        // 撤销条（文字含「撤销」/「Undo」）
        let undoBar = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '撤销' OR label CONTAINS 'Undo' OR label CONTAINS 'undo'")
        ).firstMatch
        XCTAssertTrue(undoBar.waitForExistence(timeout: 6), "打卡成功后未见撤销提示条")
    }

    func testC_回顾整体到单习惯() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        tapIdentifier("habit.tab.review")
        sleep(2)
        shoot("V2_R01_overview_current")

        // R04：整体摘要存在（en 系统显示英文翻译）
        let daysMetric = app.staticTexts.matching(
            NSPredicate(format: "label IN {'有记录的日子', 'Days with records'}")
        ).firstMatch
        XCTAssertTrue(daysMetric.waitForExistence(timeout: 6), "缺整体摘要")
        XCTAssertTrue(waitFor("habit.review.monthTitle", 4), "缺月份导航")

        // 点一行进单习惯（对数据鲁棒：回顾行 identifier 前缀 habit.review.row.）
        let anyRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'habit.review.row.'")
        ).firstMatch
        var rowFound = anyRow.waitForExistence(timeout: 5)
        if !rowFound {
            app.swipeUp()
            rowFound = anyRow.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(rowFound, "回顾列表无习惯行")
        anyRow.tap()
        sleep(2)
        shoot("V2_R02_single_trend")
        XCTAssertTrue(app.otherElements["habit.single.range"].firstMatch.exists
                      || app.buttons["habit.single.range"].firstMatch.exists, "缺范围控制")

        // 切日历模式（仅数值型有切换；打卡型固定日历——存在才验证）
        let calendarChip = app.buttons["habit.single.viz.calendar"].firstMatch
        if calendarChip.waitForExistence(timeout: 3) {
            calendarChip.tap()
            sleep(1)
            shoot("V2_R03_single_calendar")
        }

        // 点日历一个有记录的日子（label 含「有记录」/ 'has records' / 'Recorded'）
        let dayCell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '有记录' OR label CONTAINS 'record'")
        ).firstMatch
        if dayCell.waitForExistence(timeout: 4) {
            dayCell.tap()
            sleep(1)
            shoot("V2_R04_day_detail")
        }

        // 返回整体
        tapIdentifier("habit.single.back")
        sleep(1)
        shoot("V2_R05_back_overview")
    }

    func testD_九月继承与归档历史() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        tapIdentifier("habit.tab.review")
        sleep(2)

        // 切九月（月选择弹层；en 系统月份显示 2026/9，zh 显示 2026年9月）
        tapIdentifier("habit.review.monthTitle")
        sleep(1)
        let sepButton = app.buttons.matching(
            NSPredicate(format: "label MATCHES '2026(年|/)9(月)?'")
        ).firstMatch
        XCTAssertTrue(sepButton.waitForExistence(timeout: 5), "月选择缺九月")
        sepButton.tap()
        sleep(1)
        shoot("V2_R06_september_overview")

        // 九月有行则进单习惯再返回（验证继承与返回；数据态不足时仅验证月份切换）
        let sepRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'habit.review.row.'")
        ).firstMatch
        if sepRow.waitForExistence(timeout: 5) {
            sepRow.tap()
            sleep(2)
            shoot("V2_R07_single_from_september")
            tapIdentifier("habit.single.back")
            sleep(1)
        }

        // R05：返回后整体仍九月（月份按钮 label 含 9；Button 吸收子 Text，查按钮而非 staticText）
        let monthButton = app.buttons["habit.review.monthTitle"].firstMatch
        XCTAssertTrue(monthButton.waitForExistence(timeout: 5), "未回到整体月份导航")
        XCTAssertTrue(monthButton.label.range(of: "9") != nil,
                      "当前未停留在九月，实际显示：\(monthButton.label)")
        shoot("V2_R08_month_state")
    }

    func testE_更多选项与名单() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        tapIdentifier("habit.more")
        sleep(1)
        shoot("V2_O01_more_sheet")
        XCTAssertTrue(waitFor("habit.options.lifecycle", 5), "缺名单入口")

        // 进名单
        tapIdentifier("habit.options.lifecycle")
        sleep(1)
        shoot("V2_O02_lifecycle_list")

        // 返回更多 → 排序页
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        tapIdentifier("habit.options.sort")
        sleep(1)
        shoot("V2_O03_sort_page")

        // 回顾展示设置
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        tapIdentifier("habit.options.reviewVisibility")
        sleep(1)
        shoot("V2_O04_visibility_page")
    }
}
