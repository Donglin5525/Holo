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
        for (label, name) in [("账本", "ov-fin-02-ledger"), ("统计", "ov-fin-03-stats"), ("固定支出", "ov-fin-04-spending"), ("设置", "ov-fin-05-settings")] {
            _ = tapLabeled(app, label, sidebar: false, settle: 4)
            shoot(name)
        }
        // 回账户 tab 打开「记一笔」弹层（弹层政策基线）
        _ = tapLabeled(app, "账户", sidebar: false, settle: 3)
        let fab = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.90))
        let fabLabel = app.staticTexts.matching(NSPredicate(format: "label == %@", "记一笔")).allElementsBoundByIndex.first
        if let fl = fabLabel, fl.isHittable {
            fl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(4)
            shoot("ov-fin-06-sheet-addtransaction")
            dismissSheet(app)
        } else {
            fab.tap()
            sleep(4)
            shoot("ov-fin-06-sheet-addtransaction")
            dismissSheet(app)
        }
        if false {
            shoot("ov-fin-06-sheet-addtransaction")
            dismissSheet(app)
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
        // 个人页常见行
        for (label, name) in [("会员", "ov-profile-02-membership"), ("订阅", "ov-profile-02-membership")] {
            if tapLabeled(app, label, sidebar: false, settle: 4) {
                shoot(name)
                break
            }
        }
    }
}
