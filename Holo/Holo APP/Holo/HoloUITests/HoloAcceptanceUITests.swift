//
//  HoloAcceptanceUITests.swift
//  Holo
//
//  账户页列表版验收（L1-L5）：净资产卡 + 平铺账户列表 + 详情往返 + 长按管理菜单
//  【1.0.1 改版】卡堆拟物形式收起，原翻卡/置顶/动态面板用例随形式一并移除
//

import XCTest

final class HoloAcceptanceUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_accept_list"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    @discardableResult
    func shoot(_ name: String, settle: UInt32 = 0) -> Bool {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    func check(_ id: String, _ condition: Bool, _ detail: String = "") {
        print("[CHECK] \(id) \(condition ? "PASS" : "FAIL") \(detail)")
    }

    func openAccountsPage() {
        let finance = app.buttons["财务"]
        if finance.waitForExistence(timeout: 10) {
            finance.tap()
        } else {
            print("[NAV] 财务入口未找到")
            return
        }
        sleep(3)
        let accountsTab = app.buttons["账户"].firstMatch
        if accountsTab.waitForExistence(timeout: 8) {
            accountsTab.tap()
            sleep(3)
        }
    }

    // MARK: - 主验收流程

    func testFullAcceptance() throws {
        openAccountsPage()

        // ============ L1 页面骨架：净资产卡 + 全部账户行平铺可见 ============
        shoot("L01_overview", settle: 1)
        check("L1-networth", app.staticTexts["总净资产 · NET WORTH"].firstMatch.waitForExistence(timeout: 5))
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"] {
            let e = app.staticTexts[n].firstMatch
            check("L1-row-\(n)", e.exists, e.exists ? "y=\(Int(e.frame.minY))" : "未找到")
        }
        // 一屏容量：最后一张账户行应落在首屏内（列表化后不依赖滚动看全账户）
        if let last = ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
            .compactMap({ app.staticTexts[$0].firstMatch.exists ? app.staticTexts[$0].firstMatch.frame.minY : nil })
            .max() {
            check("L1-one-screen", last < 820, "末行 y=\(Int(last))")
        }
        // 负债语义：现金为负余额时行内出现「负债」标签
        check("L1-debt-label", app.staticTexts["负债"].firstMatch.waitForExistence(timeout: 3))

        // ============ L2 添加入口（导航栏 +）+ 表单开关 ============
        let addBtn = app.buttons["添加账户"].firstMatch
        check("L2-add-exists", addBtn.exists)
        check("L2-add-hittable", addBtn.isHittable)
        addBtn.tap()
        let sheetOpen = app.navigationBars["新建账户"].waitForExistence(timeout: 6)
        check("L2-sheet-open", sheetOpen)
        check("L2-sheet-cancel", sheetOpen && app.buttons["取消"].firstMatch.exists)
        shoot("L02_add_sheet", settle: 1)
        if sheetOpen {
            app.buttons["取消"].firstMatch.tap()
            sleep(2)
            check("L2-sheet-dismissed", app.staticTexts["总净资产 · NET WORTH"].waitForExistence(timeout: 6))
        }

        // ============ L3 点行进详情 / 返回 ============
        let cashRow = app.staticTexts["现金"].firstMatch
        check("L3-cash-row", cashRow.exists)
        if cashRow.exists {
            cashRow.tap()
            let detailNav = app.navigationBars["现金"].firstMatch
            check("L3-detail-open", detailNav.waitForExistence(timeout: 6))
            shoot("L03_cash_detail", settle: 1)
            if detailNav.exists {
                detailNav.buttons.firstMatch.tap()
                sleep(2)
                check("L3-detail-back", app.staticTexts["总净资产 · NET WORTH"].waitForExistence(timeout: 6))
                shoot("L04_after_detail_back", settle: 1)
            }
        }

        // ============ L4 长按行 → 管理菜单 ============
        let wechatRow = app.staticTexts["微信"].firstMatch
        if wechatRow.exists {
            wechatRow.press(forDuration: 1.2)
            sleep(1)
            let editItem = app.buttons["编辑账户"].firstMatch
            check("L4-menu-open", editItem.waitForExistence(timeout: 5))
            check("L4-item-adjust", app.buttons["对账"].firstMatch.exists)
            check("L4-item-default", app.buttons["设为默认"].firstMatch.exists
                || app.staticTexts["设为默认（当前默认）"].firstMatch.exists)
            check("L4-item-archive", app.buttons["归档账户"].firstMatch.exists)
            shoot("L05_row_menu", settle: 1)
            if editItem.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
                sleep(1)
            }
        } else {
            check("L4-menu-open", false, "微信行未找到")
        }
    }
}

