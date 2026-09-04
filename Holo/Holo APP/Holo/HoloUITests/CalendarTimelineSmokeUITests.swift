//
//  CalendarTimelineSmokeUITests.swift
//  Holo
//
//  系统日历三期「时间轴」冒烟：长廊 → 轴档渲染不崩溃 + 关键截图
//  通道：XCUITest（idb 不可用环境的 UI 走查替代）
//

import XCTest

final class CalendarTimelineSmokeUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_timeline_smoke"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func shoot(_ name: String, settle: UInt32 = 1) -> Bool {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    func test_长廊时间轴档冒烟() throws {
        // 1. 首页正常启动（三期改动后不崩）
        shoot("T01_home", settle: 2)

        // 2. 进记忆长廊（底部导航「记忆长廊」/「记忆」）
        let memory = app.buttons["记忆长廊"].firstMatch
        let memoryAlt = app.buttons["记忆"].firstMatch
        if memory.waitForExistence(timeout: 6) {
            memory.tap()
        } else if memoryAlt.waitForExistence(timeout: 4) {
            memoryAlt.tap()
        } else {
            print("[NAV] 长廊入口未找到")
            shoot("T02_no_entry")
            return
        }
        sleep(3)
        shoot("T02_gallery_default")

        // 3. 切到「轴」档
        let timeline = app.buttons["轴"].firstMatch
        if timeline.waitForExistence(timeout: 6) {
            timeline.tap()
            sleep(2)
            shoot("T03_timeline")

            // 4. 轴档翻一天（右箭头回看昨天——回看限制下右箭头指向过去）
            shoot("T04_timeline_settle", settle: 1)
        } else {
            print("[NAV] 「轴」档未找到")
            shoot("T03_no_timeline_button")
        }
    }

    func test_任务页引导条冒烟() throws {
        shoot("T10_home_task_entry", settle: 2)
        // 任务入口（五角星/功能入口），label 可能是「任务」
        let task = app.buttons["任务"].firstMatch
        if task.waitForExistence(timeout: 6) {
            task.tap()
            sleep(3)
            shoot("T11_task_page")
        } else {
            print("[NAV] 任务入口未找到")
        }
    }
}

// MARK: - iPad 适配审计（2026-09-04 iPad 专项，全页面竖横双拍）
final class HoloIPadAuditUITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[IPADAUDIT] shot \(name)")
    }

    private func tapText(_ app: XCUIApplication, _ label: String) -> Bool {
        let el = app.staticTexts[label].firstMatch
        guard el.waitForExistence(timeout: 8) else {
            print("[IPADAUDIT] missing text \(label)")
            return false
        }
        el.tap()
        return true
    }

    private func back(_ app: XCUIApplication) {
        let b = app.navigationBars.buttons.firstMatch
        if b.exists { b.tap(); sleep(2) }
    }

    func testIPadPortraitAllPages() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        shoot("p00-home")

        // 首页下滑：今日看板
        app.swipeUp(); sleep(2); shoot("p01-kanban")
        app.swipeDown(); app.swipeDown(); sleep(2)

        // 财务
        if tapText(app, "财务") {
            sleep(4); shoot("p02-finance-ledger")
            for tab in ["账户", "统计", "固定支出"] {
                let t = app.staticTexts[tab].firstMatch
                if t.exists { t.tap(); sleep(3); shoot("p02-finance-\(tab)") }
            }
            back(app)
        }

        if tapText(app, "想法") { sleep(3); shoot("p03-thoughts"); back(app) }
        if tapText(app, "任务") { sleep(3); shoot("p04-tasks"); back(app) }
        if tapText(app, "习惯") { sleep(3); shoot("p05-habits"); back(app) }
        if tapText(app, "健康") { sleep(4); shoot("p06-health"); back(app) }

        let ai = app.buttons["闪光"].firstMatch
        if ai.exists { ai.tap(); sleep(5); shoot("p07-ai"); }

        if tapText(app, "记忆长廊") { sleep(5); shoot("p08-gallery"); back(app) }
        if tapText(app, "个人") { sleep(3); shoot("p09-profile"); back(app) }

        // 付费墙
        let app2 = XCUIApplication()
        app2.launchEnvironment["HOLO_DEBUG_AUTO_SURFACE"] = "paywall"
        app2.launch()
        sleep(8)
        shoot("p10-paywall")
    }

    func testIPadLandscapeKeyPages() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        shoot("l00-home")

        if tapText(app, "财务") { sleep(4); shoot("l01-finance"); back(app) }
        if tapText(app, "想法") { sleep(3); shoot("l02-thoughts"); back(app) }
        if tapText(app, "记忆长廊") { sleep(5); shoot("l03-gallery"); back(app) }
        if tapText(app, "个人") { sleep(3); shoot("l04-profile"); back(app) }

        // 旋转回竖屏，验证旋转后状态
        XCUIDevice.shared.orientation = .portrait
        sleep(4)
        shoot("l05-back-to-portrait")
    }
}

