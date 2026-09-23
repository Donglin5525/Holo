//
//  CalendarTimelineSmokeUITests.swift
//  Holo
//
//  系统日历三期「时间轴」冒烟：长廊 → 轴档渲染不崩溃 + 关键截图
//  通道：XCUITest（idb 不可用环境的 UI 走查替代）
//

import XCTest

/// 旋转偶发失效（连续竖屏跑完一整轮），设置后用窗口宽高校验，失败重试。
/// 文件级供 V8/V9 各审计类共用；XCTest 用例默认跑在主线程，assumeIsolated 安全。
func auditRotateToLandscape(_ app: XCUIApplication) {
    MainActor.assumeIsolated {
        for attempt in 0..<3 {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
            if app.frame.width > app.frame.height { return }
            print("[AUDIT] rotation attempt \(attempt) failed, retrying")
        }
    }
}

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

// MARK: - iPad 审计 v8：横屏全目的地走查（2026-09-07 五轮走查 R1 取证通道）
// 注意：xcodebuild 安装会重置本模拟器应用容器，故数据种子经 launchEnvironment
// 随本次运行自造（HoloAppStoreScreenshotSeeder DEBUG 通道）；侧边栏用坐标点击，
// 绕开 iOS 26 plain 按钮 AX 热区缩水导致的 not hittable。
final class HoloIPadAuditV8UITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[IPAD8] shot \(name)")
    }

    private func launchSeeded(_ orientation: UIDeviceOrientation) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "rhythm"
        app.launch()
        sleep(9)
        auditRotateToLandscape(app)
        return app
    }

    /// 坐标点击：元素 AX 报 not hittable 时仍按 frame 中心落点。
    /// 常驻壳层下隐藏层（首页模块环等）仍在 AX 树里，必须按 minX 分区锁定侧边栏/内容区元素。
    private func tapLabeled(_ app: XCUIApplication, _ label: String, sidebar: Bool, settle: UInt32 = 5) {
        let els = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        let zone: (CGFloat) -> Bool = sidebar ? { $0 < 300 } : { $0 >= 300 }
        guard let el = els.first(where: { zone($0.frame.minX) }) else {
            print("[IPAD8] missing \(label) (sidebar=\(sidebar))")
            return
        }
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(settle)
    }

    func testV8LandscapeAllPages() throws {
        let app = launchSeeded(.landscapeLeft)
        shoot("v8-l-01-home")

        tapLabeled(app, "想法", sidebar: true)
        shoot("v8-l-02-thoughts")
        tapLabeled(app, "财务", sidebar: true)
        shoot("v8-l-03-finance")
        tapLabeled(app, "任务", sidebar: true)
        shoot("v8-l-04-tasks")
        tapLabeled(app, "习惯", sidebar: true)
        shoot("v8-l-05-habits")

        // 长廊四档 + 洞察。档位分段控件 AX 受常驻隐藏层干扰，按横屏几何位置直接点按。
        tapLabeled(app, "记忆长廊", sidebar: true, settle: 6)
        shoot("v8-l-06-gallery-day")
        let scaleTaps: [(String, CGFloat, CGFloat)] = [
            ("v8-l-07-gallery-week", 0.50, 0.127),
            ("v8-l-08-gallery-month", 0.668, 0.127),
            ("v8-l-09-gallery-axis", 0.835, 0.127)
        ]
        for (name, dx, dy) in scaleTaps {
            app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            sleep(4)
            shoot(name)
        }
        // 右上角 日历/洞察 拨动开关（图标段，最右）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.965, dy: 0.07)).tap()
        sleep(5)
        shoot("v8-l-10-gallery-insight")

        tapLabeled(app, "健康", sidebar: true)
        shoot("v8-l-11-health")
        tapLabeled(app, "AI 对话", sidebar: true, settle: 6)
        shoot("v8-l-12-ai")
        tapLabeled(app, "个人", sidebar: true)
        shoot("v8-l-13-profile")
        tapLabeled(app, "设置", sidebar: true, settle: 6)
        shoot("v8-l-14-settings")

        XCUIDevice.shared.orientation = .portrait
        sleep(3)
    }

    func testV8PortraitHabitsAndGallery() throws {
        let app = launchSeeded(.portrait)
        tapLabeled(app, "习惯", sidebar: true, settle: 5)
        shoot("v8-p-habits")
        tapLabeled(app, "记忆长廊", sidebar: true, settle: 6)
        shoot("v8-p-gallery-day")
    }
}

