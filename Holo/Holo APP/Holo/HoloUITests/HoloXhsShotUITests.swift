//
//  HoloXhsShotUITests.swift
//  Holo
//  小红书轮播图截图辅助：种子数据启动后导航到观点页并截屏到固定目录
//

import XCTest

final class HoloXhsShotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testShotThoughtsPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "home"
        app.launch()

        let thoughtsButton = app.buttons["观点"]
        XCTAssertTrue(thoughtsButton.waitForExistence(timeout: 60), "主页观点入口未出现")
        sleep(4)
        thoughtsButton.tap()
        sleep(5)

        let out = "/tmp/holo_xhs_shots/thoughts.png"
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: out))
        print("[XHS] saved \(out)")
    }

    /// AI 对话页：种子对话自动停在底部（月度回放卡），向上滚动到最早
    /// 的「一句话三件事」确认卡后截图。列表是 IM 风格渐进分页，
    /// 需要多轮滚动+等待加载。
    func testShotAIActionsTop() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "ai-actions"
        app.launch()

        // 等 AI 对话 sheet 出现（seeder 导航目标）
        sleep(15)

        // 阶梯滚动：滚 4/6/8 轮各截一张候选（手势滚动落点不稳定，多备选）
        var round = 0
        for stage in [4, 2, 2] {
            for _ in 0..<stage {
                round += 1
                app.swipeDown(velocity: .slow)
                sleep(1)
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                start.press(forDuration: 0.08, thenDragTo: end)
                sleep(1)
            }
            sleep(2)
            let out = "/tmp/holo_xhs_shots/ai-actions-r\(round).png"
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: out))
            print("[XHS] saved \(out)")
        }

        let out = "/tmp/holo_xhs_shots/ai-actions-top.png"
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: out))
        print("[XHS] saved \(out)")
    }

    /// 财务统计页：种子账单在 8 月，点击「上一月」切到 8 月后截图。
    func testShotFinanceStatsAugust() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "finance-stats"
        app.launch()

        // 等 seeder 的深链真正落到统计页
        let title = app.staticTexts["统计分析"]
        XCTAssertTrue(title.waitForExistence(timeout: 45), "统计页未出现")
        sleep(3)

        // 日期选择器左侧的「上一月」圆形按钮（位置在月份胶囊左边，
        // 不能碰左上角的「<」返回按钮）
        let prev = app.coordinate(withNormalizedOffset: CGVector(dx: 0.234, dy: 0.145))
        prev.tap()
        sleep(4)

        let out = "/tmp/holo_xhs_shots/finance-stats-aug.png"
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: out))
        print("[XHS] saved \(out)")
    }

    /// 今日看板：seeder 深链直达，验证渲染后截图。
    func testShotDailyKanban() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "daily-kanban"
        app.launch()

        // 等深链落到看板页
        let title = app.staticTexts["今日看板"]
        XCTAssertTrue(title.waitForExistence(timeout: 45), "今日看板未出现")
        sleep(4)

        let out = "/tmp/holo_xhs_shots/daily-kanban.png"
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: out))
        print("[XHS] saved \(out)")
    }

    // MARK: - 里程碑八月剧本（第二篇笔记）

    private func launchMilestone(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = route
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "milestone-august"
        app.launch()
        return app
    }

    private func saveShot(_ name: String) throws {
        let out = "/tmp/holo_xhs_shots/\(name).png"
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: out))
        print("[XHS] saved \(out)")
    }

    /// 对话页：月度回放卡折叠态（封面主图，与真实用户截图同款界面）。
    func testShotMilestoneChatCollapsed() throws {
        let app = launchMilestone(route: "period-replay-monthly")
        sleep(16)
        try saveShot("milestone-chat-collapsed")
    }

    /// 对话页：展开 7 张洞察后的正文与证据。先拍展开瞬间的候选 0；
    /// 随后用坐标拖拽拍候选 1（IM 列表对 swipe 的响应不稳，拖拽超时则只保留候选 0）。
    func testShotMilestoneChatExpanded() throws {
        let app = launchMilestone(route: "period-replay-monthly")
        sleep(16)

        let expand = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '展开' AND label CONTAINS '洞察'")
        ).firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 20), "展开洞察按钮未出现")
        expand.tap()
        sleep(4)
        try saveShot("milestone-chat-expanded-0")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        start.press(forDuration: 0.08, thenDragTo: end)
        sleep(2)
        try saveShot("milestone-chat-expanded-1")
    }

    /// 财务统计：深链直达 8 月（8 月支出 2.8 万、环比 +17%）。
    func testShotMilestoneFinanceStats() throws {
        let app = launchMilestone(route: "finance-stats")
        let title = app.staticTexts["统计分析"]
        XCTAssertTrue(title.waitForExistence(timeout: 45), "统计页未出现")
        sleep(4)
        try saveShot("milestone-finance-stats")
    }

    /// 想法页：从主页「想法」入口进入（模块已由「观点」改名「想法」，含
    /// 「从零到一的过程已经走完」等记录）。
    func testShotMilestoneThoughts() throws {
        let app = launchMilestone(route: "home")
        let thoughtsButton = app.buttons["想法"]
        XCTAssertTrue(thoughtsButton.waitForExistence(timeout: 60), "主页想法入口未出现")
        sleep(4)
        thoughtsButton.tap()
        sleep(5)
        try saveShot("milestone-thoughts")
    }

    /// 报告 Tab：「报告」开关在 AI 对话页内，先用深链进对话页，再切报告，
    /// 并通过「读报告」进入报告阅读版连拍一张。需在全新容器上单独跑：
    /// 每次启动都会在报告列表留档，多次启动会出现重复条目。
    func testShotMilestoneReportTab() throws {
        let app = launchMilestone(route: "period-replay-monthly")
        sleep(16)

        let reportButton = app.buttons["报告"].firstMatch
        let fallback = app.staticTexts["报告"].firstMatch
        let target = reportButton.exists ? reportButton : fallback
        XCTAssertTrue(target.waitForExistence(timeout: 30), "报告入口未出现")
        target.tap()
        sleep(5)
        try saveShot("milestone-report-tab")

        let readButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '读报告'")
        ).firstMatch
        if readButton.waitForExistence(timeout: 8) {
            readButton.tap()
            sleep(5)
            try saveShot("milestone-report-detail")
        }
    }
}
