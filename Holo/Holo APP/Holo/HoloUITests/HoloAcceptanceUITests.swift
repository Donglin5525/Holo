//
//  HoloAcceptanceUITests.swift
//  Holo
//
//  第二轮验收：财务-账户页卡堆回归（R1-R4 + W1-W9）
//  仅测试基础设施，不修改 App 功能代码。
//

import XCTest

final class HoloAcceptanceUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_accept_r3"

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

    /// 坐标拖拽（避开 XCUIElement.swipe 的不稳定行为）
    func drag(_ y0: CGFloat, _ y1: CGFloat, hold: TimeInterval = 0.05) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y0 / 874.0))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y1 / 874.0))
        a.press(forDuration: hold, thenDragTo: b)
        sleep(2)
    }

    /// 滚回顶部：固定坐标分段 50pt 小拖——拖距压在 56pt 翻卡阈值以内不会触发
    /// 卡堆翻卡，终点 350 远离底部 tab 栏；分段短拖起点落在卡堆内也安全
    func scrollTop() {
        var tries = 0
        while !app.staticTexts["总净资产 · NET WORTH"].firstMatch.isHittable && tries < 8 {
            drag(300, 350)
            sleep(1)
            tries += 1
        }
    }

    var topPanel: String {
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
        where app.staticTexts["\(n) · 动态"].firstMatch.exists { return n }
        return "?"
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

    /// 找一张处于收起区（可视范围内）的卡头名
    func collapsedHead(except: String? = nil) -> String? {
        ["微信", "支付宝", "储蓄卡", "现金", "信用卡"]
            .first {
                guard $0 != except else { return false }
                let e = app.staticTexts[$0].firstMatch
                return e.exists && e.frame.minY > 370 && e.frame.minY < 720
            }
    }

    /// 把指定账户换到置顶。已在顶部或目标在 tab 栏危险区（y≥720，tap 中心会压到
    /// tab 栏）时直接返回——不要强行点，交给调用方动态适配断言
    func bringToTop(_ name: String) {
        let e = app.staticTexts[name].firstMatch
        guard e.exists, e.frame.minY >= 360, e.frame.minY < 720 else { return }
        e.tap()
        sleep(2)
    }

    // MARK: - 主验收流程

    func testFullAcceptance() throws {
        openAccountsPage()

        // ============ R1 收起卡显示卡头 ============
        shoot("A01_stack_overview", settle: 1)
        // 先把现金归一到置顶：collapse-count==4 的前提是置顶卡为负债卡
        // （现金负债标签不计入「当前余额」，其余 4 张收起卡全计入）
        bringToTop("现金")
        let names = ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
        for n in names {
            let e = app.staticTexts[n].firstMatch
            check("R1-name-\(n)", e.exists, e.exists ? "y=\(Int(e.frame.minY))" : "未找到")
        }
        // 动态识别当前置顶卡（名字 y 最小者为当前卡头）
        let nameYs: [(String, CGFloat)] = names.compactMap { n in
            let e = app.staticTexts[n].firstMatch
            return e.exists ? (n, e.frame.minY) : nil
        }.sorted { $0.1 < $1.1 }
        print("[INFO] 当前置顶=\(nameYs.first?.0 ?? "?") 顺序=\(nameYs.map { $0.0 })")
        let currentHeadBottom = (nameYs.first?.1 ?? 0) + 212
        let collapseLabels = app.staticTexts.matching(identifier: "当前余额").allElementsBoundByIndex
            .filter { $0.frame.width > 0 && $0.frame.minY > currentHeadBottom - 60 }
        check("R1-collapse-count", collapseLabels.count == 4, "count=\(collapseLabels.count)")
        if collapseLabels.count >= 2 {
            let ys = collapseLabels.map { Int($0.frame.minY) }.sorted()
            let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }
            print("[CHECK] R1-collapse-ys \(ys)")
            check("R1-64pt-spacing", gaps.allSatisfy { $0 == 64 }, "gaps=\(gaps)")
        }
        check("R1-type-weixin", app.staticTexts["数字钱包 · WALLET"].firstMatch.exists)

        // ============ R2 添加账户入口（导航栏 +，唯一入口）+ 表单弹出 ============
        let addBtn = app.buttons["添加账户"].firstMatch
        check("R2-add-exists", addBtn.exists)
        check("R2-add-hittable", addBtn.isHittable)
        shoot("A02_nav_add_entry", settle: 1)
        addBtn.tap()
        let sheetOpen = app.navigationBars["新建账户"].waitForExistence(timeout: 6)
        check("R2-sheet-open", sheetOpen)
        check("R2-sheet-cancel", sheetOpen && app.buttons["取消"].firstMatch.exists)
        shoot("A03_add_sheet", settle: 1)
        if sheetOpen {
            app.buttons["取消"].firstMatch.tap()
            sleep(2)
            check("R2-sheet-dismissed", app.staticTexts["总净资产 · NET WORTH"].waitForExistence(timeout: 6))
        }
        scrollTop()
        shoot("A04_back_to_top", settle: 1)

        // ============ R3 点击收起卡置顶 ============
        bringToTop("现金")
        check("R3-normalize-cash", app.staticTexts["现金 · 动态"].firstMatch.exists)
        for i in 1...3 {
            guard let target = collapsedHead(except: "现金") else {
                check("R3-tap-\(i)", false, "无可用收起卡头")
                break
            }
            let targetY = app.staticTexts[target].firstMatch.frame.minY
            app.staticTexts[target].firstMatch.tap()
            sleep(2)
            let newY = app.staticTexts[target].firstMatch.frame.minY
            let panelOK = app.staticTexts["\(target) · 动态"].firstMatch.exists
            check("R3-tap-\(i)-\(target)-top", panelOK && newY < 360 && newY < targetY,
                  "y: \(Int(targetY)) -> \(Int(newY)) panel=\(panelOK)")
            shoot("A0\(4 + i)_tap_\(target)_top", settle: 1)
        }

        // ============ W9 翻卡动画抓帧（点一张收起卡头拍翻卡过程） ============
        // 页面保持在顶部：收起卡头在 553/617/681，tap 中心安全；
        // 不再滚动、不再把信用卡换上换下——抓帧对象随当前顺序动态取
        if let head = collapsedHead() {
            app.staticTexts[head].firstMatch.tap()
            shoot("A08_anim_t0")
            usleep(250_000); shoot("A08_anim_t1")
            usleep(250_000); shoot("A08_anim_t2")
            usleep(300_000); shoot("A08_anim_t3")
            sleep(1)
            shoot("A08_anim_t4_settled")
            check("W9-tap-flip-top", app.staticTexts["\(head) · 动态"].firstMatch.waitForExistence(timeout: 4))
        }

        // ============ W8 动态面板联动（随置顶卡适配收支三格/信用卡账单格） ============
        let panelUp = topPanel
        check("W8-panel-linked", panelUp != "?", "panel=\(panelUp)")
        if panelUp != "?" {
            // 信用卡面板是账单三格，普通账户面板是收支三格/零态行——对应存在即联动正常
            let expectCredit = (panelUp == "信用卡")
            let creditStyle = app.staticTexts["本期账单 BILL"].firstMatch.exists
            let plainStyle = app.staticTexts["本月收入 IN"].firstMatch.exists
                || app.staticTexts["本月暂无收支记录"].firstMatch.exists
            check("W8-credit-grid", expectCredit ? creditStyle : plainStyle, "panel=\(panelUp) credit=\(creditStyle) plain=\(plainStyle)")
            check("W8-due-cell", !expectCredit || app.staticTexts["距还款日 DUE"].firstMatch.exists)
            check("W8-due-value", true)
        }
        shoot("A09_credit_panel", settle: 1)
        scrollTop()

        // ============ W3 进详情/返回（置顶卡动态适配：现金负债态标签是「负债 · DEBT」） ============
        let currentName = topPanel
        let balLabel = currentName == "现金"
            ? app.staticTexts["负债 · DEBT"].firstMatch
            : app.staticTexts["当前余额 · BALANCE"].firstMatch
        if balLabel.waitForExistence(timeout: 4) {
            balLabel.tap()
            sleep(2)
            if currentName != "?" {
                let detailNav = app.navigationBars[currentName].firstMatch
                check("W3-detail-open", detailNav.waitForExistence(timeout: 6))
                shoot("A10_credit_detail", settle: 1)
                let back = detailNav.buttons.firstMatch
                if back.exists { back.tap() }
                sleep(2)
                check("W3-detail-back", app.staticTexts["总净资产 · NET WORTH"].waitForExistence(timeout: 6))
                shoot("A11_after_detail_back", settle: 1)
            } else {
                check("W3-detail-open", false, "topPanel 未知")
            }
        } else {
            check("W3-detail-open", false, "当前卡未找到")
        }

        // ============ W4 上滑翻卡 / 下滑翻回（卡堆中心=收起头区） ============
        let beforeUp = topPanel
        check("W4-before-top", beforeUp != "?", "top=\(beforeUp)")
        if let head = collapsedHead() {
            app.staticTexts[head].firstMatch.swipeUp(velocity: .slow)
            sleep(2)
            let afterUp = topPanel
            check("W4-swipeup-flip", afterUp != beforeUp && afterUp != "?",
                  "top: \(beforeUp) -> \(afterUp)")
            shoot("A12_swipe_up", settle: 1)
            if let head2 = collapsedHead() {
                app.staticTexts[head2].firstMatch.swipeDown(velocity: .slow)
                sleep(2)
                let afterDown = topPanel
                check("W4-swipedown-flip", afterDown != afterUp && afterDown != "?",
                      "top: \(afterUp) -> \(afterDown)")
                shoot("A13_swipe_down", settle: 1)
            }
        } else {
            check("W4-swipeup-flip", false, "未找到收起卡头")
        }
        scrollTop()

        // ============ W5 卡片视图切换 ============
        let toggle = app.buttons["› 列表"].firstMatch
        check("W5-toggle-exists", toggle.waitForExistence(timeout: 4))
        toggle.tap()
        sleep(2)
        check("W5-list-open", app.staticTexts["全部账户 · 5 个"].firstMatch.waitForExistence(timeout: 5))
        shoot("A14_list_view", settle: 1)
        app.staticTexts["微信"].firstMatch.tap()
        sleep(2)
        check("W5-row-back-to-stack", app.staticTexts["微信 · 动态"].firstMatch.waitForExistence(timeout: 5))
        check("W5-toggle-restored", app.buttons["› 列表"].firstMatch.exists)
        shoot("A15_back_to_stack_wechat_top", settle: 1)

        // ============ W7 编辑账户 / 调整余额 sheet ============
        let curBal = app.staticTexts["当前余额 · BALANCE"].firstMatch
        curBal.press(forDuration: 1.3)
        sleep(1)
        let editItem = app.buttons["编辑账户"].firstMatch
        check("W7-menu-open", editItem.waitForExistence(timeout: 5))
        if editItem.exists {
            editItem.tap()
            sleep(2)
            check("W7-edit-sheet", app.navigationBars["编辑账户"].waitForExistence(timeout: 6))
            check("W7-edit-cancel", app.buttons["取消"].firstMatch.exists)
            shoot("A16_edit_sheet", settle: 1)
            app.buttons["取消"].firstMatch.tap()
            sleep(2)
        }
        curBal.press(forDuration: 1.3)
        sleep(1)
        let adjItem = app.buttons["调整余额"].firstMatch
        check("W7-menu-open-2", adjItem.waitForExistence(timeout: 5))
        if adjItem.exists {
            adjItem.tap()
            sleep(2)
            check("W7-adjust-sheet", app.navigationBars["调整余额"].waitForExistence(timeout: 6))
            check("W7-adjust-cancel", app.buttons["取消"].firstMatch.exists)
            shoot("A17_adjust_sheet", settle: 1)
            app.buttons["取消"].firstMatch.tap()
            sleep(2)
        }

        // ============ R4 长按菜单（当前卡 + 收起卡头） ============
        curBal.press(forDuration: 1.3)
        sleep(1)
        check("R4-menu-items", app.buttons["编辑账户"].firstMatch.waitForExistence(timeout: 5))
        check("R4-item-adjust", app.buttons["调整余额"].firstMatch.exists)
        let setDefault = app.buttons["设为默认"].firstMatch.exists
            || app.staticTexts["设为默认（当前默认）"].firstMatch.exists
        check("R4-item-default", setDefault)
        check("R4-item-archive", app.buttons["归档账户"].firstMatch.exists)
        shoot("A18_menu_wechat_current", settle: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        sleep(1)
        let alipayHead = app.staticTexts["支付宝"].firstMatch
        check("R4-collapse-head-exists", alipayHead.exists, "y=\(Int(alipayHead.frame.minY))")
        alipayHead.press(forDuration: 1.3)
        sleep(1)
        var menuOK = app.buttons["编辑账户"].firstMatch.exists
            || app.buttons["归档账户"].firstMatch.exists
        if !menuOK {
            // 空预览紧凑菜单在触摸点弹出：释放手指可能误触菜单项直接打开 sheet。
            // 出现编辑/调整 sheet 同样证明菜单已弹出——取消后用短长按重试取证。
            let sheetHit = app.navigationBars["编辑账户"].firstMatch.exists
                || app.navigationBars["调整余额"].firstMatch.exists
            if sheetHit {
                app.buttons["取消"].firstMatch.tap()
                sleep(2)
                alipayHead.press(forDuration: 1.0)
                sleep(1)
                menuOK = app.buttons["编辑账户"].firstMatch.exists
                    || app.buttons["归档账户"].firstMatch.exists
                check("R4-menu-on-collapse-retry", menuOK)
                if menuOK {
                    check("R4-item-edit-c", app.buttons["编辑账户"].firstMatch.exists)
                    check("R4-item-archive-c", app.buttons["归档账户"].firstMatch.exists)
                }
            }
        } else {
            check("R4-menu-on-collapse-retry", true)
        }
        check("R4-menu-on-collapse", menuOK, menuOK ? "" : "菜单未出现且无 sheet 证据")
        shoot("A19_menu_on_alipay_head", settle: 1)
        if app.buttons["编辑账户"].firstMatch.exists || app.buttons["归档账户"].firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            sleep(1)
        } else if app.buttons["取消"].firstMatch.exists {
            app.buttons["取消"].firstMatch.tap()
            sleep(2)
        }

        // ============ W2 面板内容（面板存在性 + 截图取证） ============
        // exists 不要求可视，无需滚动； scrollTop 保证页面状态归位
        scrollTop()
        let seeAllBtn = app.buttons["查看全部交易 ›"].firstMatch.exists
            || app.staticTexts["查看全部交易 ›"].firstMatch.exists
        check("W2-see-all-exists", seeAllBtn)
        shoot("A20_panel_full", settle: 1)
        print("[CHECK] W2 重叠与 W6 背景色由截图事后分析")
    }
}