// MARK: - iPad 审计 v9：旋转往返状态保持 + 深色横屏（R3/R4 取证）
final class HoloIPadAuditV9UITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[IPAD9] shot \(name)")
    }

    private func tapLabeled(_ app: XCUIApplication, _ label: String, sidebar: Bool, settle: UInt32 = 5) {
        let els = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        let zone: (CGFloat) -> Bool = sidebar ? { $0 < 300 } : { $0 >= 300 }
        guard let el = els.first(where: { zone($0.frame.minX) }) else {
            print("[IPAD9] missing \(label) (sidebar=\(sidebar))")
            return
        }
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(settle)
    }

    private func launchSeeded(_ orientation: UIDeviceOrientation, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "rhythm"
        if dark { app.launchArguments += ["-darkModeSetting", "dark"] }
        app.launch()
        sleep(9)
        auditRotateToLandscape(app)
        return app
    }

    /// 旋转往返：长廊日档状态（聚焦日期/档位）跨旋转保持
    func testV9ARotationCycleGallery() throws {
        let app = launchSeeded(.portrait)
        tapLabeled(app, "记忆长廊", sidebar: true, settle: 6)
        shoot("v9-r1-portrait-gallery")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        shoot("v9-r2-landscape-gallery")

        XCUIDevice.shared.orientation = .portrait
        sleep(4)
        shoot("v9-r3-portrait-again")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        tapLabeled(app, "习惯", sidebar: true, settle: 5)
        // 打开一块磁贴详情 sheet，验证横屏 sheet 呈现与关闭
        let tile = app.staticTexts["晨间阅读"].firstMatch
        if tile.waitForExistence(timeout: 6) {
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(4)
            shoot("v9-r4-habit-detail-sheet")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
    }

    /// 深色模式横屏关键页（东林真机为深色）。
    /// 不带种子环境：种子启动会强制浅色覆盖 -darkModeSetting；
    /// 每个用例独立启动，避免状态串扰（前一轮连点导致误触想法详情）。
    private func darkPage(_ label: String, _ name: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-darkModeSetting", "dark"]
        app.launch()
        sleep(9)
        auditRotateToLandscape(app)
        if label.isEmpty {
            shoot(name)
        } else {
            tapLabeled(app, label, sidebar: true, settle: 6)
            shoot(name)
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
    }

    func testV9B1DarkHome() { darkPage("", "v9-d-01-home") }
    func testV9B2DarkGallery() { darkPage("记忆长廊", "v9-d-02-gallery-day") }
    func testV9B3DarkHabits() { darkPage("习惯", "v9-d-03-habits") }
    func testV9B4DarkThoughts() { darkPage("想法", "v9-d-04-thoughts") }
    func testV9B5DarkTasks() { darkPage("任务", "v9-d-05-tasks") }
}

// MARK: - iPad 审计 v9b：真实新装空态（须单独一次 xcodebuild 运行——安装会重置容器）
final class HoloIPadAuditV9bEmptyUITests: XCTestCase {

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/holo_ipad_audit/\(name).png"))
        print("[IPAD9b] shot \(name)")
    }

    func testV9bFreshInstallEmptyStates() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(9)
        // 跳过新人引导与首页导览：AX 查询在引导层不稳定，按已验证的
        // 右上角坐标直接点按（竖屏 跳过 ≈ x 94%, y 6.5%），循环覆盖多层浮层
        let skipPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.876, dy: 0.049))
        for _ in 0..<4 {
            skipPoint.tap()
            sleep(2)
        }
        shoot("v9b-01-fresh-home")

        let els = app.staticTexts.matching(NSPredicate(format: "label == %@", "习惯")).allElementsBoundByIndex
        if let el = els.first(where: { $0.frame.minX < 300 }) {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(5)
        }
        shoot("v9b-02-fresh-habits-empty")

        let g = app.staticTexts.matching(NSPredicate(format: "label == %@", "记忆长廊")).allElementsBoundByIndex
        if let el = g.first(where: { $0.frame.minX < 300 }) {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(6)
        }
        shoot("v9b-03-fresh-gallery-empty")
    }
}

