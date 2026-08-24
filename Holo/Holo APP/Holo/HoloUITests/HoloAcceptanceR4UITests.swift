//
//  HoloAcceptanceR4UITests.swift
//  Holo
//
//  第四轮验收：A) 账户页/详情页顶部黑块修复（背景贯穿导航栏）
//             B) push 转场卡顿修复（账单卡查库下沉）
//  仅测试基础设施，不修改 App 功能代码。
//  录屏拆帧由外部完成，本测试负责驱动交互与打点。
//

import XCTest

final class HoloAcceptanceR4UITests: XCTestCase {

    var app: XCUIApplication!
    static var prefix: String {
        ProcessInfo.processInfo.environment["R4_PREFIX"] ?? "L"
    }
    static var dir: String {
        ProcessInfo.processInfo.environment["R4_SHOT_DIR"] ?? "/tmp/holo_accept_r4/shots"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    var p: String { Self.prefix }

    func mark(_ s: String) {
        // mach 时间与 unix 时间都打，供录屏对齐
        print("[R4MARK][\(p)] \(s) unix=\(Date().timeIntervalSince1970)")
    }

    func shoot(_ name: String, settle: UInt32 = 0) {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(p)_\(name).png"))) != nil
        print("[R4SHOT] \(p)_\(name).png ok=\(ok)")
    }

    func check(_ id: String, _ condition: Bool, _ detail: String = "") {
        print("[R4CHECK] \(id) \(condition ? "PASS" : "FAIL") \(detail)")
    }

    func drag(_ y0: CGFloat, _ y1: CGFloat, hold: TimeInterval = 0.05) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y0 / 874.0))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y1 / 874.0))
        a.press(forDuration: hold, thenDragTo: b)
    }

    func openAccountsPage() {
        mark("nav-finance-tap")
        let finance = app.buttons["财务"]
        if finance.waitForExistence(timeout: 15) {
            finance.tap()
        } else {
            mark("nav-finance-NOT-FOUND")
            return
        }
        sleep(3)
        let accountsTab = app.buttons["账户"].firstMatch
        mark("nav-accounts-tab-tap")
        if accountsTab.waitForExistence(timeout: 8) {
            accountsTab.tap()
            sleep(3)
        } else {
            mark("nav-accounts-tab-NOT-FOUND")
        }
        mark("nav-accounts-entered")
    }

    /// 滚动直到某元素可视（返回是否成功）
    @discardableResult
    func scrollTo(_ el: XCUIElement, rounds: Int = 6) -> Bool {
        for _ in 0..<rounds {
            if el.exists && el.isHittable && el.frame.minY > 60 && el.frame.minY < 740 { return true }
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            a.press(forDuration: 0.05, thenDragTo: b)
            sleep(2)
        }
        return el.exists && el.frame.minY > 60 && el.frame.minY < 740
    }

    func scrollTop() {
        for _ in 0..<6 {
            if app.staticTexts["总净资产 · NET WORTH"].firstMatch.isHittable { return }
            let c = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            let t = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            c.press(forDuration: 0.05, thenDragTo: t)
            sleep(2)
        }
    }

    /// 把指定账户卡置顶（复用 R3 逻辑）
    func bringToTop(_ name: String) {
        let e = app.staticTexts[name].firstMatch
        guard e.exists else { return }
        if e.frame.minY < 360 {
            if let other = ["微信", "支付宝", "储蓄卡", "现金", "信用卡"]
                .first(where: { $0 != name && app.staticTexts[$0].firstMatch.exists && app.staticTexts[$0].firstMatch.frame.minY > 370 && app.staticTexts[$0].firstMatch.frame.minY < 720 }) {
                app.staticTexts[other].firstMatch.tap()
                sleep(2)
            }
        }
        let e2 = app.staticTexts[name].firstMatch
        if e2.exists && e2.frame.minY >= 370 {
            e2.tap()
            sleep(2)
        }
    }

    var topPanel: String {
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
        where app.staticTexts["\(n) · 动态"].firstMatch.exists { return n }
        return "?"
    }

    /// 点「查看全部交易 ›」push 详情页，返回 nav 标题
    func pushDetail() -> String {
        let seeAll = app.buttons["查看全部交易 ›"].firstMatch.exists
            ? app.buttons["查看全部交易 ›"].firstMatch
            : app.staticTexts["查看全部交易 ›"].firstMatch
        guard seeAll.exists else { return "" }
        seeAll.tap()
        sleep(2)
        for n in ["现金", "微信", "支付宝", "储蓄卡", "信用卡"]
        where app.navigationBars[n].firstMatch.exists { return n }
        return ""
    }

    func popBack() {
        let nav = app.navigationBars.firstMatch
        if nav.exists {
            nav.buttons.firstMatch.tap()
            sleep(2)
        }
    }

    // MARK: - Test 1: 冷启动 → 账户页（黑块扫描段 1）

    func test01ColdNavAccounts() throws {
        mark("T1-launch-start")
        app.launch()
        mark("T1-launched")
        sleep(2)
        openAccountsPage()
        sleep(4) // 停留，覆盖黑块出现窗口（约1s）
        mark("T1-settle-end")
        shoot("T1_accounts_settled", settle: 1)
        check("T1-accounts-reached", app.staticTexts["总净资产 · NET WORTH"].firstMatch.exists)
    }

    // MARK: - Test 2: 5×push/pop + 详情页驻留滚动 + 账单卡回归

    func test02Transitions() throws {
        app.launch()
        sleep(2)
        openAccountsPage()

        // 信用卡置顶 → push 进的就是信用卡详情页（账单卡回归可同时验证）
        bringToTop("信用卡")
        check("T2-cc-top", app.staticTexts["信用卡 · 动态"].firstMatch.exists)

        // 滚到面板，露出「查看全部交易 ›」
        let seeAll = app.buttons["查看全部交易 ›"].firstMatch.exists
            ? app.buttons["查看全部交易 ›"].firstMatch
            : app.staticTexts["查看全部交易 ›"].firstMatch
        let found = scrollTo(seeAll)
        check("T2-seeall-visible", found)
        shoot("T2_panel_before_push", settle: 1)

        // ---- 5 次 push/pop ----
        var titles: [String] = []
        for i in 1...5 {
            mark("T2-push-\(i)-start")
            let t = pushDetail()
            titles.append(t)
            mark("T2-push-\(i)-end")
            sleep(1)
            if i < 5 {
                mark("T2-pop-\(i)-start")
                popBack()
                mark("T2-pop-\(i)-end")
                sleep(1)
                // 回来后重新滚到查看全部（布局可能复位）
                scrollTo(seeAll, rounds: 3)
            }
        }
        check("T2-push-title", titles.allSatisfy { $0 == "信用卡" }, "titles=\(titles)")

        // ---- 详情页驻留 + 滚动（最后一次 push 留在详情页） ----
        mark("T2-detail-stay-start")
        shoot("T2_detail_top", settle: 1)
        for r in 1...3 {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            a.press(forDuration: 0.05, thenDragTo: b)
            sleep(2)
            shoot("T2_detail_scrolldown_r\(r)", settle: 0)
            let c = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let d = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            c.press(forDuration: 0.05, thenDragTo: d)
            sleep(2)
        }
        mark("T2-detail-stay-end")
        shoot("T2_detail_after_scroll", settle: 1)

        // ---- 回归：信用卡账单信息卡数据 ----
        // 滚回详情页顶部再滚到账单卡
        for _ in 0..<6 {
            if app.staticTexts["账单信息"].firstMatch.exists
                && app.staticTexts["账单信息"].firstMatch.frame.minY > 60
                && app.staticTexts["账单信息"].firstMatch.frame.minY < 740 { break }
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            a.press(forDuration: 0.05, thenDragTo: b)
            sleep(2)
        }
        let stmtCard = app.staticTexts["账单信息"].firstMatch
        check("T2-stmt-card-exists", stmtCard.exists && stmtCard.frame.minY > 60 && stmtCard.frame.minY < 740,
              stmtCard.exists ? "y=\(Int(stmtCard.frame.minY))" : "未找到")
        check("T2-stmt-cycle-text", app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*月.*日.*账单周期|.*[0-9]{2}\\.[0-9]{2}.*")).firstMatch.exists
              || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "月")).firstMatch.exists)
        check("T2-stmt-due", app.staticTexts["距还款日"].firstMatch.exists)
        check("T2-stmt-limit", app.staticTexts["可用额度"].firstMatch.exists)
        // 金额：找 ¥ 数字大字
        let amountOK = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9,]+\\.[0-9]{2}$")).firstMatch.exists
        check("T2-stmt-amount", amountOK)
        shoot("T2_stmt_card", settle: 1)

        // ---- 返回，换普通账户（现金）详情回归 ----
        popBack()
        bringToTop("现金")
        check("T2-cash-top", app.staticTexts["现金 · 动态"].firstMatch.exists)
        let seeAll2 = app.buttons["查看全部交易 ›"].firstMatch.exists
            ? app.buttons["查看全部交易 ›"].firstMatch
            : app.staticTexts["查看全部交易 ›"].firstMatch
        scrollTo(seeAll2, rounds: 4)
        mark("T2-cash-push-start")
        let t = pushDetail()
        check("T2-cash-detail", t == "现金", "title=\(t)")
        shoot("T2_cash_detail", settle: 1)
        check("T2-cash-no-stmt-card", !app.staticTexts["账单信息"].firstMatch.exists, "普通账户不应有账单卡")
        check("T2-cash-month-summary", app.staticTexts["本月收支"].firstMatch.exists
              || app.staticTexts["收入"].firstMatch.exists)
        mark("T2-all-end")
    }
}

