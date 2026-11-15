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

        // 分段控件存在（原生 segmented）
        let segmented = app.segmentedControls.firstMatch
        XCTAssertTrue(segmented.waitForExistence(timeout: 10), "分段控件「进行中|已完成」应存在")
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
        segmented.buttons["已完成"].tap()
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

        // 切累积型：「目标」+ 单位框出现
        typeCard(app, name: "累积型").tap()
        XCTAssertTrue(app.staticTexts["目标"].firstMatch.waitForExistence(timeout: 4), "累积型出「目标」标签")
        XCTAssertTrue(app.textFields["300"].firstMatch.exists, "累积型目标数框占位 300")
        XCTAssertTrue(app.textFields["km"].firstMatch.exists, "累积型单位框占位 km")
        snap(app, "02-form-cumulative")

        // 切达标型：「现在→目标」结构
        typeCard(app, name: "达标型").tap()
        XCTAssertTrue(app.staticTexts["现在"].firstMatch.waitForExistence(timeout: 4), "达标型出「现在」标签")
        XCTAssertTrue(app.textFields["75"].firstMatch.exists, "达标型现在框占位 75")
        XCTAssertTrue(app.textFields["70"].firstMatch.exists, "达标型目标框占位 70")
        XCTAssertTrue(app.textFields["kg"].firstMatch.exists, "达标型单位框占位 kg")
        snap(app, "02-form-target")

        // 回过程型：数字区收起
        typeCard(app, name: "过程型").tap()
        XCTAssertFalse(app.staticTexts["现在"].firstMatch.waitForExistence(timeout: 2), "回过程型「现在」应收起")
        XCTAssertFalse(app.textFields["300"].firstMatch.exists, "回过程型数字框应收起")
        snap(app, "02-form-back-to-process")

        // 输入含 300 的标题 → 提示行出现 → 点击切累积型且目标框=300
        bigInput.tap()
        bigInput.typeText("今年跑满 300 公里")
        let hint = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "点一下切到「累积型」")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 4), "标题含 300 停过程型时提示行应出现")
        snap(app, "02-form-hint-row")

        hint.tap()
        XCTAssertTrue(app.staticTexts["目标"].firstMatch.waitForExistence(timeout: 4), "点击提示行后应切累积型")
        let targetField = app.textFields.matching(NSPredicate(format: "value == %@", "300")).firstMatch
        XCTAssertTrue(targetField.waitForExistence(timeout: 4), "目标框应预填 300")
        // R5：单位微型映射——标题含「公里」→ 单位预填 km；数字有效+标题非空即可保存
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "km")).firstMatch.waitForExistence(timeout: 4),
                      "单位应按标题词映射预填 km")
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

    // MARK: - 4. 详情页目标设置面板（五字段+领域行）

    func testGoalSettingsPanel() throws {
        let app = launchApp(seedListStates: true)
        openGoalList(app)

        // 进详情（记录改前图标：learning 默认 📚）
        let processCard = card(app, title: "走查·过程型目标")
        XCTAssertTrue(processCard.waitForExistence(timeout: 10))
        XCTAssertTrue(processCard.label.contains("📚"), "改前图标应为学习领域默认 📚")
        processCard.tap()

        let settingsEntry = app.buttons["目标设置与全部关联"].firstMatch
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 8), "详情页应有「目标设置与全部关联」")
        snap(app, "04-detail")

        settingsEntry.tap()
        // 面板内 actionSection 的「目标设置」行打开二层面板：详情工具栏 ellipsis 同名
        // （accessibilityLabel 也叫「目标设置」），被 sheet 遮挡时 hittable 判定不可靠，
        // 按 identifier 排除 ellipsis 后取可点中的，屏外则上滑找
        let settingsAction = scrollUntilHittable(
            app,
            predicate: NSPredicate(format: "label == %@ AND identifier != %@", "目标设置", "ellipsis")
        )
        XCTAssertNotNil(settingsAction, "设置面板应有「目标设置」入口")
        settingsAction?.tap()
        XCTAssertTrue(app.staticTexts["说明"].firstMatch.waitForExistence(timeout: 6),
                      "二层面板应打开（「说明」字段可见）")
        snap(app, "04-settings-panel")

        // 五字段 + 领域行存在
        for label in ["说明", "期望结果", "动机", "领域", "图标", "AI 上下文"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.waitForExistence(timeout: 4),
                          "面板应有「\(label)」")
        }

        // 改领域：学习 → 健康
        let domainRow = scrollUntilHittable(app, predicate: NSPredicate(format: "label CONTAINS %@", "领域"))
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

        // picker 选完回到设置面板，领域行值应显示「健康」（draft 已回写）
        let domainAfterPick = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "领域、健康")).firstMatch
        XCTAssertTrue(domainAfterPick.waitForExistence(timeout: 6), "选完「健康」后领域行应显示新值")

        let save = app.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "保存按钮应存在")
        save.tap()

        // 保存后二层面板应关闭（保存成功路径才 dismiss）；「保存失败」alert 不应出现
        XCTAssertTrue(waitForNonExistence(app.buttons["知道了"].firstMatch, timeout: 4), "不应弹「保存失败」alert")
        XCTAssertFalse(app.staticTexts["说明"].firstMatch.waitForExistence(timeout: 2), "保存后设置面板应关闭")

        // 返回列表：卡片图标块随领域变健康默认 💪（配色变化的最直接可观测）
        let done = app.buttons["完成"].firstMatch
        if done.waitForExistence(timeout: 4) { done.tap() }
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 4) { back.tap() }
        let changedCard = card(app, title: "走查·过程型目标")
        XCTAssertTrue(changedCard.waitForExistence(timeout: 10), "返回列表后无崩溃且卡片仍在")
        XCTAssertTrue(changedCard.label.contains("💪"), "图标块配色应随新领域变化（📚→💪）")
        XCTAssertFalse(changedCard.label.contains("📚"), "旧领域默认图标不应残留")
        snap(app, "04-list-after-domain-change")
    }
}
