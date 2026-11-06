//
//  TaskQuadrantDragUITests.swift
//  Holo
//
//  四象限拖拽与侧栏交互回归闸门（2026-11-05 真机两轮拍板随案）：
//  1. 待确认侧栏（左上筛选行拉出）长按任务拖到「留出时间」格 → 落格
//  2. 侧栏关闭时格间拖拽（重要+不紧急分段预填 → 留出时间 → 拖到优先处理）
//  3. 勾选完成 → 撤回横条出现 → 3 秒窗口后自动消失
//  4. 松手落在格间缝隙 → 任务退回待确认、不落格（矩形命中/系统取消双保险）
//  5. 格内任务拖到侧栏 → 回到待确认（两轴重置未判断）
//

import XCTest

final class TaskQuadrantDragUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: 1. 侧栏 → 右列格

    func testSidebarDragIntoScheduleTimeCell() throws {
        try enterTaskModule()
        try createTask(title: "拖拽回归任务", pickImportance: false, pickNotUrgent: false)

        // 筛选行出现「待确认 N」badge → 点击拉出左侧侧栏
        try openSidebar()
        let sidebarRow = pendingRow(title: "拖拽回归任务")
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 8), "侧栏应列出待确认任务")

        // 长按拖到「留出时间」格：目标格被遮罩盖住（isHittable=false），用坐标拖拽
        let cell = app.otherElements["quadrant.cell.scheduleTime"]
        XCTAssertTrue(cell.waitForExistence(timeout: 8), "留出时间格应存在")
        drag(from: sidebarRow, to: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

        let inCell = cell.buttons.matching(
            NSPredicate(format: "label CONTAINS '拖拽回归任务'")
        ).firstMatch
        XCTAssertTrue(inCell.waitForExistence(timeout: 8), "拖拽后任务应落入留出时间格")
        XCTAssertEqual(app.state, .runningForeground, "拖拽归位后 App 应存活")
    }

    // MARK: 2. 格间拖拽（侧栏关闭）

    func testGridRowDragBetweenCells() throws {
        try enterTaskModule()
        try createTask(title: "格间拖拽实验", pickImportance: true, pickNotUrgent: true)

        let greenCell = app.otherElements["quadrant.cell.scheduleTime"]
        XCTAssertTrue(greenCell.waitForExistence(timeout: 8))
        let row = greenCell.buttons.matching(
            NSPredicate(format: "label CONTAINS '格间拖拽实验'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "分段预填任务应直接落入留出时间格")

        let destination = app.otherElements["quadrant.cell.doFirst"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag(from: row, to: destination)

        let inRed = app.otherElements["quadrant.cell.doFirst"].buttons.matching(
            NSPredicate(format: "label CONTAINS '格间拖拽实验'")
        ).firstMatch
        XCTAssertTrue(inRed.waitForExistence(timeout: 8), "格间拖拽后任务应落入优先处理格")
    }

    // MARK: 3. 完成撤回横条

    func testCompletionUndoBannerAppearsAndFades() throws {
        try enterTaskModule()
        try createTask(title: "撤回横条实验", pickImportance: true, pickNotUrgent: true)

        let greenCell = app.otherElements["quadrant.cell.scheduleTime"]
        XCTAssertTrue(greenCell.waitForExistence(timeout: 8))
        let ring = greenCell.buttons["完成撤回横条实验"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 10), "任务应已落入留出时间格")

        ring.tap()
        let banner = app.buttons["holo.undo"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 4), "完成撤回横条应出现")

        sleep(5)
        XCTAssertFalse(banner.exists, "撤回窗口到期后横条应消失")
        XCTAssertFalse(ring.exists, "任务确认完成后应离开四象限格")
    }

    // MARK: 4. 落在格间缝隙 → 取消退回待确认

    func testGapDropCancelsAndStaysPending() throws {
        try enterTaskModule()
        try createTask(title: "缝隙取消实验", pickImportance: false, pickNotUrgent: false)
        try openSidebar()
        let sidebarRow = pendingRow(title: "缝隙取消实验")
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 8))

        // 目标点：四格中心十字缝隙（列缝 x≈中线、行缝 y≈格行分界）
        let gap = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 455.0 / 874.0))
        drag(from: sidebarRow, to: gap)

        // 任务退回待确认：侧栏行仍在、四格仍无此任务
        // （死区取消无源端回调，收窄竖条最多 5 秒兜底回弹为全宽，等待放宽）
        XCTAssertTrue(
            pendingRow(title: "缝隙取消实验").waitForExistence(timeout: 10),
            "缝隙落手应取消，任务留在待确认"
        )
        let leaked = app.otherElements["quadrant.cell.doFirst"].buttons.matching(
            NSPredicate(format: "label CONTAINS '缝隙取消实验'")
        ).firstMatch
        XCTAssertFalse(leaked.exists, "缝隙落手不应落入任何格")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: 5. 遮罩模态语义（四验拍板）：侧栏开着外层不可交互、点蒙版退出

    func testScrimBlocksInteractionAndTapCloses() throws {
        try enterTaskModule()
        try createTask(title: "遮罩拦截实验", pickImportance: true, pickNotUrgent: true)

        let greenCell = app.otherElements["quadrant.cell.scheduleTime"]
        let row = greenCell.buttons.matching(
            NSPredicate(format: "label CONTAINS '遮罩拦截实验'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "任务应先落入留出时间格")

        try openSidebar()

        // ① 侧栏开着点格内任务：触摸被遮罩吃掉 → 不进详情（无「移动到象限」详情行），
        //    该点按落在遮罩上 = 关闭侧栏（行被遮罩盖住 isHittable=false，用坐标点击）
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let detailMarker = app.buttons["移动到象限"].firstMatch
        XCTAssertFalse(detailMarker.waitForExistence(timeout: 3), "遮罩应拦截外层点击，不得进详情")
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["quadrant.sidebar"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "点在遮罩上的点击应关闭侧栏")

        // ② 重新打开，直接点遮罩空白 → 关闭
        try openSidebar()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4)).tap()
        let closedAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["quadrant.sidebar"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closedAgain], timeout: 5), .completed,
                       "点遮罩应关闭侧栏")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: 6. 侧栏开着从侧栏拖出 → 落左列格（收窄露出左列）

    func testSidebarDragToLeftCellWhileCollapsed() throws {
        try enterTaskModule()
        try createTask(title: "左列落格实验", pickImportance: false, pickNotUrgent: false)
        try openSidebar()
        let sidebarRow = pendingRow(title: "左列落格实验")
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 8))

        // 拖起时侧栏收窄，左列（优先处理）露出可达
        let destination = app.otherElements["quadrant.cell.doFirst"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag(from: sidebarRow, to: destination)

        let inLeft = app.otherElements["quadrant.cell.doFirst"].buttons.matching(
            NSPredicate(format: "label CONTAINS '左列落格实验'")
        ).firstMatch
        XCTAssertTrue(inLeft.waitForExistence(timeout: 8), "侧栏开着也应能落左列（收窄后露出）")
    }

    // MARK: - Helpers

    private func pendingRow(title: String) -> XCUIElement {
        app.otherElements["quadrant.sidebar"]
            .buttons.matching(NSPredicate(format: "label CONTAINS '\(title)'")).firstMatch
    }

    /// 长按拖拽（坐标式：终点可被覆盖/不可点击）
    private func drag(from element: XCUIElement, to destination: XCUICoordinate) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2, thenDragTo: destination)
    }

    /// 进任务模块（默认四象限视图），处理引导与系统弹窗
    private func enterTaskModule() throws {
        skipOnboardingIfNeeded()
        dismissSystemAlertsIfNeeded()
        let entry = app.buttons["任务"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "首页任务入口应出现")
        entry.tap()
        sleep(2)
        dismissSystemAlertsIfNeeded()
    }

    /// FAB 新建：填标题 + 可选分段（重要/不紧急），回车提交（onSubmit=保存）
    private func createTask(title: String, pickImportance: Bool, pickNotUrgent: Bool) throws {
        let fab = app.buttons["todoAddFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "新增 FAB 应出现")
        fab.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "新建弹层标题输入框应出现")
        field.tap()
        field.typeText(title)
        if pickImportance {
            app.buttons["重要"].firstMatch.tap()
        }
        if pickNotUrgent {
            app.buttons["不紧急"].firstMatch.tap()
        }
        field.typeText("\n")
    }

    /// 点左上筛选行拉出左侧侧栏
    private func openSidebar() throws {
        let scopeRow = app.buttons["tasks.scope"]
        XCTAssertTrue(scopeRow.waitForExistence(timeout: 8), "筛选行应存在")
        scopeRow.tap()
        XCTAssertTrue(
            app.otherElements["quadrant.sidebar"].waitForExistence(timeout: 8),
            "侧栏浮岛应滑出"
        )
    }

    /// 跳过首启全屏引导与首页新手引导气泡（ReleaseGateFiveEntryUITests 同款）
    private func skipOnboardingIfNeeded() {
        for _ in 0..<2 {
            let skip = app.buttons.matching(
                NSPredicate(format: "label == '跳过引导' OR label CONTAINS '跳过'")
            ).firstMatch
            if skip.waitForExistence(timeout: 4), skip.isHittable {
                skip.tap()
                sleep(2)
            }
            let bubble = app.buttons.matching(
                NSPredicate(format: "identifier == 'firstStepBubble.dismiss' OR label == '关闭新手引导'")
            ).firstMatch
            if bubble.exists, bubble.isHittable {
                bubble.tap()
                sleep(1)
            }
        }
    }

    /// 新装首启的系统权限弹窗（通知等）：一律拒绝
    private func dismissSystemAlertsIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["不允许", "拒绝", "Don’t Allow", "Don't Allow"] {
            let button = springboard.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) {
                button.tap()
                sleep(1)
                return
            }
        }
    }
}
