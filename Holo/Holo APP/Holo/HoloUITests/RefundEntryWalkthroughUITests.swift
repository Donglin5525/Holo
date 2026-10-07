//
//  RefundEntryWalkthroughUITests.swift
//  HoloUITests
//
//  退款编辑层 9-26 改版冒烟（键盘组件抽取后全链回归）：
//  1. 记一笔 ¥100 支出（共用键盘组件在记账页回归：keypad.* 可命中）
//  2. 长按该支出 → 记退款 → 点金额行唤起计算键盘（共用组件 identifier 复用）
//  3. 断言全额 chip / 备注输入框存在
//  4. 表达式 50-20 → ✓ 保存 → 退款笔落库（账本出现退款徽章）
//  5. 点退款笔 → 「编辑退款」层回显
//  宽屏详情面板的退款摘要行→列表→编辑链路为 iPad 双栏路径，不在本冒烟范围。
//

import XCTest

final class RefundEntryWalkthroughUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        skipOnboardingIfNeeded()
    }

    private func skipOnboardingIfNeeded() {
        let skip = app.buttons["跳过引导"].firstMatch
        if skip.waitForExistence(timeout: 8) {
            skip.tap()
            sleep(1)
        }
    }

    private func key(_ k: String) -> XCUIElement {
        app.buttons["keypad.\(k)"].firstMatch
    }

    /// label CONTAINS 兜底匹配（任意元素类型）
    private func element(labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// 失败诊断：打印当前可见按钮/文本，定位卡在哪一屏
    private func dumpHierarchy(_ tag: String) {
        print("[DUMP] ===== \(tag) =====")
        for b in app.buttons.allElementsBoundByIndex where b.exists {
            print("[DUMP] button | \(b.identifier) | \(b.label.prefix(30))")
        }
        for t in app.staticTexts.allElementsBoundByIndex where t.exists {
            print("[DUMP] text | \(t.label.prefix(40))")
        }
    }

    func test_refundEntry_keypadFullRemark_expressionSave_andReopen() throws {
        // ── 1. 进财务记一笔 ¥100（共用键盘组件回归）──
        let financeTab = app.buttons["财务"].firstMatch
        XCTAssertTrue(financeTab.waitForExistence(timeout: 10), "财务入口存在")
        // 新首页球体入场动画期间 hit test 可能落空，等可命中再点
        for _ in 0..<4 where !financeTab.isHittable { sleep(2) }
        financeTab.tap()
        sleep(3)

        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        if !fab.waitForExistence(timeout: 12) {
            dumpHierarchy("afterFinanceTap")
        }
        XCTAssertTrue(fab.exists, "记账 FAB 存在")
        fab.tap()

        XCTAssertTrue(key("1").waitForExistence(timeout: 8), "记账键盘默认弹出（共用组件）")
        key("1").tap(); key("0").tap(); key("0").tap()

        // 分类：一级「餐饮」下钻二级「午餐」（新装预设种子）。
        // 精确 label 匹配——CONTAINS 会误中 sheet 底下被遮的账本交易行（not hittable）
        let dining = app.buttons["餐饮"].firstMatch
        XCTAssertTrue(dining.waitForExistence(timeout: 6), "预设一级分类存在")
        dining.tap()
        let lunch = app.buttons["午餐"].firstMatch
        XCTAssertTrue(lunch.waitForExistence(timeout: 6), "二级分类存在")
        lunch.tap()

        // ✓ = 求值并保存（薄壳化后行为不变）
        app.buttons["transactionSheet.keypadConfirm"].firstMatch.tap()

        // ── 2. 回账本，长按今天的支出 → 记退款 ──
        // 行按钮 label 由内容拼成（「午餐、¥100.00」）；账本行 isHittable 大面积误报（G1 在档），
        // 一律走坐标 press 不检查 hittable
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '¥100'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "账本出现 ¥100 交易行")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.5)
        sleep(2)

        var recordRefund = app.buttons["记退款"].firstMatch
        if !recordRefund.exists {
            dumpHierarchy("afterLongPress")
        }
        XCTAssertTrue(recordRefund.waitForExistence(timeout: 6), "长按菜单出现「记退款」")
        recordRefund.tap()

        // ── 3. 退款编辑层：键盘默认收起，点金额行唤起 ──
        let amountRow = element(labelContains: "退款金额")
        XCTAssertTrue(amountRow.waitForExistence(timeout: 8), "退款金额行存在")
        XCTAssertFalse(key("5").exists, "键盘默认收起")
        amountRow.tap()
        XCTAssertTrue(key("5").waitForExistence(timeout: 6), "点击金额行唤起计算键盘（共用组件）")

        // 全额 chip（默认预填全额 ¥100.00，chip 文案含「全额」）
        let fullChip = element(labelContains: "全额")
        XCTAssertTrue(fullChip.waitForExistence(timeout: 4), "全额快捷 chip 存在")

        // 备注输入框（placeholder 选填）
        let remarkField = app.textFields["选填"].firstMatch
        XCTAssertTrue(remarkField.waitForExistence(timeout: 4), "备注输入框存在")

        // ── 4. 表达式 50-20 → ✓ 保存 ──
        key("AC").tap()
        key("5").tap(); key("0").tap()
        key("-").tap()
        key("2").tap(); key("0").tap()
        // 金额行显示表达式串
        XCTAssertTrue(element(labelContains: "50-20").waitForExistence(timeout: 3),
                      "金额行回显表达式 50-20")
        // ✓ 键 identifier 特判为 transactionSheet.keypadConfirm（共用组件沿用）
        app.buttons["transactionSheet.keypadConfirm"].firstMatch.tap()

        // 保存成功 → 弹层关闭 → 账本出现退款笔（徽章「退款」）
        let refundBadge = element(labelContains: "退款")
        XCTAssertTrue(refundBadge.waitForExistence(timeout: 8), "退款笔落库（账本可见退款标识）")

        // ── 5. 点退款笔 → 编辑退款层回显 ──
        // 退款行金额 ¥30.00（CONTAINS '30' 会误中日期等文本）；坐标 tap 防 hittable 误报
        let refundRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '¥30'")).firstMatch
        XCTAssertTrue(refundRow.waitForExistence(timeout: 6), "退款金额 ¥30 可见")
        refundRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let editTitle = element(labelContains: "编辑退款")
        if !editTitle.waitForExistence(timeout: 8) {
            dumpHierarchy("afterRefundRowTap")
        }
        XCTAssertTrue(editTitle.exists, "点退款笔进入编辑退款层")
    }
}
