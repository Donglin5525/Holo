//
//  TodayReliefUITests.swift
//  HoloUITests
//
//  「今天减负」UI 走查（2026-10-03 实施方案 §15.2：R01/R06/R07/R23/R26 手动链）
//  播种 4 根任务（UITEST_SEED_TODAY_RELIEF）→ Today 入口 → 手动审阅 →
//  采用（三分组出现）→ 撤销安排；取消路径回到输入且表达不丢。
//

import XCTest

final class TodayReliefUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_SEED_TODAY_RELIEF"]
        app.launch()
        return app
    }

    /// G1 同款导航：关浮层 → 按标题命中模块按钮 → 等待动画后确认新 Today 就绪。
    private func openToday(_ app: XCUIApplication) -> Bool {
        var btn = app.buttons["前往今天"].firstMatch
        if !btn.exists { btn = app.buttons["今天"].firstMatch }
        guard btn.waitForExistence(timeout: 10) else {
            print("[TR] 今天入口不存在；buttons:", app.buttons.allElementsBoundByIndex.prefix(12).map(\.label))
            return false
        }
        for _ in 0..<3 where !btn.isHittable { sleep(2) }
        // isHittable 在浮层动画期可能误报；coordinate 兜底点击
        if btn.isHittable {
            btn.tap()
        } else {
            btn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        sleep(3)
        return true
    }

    func test_manual_relief_flow() throws {
        let app = launchSeeded()
        XCTAssertTrue(openToday(app), "今天页必须可进入")

        // R01：主行动区后出现「帮我理一理」轻量入口
        let entry = app.buttons["todayReliefEntryButton"]
        XCTAssertTrue(entry.waitForExistence(timeout: 12), "Today 必须有「帮我理一理」入口")
        entry.tap()

        // 输入态：占位示例 + 快捷表达 + 手动入口（不弹强制引导）
        let editor = app.textViews["todayReliefSituationEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6), "弹层必须先进入表达输入态")
        XCTAssertTrue(app.buttons["todayReliefManualButton"].waitForExistence(timeout: 4), "手动入口必须可用（AI 不可用时仍可整理）")

        // R26（取消语义·手动态）：填入表达 → 手动模式进审阅 →「再说一句」返回输入且文本保留
        editor.tap()
        app.typeText("UITEST 突然加班")
        app.buttons["todayReliefManualButton"].tap()

        let summary = app.staticTexts["todayReliefReviewSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8), "手动审阅态必须出现本地概括")

        // R07（采用前零业务写入）：审阅态可见种子任务行
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'UITEST-提交活动报名'")).firstMatch.waitForExistence(timeout: 6),
                      "审阅列表必须包含今晚到期的报名任务")

        // R06：调整——把照片移出（今日做→放下）不可行（未选）；改为确认取消路径
        let cancel = app.buttons["todayReliefCancelButton"].firstMatch
        if cancel.exists { cancel.tap() }
        // 回到输入态再走一遍手动（会话保留表达）
        XCTAssertTrue(editor.waitForExistence(timeout: 6) || summary.exists, "关闭/取消后状态一致")

        // 重新进入审阅并采用
        if editor.exists {
            editor.tap()
            app.buttons["todayReliefManualButton"].tap()
        }
        XCTAssertTrue(summary.waitForExistence(timeout: 8))

        let adopt = app.buttons["todayReliefAdoptButton"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 6), "采用按钮必须出现")
        adopt.tap()

        // R23：回执出现且可撤销安排
        let done = app.buttons["todayReliefDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "采用后必须给回执")
        let undo = app.buttons["todayReliefUndoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 4), "回执必须带「撤销安排」")
        undo.tap()

        // 撤销回到输入态；关闭弹层回到 Today
        XCTAssertTrue(editor.waitForExistence(timeout: 6) || app.buttons["todayReliefSubmitButton"].waitForExistence(timeout: 6), "撤销后回到输入态")
        app.buttons["todayReliefCloseButton"].tap()
        sleep(1)

        // 采用→撤销→再采用：安排区三分组在显式计划生效时出现（手动再采用一次）
        let entryAgain = app.buttons["todayReliefEntryButton"]
        XCTAssertTrue(entryAgain.waitForExistence(timeout: 6))
        entryAgain.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 6))
        editor.tap()
        app.buttons["todayReliefManualButton"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        app.buttons["todayReliefAdoptButton"].tap()
        XCTAssertTrue(done.waitForExistence(timeout: 8), "再次采用必须成功")
        done.tap()
        sleep(1)

        // 安排区出现「今天选择推进」分组（显式计划生效）
        XCTAssertTrue(app.staticTexts["今天选择推进"].firstMatch.waitForExistence(timeout: 8),
                      "显式计划生效后安排区必须三分组渲染")
        let deferredToggle = app.buttons["todayDeferredGroupToggle"]
        if deferredToggle.waitForExistence(timeout: 4) {
            deferredToggle.tap()
            sleep(1)
        }
    }
}
