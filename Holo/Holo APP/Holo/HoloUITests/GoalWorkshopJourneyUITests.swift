//
//  GoalWorkshopJourneyUITests.swift
//  HoloUITests
//
//  目标共创 UI 旅程（方案任务 5）：首次进入、路径选择、退出再进恢复、
//  旧入口回退（关闸不变）。用本地脚本 mock（GOAL_WORKSHOP_UI_MOCK），
//  不依赖网络与后端发版；测试数据用内存态（取消关闭不落业务库）。
//

import XCTest

final class GoalWorkshopJourneyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["GOAL_WORKSHOP_FORCE_ON", "GOAL_WORKSHOP_UI_MOCK"] + extraArguments
        app.launch()
        return app
    }

    /// 从个人页「目标管理」进入目标列表（G1 旅程同款路径）
    private func openGoalList(_ app: XCUIApplication) {
        let personal = app.buttons["个人"].firstMatch
        if personal.waitForExistence(timeout: 8) {
            personal.tap()
        }
        let goalEntry = app.buttons["目标管理"].firstMatch
        if goalEntry.waitForExistence(timeout: 8) {
            goalEntry.tap()
        } else {
            // iPad/宽屏侧栏形态
            let sidebarEntry = app.staticTexts["目标管理"].firstMatch
            XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 6), "找不到目标管理入口")
            sidebarEntry.tap()
        }
    }

    private func openWorkshopMenu(_ app: XCUIApplication) {
        let newButton = app.buttons["新建目标"].firstMatch
        XCTAssertTrue(newButton.waitForExistence(timeout: 8), "新建菜单应可见")
        newButton.tap()
    }

    /// 进共创流程；若存在上次会话残留，先「换个新的想法」另建
    private func enterWorkshopFresh(_ app: XCUIApplication) {
        openWorkshopMenu(app)
        let workshopItem = app.buttons["一起想清楚"].firstMatch
        XCTAssertTrue(workshopItem.waitForExistence(timeout: 6), "开闸后应显示「一起想清楚」入口")
        workshopItem.tap()
        let fresh = app.buttons["换个新的想法"].firstMatch
        if fresh.waitForExistence(timeout: 4) {
            fresh.tap()
        }
    }

    func testJourneyQuestionToOptionsToConfirmPage() throws {
        let app = launchApp()
        openGoalList(app)

        // 开闸时新建菜单出现「一起想清楚」（残留会话先另建）
        enterWorkshopFresh(app)

        // 脚本 mock 首轮：问题卡（一次一个问题 + 跳过）
        XCTAssertTrue(app.buttons["先跳过这个问题"].waitForExistence(timeout: 10), "应出现单个问题卡")

        // 跳过 → 路径卡（两条路径 + 代价）
        app.buttons["先跳过这个问题"].tap()
        XCTAssertTrue(app.buttons["选这条"].waitForExistence(timeout: 10), "跳过后应出现路径选择")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "选这条").count, 2, "应至少两条路径")

        // 选第二条 → 出草案 → 定义卡与确认入口
        app.buttons.matching(identifier: "选这条").element(boundBy: 1).tap()
        let generate = app.buttons["按这条路径出草案"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 8), "选路径后应可生成草案")
        generate.tap()

        XCTAssertTrue(app.staticTexts["成功标准"].waitForExistence(timeout: 10), "草案应展示成功标准")
        let confirm = app.buttons["去确认这份草案"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 6))
        confirm.tap()

        // 确认页（GoalDraftReviewView）出现；不点保存——UI 测试不写业务库
        XCTAssertTrue(app.navigationBars["确认目标计划"].waitForExistence(timeout: 8)
                      || app.buttons["保存"].firstMatch.waitForExistence(timeout: 8),
                      "应进入草案确认页")
    }

    func testExitAndResumeKeepsSession() throws {
        let app = launchApp()
        openGoalList(app)
        // 清掉历史残留后进入全新会话
        enterWorkshopFresh(app)

        // 到达问题卡后关闭（不放弃）
        XCTAssertTrue(app.buttons["先跳过这个问题"].waitForExistence(timeout: 10))
        app.buttons["关闭"].firstMatch.tap()

        // 再次进入：恢复卡出现「继续」
        openWorkshopMenu(app)
        app.buttons["一起想清楚"].firstMatch.tap()
        let resume = app.buttons["继续"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 8), "退出再进应给继续入口")
        resume.tap()

        // 继续后回到问题卡
        XCTAssertTrue(app.buttons["先跳过这个问题"].waitForExistence(timeout: 8), "继续后应恢复到原问题")

        // 放弃：清掉会话
        app.buttons["关闭"].firstMatch.tap()
        openWorkshopMenu(app)
        app.buttons["一起想清楚"].firstMatch.tap()
        let discard = app.buttons["trash"].firstMatch
        if discard.waitForExistence(timeout: 6) {
            discard.tap()
            // 放弃后：要么列表清空自动开新会话（问题卡），要么恢复卡仍在并可另建
            XCTAssertTrue(app.buttons["先跳过这个问题"].waitForExistence(timeout: 8)
                          || app.buttons["换个新的想法"].firstMatch.waitForExistence(timeout: 4),
                          "放弃后应可另建")
        }
    }

    func testFlagOffKeepsLegacyBehavior() throws {
        // 不带 FORCE_ON：开闸参数缺省（服务端未下发=关），菜单回到旧三件
        let app = XCUIApplication()
        app.launchArguments = ["GOAL_WORKSHOP_UI_MOCK"]
        app.launch()
        openGoalList(app)
        openWorkshopMenu(app)

        XCTAssertFalse(app.buttons["一起想清楚"].waitForExistence(timeout: 3), "关闸时不应显示新入口")
        XCTAssertTrue(app.buttons["让 HoloAI 规划"].firstMatch.waitForExistence(timeout: 6), "旧规划入口应保留")
        XCTAssertTrue(app.buttons["手动创建"].firstMatch.waitForExistence(timeout: 4), "手动创建应保留")
    }
}
