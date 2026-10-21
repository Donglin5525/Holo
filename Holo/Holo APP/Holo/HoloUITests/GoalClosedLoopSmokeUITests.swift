//
//  GoalClosedLoopSmokeUITests.swift
//  HoloUITests
//
//  目标闭环冒烟（最终规格 §8 E 阶段 / R02 R42 的模拟器层证据）：
//  - 开关开：个人 → 目标管理 → 目标详情原位出现「目标分析」区，页面可正常返回，无闪退；
//  - 开关关：同一详情不出现「目标分析」区（回退隐藏增量，不破坏既有区块）；
//  - 列表与详情均不出现五模块子 Tab / 记录表单（R02：只有增量区块）。
//  截图模式种子数据提供目标；不发真实模型请求（不点「分析目标」）。
//

import XCTest
import UIKit

final class GoalClosedLoopSmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(closedLoop: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "home"
        var arguments = ["GOAL_WORKSHOP_FORCE_ON"]
        if closedLoop {
            arguments.append("GOAL_CLOSED_LOOP_FORCE_ON")
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// 从个人页「目标管理」进目标列表（GoalWorkshopJourneyUITests 同款路径）
    private func openGoalList(_ app: XCUIApplication) {
        let personal = app.buttons["个人"].firstMatch
        if personal.waitForExistence(timeout: 10) {
            personal.tap()
        }
        let goalEntry = app.buttons["目标管理"].firstMatch
        if goalEntry.waitForExistence(timeout: 8) {
            goalEntry.tap()
        } else {
            let sidebarEntry = app.staticTexts["目标管理"].firstMatch
            XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 6), "找不到目标管理入口")
            sidebarEntry.tap()
        }
    }

    /// 打开第一个目标详情；列表为空时通过「手动创建」建一个（保存后自动进入详情）
    @discardableResult
    private func openFirstGoalDetail(_ app: XCUIApplication) -> Bool {
        let newButton = app.buttons["新建目标"].firstMatch
        XCTAssertTrue(newButton.waitForExistence(timeout: 8), "目标列表应可见")
        // 截图种子无目标时：新建目标 → 手动创建 → 填标题 → 创建（保存后自动进详情）
        let createItem = app.buttons["手动创建"].firstMatch
        newButton.tap()
        if createItem.waitForExistence(timeout: 4) {
            createItem.tap()
            let titleField = app.textFields["目标标题"].firstMatch
            XCTAssertTrue(titleField.waitForExistence(timeout: 8), "手动创建表单应出现")
            titleField.tap()
            titleField.typeText("闭环冒烟目标")
            app.buttons["创建目标"].firstMatch.tap()
        } else {
            // 已有目标：直接点第一张目标卡（含「待回顾」标的优先）
            let due = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "待回顾")).firstMatch
            if due.waitForExistence(timeout: 3) {
                due.tap()
            } else {
                app.buttons["新建目标"].firstMatch.tap() // 收起菜单
                let anyGoal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "闭环冒烟目标")).firstMatch
                XCTAssertTrue(anyGoal.waitForExistence(timeout: 4), "应存在可打开的目标")
                anyGoal.tap()
            }
        }
        return app.navigationBars["目标详情"].waitForExistence(timeout: 10)
    }

    func testClosedLoopOnOpensAnalysisFromReviewEntry() throws {
        let app = launchApp(closedLoop: true)
        openGoalList(app)
        XCTAssertTrue(openFirstGoalDetail(app), "应进入目标详情")

        // 分析入口收在原型的“回顾与历史”，既有报告链和功能仍保留。
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查看回顾与历史")).firstMatch
        for _ in 0..<6 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isHittable); review.tap()
        let section = app.staticTexts["目标分析"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 8), "开关开：详情应原位出现「目标分析」区")
        XCTAssertTrue(app.navigationBars["回顾与历史"].exists)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["目标详情"].waitForExistence(timeout: 5), "返回原目标详情")
        XCTAssertFalse(app.buttons["去记账"].exists, "不得出现目标页记账表单入口")

        // 返回列表不闪退
        app.navigationBars["目标详情"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["新建目标"].waitForExistence(timeout: 6), "返回列表正常")
    }

    func testClosedLoopOffHidesAnalysisSection() throws {
        let app = launchApp(closedLoop: false)
        openGoalList(app)
        XCTAssertTrue(openFirstGoalDetail(app), "应进入目标详情")
        XCTAssertFalse(app.staticTexts["目标分析"].waitForExistence(timeout: 4), "开关关：详情不出现分析区（回退=隐藏增量）")
        XCTAssertTrue(app.navigationBars["目标详情"].waitForExistence(timeout: 4), "既有详情结构不受影响")
    }
    /// 真正经过原生今天、长卷、原记录编辑后返回，验证展示与保存联动。
    func testTodaySourceRecordEditingAfterPriorEdits() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS"]
        app.launch()
        let focus = app.buttons["today-focus-goal"]
        XCTAssertTrue(focus.waitForExistence(timeout: 20), "今天应只展示重点目标摘要")
        focus.tap()
        XCTAssertTrue(app.staticTexts["进展长卷"].waitForExistence(timeout: 8))
        let reading = app.buttons["goal-source-验收·阅读"]
        for _ in 0..<5 where !reading.isHittable { app.swipeUp() }
        XCTAssertTrue(reading.isHittable)
        reading.tap()
        let totalText = app.staticTexts["habit-source-summary"]
        XCTAssertTrue(totalText.waitForExistence(timeout: 5))
        let before = try XCTUnwrap(Double(totalText.label.components(separatedBy: " ").first ?? ""))
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "habit-source-record-")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 6))
        original.tap()
        let value = app.textFields["habit-record-edit-value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap()
        let old = value.value as? String ?? ""
        let target = (Double(old) ?? 0) + 15
        value.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + String(Int(target)))
        app.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["\(Int(before + 15)) 分钟"].waitForExistence(timeout: 6), "保存后汇总应按两条原记录重算")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["\(Int(before + 15)) / 120 分钟"].waitForExistence(timeout: 6), "返回后目标应读取同一条记录的新值")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "今天到目标长卷-原记录修改后"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDailyConfirmationUsingExplicitDarkAppearance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS", "UITEST_GOAL_DARK"]
        app.launch()
        let focus = app.buttons["today-focus-goal"]
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        let today = XCTAttachment(screenshot: app.screenshot()); today.name = "今天-重点摘要"; today.lifetime = .keepAlways; add(today)
        focus.tap()
        let tea = app.buttons["goal-source-验收·奶茶"]
        for _ in 0..<5 where !tea.isHittable { app.swipeUp() }
        XCTAssertTrue(tea.isHittable); tea.tap()
        app.buttons["每日确认"].firstMatch.tap()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let day = app.buttons["habit-source-day-\(Int(yesterday.timeIntervalSince1970))"]
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        app.buttons["撤回这一天的确认"].firstMatch.tap()
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        let selector = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "请选择实际情况")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 5)); selector.tap()
        app.buttons["这一天确认未发生"].firstMatch.tap()
        app.buttons["保存确认"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "这一天确认未发生")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "尚未记录")).firstMatch.exists, "其他缺记录日期仍是未知")
        let source = XCTAttachment(screenshot: app.screenshot()); source.name = "每日确认-已确认与未知并存"; source.lifetime = .keepAlways; add(source)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 / 2 杯"].waitForExistence(timeout: 5), "确认未发生不新增数量记录")
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "目标长卷-深色"; detail.lifetime = .keepAlways; add(detail)
    }

    func testGoalScrollOnIPadPortraitAndLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅供iPad尺寸验收") }
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let focus = app.buttons["today-focus-goal"]
        XCTAssertTrue(focus.waitForExistence(timeout: 20)); focus.tap()
        XCTAssertTrue(app.staticTexts["进展长卷"].waitForExistence(timeout: 6))
        for (orientation, name) in [(UIDeviceOrientation.portrait, "iPad竖屏"), (.landscapeLeft, "iPad横屏")] {
            XCUIDevice.shared.orientation = orientation
            let reading = app.buttons["goal-source-验收·阅读"]
            XCTAssertTrue(reading.waitForExistence(timeout: 6))
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
            for _ in 0..<3 where !reading.isHittable { app.swipeUp() }
            XCTAssertTrue(reading.isHittable)
            reading.tap()
            XCTAssertTrue(app.navigationBars["验收·阅读"].waitForExistence(timeout: 6))
            let sourceShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); sourceShot.name = name + "-来源明细"; sourceShot.lifetime = .keepAlways; add(sourceShot)
            app.buttons["完成"].firstMatch.tap()
            XCTAssertTrue(reading.waitForExistence(timeout: 6))
            XCTAssertLessThanOrEqual(reading.frame.maxX, app.windows.firstMatch.frame.maxX + 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
            openPlan(app)
            XCTAssertTrue(app.textFields["goal-plan-result-target"].waitForExistence(timeout: 5))
            let planShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); planShot.name = name + "-约定编辑"; planShot.lifetime = .keepAlways; add(planShot)
            app.navigationBars["调整本目标约定"].buttons["取消"].firstMatch.tap()
            let heading = app.staticTexts["进展长卷"]
            for _ in 0..<8 where !heading.isHittable { app.swipeDown() }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testPrototypeStructurePreservesSettingsAndReview() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS", "GOAL_CLOSED_LOOP_FORCE_ON"]
        app.launch()
        let focus = app.buttons["today-focus-goal"]
        XCTAssertTrue(focus.waitForExistence(timeout: 20)); focus.tap()
        XCTAssertTrue(app.staticTexts["想达成什么"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["为此做的安排"].exists)
        let time = app.sliders["拨动长卷时间"]
        time.adjust(toNormalizedSliderPosition: 0)
        let now = app.buttons["回到当前进展"]
        XCTAssertTrue(now.waitForExistence(timeout: 5)); now.tap()
        app.navigationBars.buttons["目标设置"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["目标设置"].waitForExistence(timeout: 5))
        let edit = app.buttons["编辑目标"].firstMatch
        for _ in 0..<5 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable); edit.tap()
        XCTAssertTrue(app.navigationBars["编辑目标"].waitForExistence(timeout: 5))
        app.navigationBars["编辑目标"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["目标设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查看回顾与历史")).firstMatch
        for _ in 0..<6 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isHittable); review.tap()
        XCTAssertTrue(app.navigationBars["回顾与历史"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["目标分析"].exists)
    }

    func testNarrativeNumberOpensOriginalAccount() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS"]
        app.launch()
        let focus = app.buttons["today-focus-goal"]
        XCTAssertTrue(focus.waitForExistence(timeout: 20)); focus.tap()
        let amount = app.links.matching(NSPredicate(format: "label BEGINSWITH %@", "¥")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 6), "叙事数字应是可访问的链接")
        let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); preview.name = "按原型还原-长卷首屏"; preview.lifetime = .keepAlways; add(preview)
        amount.tap()
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 6), "应进入原账户来源弹层")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "叙事金额-原账户"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["进展长卷"].waitForExistence(timeout: 6))
    }

    func testSourceShowsGoalsUsingDifferentMetrics() throws {
        let app = launchProgressApp()
        app.buttons["today-focus-goal"].tap()
        let running = app.buttons["goal-source-验收·跑步"]
        for _ in 0..<5 where !running.isHittable { app.swipeUp() }
        XCTAssertTrue(running.isHittable); running.tap()
        XCTAssertTrue(app.staticTexts["habit-source-summary"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["habit-source-summary"].label, "2 次", "旅行目标按活动次数读取")
        let linked = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "habit-source-goal-"))
        for _ in 0..<4 where linked.count < 2 { app.swipeUp() }
        XCTAssertEqual(linked.count, 2, "同一习惯应展示全部有效关联目标")
        XCTAssertTrue(linked.matching(NSPredicate(format: "label CONTAINS %@", "3 次")).firstMatch.exists)
        XCTAssertTrue(linked.matching(NSPredicate(format: "label CONTAINS %@", "40 公里")).firstMatch.exists, "来源页应直接说明不同目标的各自要求")
        let fitness = linked.matching(NSPredicate(format: "label CONTAINS %@", "验收·跑得更远")).firstMatch
        for _ in 0..<3 where !fitness.isHittable { app.swipeUp() }
        XCTAssertTrue(fitness.isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "来源明细-共享记录与双向目标"; shot.lifetime = .keepAlways; add(shot)
        fitness.tap()
        let distance = app.buttons["goal-source-验收·跑步"]
        XCTAssertTrue(distance.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["15 / 40 公里"].exists, "另一个目标仍按里程读取同一组原记录")
    }

    func testPlanPreviewSavesAndReopensWithoutChangingFacts() throws {
        let app = launchProgressApp()
        app.buttons["today-focus-goal"].tap()
        let amount = app.links.matching(NSPredicate(format: "label BEGINSWITH %@", "¥")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 6))
        let originalFact = amount.label
        openPlan(app)
        let field = app.textFields["goal-plan-result-target"]
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        let old = field.value as? String ?? ""
        let baseline = try XCTUnwrap(Double(old.replacingOccurrences(of: ",", with: "")))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + String(Int(baseline + 100)))
        app.buttons["完成输入"].firstMatch.tap()
        let confirm = app.switches["goal-plan-confirm"]
        for _ in 0..<8 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "成果要求：")).firstMatch.exists)
        confirm.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "调整约定-采用前影响预览"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["goal-plan-save"].tap()
        XCTAssertTrue(app.navigationBars["目标详情"].waitForExistence(timeout: 6))
        XCTAssertEqual(amount.label, originalFact, "修改要求不能改变账户的实际余额")
        openPlan(app)
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        let saved = field.value as? String ?? ""
        XCTAssertEqual(Double(saved.replacingOccurrences(of: ",", with: "")), baseline + 100)
        // 恢复验收数据原要求，后续验收不依赖本用例的修改。
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: saved.count) + String(Int(baseline)))
        app.buttons["完成输入"].firstMatch.tap()
        for _ in 0..<8 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable); confirm.tap(); app.buttons["goal-plan-save"].tap()
        XCTAssertTrue(app.navigationBars["目标详情"].waitForExistence(timeout: 6))
        XCTAssertEqual(amount.label, originalFact)
    }

    func testSourceAndPlanWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let focus = app.buttons["today-focus-goal"]
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        for _ in 0..<4 where !focus.isHittable { app.swipeUp() }
        XCTAssertTrue(focus.isHittable); focus.tap()
        let reading = app.buttons["goal-source-验收·阅读"]
        for _ in 0..<12 where !reading.isHittable { app.swipeUp() }
        XCTAssertTrue(reading.isHittable); reading.tap()
        let summary = app.staticTexts["habit-source-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 6))
        XCTAssertLessThanOrEqual(summary.frame.maxX, app.windows.firstMatch.frame.maxX)
        let source = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); source.name = "来源明细-辅助大字"; source.lifetime = .keepAlways; add(source)
        app.buttons["完成"].firstMatch.tap()
        openPlan(app)
        let field = app.textFields["goal-plan-result-target"]
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
        let cancel = app.buttons["取消，沿用原要求"].firstMatch
        for _ in 0..<16 where !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.isHittable, "大字体仍能抵达页尾保存与取消")
        let plan = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); plan.name = "调整约定-辅助大字"; plan.lifetime = .keepAlways; add(plan)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["目标详情"].waitForExistence(timeout: 6))
    }

    func testReadOnlyTodayAndIndependentMetricBars() throws {
        let app = launchProgressApp()
        XCTAssertTrue(app.staticTexts["today-overview-headline"].exists)
        XCTAssertFalse(app.buttons["对 Holo 说"].exists)
        XCTAssertFalse(app.buttons["todayReliefEntryButton"].exists)
        XCTAssertFalse(app.staticTexts["更多安排与日常状态"].exists)
        XCTAssertEqual(app.textFields.count, 0)
        let today = XCTAttachment(screenshot: app.screenshot()); today.name = "只读今天-原生重点摘要"; today.lifetime = .keepAlways; add(today)
        app.buttons["today-focus-goal"].tap()
        let money = app.buttons["goal-result-source"]
        for _ in 0..<5 where !money.isHittable { app.swipeUp() }
        XCTAssertTrue(money.isHittable)
        XCTAssertTrue((money.value as? String ?? "").contains("33%"), "6000/18000 单独显示资金进度")
        money.tap()
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 6))
        app.buttons["完成"].firstMatch.tap()
        let reading = app.buttons["goal-source-验收·阅读"]
        for _ in 0..<5 where !reading.isHittable { app.swipeUp() }
        XCTAssertTrue((reading.value as? String ?? "").contains("92%"), "阅读按110/120分钟读取")
        let running = app.buttons["goal-source-验收·跑步"]
        for _ in 0..<5 where !running.isHittable { app.swipeUp() }
        XCTAssertTrue((running.value as? String ?? "").contains("67%"), "运动按2/3次读取")
        let tea = app.buttons["goal-source-验收·奶茶"]
        for _ in 0..<5 where !tea.isHittable { app.swipeUp() }
        XCTAssertTrue((tea.value as? String ?? "").contains("上限已用 50%"), "上限占用不能冒充达标完成率")
        let goal = XCTAttachment(screenshot: app.screenshot()); goal.name = "原生长卷-独立数值进度"; goal.lifetime = .keepAlways; add(goal)
    }

    func testReadOnlyNoGoalTodayOpensTaskModule() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_TODAY_RELIEF"]
        app.launch()
        XCTAssertTrue(app.staticTexts["today-overview-headline"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["today-focus-goal"].exists)
        XCTAssertFalse(app.buttons["查看任务"].exists, "无目标时不恢复旧主行动卡")
        XCTAssertFalse(app.buttons["对 Holo 说"].exists)
        XCTAssertFalse(app.staticTexts["更多安排与日常状态"].exists)
        let tasks = app.buttons["today-open-tasks"]
        for _ in 0..<4 where !tasks.isHittable { app.swipeUp() }
        XCTAssertTrue(tasks.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "只读今天-原生无目标"; shot.lifetime = .keepAlways; add(shot)
        tasks.tap()
        XCTAssertTrue(app.buttons["todoAddFAB"].waitForExistence(timeout: 6), "查看全部任务进入原任务模块")
    }

    private func launchProgressApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS"]
        app.launch()
        XCTAssertTrue(app.buttons["today-focus-goal"].waitForExistence(timeout: 20))
        return app
    }
    private func openPlan(_ app: XCUIApplication) {
        let plan = app.buttons["调整本目标约定"].firstMatch
        for _ in 0..<8 where !plan.isHittable { app.swipeUp() }
        XCTAssertTrue(plan.isHittable); plan.tap()
        XCTAssertTrue(app.navigationBars["调整本目标约定"].waitForExistence(timeout: 6))
    }

}
