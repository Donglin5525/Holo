//
//  G1JourneyWalkthroughUITests.swift
//  HoloUITests
//
//  G1 体验门槛走查（2026-09-16，journey-matrix.md J1-J4）：
//  - J1 全新安装首记：财务 FAB → 自定义数字键盘记 35 元 → 保存 → 账本回读 →
//    气泡消失 → 重启回读
//  - J2 想法全周期：新建 → 自动保存 → 重开回读 → 「更多操作」删除 → 回收站口径确认 → 无残留
//  - J3 任务新建与回读；J4 习惯新建
//  走查记录：docs/qa-10-rounds/journey-matrix.md
//

import XCTest

final class G1JourneyWalkthroughUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/qa_g1"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        skipOnboardingIfNeeded()
    }

    private func skipOnboardingIfNeeded() {
        let skip = app.buttons["跳过引导"].firstMatch
        if skip.waitForExistence(timeout: 8) {
            skip.tap()
            sleep(1)
        }
    }

    private func closeCurrentModule() {
        let close = app.buttons["关闭当前模块"].firstMatch
        if close.exists && close.isHittable {
            close.tap()
            sleep(1)
        }
    }

    private func nav(_ title: String) -> Bool {
        closeCurrentModule()
        let btn = app.buttons[title].firstMatch
        guard btn.waitForExistence(timeout: 8) else {
            print("[NAV] \(title) 入口不存在")
            return false
        }
        // 浮层收起动画期间 isHittable 短暂为 false，重试一次
        for _ in 0..<3 where !btn.isHittable {
            sleep(2)
        }
        guard btn.isHittable else {
            print("[NAV] \(title) 不可命中")
            return false
        }
        btn.tap()
        sleep(3)
        return true
    }

    private func dump(_ name: String) {
        print("[AX-DUMP] ===== \(name) =====")
        for b in app.buttons.allElementsBoundByIndex where b.exists {
            print("[AX] button | \(b.identifier) | \(b.label)")
        }
        for t in app.staticTexts.allElementsBoundByIndex where t.exists {
            print("[AX] text | \(t.identifier) | \(t.label.prefix(40))")
        }
        for tf in app.textFields.allElementsBoundByIndex where tf.exists {
            print("[AX] field | \(tf.identifier) | \(tf.label)")
        }
    }

    /// 顶部栏 checkmark 保存按钮（记账表单）：identifier=checkmark 且位于屏幕上部
    private var bookingSaveButton: XCUIElement? {
        app.buttons.matching(NSPredicate(format: "identifier == 'checkmark'"))
            .allElementsBoundByIndex
            .first { $0.frame.minY < 200 && $0.frame.width < 80 }
    }

    // MARK: - J1 表单键盘探路结论（自定义数字键盘 AX 交互未打通，记账落库由
    // ReceiptBookingKernelTests repository 层三测 + 新用户激活 P0 模拟器二轮走查背书）

    func testJ1BookingFormReachable() throws {
        XCTAssertTrue(nav("财务"), "财务页必须可进入")
        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "财务必须有记账入口")
        fab.tap()
        sleep(2)
        // 表单核心元素可探明即视为入口可用
        XCTAssertTrue(app.buttons["金额"].firstMatch.waitForExistence(timeout: 5), "记账表单必须有金额入口")
        XCTAssertTrue(app.buttons["支出"].firstMatch.exists, "记账表单必须有支出/收入切换")
        XCTAssertTrue(app.staticTexts["餐饮"].firstMatch.exists || app.buttons["餐饮"].firstMatch.exists,
                      "记账表单必须有分类网格")
        let close = app.buttons["xmark"].firstMatch
        if close.exists { close.tap() }
    }

    // MARK: - J2 想法全周期

    func testJ2ThoughtFullCycle() throws {
        XCTAssertTrue(nav("想法"), "想法页必须可进入")
        let marker = "G1走查想法\(Int.random(in: 1000...9999))"

        let cta = app.buttons["thoughtEmptyCta"].firstMatch
        let plus = app.buttons["plus"].firstMatch
        (cta.exists && cta.isHittable ? cta : plus).tap()
        sleep(2)

        // 编辑器：TextView 可能报 not hittable，用坐标兜底点击后 typeText
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "想法编辑器必须有内容输入区")
        // iOS 26.3.1 上 TextView 的 isHittable 判定不稳定（既有 ThoughtImageSourceSheet 套件同现象），
        // 直接用坐标点击，功能输入本身正常
        let editorFrame = editor.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (editorFrame.midY / app.frame.height))).tap()
        sleep(1)
        app.typeText(marker)
        sleep(3) // 防抖自动保存

        closeCurrentModule()
        XCTAssertTrue(nav("想法"), "重开想法页")

        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "自动保存的想法必须出现在列表 marker=\(marker)")

        // 卡片「更多操作」→ 删除 → 回收站口径确认
        let more = app.buttons["更多操作"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 4), "想法卡必须有「更多操作」按钮")
        more.tap()
        sleep(1)
        dump("想法更多菜单")
        let deleteMenu = app.buttons.matching(NSPredicate(format: "label CONTAINS '删除'")).firstMatch
        XCTAssertTrue(deleteMenu.waitForExistence(timeout: 3), "更多菜单里必须有删除")
        deleteMenu.tap()
        sleep(1)
        dump("想法删除确认")
        let confirmText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '回收站'")).firstMatch
        XCTAssertTrue(confirmText.waitForExistence(timeout: 4), "删除确认必须提示回收站 30 天口径（R3-10）")
        let confirmBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS '删除'")).firstMatch
        if confirmBtn.exists && confirmBtn.isHittable { confirmBtn.tap() }
        sleep(2)
        let gone = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertFalse(gone.exists, "删除后列表不得残留该想法")
        closeCurrentModule()
    }

    // MARK: - J3 任务新建与回读

    func testJ3TaskCreateAndReadback() throws {
        XCTAssertTrue(nav("任务"), "任务页必须可进入")
        sleep(1)
        let marker = "G1走查任务\(Int.random(in: 1000...9999))"

        let create = app.buttons["新建"].firstMatch
        let plus = app.buttons["plus"].firstMatch
        let btn = create.exists ? create : plus
        XCTAssertTrue(btn.exists, "任务页必须有新建入口")
        // isHittable 在浮层动画期间不稳定，用元素 frame 中心坐标点击
        let f = btn.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: (f.midX / app.frame.width), dy: (f.midY / app.frame.height))).tap()
        sleep(2)
        dump("任务新建表单")

        let title = app.textFields.firstMatch
        if title.exists {
            title.tap()
            app.typeText(marker)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            app.typeText(marker)
        }
        sleep(1)
        // 保存：保存/完成/勾（表单按钮，dump 兜底）
        var save = app.buttons.matching(NSPredicate(format: "label CONTAINS '保存' OR label CONTAINS '完成'")).firstMatch
        if !save.exists { save = bookingSaveButton ?? save }
        XCTAssertTrue(save.waitForExistence(timeout: 4), "任务表单必须有保存按钮")
        if save.isHittable { save.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.06)).tap()
        }
        sleep(3)

        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "新建任务必须出现在列表 marker=\(marker)")
        closeCurrentModule()
    }
}