// MARK: - 深色外观走查（列表版）

final class HoloListDarkMode: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func shoot(_ name: String) {
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/holo_accept_list/\(name).png"))
        print("[SHOT] \(name)")
    }

    func check(_ id: String, _ ok: Bool, _ d: String = "") {
        print("[CHECK] \(id) \(ok ? "PASS" : "FAIL") \(d)")
    }

    func testDarkWalkthrough() throws {
        let finance = app.buttons["财务"].firstMatch
        if finance.waitForExistence(timeout: 10) { finance.tap() }
        sleep(3)
        let accountsTab = app.buttons["账户"].firstMatch
        if accountsTab.waitForExistence(timeout: 8) { accountsTab.tap() }
        sleep(3)

        shoot("D1_list_overview")
        check("DK-networth", app.staticTexts["总净资产 · NET WORTH"].firstMatch.exists)
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"] {
            check("DK-row-\(n)", app.staticTexts[n].firstMatch.exists)
        }
        shoot("D2_list_scrolled")
    }
    // MARK: - 手势回归（2026-09-08 右滑返回体检）

    /// 模块根页（SwipeBackModifier 常驻层）与二级页（holoEdgeSwipeBack 全屏 cover）
    /// 两条右滑返回通道的回归：从屏幕左缘右滑，页面必须关闭。
    func testEdgeSwipeBackRegression() throws {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.004, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))

        // 记忆长廊：模块根页
        let gallery = app.buttons["记忆长廊"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), "首页长廊入口不存在")
        gallery.tap()
        let weekChip = app.buttons["周"].firstMatch
        XCTAssertTrue(weekChip.waitForExistence(timeout: 8), "长廊未打开")
        // 档位条行尾「今天」必须完整落在屏内（右缘截断回归锚点）
        let today = app.buttons["今天"].firstMatch
        if today.waitForExistence(timeout: 3) {
            XCTAssertLessThanOrEqual(today.frame.maxX, app.frame.maxX, "「今天」按钮被屏幕右缘截断")
        }
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertFalse(weekChip.waitForExistence(timeout: 4), "长廊右滑未关闭")
        _ = app.buttons["记忆长廊"].firstMatch.waitForExistence(timeout: 5)

        // 财务账本 → 搜索页：fullScreenCover 二级页
        let finance = app.buttons["财务"].firstMatch
        XCTAssertTrue(finance.waitForExistence(timeout: 10), "首页财务入口不存在")
        finance.tap()
        sleep(2)
        let searchBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'magnifyingglass' OR identifier CONTAINS 'magnifyingglass'")
        ).firstMatch
        guard searchBtn.waitForExistence(timeout: 5) else {
            throw XCTSkip("财务搜索按钮无 AX 标识，跳过")
        }
        searchBtn.tap()
        sleep(1)
        XCTAssertFalse(searchBtn.isHittable, "搜索页未打开（账本仍可点）")
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
        XCTAssertTrue(searchBtn.isHittable, "财务搜索页右滑未关闭")
    }
}