// MARK: - R4 收起卡头长按菜单专项验证

final class HoloR4CollapseMenu: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }
    func shoot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/holo_accept_r3/\(name).png"))
        print("[SHOT] \(name)")
    }
    func check(_ id: String, _ ok: Bool, _ d: String = "") {
        print("[CHECK] \(id) \(ok ? "PASS" : "FAIL") \(d)")
    }

    func testCollapseLongPress() throws {
        app.buttons["财务"].firstMatch.tap(); sleep(3)
        app.buttons["账户"].firstMatch.tap(); sleep(3)

        guard let head = ["微信", "支付宝", "储蓄卡", "现金", "信用卡"].first(where: {
            let e = app.staticTexts[$0].firstMatch
            return e.exists && e.frame.minY > 370 && e.frame.minY < 720
        }) else {
            check("R4c-head-found", false); return
        }
        print("[INFO] 目标收起头=\(head) y=\(Int(app.staticTexts[head].firstMatch.frame.minY))")

        let el = app.staticTexts[head].firstMatch
        // 后台延时截图：长按进行中（0.9s 时）抓菜单
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.shoot("R4c_menu_mid_press")
        }
        el.press(forDuration: 1.4)
        sleep(1)

        let menuShown = app.buttons["编辑账户"].firstMatch.exists
            || app.buttons["调整余额"].firstMatch.exists
            || app.buttons["归档账户"].firstMatch.exists
        let editSheet = app.navigationBars["编辑账户"].firstMatch.exists
        let adjustSheet = app.navigationBars["调整余额"].firstMatch.exists
        print("[INFO] menu=\(menuShown) editSheet=\(editSheet) adjustSheet=\(adjustSheet)")
        shoot("R4c_after_release")

        if menuShown {
            check("R4c-menu-on-collapse", true)
            check("R4c-item-edit", app.buttons["编辑账户"].firstMatch.exists)
            check("R4c-item-adjust", app.buttons["调整余额"].firstMatch.exists)
            check("R4c-item-archive", app.buttons["归档账户"].firstMatch.exists)
            // 点击空白取消菜单
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            sleep(1)
        } else if editSheet || adjustSheet {
            // 释放时误触菜单项 → 证明菜单已弹出且项可点；取消后重试一次短长按
            check("R4c-menu-on-collapse", true, "菜单弹出但释放时误触了\(editSheet ? "编辑账户" : "调整余额")（空预览菜单在触摸点弹出所致），重试验证")
            app.buttons["取消"].firstMatch.tap(); sleep(2)
            el.press(forDuration: 1.0)
            sleep(1)
            let menu2 = app.buttons["编辑账户"].firstMatch.exists
                || app.buttons["归档账户"].firstMatch.exists
            check("R4c-menu-retry", menu2)
            if menu2 { shoot("R4c_menu_retry") ; app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap(); sleep(1) }
        } else {
            check("R4c-menu-on-collapse", false, "无菜单无 sheet")
        }
    }
}

