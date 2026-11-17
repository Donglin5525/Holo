//
//  GoalUIRedesignUITests.swift
//  HoloUITests
//
//  目标界面减法重设计走查（2026-11-13，01-设计规格.md §还原检查清单）：
//  1. 列表多状态：分段控件、进行中段卡片与胶囊、已完成段切换
//  2. 创建表单三类型：大输入占位、类型切换条件字段、数字提示行一键切累积型
//  3. 卡片长按菜单：标记完成/暂停/改期限/删除，暂停出「已暂停」胶囊
//  4. 详情页目标设置面板：五字段+领域行存在，改领域保存后列表卡图标块随领域变化
//  数据：launchArgument UITEST_SEED_GOAL_LIST_STATES 走 app 内
//  GoalProgressUITestSeeder.seedListStatesIfNeeded() 造五状态目标（已到期无法经 UI 造）。
//

import XCTest

final class GoalUIRedesignUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 启动与导航

    private func launchApp(seedListStates: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = seedListStates ? ["UITEST_SEED_GOAL_LIST_STATES"] : []
        app.launch()
        skipOnboardingIfNeeded(app)
        return app
    }

    private func skipOnboardingIfNeeded(_ app: XCUIApplication) {
        let skip = app.buttons["跳过引导"].firstMatch
        if skip.waitForExistence(timeout: 6) {
            skip.tap()
        }
    }

    /// 个人页「我的目标」进目标列表（入口行 accessibilityIdentifier=personal.goals）
    private func openGoalList(_ app: XCUIApplication) {
        let personal = app.buttons["个人"].firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 10), "找不到「个人」入口")
        personal.tap()
        let byId = app.buttons["personal.goals"].firstMatch
        if byId.waitForExistence(timeout: 8) {
            byId.tap()
            return
        }
        // 兜底：按行标题匹配（「我的目标，查看目标与进展」）
        let byLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的目标")).firstMatch
        XCTAssertTrue(byLabel.waitForExistence(timeout: 4), "个人页应有「我的目标」入口")
        byLabel.tap()
    }

    /// 每步截图（keepAlways，随 xcresult 保存）
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 目标卡（Button，label 含标题文本）
    private func card(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /// 类型三选卡（Button，label 含名称+示例两段文本）
    private func typeCard(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    /// 元素在屏幕外时上滑找（最多 3 次）
    private func scrollToTap(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<3 {
            if element.isHittable { break }
            app.swipeUp()
        }
        element.tap()
    }

    /// 同名按钮取「最后一个可点中」的（前方的可能被 sheet 遮挡），屏外则上滑找
    private func scrollUntilHittable(_ app: XCUIApplication, predicate: NSPredicate) -> XCUIElement? {
        let query = app.buttons.matching(predicate)
        for _ in 0..<4 {
            if let hit = query.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                return hit
            }
            app.swipeUp()
        }
        return nil
    }

    /// 等元素消失（XCUIElement 无内建 waitForNonExistence）
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }

    // MARK: - 1. 列表多状态走查

    func testListStatesWalkthrough() throws {
        let app = launchApp(seedListStates: true)
        openGoalList(app)

        // HoloFilterChip 分段（「进行中」|「已完成」）
        let ongoingChip = app.buttons["进行中"].firstMatch
        let completedChip = app.buttons["已完成"].firstMatch
        XCTAssertTrue(ongoingChip.waitForExistence(timeout: 10), "分段「进行中」应存在")
        XCTAssertTrue(completedChip.exists, "分段「已完成」应存在")
        snap(app, "01-list-segmented")

        // 进行中段：量化/过程型/已暂停/已到期四卡（待回顾需闭环数据，无则跳）
        XCTAssertTrue(card(app, title: "走查·跑满 300 公里").waitForExistence(timeout: 10), "进行中量化卡")
        XCTAssertTrue(card(app, title: "走查·过程型目标").exists, "进行中过程型卡")
        XCTAssertTrue(card(app, title: "走查·暂停的目标").exists, "已暂停卡在进行中段")
        XCTAssertTrue(card(app, title: "走查·已到期的目标").exists, "已到期卡在进行中段")
        XCTAssertTrue(app.staticTexts["已暂停"].firstMatch.exists, "「已暂停」胶囊")
        XCTAssertTrue(app.staticTexts["已到期"].firstMatch.exists, "「已到期」胶囊")
        XCTAssertFalse(app.staticTexts["走查·完成的目标"].exists, "已完成目标不在进行中段")
        // R2：行2 数据齐全——量化卡数值行（非零进度）+ 期限；过程型真实回顾摘要
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "128 / 300")).firstMatch.waitForExistence(timeout: 8),
            "量化卡行2 应有数值行 128 / 300")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "截止")).firstMatch.exists, "量化卡行2 应有期限")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "5 / 7")).firstMatch.exists, "过程型卡行2 应有回顾摘要")
        snap(app, "01-list-ongoing-cards")

        // 切已完成段：有卡 + 「已完成」胶囊
        completedChip.tap()
        XCTAssertTrue(card(app, title: "走查·完成的目标").waitForExistence(timeout: 6), "已完成段应有卡")
        XCTAssertTrue(app.staticTexts["已完成"].firstMatch.exists, "「已完成」胶囊")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "90 / 90")).firstMatch.exists, "已完成卡数值行显示终值")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "达成")).firstMatch.exists, "已完成卡期限位显示达成日")
        snap(app, "01-list-completed-segment")
    }

    // MARK: - 2. 创建表单三类型

    func testCreateFormThreeTypes() throws {
        let app = launchApp(seedListStates: false)
        openGoalList(app)

        // + 菜单 → 手动创建
        let newMenu = app.buttons["新建目标"].firstMatch
        XCTAssertTrue(newMenu.waitForExistence(timeout: 8), "右上「+」新建菜单应存在")
        newMenu.tap()
        let manual = app.buttons["手动创建"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 6), "新建菜单应有「手动创建」")
        manual.tap()

        // 大输入占位「想做成什么？」；默认过程型无数字区、无领域选择（规格 B3 v3：AI 按标题认领）
        let bigInput = app.textFields["想做成什么？"].firstMatch
        XCTAssertTrue(bigInput.waitForExistence(timeout: 8), "大输入占位「想做成什么？」")
        XCTAssertFalse(app.textFields["300"].firstMatch.exists, "默认过程型无数字区")
        XCTAssertFalse(app.staticTexts["领域"].firstMatch.exists, "创建表单不应出现领域选择（v3）")
        snap(app, "02-form-initial-process")

        // 切「累计」：「目标累计」+ 单位框出现
        typeCard(app, name: "累计").tap()
        XCTAssertTrue(app.staticTexts["目标累计"].firstMatch.waitForExistence(timeout: 4), "累计出「目标累计」标签")
        XCTAssertTrue(app.textFields["300"].firstMatch.exists, "累计目标数框占位 300")
        XCTAssertTrue(app.textFields["km"].firstMatch.exists, "累计单位框占位 km")
        snap(app, "02-form-cumulative")

        // 切「达标」：「数据来源 / 当前数值 / 想达到」结构
        typeCard(app, name: "达标").tap()
        XCTAssertTrue(app.staticTexts["数据来源"].firstMatch.waitForExistence(timeout: 4), "达标应直接露出「数据来源」")
        XCTAssertTrue(app.staticTexts["当前数值"].firstMatch.exists, "达标出「当前数值」标签")
        XCTAssertTrue(app.staticTexts["想达到"].firstMatch.exists, "达标出「想达到」标签")
        XCTAssertTrue(app.textFields["75"].firstMatch.exists, "达标当前值占位 75")
        XCTAssertTrue(app.textFields["65"].firstMatch.exists, "达标目标框占位 65")
        XCTAssertTrue(app.textFields["kg"].firstMatch.exists, "达标单位框占位 kg")
        snap(app, "02-form-target")

        // 切回「做成一件事」：数字区收起
        typeCard(app, name: "做成一件事").tap()
        XCTAssertFalse(app.staticTexts["当前数值"].firstMatch.waitForExistence(timeout: 2), "回做成一件事「当前数值」应收起")
        XCTAssertFalse(app.textFields["300"].firstMatch.exists, "回做成一件事数字框应收起")
        snap(app, "02-form-back-to-process")

        // 输入含 300 的标题 → 提示行出现 → 点击切「累计」且目标框=300
        bigInput.tap()
        bigInput.typeText("今年跑满 300 公里")
        let hint = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "点一下按数量累计追踪")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 4), "标题含 300 时提示行应出现")
        snap(app, "02-form-hint-row")

        hint.tap()
        XCTAssertTrue(app.staticTexts["目标累计"].firstMatch.waitForExistence(timeout: 4), "点击提示行后应切累计")
        let targetField = app.textFields.matching(NSPredicate(format: "value == %@", "300")).firstMatch
        XCTAssertTrue(targetField.waitForExistence(timeout: 4), "目标框应预填 300")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "km")).firstMatch.waitForExistence(timeout: 4),
                      "单位应按标题词映射预填 km")

        // 期限交互：点 Holo 截止期限行打开 Holo 定制期限弹层 → 点「1个月后」确定 → 再打开点「不设期限」清除
        let deadlineRow = app.buttons["goal-deadline-row"].firstMatch
        if deadlineRow.waitForExistence(timeout: 4) {
            deadlineRow.tap()
            let oneMonthChip = app.buttons["goal-deadline-1m"].firstMatch
            XCTAssertTrue(oneMonthChip.waitForExistence(timeout: 4), "Holo 期限弹层应出现「1个月后」")
            oneMonthChip.tap()
            app.buttons["确定"].firstMatch.tap()
            XCTAssertTrue(deadlineRow.waitForExistence(timeout: 4))
            deadlineRow.tap()
            let clearChip = app.buttons["goal-deadline-clear"].firstMatch
            XCTAssertTrue(clearChip.waitForExistence(timeout: 4), "Holo 期限弹层「不设期限」应存在")
            clearChip.tap()
            XCTAssertTrue(app.staticTexts["不设期限"].firstMatch.waitForExistence(timeout: 4), "点「不设期限」后应清除期限")
        }

        let createButton = app.buttons["创建"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 4), "创建按钮应存在")
        XCTAssertTrue(createButton.isEnabled, "数字有效+标题非空即可保存（单位可选，规格 B5）")
        snap(app, "02-form-hint-applied")
        // 不点创建——本用例不向业务库写数据
    }

    // MARK: - 3. 卡片长按菜单

    func testListContextMenu() throws {
        let app = launchApp(seedListStates: true)
        openGoalList(app)

        let processCard = card(app, title: "走查·过程型目标")
        XCTAssertTrue(processCard.waitForExistence(timeout: 10), "进行中过程型卡应存在")
        processCard.press(forDuration: 1.0)

        for item in ["标记完成", "暂停", "改期限", "删除"] {
            XCTAssertTrue(app.buttons[item].firstMatch.waitForExistence(timeout: 4),
                          "长按菜单应含「\(item)」")
        }
        snap(app, "03-context-menu")

        app.buttons["暂停"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已暂停"].firstMatch.waitForExistence(timeout: 6),
                      "暂停后卡片应出现「已暂停」胶囊")
        snap(app, "03-after-pause")
    }

    // MARK: - 4. 详情页统一编辑与「目标管理」面板

    func testGoalSettingsPanel() throws {
        let app = launchApp(seedListStates: true)
        openGoalList(app)

        // 进详情（记录改前图标：learning 默认 📚）
        let processCard = card(app, title: "走查·过程型目标")
        XCTAssertTrue(processCard.waitForExistence(timeout: 10))
        XCTAssertTrue(processCard.label.contains("📚"), "改前图标应为学习领域默认 📚")
        processCard.tap()

        let manageBtn = app.buttons["goal-detail-manage"].firstMatch
        XCTAssertTrue(manageBtn.waitForExistence(timeout: 6), "详情页右上角应有「目标管理」")
        snap(app, "04-detail")

        // 目标管理页使用 HoloSheetScaffold，且不再套娃出现「目标设置」按钮
        manageBtn.tap()
        XCTAssertTrue(app.staticTexts["目标管理"].waitForExistence(timeout: 6), "应打开「目标管理」弹窗")
        XCTAssertFalse(app.buttons["目标设置"].exists, "管理页不应再套娃出现「目标设置」按钮")
        let editRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "编辑目标内容、目标值与期限")).firstMatch
        XCTAssertTrue(editRow.waitForExistence(timeout: 4), "管理页应有统一编辑入口")
        editRow.tap()

        // 统一编辑表单展开「补充说明、动机与图标」
        let detailsToggle = scrollUntilHittable(app, predicate: NSPredicate(format: "label CONTAINS %@", "补充说明、动机与图标"))
        XCTAssertNotNil(detailsToggle, "编辑表单应有「补充说明、动机与图标」折叠区")
        detailsToggle?.tap()
        snap(app, "04-unified-edit-extended")

        for label in ["补充说明", "期望结果", "动机", "领域", "图标"] {
            let exists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: 4)
            XCTAssertTrue(exists, "扩展细节区应含「\(label)」")
        }

        // 改领域：学习 → 健康
        let domainRow = scrollUntilHittable(app, predicate: NSPredicate(format: "identifier == %@", "goal-edit-domain-row"))
        XCTAssertNotNil(domainRow, "领域行应存在")
        domainRow?.tap()
        XCTAssertTrue(app.staticTexts["选择领域"].waitForExistence(timeout: 6), "领域选择 sheet 应打开")
        for name in ["学习", "健康", "职业", "财务", "生活", "项目", "其他"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists,
                          "领域选择应含「\(name)」")
        }
        snap(app, "04-domain-picker")
        let healthRow = scrollUntilHittable(app, predicate: NSPredicate(format: "label CONTAINS %@", "健康"))
        XCTAssertNotNil(healthRow, "领域选择应有「健康」")
        healthRow?.tap()

        let save = app.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "保存按钮应存在")
        save.tap()

        XCTAssertTrue(waitForNonExistence(app.buttons["知道了"].firstMatch, timeout: 4), "不应弹「保存失败」alert")
        XCTAssertTrue(app.navigationBars["目标详情"].waitForExistence(timeout: 6), "保存后回到目标详情")

        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 4) { back.tap() }
        let changedCard = card(app, title: "走查·过程型目标")
        XCTAssertTrue(changedCard.waitForExistence(timeout: 10), "返回列表后无崩溃且卡片仍在")
        XCTAssertTrue(changedCard.label.contains("💪"), "图标块配色应随新领域变化（📚→💪）")
        XCTAssertFalse(changedCard.label.contains("📚"), "旧领域默认图标不应残留")
        snap(app, "04-list-after-domain-change")
    }

    // MARK: - 5. 新建后直接进详情再删除，闭环无闪退

    func testDeleteGoalFromDetailNoCrash() throws {
        let app = launchApp(seedListStates: false)
        openGoalList(app)

        let newMenu = app.buttons["新建目标"].firstMatch
        XCTAssertTrue(newMenu.waitForExistence(timeout: 8))
        newMenu.tap()
        app.buttons["手动创建"].firstMatch.tap()

        let titleField = app.textFields["想做成什么？"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 8))
        titleField.tap()
        let tempTitle = "走查·待删除闭环"
        titleField.typeText(tempTitle)
        app.buttons["创建"].firstMatch.tap()

        // 创建后自动进入详情页 → 点「···」目标管理 → 删除目标
        let manageBtn = app.buttons["goal-detail-manage"].firstMatch
        XCTAssertTrue(manageBtn.waitForExistence(timeout: 8), "创建后应进入详情且右上角有管理按钮")
        manageBtn.tap()

        let deleteRow = scrollUntilHittable(app, predicate: NSPredicate(format: "label CONTAINS %@", "删除目标"))
        XCTAssertNotNil(deleteRow, "管理页应有删除目标入口")
        deleteRow?.tap()

        let confirmDelete = app.buttons.matching(NSPredicate(format: "label == %@", "删除目标"))
            .allElementsBoundByIndex
            .last(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(confirmDelete, "应弹出删除确认按钮")
        confirmDelete?.tap()

        let deletedCard = card(app, title: tempTitle)
        XCTAssertTrue(waitForNonExistence(deletedCard, timeout: 6), "删除后应安全退回列表且目标消失，无闪退")
        XCTAssertTrue(app.buttons["新建目标"].waitForExistence(timeout: 6), "删除返回后目标列表应仍可正常交互")
        snap(app, "05-after-detail-delete-no-crash")
    }
}
