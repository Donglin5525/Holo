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
}