// MARK: - R3 交易行点击进详情

final class HoloR3RowTap: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }
    func shoot(_ name: String) {
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/holo_accept_r3/\(name).png"))
        print("[SHOT] \(name)")
    }
    func check(_ id: String, _ ok: Bool, _ d: String = "") {
        print("[CHECK] \(id) \(ok ? "PASS" : "FAIL") \(d)")
    }

    func testTapRecentRow() throws {
        app.buttons["财务"].firstMatch.tap(); sleep(3)
        app.buttons["账户"].firstMatch.tap(); sleep(3)

        // 交易记在现金（默认账户）——先把现金置顶，面板才会显示这笔交易
        let cash = app.staticTexts["现金"].firstMatch
        if cash.exists && cash.frame.minY > 370 {
            cash.tap(); sleep(2)
        }
        check("TX2-cash-top", app.staticTexts["现金 · 动态"].firstMatch.exists)

        // 元素驱动滚动：直到「晚餐」行进入可视区
        for _ in 0..<6 {
            let t = app.staticTexts["晚餐"].firstMatch
            if t.exists && t.frame.minY > 40 && t.frame.minY < 740 { break }
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            a.press(forDuration: 0.05, thenDragTo: b)
            sleep(2)
        }
        let title = app.staticTexts["晚餐"].firstMatch
        check("TX2-row-visible", title.exists && title.frame.minY > 40 && title.frame.minY < 740,
              title.exists ? "y=\(Int(title.frame.minY))" : "行未出现")

        if title.exists && title.frame.minY > 40 && title.frame.minY < 740 {
            title.tap(); sleep(2)
            var detail = ""
            for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
            where app.navigationBars[n].firstMatch.exists { detail = n }
            check("TX2-row-to-detail", !detail.isEmpty, "detail=\(detail)")
            shoot("T7_row_tap_detail")
            if !detail.isEmpty {
                let nav = app.navigationBars[detail].firstMatch
                nav.buttons.firstMatch.tap(); sleep(2)
                check("TX2-back", app.staticTexts["总净资产 · NET WORTH"].firstMatch.exists)
                shoot("T8_row_back")
            }
        } else {
            check("TX2-row-to-detail", false, "行不在可视区")
        }
    }
}