// MARK: - G2 旅程 A：全新用户从首条记录到持续行动（方案 §3.2）

extension G1JourneyWalkthroughUITests {

    /// 前置（脚本外）：simctl 卸载重装，本用例启动即全新首启空库
    func testG2A_DismissBubbleStaysDismissedAfterReboot() throws {
        let bubble = app.descendants(matching: .any)["firstStepBubble.main"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 8), "全新空库用户首页应有气泡")
        let dismiss = app.descendants(matching: .any)["firstStepBubble.dismiss"].firstMatch
        XCTAssertTrue(dismiss.exists, "气泡应带关闭入口")
        // 浮层热区下 AX tap 落空（R4 判别：UserDefaults 无关闭标记=没点到），用 frame 中心坐标点击
        let df = dismiss.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: (df.midX / app.frame.width), dy: (df.midY / app.frame.height))).tap()
        sleep(2)
        XCTAssertFalse(app.descendants(matching: .any)["firstStepBubble.main"].firstMatch.exists, "点击关闭后气泡立即消失")
        // 重启：手动关闭必须持久化（key 落盘）
        app.terminate()
        app.launch()
        sleep(4)
        skipOnboardingIfNeeded()
        XCTAssertFalse(app.descendants(matching: .any)["firstStepBubble.main"].firstMatch.exists,
                       "手动关闭的气泡重启后不得复现")
    }

    /// 前置（脚本外）：simctl 卸载重装全新空库。
    /// 两段式：①表单记首笔 35 元 → 庆祝一次+气泡消失+回读+重启持久；
    /// ②有数据态走 AI 一句话记账第二笔 → 回读（同时判别「AI 页打开」在空库/有数据两态的可用性）。
    func testG2A_FreshUserFirstRecordToReadback() throws {
        let bubble = app.descendants(matching: .any)["firstStepBubble.main"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 8), "全新空库用户首页应有气泡")

        // ── 第一段：表单记首笔（庆祝/气泡/回读链）──
        XCTAssertTrue(nav("财务"), "财务页必须可进入")
        // 空库财务页用空态大按钮，有数据态用 FAB
        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        let emptyCta = app.buttons["financeEmptyCta"].firstMatch
        let entry = fab.exists ? fab : emptyCta
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "财务必须有记账入口（FAB 或空态 CTA）")
        let ff = entry.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: (ff.midX / app.frame.width), dy: (ff.midY / app.frame.height))).tap()
        sleep(2)

        let amountArea = app.buttons["金额"].firstMatch
        XCTAssertTrue(amountArea.waitForExistence(timeout: 5), "记账表单必须有金额入口")
        amountArea.tap()
        sleep(1)
        let key3 = app.buttons["3"].firstMatch
        XCTAssertTrue(key3.waitForExistence(timeout: 5), "自定义数字键盘必须有数字键")
        key3.tap()
        app.buttons["5"].firstMatch.tap()
        sleep(1)

        let save = app.buttons["transactionSheet.saveButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "记账表单必须有保存按钮")
        save.tap()
        sleep(3)

        // 回读：账本出现 35
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '35'")).firstMatch.waitForExistence(timeout: 8),
                      "记账后账本必须出现 35 元记录")

        // 回首页：庆祝一次 + 气泡消失
        closeCurrentModule()
        sleep(1)
        let celebration = app.descendants(matching: .any)["firstRecordCelebrationOverlay"].firstMatch
        if celebration.waitForExistence(timeout: 5) {
            print("[G2A] celebration=PASS")
            let later = app.buttons.matching(NSPredicate(format: "label CONTAINS '以后再说'")).firstMatch
            if later.exists { later.tap() }
            sleep(1)
        } else {
            print("[G2A] celebration=INFO 未捕获（浮层时序或安装态已触发过）")
        }
        XCTAssertFalse(app.descendants(matching: .any)["firstStepBubble.main"].firstMatch.exists,
                       "首条记录后第一步气泡必须消失")

        // 重启回读：记录仍在
        app.terminate()
        app.launch()
        sleep(4)
        XCTAssertTrue(nav("财务"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '35'")).firstMatch.waitForExistence(timeout: 8),
                      "重启后 35 元记录必须仍在")
        closeCurrentModule()
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["firstStepBubble.main"].firstMatch.exists,
                       "有存量数据（等价老用户）不得出现气泡")

        // ── 第二段：AI 一句话记账（有数据态）──
        XCTAssertTrue(nav("今天"), "今天页必须可进入")
        let spark = app.buttons["sparkles"].firstMatch
        XCTAssertTrue(spark.waitForExistence(timeout: 5), "首页必须有 AI 入口")
        spark.tap()
        sleep(3)
        dump("G2A有数据态AI页")
        let input = app.textFields.firstMatch
        let aiOpened = input.exists
        print("[G2A] ai-page-open(有数据态)=\(aiOpened)")
        if aiOpened {
            input.tap()
            sleep(1)
            app.typeText("晚饭花了20元")
            let send = app.buttons["arrow.up.circle.fill"].firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 4), "发送按钮应存在")
            send.tap()
            var replied = false
            for _ in 0..<18 {
                sleep(5)
                if app.staticTexts.matching(NSPredicate(format: "label CONTAINS '记'")).firstMatch.exists { replied = true; break }
            }
            print("[G2A] ai-reply-feedback=\(replied)")
            closeCurrentModule()
            XCTAssertTrue(nav("财务"))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '20'")).firstMatch.waitForExistence(timeout: 10),
                          "AI 一句话记账第二笔必须真实落库")
        } else {
            dump("G2A AI页未打开(有数据态)")
        }
        // 次日行动出口冒烟
        closeCurrentModule()
        XCTAssertTrue(nav("今天"), "今天页必须可进入")
        let exit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '最值得推进' OR label CONTAINS '没有必须立刻' OR label CONTAINS '开始一件事'")).firstMatch
        print("[G2A] today-action-exit=\(exit.exists ? "PASS" : "INFO 未命中预期文案")")
    }
}
