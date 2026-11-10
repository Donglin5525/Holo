//
//  RefundEntryWalkthroughUITests.swift
//  HoloUITests
//
//  退款编辑层 9-26 改版冒烟（键盘组件抽取后全链回归）：
//  1. 记一笔 ¥100 支出（共用键盘组件在记账页回归：keypad.* 可命中）
//  2. 长按该支出 → 记退款 → 点金额行唤起计算键盘（共用组件 identifier 复用）
//  3. 断言全额 chip / 备注输入框存在
//  4. 表达式 50-20 → ✓ 两段式（先折算 30，再点一次保存）→ 退款笔落库（账本出现退款徽章）
//  5. 点退款笔 → 「编辑退款」层回显
//  另：test_keypadTwoPhaseConfirm 覆盖 10-10 ✓ 键两段式改版（表达式先求值、纯数字才保存）。
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

    /// 金额显示控件：identifier 在 Button 内的 Text 上，AX 树会被提升为
    /// Button 元素的 identifier，故用 any 类型兜底查询
    private func amountDisplay(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier).firstMatch
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

        // ✓ = 纯数字 100 直接确认保存（两段式下无运算符一次即存）
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

        // ── 4. 表达式 50-20 → ✓ 两段式确认（先折算成结果，再点一次才保存）──
        key("AC").tap()
        key("5").tap(); key("0").tap()
        key("-").tap()
        key("2").tap(); key("0").tap()
        // 金额行显示表达式串
        XCTAssertTrue(element(labelContains: "50-20").waitForExistence(timeout: 3),
                      "金额行回显表达式 50-20")
        // ✓ 第一次：只求值回填（¥ 30），弹层不关、键盘仍在
        app.buttons["transactionSheet.keypadConfirm"].firstMatch.tap()
        let refundAmount = amountDisplay("refundSheet.amountDisplay")
        XCTAssertTrue(refundAmount.waitForExistence(timeout: 3), "退款金额显示控件存在")
        // label 是「退款金额、¥ 30」（行标签与金额合成），用后缀断言
        XCTAssertTrue(refundAmount.label.hasSuffix("¥ 30"),
                      "第一次 ✓ 只求值：50-20 折算为 30（实际 label=\(refundAmount.label)）")
        XCTAssertTrue(key("5").exists, "第一次 ✓ 不保存：键盘仍在（弹层未关）")
        // ✓ 第二次：纯数字确认保存
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

    /// ✓ 键两段式（10-10）：表达式第一次点只折算成结果，第二次点纯数字才完成记账
    func test_keypadTwoPhaseConfirm_expressionResolvesBeforeSave() throws {
        // ── 进财务 → FAB 记账 ──
        let financeTab = app.buttons["财务"].firstMatch
        XCTAssertTrue(financeTab.waitForExistence(timeout: 10), "财务入口存在")
        for _ in 0..<4 where !financeTab.isHittable { sleep(2) }
        financeTab.tap()
        sleep(3)

        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        if !fab.waitForExistence(timeout: 12) {
            dumpHierarchy("afterFinanceTap")
        }
        XCTAssertTrue(fab.exists, "记账 FAB 存在")
        fab.tap()
        XCTAssertTrue(key("3").waitForExistence(timeout: 8), "记账键盘默认弹出")

        // 输入表达式 3+4
        key("3").tap()
        app.buttons["keypad.+"].firstMatch.tap()
        key("4").tap()

        // 分类先选好（餐饮→午餐），保证第二次 ✓ 能走通保存
        let dining = app.buttons["餐饮"].firstMatch
        XCTAssertTrue(dining.waitForExistence(timeout: 6), "预设一级分类存在")
        dining.tap()
        let lunch = app.buttons["午餐"].firstMatch
        XCTAssertTrue(lunch.waitForExistence(timeout: 6), "二级分类存在")
        lunch.tap()

        // 表达式回显在金额行
        let txnAmount = amountDisplay("transactionSheet.amountDisplay")
        XCTAssertTrue(txnAmount.waitForExistence(timeout: 3), "金额显示控件存在")
        XCTAssertTrue(txnAmount.label.hasSuffix("3+4"), "金额行回显表达式 3+4（实际 label=\(txnAmount.label)）")

        // ✓ 第一次：只求值（3+4 → 7），不保存——键盘仍在、金额行变结果
        app.buttons["transactionSheet.keypadConfirm"].firstMatch.tap()
        XCTAssertTrue(txnAmount.waitForExistence(timeout: 3), "求值后金额显示控件仍在")
        XCTAssertTrue(txnAmount.label.hasSuffix("¥ 7"), "第一次 ✓ 把 3+4 折算为 7（实际 label=\(txnAmount.label)）")
        XCTAssertTrue(key("5").exists, "第一次 ✓ 不触发保存：记账页未关、键盘仍在")

        // ✓ 第二次：纯数字确认 → 保存成功落库
        app.buttons["transactionSheet.keypadConfirm"].firstMatch.tap()
        let savedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '¥7'")).firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 8), "第二次 ✓ 完成记账：账本出现 ¥7 交易行")
    }

    // MARK: - 手动记收入退款引导（11-10 拍板批次，原型 docs/design/2026-11-10-记一笔退款引导-原型.html）

    /// 唯一名称串：候选匹配只认本测试造的原支出，防历史数据误命中
    private var uniqueName: String {
        "RGU" + String(Int(Date().timeIntervalSince1970) % 100_000)
    }

    /// 记一笔支出（键盘唤起 → 金额 → 名称 → 餐饮/午餐 → 保存），返回唯一名称
    @discardableResult
    private func recordExpense(name: String, amountKeys: [String]) throws {
        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 8), "记账 FAB 存在")
        fab.tap()

        let amountDisplayEl = amountDisplay("transactionSheet.amountDisplay")
        XCTAssertTrue(amountDisplayEl.waitForExistence(timeout: 6), "金额显示控件存在")
        amountDisplayEl.tap()  // 11-09 改版：打开默认收起，点金额行唤起键盘
        for k in amountKeys { key(k).tap() }

        let nameField = app.textFields["名称"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 6), "名称输入框存在")
        nameField.tap()
        nameField.typeText(name)

        let dining = app.buttons["餐饮"].firstMatch
        XCTAssertTrue(dining.waitForExistence(timeout: 6), "一级分类「餐饮」存在")
        dining.tap()
        let lunch = app.buttons["午餐"].firstMatch
        XCTAssertTrue(lunch.waitForExistence(timeout: 6), "二级分类「午餐」存在")
        lunch.tap()

        app.buttons["transactionSheet.saveButton"].firstMatch.tap()
        sleep(2)
    }

    /// 全链：原支出 → 记收入名称带「退货」→ 提示条 → 弹层选候选 → 确认卡+金额带出 →
    /// 保存 → 原支出带「已退」徽章
    func test_manualIncomeRefundGuide_pick_link_save() throws {
        let name = uniqueName
        try enterFinance()
        try recordExpense(name: name, amountKeys: ["8", "8"])

        // 记收入：名称 = 原支出名 + 「退货」触发退款语义
        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 8), "FAB 再次可用")
        fab.tap()

        let incomeSegment = app.buttons["transactionSheet.incomeSegment"].firstMatch
        XCTAssertTrue(incomeSegment.waitForExistence(timeout: 6), "收入分段存在")
        incomeSegment.tap()
        // 收入域标志：宫格切到收入分类（防「收入」label 误中被遮元素、段没切过去）
        XCTAssertTrue(app.buttons["工资收入"].firstMatch.waitForExistence(timeout: 6),
                      "切收入后宫格出现收入分类")

        let nameField = app.textFields["名称"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 6), "名称输入框存在")
        nameField.tap()
        nameField.typeText("\(name)退货")

        // ── 提示条出现 ──
        let pickButton = app.descendants(matching: .any)
            .matching(identifier: "refundGuide.pickButton").firstMatch
        if !pickButton.waitForExistence(timeout: 5) {
            dumpHierarchy("afterRefundNameTyped")
        }
        XCTAssertTrue(pickButton.exists, "名称带退款词后提示条出现（选择原支出按钮）")

        // ── 弹层：搜索框 + 候选行 + 降级出口 ──
        pickButton.tap()
        let searchField = app.textFields.matching(identifier: "refundPicker.searchField").firstMatch
        if !searchField.waitForExistence(timeout: 8) {
            dumpHierarchy("afterPickButtonTap")
        }
        XCTAssertTrue(searchField.exists, "候选弹层打开（搜索框）")
        XCTAssertTrue(app.buttons["refundPicker.declineButton"].firstMatch.exists, "降级出口存在")

        let candidateRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'refundPicker.row' AND label CONTAINS %@", name))
            .firstMatch
        if !candidateRow.waitForExistence(timeout: 8) {
            dumpHierarchy("candidateList")
        }
        XCTAssertTrue(candidateRow.exists, "推荐候选出现原支出（\(name)）")
        candidateRow.tap()

        // ── 确认卡 + 金额带出（金额未填时自动填可退余额 88）──
        let linkedCard = element(labelContains: "将关联原支出")
        XCTAssertTrue(linkedCard.waitForExistence(timeout: 6), "确认卡出现（将关联原支出）")
        let incomeAmount = amountDisplay("transactionSheet.amountDisplay")
        XCTAssertTrue(incomeAmount.waitForExistence(timeout: 4), "金额显示存在")
        XCTAssertTrue(incomeAmount.label.hasSuffix("88"), "金额自动带出可退余额 88（实际 label=\(incomeAmount.label)）")

        // ── 保存：退款笔落库，原支出带「已退」徽章 ──
        app.buttons["transactionSheet.saveButton"].firstMatch.tap()
        let refundedBadge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '已退'")).firstMatch
        XCTAssertTrue(refundedBadge.waitForExistence(timeout: 10), "原支出出现「已退」徽章（退款笔落库）")
    }

    /// 降级出口：弹层点「没找到，直接按普通收入记录」→ 提示条收起不再骚扰
    func test_manualIncomeRefundGuide_declineHidesHint() throws {
        try enterFinance()

        let fab = app.buttons["finance.fab.addTransaction"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 8), "记账 FAB 存在")
        fab.tap()

        let incomeSegment = app.buttons["transactionSheet.incomeSegment"].firstMatch
        XCTAssertTrue(incomeSegment.waitForExistence(timeout: 6), "收入分段存在")
        incomeSegment.tap()
        // 收入域标志：宫格切到收入分类（防「收入」label 误中被遮元素、段没切过去）
        XCTAssertTrue(app.buttons["工资收入"].firstMatch.waitForExistence(timeout: 6),
                      "切收入后宫格出现收入分类")

        let nameField = app.textFields["名称"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 6), "名称输入框存在")
        nameField.tap()
        nameField.typeText("退货")
        XCTAssertEqual(nameField.value as? String ?? "", "退货", "名称框已输入触发词（实际=\(nameField.value ?? "nil")）")

        // 提示条查询用 any 兜底（SwiftUI identifier 在 AX 树提升后元素类型不一定是 button，存量同坑）
        let pickButton = app.descendants(matching: .any)
            .matching(identifier: "refundGuide.pickButton").firstMatch
        if !pickButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(element(labelContains: "看起来是退款").exists,
                          "提示条存在但按钮标识不可见")
            dumpHierarchy("hintBarButNoButtonID")
        }
        XCTAssertTrue(pickButton.exists, "提示条出现")
        pickButton.tap()

        let decline = app.buttons["refundPicker.declineButton"].firstMatch
        XCTAssertTrue(decline.waitForExistence(timeout: 8), "候选弹层打开（降级出口存在）")
        decline.tap()

        let hintGone = NSPredicate(format: "exists == 0")
        expectation(for: hintGone, evaluatedWith: pickButton)
        waitForExpectations(timeout: 6)
        XCTAssertFalse(pickButton.exists, "降级后提示条收起")
    }

    /// 进财务模块（首页→财务 tab，球体动画期间等待可命中）
    private func enterFinance() throws {
        let financeTab = app.buttons["财务"].firstMatch
        XCTAssertTrue(financeTab.waitForExistence(timeout: 10), "财务入口存在")
        for _ in 0..<4 where !financeTab.isHittable { sleep(2) }
        financeTab.tap()
        sleep(3)
    }
}