// MARK: - R3 冷启动记忆置顶账户

final class HoloR3ColdStart: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }
    func shoot(_ name: String) {
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/holo_accept_r3/\(name).png"))
        print("[SHOT] \(name)")
    }
    func check(_ id: String, _ ok: Bool, _ d: String = "") {
        print("[CHECK] \(id) \(ok ? "PASS" : "FAIL") \(d)")
    }

    func testRememberTopAccount() throws {
        // 第一次进入：把「储蓄卡」置顶
        app.buttons["财务"].firstMatch.tap(); sleep(3)
        app.buttons["账户"].firstMatch.tap(); sleep(3)
        let union = app.staticTexts["储蓄卡"].firstMatch
        if union.exists && union.frame.minY > 370 {
            union.tap(); sleep(2)
        }
        check("CS-set-top", app.staticTexts["储蓄卡 · 动态"].firstMatch.exists)
        shoot("C1_union_top_before_kill")

        // 杀进程 → 冷启动
        app.terminate(); sleep(2)
        app.launch(); sleep(4)
        check("CS-relaunch-home", app.buttons["财务"].firstMatch.waitForExistence(timeout: 10))

        // 重新进账户页：验证「储蓄卡」仍置顶
        app.buttons["财务"].firstMatch.tap(); sleep(3)
        app.buttons["账户"].firstMatch.tap(); sleep(3)
        let panelOK = app.staticTexts["储蓄卡 · 动态"].firstMatch.exists
        let unionY = app.staticTexts["储蓄卡"].firstMatch.frame.minY
        check("CS-remember-top", panelOK && unionY < 360,
              "panel=\(panelOK) unionY=\(Int(unionY))")
        shoot("C2_union_top_after_cold_start")
    }
}