// MARK: - iPad 审计 v10：拍板项实施取证（轴档多泳道/设置双栏/想法双栏）
final class HoloIPadAuditV10UITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[IPAD10] shot \(name)")
    }

    private func tapLabeled(_ app: XCUIApplication, _ label: String, sidebar: Bool, settle: UInt32 = 5) {
        let els = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        let zone: (CGFloat) -> Bool = sidebar ? { $0 < 300 } : { $0 >= 300 }
        guard let el = els.first(where: { zone($0.frame.minX) }) else {
            print("[IPAD10] missing \(label) (sidebar=\(sidebar))")
            return
        }
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(settle)
    }

    private func launchSeededLandscape() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "rhythm"
        app.launch()
        sleep(9)
        auditRotateToLandscape(app)
        return app
    }

    func testV10LandscapePivotImplementations() throws {
        let app = launchSeededLandscape()

        // ②轴档多泳道：重叠任务各占一条泳道
        tapLabeled(app, "记忆长廊", sidebar: true, settle: 6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.835, dy: 0.127)).tap()
        sleep(4)
        shoot("v10-01-axis-lanes")

        // ④设置宽屏双栏
        tapLabeled(app, "设置", sidebar: true, settle: 6)
        shoot("v10-02-settings-two-column")

        // ③想法列表-详情双栏：未选中→引导位；点左列表卡片→右栏详情
        tapLabeled(app, "想法", sidebar: true, settle: 6)
        shoot("v10-03-thoughts-placeholder")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5)).tap()
        sleep(5)
        shoot("v10-04-thoughts-detail")

        XCUIDevice.shared.orientation = .portrait
        sleep(3)
    }

    func testV10PortraitThoughtsRegression() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "rhythm"
        app.launch()
        sleep(9)
        tapLabeled(app, "想法", sidebar: true, settle: 6)
        // 竖屏回归：单列列表 + 右下角 FAB 在场
        shoot("v10-05-thoughts-portrait")
    }
}

// MARK: - 通宵冲刺深页取证（2026-09-08，iPad 10→80）
// 覆盖 V8 未及的子页面/弹层/详情页；ov- 前缀落 /tmp/holo_ipad_audit。
final class HoloIPadOvernightUITests: XCTestCase {

    private let dir = "/tmp/holo_ipad_audit"

    private func shoot(_ name: String, settle: UInt32 = 2) {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("[OV] shot \(name)")
    }