// MARK: - iPad 适配审计 v2：每模块独立冷启动直达（避免全屏层遮挡）
final class HoloIPadAuditV2UITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[IPAD2] shot \(name)")
    }

    @discardableResult
    private func tapText(_ app: XCUIApplication, _ label: String) -> Bool {
        let el = app.staticTexts[label].firstMatch
        guard el.waitForExistence(timeout: 8) else {
            print("[IPAD2] missing \(label)")
            return false
        }
        el.tap()
        return true
    }

    private func back(_ app: XCUIApplication) {
        let b = app.navigationBars.buttons.firstMatch
        if b.exists { b.tap(); sleep(2) }
    }

    func testV2Portrait() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        shoot("v2-p00-home")

        if tapText(app, "财务") {
            sleep(4); shoot("v2-p02-finance-ledger")
            for tab in ["账户", "统计", "固定支出"] {
                let t = app.staticTexts[tab].firstMatch
                if t.exists { t.tap(); sleep(3); shoot("v2-p02-finance-\(tab)") }
            }
            back(app)
        }

        if tapText(app, "想法") { sleep(3); shoot("v2-p03-thoughts"); back(app) }
        if tapText(app, "任务") { sleep(3); shoot("v2-p04-tasks"); back(app) }
        if tapText(app, "习惯") { sleep(3); shoot("v2-p05-habits"); back(app) }
        if tapText(app, "健康") { sleep(4); shoot("v2-p06-health"); back(app) }

        // AI：独立拍，拍完直接重开
        if tapText(app, "闪光") || app.buttons["闪光"].firstMatch.exists {
            sleep(5); shoot("v2-p07-ai")
        }

        // 看板：独立拍（中心球无 AX 标签，坐标点击）
        app.terminate(); sleep(2); app.launch(); sleep(6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(4)
        shoot("v2-p01-kanban")
    }

    func testV2GalleryProfilePaywallSettings() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        if tapText(app, "记忆长廊") { sleep(5); shoot("v2-p08-gallery"); back(app) }
        if tapText(app, "个人") { sleep(3); shoot("v2-p09-profile"); back(app) }

        let app2 = XCUIApplication()
        app2.launchEnvironment["HOLO_DEBUG_AUTO_SURFACE"] = "paywall"
        app2.launch()
        sleep(8)
        shoot("v2-p10-paywall")

        let app3 = XCUIApplication()
        app3.launch()
        sleep(6)
        let gear = app3.buttons["设置"].firstMatch
        if gear.exists { gear.tap(); sleep(3) }
        shoot("v2-p11-settings")
    }
}

// MARK: - iPad 适配审计 v3：单模块独立冷启动（消除导航竞态）
final class HoloIPadAuditV3UITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[IPAD3] shot \(name)")
    }

    private func launchAndTap(_ label: String, _ name: String, wait: UInt32 = 4) {
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        let el = app.staticTexts[label].firstMatch
        if el.waitForExistence(timeout: 8) {
            el.tap()
            sleep(wait)
            shoot(name)
        } else {
            print("[IPAD3] missing \(label)")
            shoot("\(name)-MISSING")
        }
    }

    func testV3Tasks() { launchAndTap("任务", "v3-p04-tasks") }
    func testV3Habits() { launchAndTap("习惯", "v3-p05-habits", wait: 5) }
    func testV3Health() { launchAndTap("健康", "v3-p06-health", wait: 5) }
    func testV3Profile() { launchAndTap("个人", "v3-p09-profile") }

    func testV3AIViaCoordinate() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        // AI 球在底部导航中央（约 x 50%, y 93%）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        sleep(6)
        shoot("v3-p07-ai")
    }

    func testV3GalleryFixed() throws {
        launchAndTap("记忆长廊", "v3-p08-gallery-fixed", wait: 6)
    }
}

// MARK: - iPad 审计 v5：启动后旋转横屏拍关键页
final class HoloIPadAuditV5UITests: XCTestCase {

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/holo_ipad_audit/\(name).png"))
        print("[IPAD5] shot \(name)")
    }

    func testV5LandscapeAfterLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(6)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(5)
        shoot("v5-l0-home")

        // 财务
        let finance = app.staticTexts["财务"].firstMatch
        if finance.waitForExistence(timeout: 8) { finance.tap(); sleep(4); shoot("v5-l1-finance") }

        // 记忆长廊（验证修复后的限宽在横屏下）
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap(); sleep(2) }
        let gallery = app.staticTexts["记忆长廊"].firstMatch
        if gallery.exists { gallery.tap(); sleep(5); shoot("v5-l2-gallery") }
    }
}

// MARK: - iPad 审计 v6：横屏长廊（验证修复）
final class HoloIPadAuditV6UITests: XCTestCase {

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/holo_ipad_audit/\(name).png"))
        print("[IPAD6] shot \(name)")
    }

    func testV6LandscapeGallery() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        let gallery = app.staticTexts["记忆长廊"].firstMatch
        if gallery.waitForExistence(timeout: 8) {
            gallery.tap()
            sleep(6)
            shoot("v6-l-gallery")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
    }
}

// MARK: - iPad 审计 v7：R2 修复复验（首页头部对齐 + AI 页 + 竖屏长廊终态）
final class HoloIPadAuditV7UITests: XCTestCase {

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/holo_ipad_audit/\(name).png"))
        print("[IPAD7] shot \(name)")
    }

    func testV7HomeAndAI() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        shoot("v7-p-home")

        // AI 球（底部导航中央）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        sleep(6)
        shoot("v7-p-ai")
    }

    func testV7GalleryPortraitFinal() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(7)
        let gallery = app.staticTexts["记忆长廊"].firstMatch
        if gallery.waitForExistence(timeout: 8) {
            gallery.tap()
            sleep(6)
            shoot("v7-p-gallery-final")
        }
    }
}