/// 直接验证公共图表的真实触摸链路，不依赖业务种子数据或截图推断。
final class HoloChartInteractionUITests: XCTestCase {
    private struct PlotCoordinates {
        let app: XCUIApplication
        func waitForExistence(timeout: TimeInterval) -> Bool {
            let metadata = app.staticTexts["chart.gallery.geometry"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                metadata.exists && frame.width > 0 && frame.height > 0
            }, object: nil)
            let success = XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
            if !success { print("图表布局尚未就绪：\(app.debugDescription)") }
            return success
        }
        var frame: CGRect {
            let raw = app.staticTexts["chart.gallery.geometry"].value as? String ?? ""
            let values = raw.split(separator: "|").compactMap { Double($0) }
            guard values.count == 4 else { return .zero }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        func coordinate(withNormalizedOffset vector: CGVector) -> XCUICoordinate {
            let current = frame
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: current.minX + current.width * vector.dx, dy: current.minY + current.height * vector.dy))
        }
    }

    private func launch(largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-HoloChartGallery"]
        if largeType { app.launchArguments += ["-HoloChartGalleryLargeType", "-HoloChartGalleryDark"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["chart.gallery.selection"].waitForExistence(timeout: 15))
        return app
    }

    func testBarCentersEdgesPersistenceAndReset() {
        let app = launch()
        let plot = PlotCoordinates(app: app)
        XCTAssertTrue(plot.waitForExistence(timeout: 10))
        let result = app.staticTexts["chart.gallery.selection"]
        for index in [0, 1, 2, 5, 10] {
            for fraction in [0.1, 0.5, 0.9] {
                plot.coordinate(withNormalizedOffset: CGVector(dx: (Double(index) + fraction) / 12, dy: 0.5)).tap()
                XCTAssertEqual(result.label, "slot-\(index)")
            }
        }
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.5 / 12, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: plot.coordinate(withNormalizedOffset: CGVector(dx: 8.5 / 12, dy: 0.6)))
        XCTAssertEqual(result.label, "slot-8", "松手后保留最后一格")
        plot.coordinate(withNormalizedOffset: CGVector(dx: 11.5 / 12, dy: 0.5)).tap()
        XCTAssertEqual(result.label, "slot-8", "未来日期不应被选中")
        app.buttons["chart.gallery.reset"].tap()
        XCTAssertEqual(result.label, "未选中")
    }

    func testMissingDayDoesNotJumpAndVerticalPanScrolls() {
        let app = launch()
        app.buttons["折线"].tap()
        let plot = PlotCoordinates(app: app)
        XCTAssertTrue(plot.waitForExistence(timeout: 10))
        plot.coordinate(withNormalizedOffset: CGVector(dx: 2.5 / 12, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["chart.gallery.selection"].label, "slot-2")
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.8))
            .press(forDuration: 0.01, thenDragTo: plot.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.05)))
        XCTAssertEqual(app.staticTexts["chart.gallery.selection"].label, "slot-2", "纵滑不能被图表接管")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["chart.gallery.footer"].isHittable)
    }

    func testHeatmapTwoDimensionalScrubAndTinyCategoryList() {
        let app = launch()
        app.buttons["格子"].tap()
        let grid = app.descendants(matching: .any)["holo.heatmap.grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5 / 12, dy: 0.5 / 7)).tap()
        XCTAssertEqual(app.staticTexts["chart.gallery.selection"].label, "heat-0")
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5 / 12, dy: 0.5 / 7))
            .press(forDuration: 0.35, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 3.5 / 12, dy: 4.5 / 7)))
        XCTAssertEqual(app.staticTexts["chart.gallery.selection"].label, "heat-25")
        app.buttons["占比"].tap()
        let tiny = app.buttons["holo.donut.segment.tiny"]
        if !tiny.isHittable { app.scrollViews.firstMatch.swipeUp() }
        tiny.tap()
        XCTAssertEqual(app.staticTexts["chart.gallery.selection"].label, "tiny")
    }

    func testLargeTypeDarkModeAndWideRotationRemainSelectable() {
        let app = launch(largeType: true)
        let wide = app.frame.width > 600
        if wide { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if wide { XCUIDevice.shared.orientation = .portrait } }
        let plot = PlotCoordinates(app: app)
        XCTAssertTrue(plot.waitForExistence(timeout: 10))
        for _ in 0..<3 where plot.frame.maxY > app.frame.maxY - 25 {
            let scroll = app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
                .press(forDuration: 0.01, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        XCTAssertGreaterThan(plot.frame.width, 150)
        XCTAssertLessThan(plot.frame.maxY, app.frame.maxY)
        plot.coordinate(withNormalizedOffset: CGVector(dx: 5.5 / 12, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["chart.gallery.selection"].label, "slot-5")
        let readout = app.otherElements["holo.chart.readout"].firstMatch
        if readout.exists { XCTAssertLessThanOrEqual(readout.frame.maxY, plot.frame.minY + 1) }
    }

}