    private func launchSeeded(_ story: String = "rhythm") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = story
        app.launch()
        sleep(9)
        auditRotateToLandscape(app)
        return app
    }

    /// 按标签点按（侧边栏 x<300，内容区 x>=300；先 staticTexts 后 buttons）
    private func tapLabeled(_ app: XCUIApplication, _ label: String, sidebar: Bool, settle: UInt32 = 4) -> Bool {
        let zone: (CGFloat) -> Bool = sidebar ? { $0 < 300 } : { $0 >= 300 }
        var texts: [XCUIElement] = []
        for el in app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex {
            if zone(el.frame.minX) { texts.append(el) }
        }
        var btns: [XCUIElement] = []
        for el in app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex {
            if zone(el.frame.minX) { btns.append(el) }
        }
        // 常驻壳层隐藏元素仍在 AX 树：优先可点，其次按钮，最后坐标兜底
        let candidates: [XCUIElement] = {
            var c = btns.filter { $0.isHittable } + texts.filter { $0.isHittable }
            if c.isEmpty { c = btns + texts }
            return c
        }()
        guard let el = candidates.first else {
            print("[OV] missing \(label) (sidebar=\(sidebar))")
            return false
        }
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(settle)
        return true
    }

    /// 按标签前缀点按（复合 label 的卡片/芯片，如「步数 8,670 …」）
    private func tapLabelPrefix(_ app: XCUIApplication, _ prefix: String, settle: UInt32 = 4) -> Bool {
        var btns: [XCUIElement] = []
        for el in app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex {
            if el.frame.minX >= 300 { btns.append(el) }
        }
        guard let el = (btns.filter { $0.isHittable }.first ?? btns.first) else {
            print("[OV] missing prefix \(prefix)")
            return false
        }
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(settle)
        return true
    }

    /// 关闭弹层：优先「取消/X/关闭」标签，否则从标题区往下抹
    private func dismissSheet(_ app: XCUIApplication) {
        for label in ["取消", "关闭", "X", "完成"] {
            let btns = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            if let b = btns.first(where: { $0.isHittable }) {
                b.tap(); sleep(2); return
            }
            let texts = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            if let t = texts.first(where: { $0.isHittable }) {
                t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2); return
            }
        }
        let win = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let dst = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        win.press(forDuration: 0.05, thenDragTo: dst)
        sleep(2)
    }


    /// 内容区找第一张卡片式按钮（任务卡/想法卡），显式循环避开长闭包类型推断超时
    private func firstCard(in app: XCUIApplication, maxX: CGFloat = 2000) -> XCUIElement? {
        let all = app.buttons.allElementsBoundByIndex
        var best: XCUIElement?
        for el in all {
            let f = el.frame
            if f.minX >= 300 && f.minX < maxX && f.minY > 150 && f.height > 60 && f.height < 400 {
                best = el
                break
            }
        }
        return best
    }

    func testOV01FinanceDeep() throws {
        let app = launchSeeded()
        tapLabeled(app, "财务", sidebar: true, settle: 5)
        shoot("ov-fin-01-accounts")
        // 「记一笔」FAB 只在账户/账本页显示——默认账户页先拍弹层，再切子页
        let fab = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.94))
        let fabText = app.staticTexts.matching(NSPredicate(format: "label == %@", "记一笔")).allElementsBoundByIndex.first
        if let fl = fabText, fl.isHittable {
            fl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            fab.tap()
        }
        sleep(4)
        shoot("ov-fin-06-sheet-addtransaction")
        dismissSheet(app)
        for (label, name) in [("账本", "ov-fin-02-ledger"), ("统计", "ov-fin-03-stats"), ("固定支出", "ov-fin-04-spending"), ("设置", "ov-fin-05-settings")] {
            _ = tapLabeled(app, label, sidebar: false, settle: 4)
            shoot(name)
        }
    }

    func testOV02TasksDeep() throws {
        let app = launchSeeded("busy-week")
        tapLabeled(app, "任务", sidebar: true, settle: 5)
        shoot("ov-task-01-list-busyweek")
        // 任务卡详情（content 区第一张卡，按坐标点列表头下方第一卡中心）
        if tapLabeled(app, "准备复盘材料", sidebar: false, settle: 4) {
            shoot("ov-task-02-detail")
            dismissSheet(app)
        } else {
            print("[OV] no task title found")
        }
        for (label, name) in [("统计", "ov-task-03-stats"), ("纪念日", "ov-task-04-anniversary")] {
            _ = tapLabeled(app, label, sidebar: false, settle: 4)
            shoot(name)
        }
    }

    func testOV03ThoughtsDeep() throws {
        let app = launchSeeded()
        tapLabeled(app, "想法", sidebar: true, settle: 5)
        // 知识树 tab（浏览切换：想法|知识树）
        if tapLabeled(app, "主题", sidebar: false, settle: 5) {
            shoot("ov-th-01-knowledge-tree")
        }
        _ = tapLabeled(app, "想法", sidebar: false, settle: 4)
        // 双栏右栏：点第一张想法卡
        if let card = firstCard(in: app, maxX: 900) {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(4)
            shoot("ov-th-02-detail-pane")
        }
    }

    func testOV04HealthDeep() throws {
        let app = launchSeeded()
        tapLabeled(app, "健康", sidebar: true, settle: 5)
        if tapLabelPrefix(app, "步数", settle: 4) {
            shoot("ov-health-01-detail-steps")
        }
        if tapLabelPrefix(app, "睡眠", settle: 4) {
            shoot("ov-health-02-detail-sleep")
        }
    }

    func testOV05SettingsDeep() throws {
        let app = launchSeeded()
        tapLabeled(app, "设置", sidebar: true, settle: 5)
        shoot("ov-set-00-shell")
        let groups = ["外观", "iCloud 同步", "日历", "AI 整理", "AI 回放", "存储与缓存", "隐私与安全", "法律与隐私", "账号与数据"]
        for (idx, g) in groups.enumerated() {
            if tapLabeled(app, g, sidebar: false, settle: 3) {
                shoot(String(format: "ov-set-%02d-%@", idx + 1, g.replacingOccurrences(of: " ", with: "-")))
            }
        }
    }

    func testOV06AIAndProfile() throws {
        let app = launchSeeded()
        tapLabeled(app, "AI 对话", sidebar: true, settle: 6)
        if tapLabeled(app, "报告", sidebar: false, settle: 5) {
            shoot("ov-ai-01-report")
        }
        tapLabeled(app, "个人", sidebar: true, settle: 4)
        shoot("ov-profile-01")
        // 目标列表（D7 卡墙验证）：从个人页我的目标进入
        if tapLabeled(app, "目标管理", sidebar: false, settle: 4) {
            shoot("ov-goal-01-list")
            // 点第一张目标卡进详情（限宽验证）
            if let card = firstCard(in: app) {
                card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(4)
                shoot("ov-goal-02-detail")
            }
        }
    }
}