// MARK: - Test 3: 账单信息卡完整字段回归（补数据后）

extension HoloAcceptanceR4UITests {
    func test03BillCardFields() throws {
        app.launch()
        sleep(2)
        openAccountsPage()
        bringToTop("信用卡")
        check("T3-cc-top", app.staticTexts["信用卡 · 动态"].firstMatch.exists)
        let seeAll = app.buttons["查看全部交易 ›"].firstMatch.exists
            ? app.buttons["查看全部交易 ›"].firstMatch
            : app.staticTexts["查看全部交易 ›"].firstMatch
        scrollTo(seeAll, rounds: 6)
        mark("T3-push-start")
        let title = pushDetail()
        check("T3-detail-title", title == "信用卡", "title=\(title)")
        // 滚到账单卡完全可见
        for _ in 0..<6 {
            let card = app.staticTexts["账单信息"].firstMatch
            if card.exists && card.frame.minY > 60 && card.frame.minY < 420 { break }
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            if card.exists && card.frame.minY > 420 {
                // 向下滚过头了，反向滚回一点
                let c = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                let d = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                c.press(forDuration: 0.05, thenDragTo: d)
            } else {
                a.press(forDuration: 0.05, thenDragTo: b)
            }
            sleep(2)
        }
        // dump 卡内文本
        let texts = app.staticTexts.allElementsBoundByIndex
            .filter { $0.frame.width > 0 && $0.frame.minY > 60 }
            .map { "\($0.label)@\(Int($0.frame.minY))" }
        print("[R4DUMP] \(texts.joined(separator: " | "))")
        check("T3-due-label", app.staticTexts["距还款日"].firstMatch.exists)
        let dueVal = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ 天$|^今天$|^已逾期.*")).firstMatch
        check("T3-due-value", dueVal.exists, dueVal.exists ? dueVal.label : "未找到")
        check("T3-limit-label", app.staticTexts["可用额度"].firstMatch.exists)
        // 额度 10000 - 账单 254.20 = 9745.80
        let limitVal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "9,745")).firstMatch
            ?? app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "9745")).firstMatch
        check("T3-limit-value", limitVal.exists, limitVal.exists ? limitVal.label : "未找到(期望9,745.80)")
        check("T3-bill-day", app.staticTexts["每月 22 号"].firstMatch.exists)
        check("T3-due-day", app.staticTexts["每月 11 号"].firstMatch.exists)
        check("T3-cycle", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "账单周期")).firstMatch.exists)
        check("T3-amount", app.staticTexts["254.20"].firstMatch.exists, "本期账单金额")
        shoot("T3_bill_card_full", settle: 1)
    }
}