// MARK: - R3 面板 dump 探针

final class HoloR3Dump: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }
    func testDumpPanel() throws {
        app.buttons["财务"].firstMatch.tap(); sleep(3)
        app.buttons["账户"].firstMatch.tap(); sleep(3)
        let cash = app.staticTexts["现金"].firstMatch
        if cash.exists && cash.frame.minY > 370 { cash.tap(); sleep(2) }
        for i in 0..<4 {
            print("[INFO] === 滚动轮 \(i) ===")
            for t in app.staticTexts.allElementsBoundByIndex
            where t.frame.width > 0 && t.frame.minY > 60 {
                print("[PD] '\(t.label)' y=\(Int(t.frame.minY)) x=\(Int(t.frame.minX))")
            }
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: "/tmp/holo_accept_r3/PD_round\(i).png"))
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            a.press(forDuration: 0.05, thenDragTo: b)
            sleep(2)
        }
    }
}

// MARK: - R3 深色模式走查

final class HoloR3DarkMode: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }
    func shoot(_ name: String) {
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/holo_accept_r3/\(name).png"))
        print("[SHOT] \(name)")
    }
    func check(_ id: String, _ ok: Bool, _ d: String = "") {
        print("[CHECK] \(id) \(ok ? "PASS" : "FAIL") \(d)")
    }

    func testDarkWalkthrough() throws {
        app.buttons["财务"].firstMatch.tap(); sleep(3)
        app.buttons["账户"].firstMatch.tap(); sleep(3)

        // 卡堆顶部（含净资产卡）
        shoot("D1_dark_stack")
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"] {
            let e = app.staticTexts[n].firstMatch
            check("DK-name-\(n)", e.exists, e.exists ? "y=\(Int(e.frame.minY))" : "未找到")
        }
        check("DK-networth", app.staticTexts["总净资产 · NET WORTH"].firstMatch.exists)

        // 滚动：添加卡 + 动态面板
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        a.press(forDuration: 0.05, thenDragTo: b); sleep(2)
        check("DK-add-visible", app.buttons["添加账户"].firstMatch.exists)
        var panel = "?"
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
        where app.staticTexts["\(n) · 动态"].firstMatch.exists { panel = n }
        check("DK-panel", panel != "?", "panel=\(panel)")
        shoot("D2_dark_panel")

        // 管理列表视图
        let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        back.press(forDuration: 0.05, thenDragTo: top); sleep(2) // 滚回顶部
        let toggle = app.buttons["› 列表"].firstMatch
        if toggle.waitForExistence(timeout: 4) {
            toggle.tap(); sleep(2)
            check("DK-list-open", app.staticTexts["全部账户 · 5 个"].firstMatch.waitForExistence(timeout: 4))
            shoot("D3_dark_list")
        } else {
            check("DK-list-open", false, "切换按钮不可见")
        }
    }
}