// MARK: - 临时 QA（验证完删除）：轴档任务块整体拖动 + 独占撑满宽度
final class AxisDragMoveQATests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_axis_qa"

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

    func coord(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x, dy: y))
    }

    /// 关闭新人引导 / 首页导览浮层（AX 查询优先，坐标兜底）
    func skipAllGuides() {
        for _ in 0..<6 {
            let btn = app.buttons["跳过"].firstMatch
            if btn.exists && btn.isHittable { btn.tap(); sleep(1); continue }
            let txt = app.staticTexts["跳过"].firstMatch
            if txt.exists && txt.isHittable {
                txt.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(1); continue
            }
            break
        }
        for _ in 0..<3 {
            guard app.staticTexts["生活的五个入口"].firstMatch.exists else { break }
            coord(app.frame.width * 0.876, app.frame.height * 0.07).tap()
            sleep(1)
        }
    }

    /// 长廊欢迎横幅的 × 在标题右侧；存在则关掉
    func dismissGalleryBannerIfNeeded() {
        let title = app.staticTexts["欢迎来到记忆长廊"].firstMatch
        guard title.exists else { return }
        coord(app.frame.width * 0.876, title.frame.midY + 13).tap()
        sleep(1)
    }

    /// 首页 → 长廊 → 轴档 → 指定日期（明天）
    func openAxis(onDay day: Int) {
        sleep(2)
        skipAllGuides()
        var entry: XCUIElement = app.buttons["记忆长廊"].firstMatch
        if !entry.exists { entry = app.staticTexts["记忆长廊"].firstMatch }
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "找不到底部「记忆长廊」入口")
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(3)
        dismissGalleryBannerIfNeeded()

        // 切「轴」档：iOS 26 AX 热区缩水常见 not hittable，按元素 frame 中心落点，
        // 查不到再按月档布局的坐标兜底（轴 ≈ 0.668 归一化 x）
        var axisTapped = false
        let axisPred = NSPredicate(format: "label == %@", "轴")
        let axisEls = (app.buttons.matching(axisPred).allElementsBoundByIndex
            + app.staticTexts.matching(axisPred).allElementsBoundByIndex)
            .filter { $0.frame.minY < 200 && $0.frame.width < 120 }
        if let el = axisEls.first {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            axisTapped = true
        } else {
            coord(app.frame.width * 0.668, app.frame.height * 0.1555).tap()
            axisTapped = true
        }
        XCTAssertTrue(axisTapped)
        // 轴档有小时刻度（月/周/日档没有带前导零的两位刻度），以「07」在场为到位凭证
        let hour07 = app.staticTexts["07"].firstMatch
        if !hour07.waitForExistence(timeout: 5) {
            print("[NAV] 切轴后未见 07 刻度，按坐标再补一刀")
            coord(app.frame.width * 0.668, app.frame.height * 0.1555).tap()
            _ = hour07.waitForExistence(timeout: 5)
        }
        sleep(2)
        shoot("N1_axis_today")

        // 导航行日历图标 → 前往一天（弹层标题「前往一天」为出现凭证，没出就重试）
        let sheetTitle = app.staticTexts["前往一天"].firstMatch
        var opened = sheetTitle.waitForExistence(timeout: 3)
        var tryIdx = 0
        while !opened && tryIdx < 3 {
            coord(app.frame.width * 0.923, app.frame.height * 0.1556).tap()
            opened = sheetTitle.waitForExistence(timeout: 3)
            tryIdx += 1
        }
        sleep(1)
        shoot("N2_date_sheet")

        var dayEl: XCUIElement?
        for q in [app.staticTexts, app.buttons] {
            let hits = q.matching(NSPredicate(format: "label == %@", "\(day)")).allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.minY > 480 && $0.frame.minY < 900
            }
            if let el = hits.first { dayEl = el; break }
        }
        if let el = dayEl {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
        } else {
            print("[NAV] 日格 \(day) 未找到")
            shoot("N2b_day_missing")
        }
        shoot("N3_day_selected")

        let go = app.buttons["前往"].firstMatch
        if go.exists && go.isHittable {
            go.tap()
        } else {
            coord(app.frame.width * 0.862, 453).tap()
        }
        sleep(2)
        shoot("N4_axis_tomorrow")
    }

    /// 小时行顶部（=整点线）的屏幕 y：标签视觉中心比行顶低 23pt（行内居中再上偏 5）
    func hourRowTop(_ hour: Int) -> CGFloat {
        let label = app.staticTexts[String(format: "%02d", hour)].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 6), "找不到小时刻度 \(hour)")
        let midY = label.frame.midY
        print("[CAL] label \(hour) midY=\(midY) frame=\(label.frame)")
        return midY - 23
    }

    func blockText(_ range: String) -> XCUIElement {
        app.staticTexts[range].firstMatch
    }

    /// 轴上所有带时间段文字的元素（含屏外，AX 树可见）
    func dumpTimeBlocks(_ tag: String) -> [String] {
        let pred = NSPredicate(format: "label MATCHES %@", "\\d{1,2}:\\d{2}-\\d{1,2}:\\d{2}")
        let els = app.staticTexts.matching(pred).allElementsBoundByIndex
        let lines = els.map { "[BLOCKS:\(tag)] \($0.label) frame=\($0.frame)" }
        for l in lines { print(l) }
        return els.map { $0.label }
    }

    func snap15(_ m: Int) -> Int {
        let v = Int((Double(m) / 15.0).rounded()) * 15
        return (v % 1440 + 1440) % 1440
    }
    func fmt(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
    func parseRange(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: "-")
        guard parts.count == 2 else { return nil }
        func mins(_ t: String.SubSequence) -> Int? {
            let hm = t.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
            return h * 60 + m
        }
        guard let a = mins(parts[0]), let b = mins(parts[1]) else { return nil }
        return (a, b)
    }

    func test_axisDragMove_fullQA() throws {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        let day = cal.component(.day, from: tomorrow)
        print("[QA] 今天=\(cal.component(.day, from: Date())) 走查日=明天 \(day) 号")

        // ===== 导航：长廊 → 轴 → 明天 =====
        openAxis(onDay: day)
        let preExisting = dumpTimeBlocks("pre")

        // ===== 造数据：长按空白拖出 ~17:00–18:00（避开上一轮 14:15 残留，互不重叠） =====
        let w = app.frame.width
        let cx: CGFloat = 220
        let y17 = hourRowTop(17)
        print("[CAL] rowTop17=\(y17) screenW=\(w) screenH=\(app.frame.height)")
        let pressStart = coord(cx, y17 + 4)
        let pressEnd = coord(cx, y17 + 64 + 4)
        pressStart.press(forDuration: 0.7, thenDragTo: pressEnd, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(1)
        shoot("C1_create_sheet")

        // 填标题，下滑保存
        var tf = app.textFields["输入任务名称"].firstMatch
        if !tf.exists { tf = app.textFields.firstMatch }
        XCTAssertTrue(tf.waitForExistence(timeout: 6), "建任务弹层没有出现标题输入框")
        tf.tap()
        tf.typeText("QA拖拽任务")
        sleep(1)
        shoot("C2_typed")
        app.swipeDown()
        sleep(1)
        if app.textFields["输入任务名称"].firstMatch.exists {
            print("[QA] 第一次下滑未关闭弹层，从弹层顶部抓握区再试一次")
            coord(w * 0.5, app.frame.height * 0.30).press(forDuration: 0.05, thenDragTo: coord(w * 0.5, app.frame.height * 0.92), withVelocity: .slow, thenHoldForDuration: 0)
            sleep(1)
        }
        sleep(2)
        shoot("C3_created")
        sleep(2)
        shoot("C3b_created_settled")

        // ===== 场景 1：宽度修复（动态识别新建块） =====
        let afterCreate = dumpTimeBlocks("post")
        let newBlocks = afterCreate.filter { !preExisting.contains($0) }
        print("[W] 新建块=\(newBlocks) 既有块=\(preExisting)")
        guard let createdRange = newBlocks.first, let created = parseRange(createdRange) else {
            XCTFail("创建后找不到新的时间段块")
            return
        }
        let createdEl = blockText(createdRange)
        XCTAssertTrue(createdEl.waitForExistence(timeout: 6), "创建块 AX 不在场")
        print("[W] createdRange=\(createdRange) AX frame=\(createdEl.frame)")
        shoot("S1_width_single_task")

        // ===== 场景 2：长按块本体 0.65s → 上移 110pt（≈-2h） =====
        // 期望候选：位移 110pt=117.9min，或 DragGesture 最小位移吃掉 8pt=109.3min
        let s0 = created.0, e0 = created.1
        func rangeStr(_ a: Int, _ b: Int) -> String { "\(fmt(a))-\(fmt(b))" }
        let moveExp = Set([rangeStr(snap15(s0 - 118), snap15(e0 - 118)), rangeStr(snap15(s0 - 109), snap15(e0 - 109))])
        print("[MOVE] 期望候选=\(moveExp.sorted())")
        let blockCenterY = y17 + 28
        shoot("S2_before_move", settle: 0)
        coord(cx, blockCenterY).press(forDuration: 0.65, thenDragTo: coord(cx, blockCenterY - 110), withVelocity: .slow, thenHoldForDuration: 0)
        sleep(2)
        shoot("S2_after_move")
        let afterMove = dumpTimeBlocks("move")
        let movedBlock = afterMove.first { moveExp.contains($0) }
        print("[MOVE] 移动后命中=\(movedBlock ?? "无")")
        XCTAssertFalse(afterMove.contains(createdRange), "移动后原区间仍在，块没有移动")
        XCTAssertNotNil(movedBlock, "移动后未找到预期新区间")

        // ===== 场景 3：杀掉重启验证落库 =====
        let movedRange = movedBlock ?? (afterMove.first { $0 != createdRange && parseRange($0) != nil } ?? createdRange)
        app.terminate()
        sleep(2)
        app.launch()
        sleep(4)
        openAxis(onDay: day)
        let persistedBlocks = dumpTimeBlocks("persist")
        let persisted = persistedBlocks.contains(movedRange) ? movedRange : nil
        shoot("S3_after_restart")
        print("[PERSIST] 重启后块时间=\(persisted ?? "无") 期望=\(movedRange)")
        XCTAssertNotNil(persisted, "重启后任务块没有出现在移动后的位置（未落库或回弹）")

        // ===== 场景 4：轻点块 → 详情页（不是移动） =====
        let cur = blockText(movedRange)
        cur.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        shoot("S4_detail")
        let titleShown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "QA拖拽任务")).firstMatch.exists
            || app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "QA拖拽任务")).firstMatch.exists
        print("[TAP] 详情页出现任务标题=\(titleShown)")
        XCTAssertTrue(titleShown, "轻点块没有打开任务详情")
        app.swipeDown()
        sleep(1)
        if !blockText(movedRange).exists {
            coord(w * 0.5, app.frame.height * 0.30).press(forDuration: 0.05, thenDragTo: coord(w * 0.5, app.frame.height * 0.92), withVelocity: .slow, thenHoldForDuration: 0)
            sleep(1)
        }
        sleep(1)
        shoot("S4_back_axis")

        // ===== 场景 5：长按块顶部边缘 0.5s → 上移 55pt（调时长，非移动） =====
        let curFrame = blockText(movedRange).frame
        let blockTopY = curFrame.minY - 5 + 6   // 块 minY ≈ 文字 minY - 5(纵向内边距)，压在顶部 14pt 把手内
        let edgeStart = coord(cx, blockTopY)
        let edgeEnd = coord(cx, blockTopY - 55)
        print("[EDGE] 文字frame=\(curFrame) 顶部按压y=\(blockTopY)")
        shoot("S5_before_edge", settle: 0)
        edgeStart.press(forDuration: 0.5, thenDragTo: edgeEnd, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(2)
        shoot("S5_after_edge")
        let afterEdge = dumpTimeBlocks("edge")
        let pm = parseRange(movedRange)!
        let edgeExp = Set([rangeStr(snap15(pm.0 - 59), pm.1), rangeStr(snap15(pm.0 - 51), pm.1)])
        let edgeBlock = afterEdge.first { edgeExp.contains($0) }
        print("[EDGE] 调边后命中=\(edgeBlock ?? "无") 期望候选=\(edgeExp.sorted())（底缘应保持 \(fmt(pm.1)) 不变）")

        // ===== 场景 6：从块正中起始滚动（慢/快各 3 次） =====
        let finalRange = edgeBlock ?? movedRange
        let blk = blockText(finalRange)
        let blockMidY = blk.exists ? blk.frame.midY : hourRowTop(11) + 28
        func refMidY() -> CGFloat {
            let l = app.staticTexts["17"].firstMatch
            return l.exists ? l.frame.midY : -999
        }
        var scrollResults: [String] = []
        let plan: [(String, CGFloat, XCUIGestureVelocity)] = [
            ("慢1上", -100, .slow), ("慢2上", -100, .slow), ("慢3下", 100, .slow),
            ("快1上", -100, .fast), ("快2上", -100, .fast), ("快3下", 100, .fast),
        ]
        for (name, dy, v) in plan {
            let before = refMidY()
            coord(cx, blockMidY).press(forDuration: 0.05, thenDragTo: coord(cx, blockMidY + dy), withVelocity: v, thenHoldForDuration: 0)
            sleep(1)
            let delta = refMidY() - before
            let still = blockText(finalRange).exists
            scrollResults.append("\(name): 17刻度位移=\(Int(delta))pt 块文字仍在=\(still)")
            print("[SCROLL] \(name) delta=\(delta) 块文字仍在=\(still)")
            shoot("S6_\(name)", settle: 0)
        }
        for r in scrollResults { print("[SCROLL-SUM] \(r)") }

        // ===== 场景 7：空白区滚动对照 =====
        let beforeBlank = refMidY()
        coord(cx, hourRowTop(20) + 28).press(forDuration: 0.05, thenDragTo: coord(cx, hourRowTop(20) + 28 - 100), withVelocity: .slow, thenHoldForDuration: 0)
        sleep(1)
        print("[SCROLL] 空白对照: 17刻度位移=\(Int(refMidY() - beforeBlank))pt")
        shoot("S7_blank_scroll", settle: 0)

        // ===== 场景 2 补充证据：长按悬停高亮（松手无位移=不移动） =====
        let shotDone = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        shotDone.pointee = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            shotDone.pointee = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/S2b_hold_highlight.png"))) != nil
        }
        coord(cx, blockMidY).press(forDuration: 0.7)
        sleep(1)
        print("[HOLD] 悬停高亮截图 ok=\(shotDone.pointee)")
        shotDone.deallocate()
        shoot("S8_final")
    }
}
