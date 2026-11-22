//
//  GoalUIRedesignUITests.swift
//  HoloUITests
//
//  目标界面减法重设计走查（2026-11-13，01-设计规格.md §还原检查清单）：
//  1. 列表多状态：分段控件、进行中段卡片与胶囊、已完成段切换
//  2. 创建目标：从已有体重习惯读取起点，通过真实保存路径进入目标详情
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

    private func launchApp(seedListStates: Bool, seedProgressData: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = seedListStates ? ["UITEST_SEED_GOAL_LIST_STATES"] : []
        if seedProgressData { app.launchArguments.append("UITEST_SEED_GOAL_PROGRESS_DATA") }
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

    // MARK: - 2. 用已有体重记录创建目标

    func testCreateUsesExistingHabitAsProgressSource() throws {
        let app = launchApp(seedListStates: false, seedProgressData: true)
        openGoalList(app)

        let newGoal = app.buttons["goal-new"].firstMatch
        XCTAssertTrue(newGoal.waitForExistence(timeout: 8))
        newGoal.tap()
        let title = app.descendants(matching: .any)["goal-title"].firstMatch
        let source = app.buttons["goal-progress-source"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(source.exists)
        XCTAssertFalse(app.textFields["goal-target"].exists)
        title.tap()
        title.typeText("走查·体重管理")
        source.tap()

        let search = app.textFields["goal-source-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        search.tap()
        search.typeText("验收·体重")
        let weight = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "goal-source-habit-")).firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 6))
        weight.tap()

        let reference = app.staticTexts["goal-reference-value"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 6))
        XCTAssertEqual(reference.label, "75 kg")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "用作起点")).firstMatch.exists)
        let target = app.textFields["goal-target"].firstMatch
        XCTAssertTrue(target.exists)
        target.tap()
        target.typeText("65")
        let hideKeyboard = app.buttons["goal-hide-keyboard"].firstMatch
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 6))
        hideKeyboard.tap()
        XCTAssertTrue(app.buttons["goal-condition"].label.contains("降到"))

        snap(app, "A3-体重-设定")
        let create = app.buttons["创建目标"].firstMatch
        XCTAssertTrue(create.exists && create.isEnabled)
        create.tap()
        XCTAssertTrue(app.buttons["goal-detail-manage"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["最新 75 kg"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["还差 10 kg"].firstMatch.exists)
        XCTAssertFalse(app.buttons["goal-achievement-complete"].exists)

        let openSource = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "去记录「验收·体重」")).firstMatch
        XCTAssertTrue(openSource.waitForExistence(timeout: 6))
        scrollToTap(app, openSource)
        let record = app.buttons["记录本次数值"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        XCTAssertTrue(record.isHittable, "多条历史记录下，记录入口应在首屏")
        record.tap()
        let measurement = app.textFields["habit.measure.value"].firstMatch
        XCTAssertTrue(measurement.waitForExistence(timeout: 8))
        measurement.tap()
        measurement.typeText("72")
        app.buttons["保存"].firstMatch.tap()
        let closeSource = app.navigationBars["验收·体重"].buttons["完成"].firstMatch
        XCTAssertTrue(closeSource.waitForExistence(timeout: 8))
        closeSource.tap()
        XCTAssertTrue(app.staticTexts["最新 72 kg"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["还差 7 kg"].firstMatch.exists)
        snap(app, "A4-体重-更新后")

        app.buttons["goal-detail-edit"].firstMatch.tap()
        let editTarget = app.textFields["goal-target"].firstMatch
        XCTAssertTrue(editTarget.waitForExistence(timeout: 6))
        editTarget.tap()
        editTarget.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "72")
        app.buttons["goal-hide-keyboard"].firstMatch.tap()
        XCTAssertTrue(app.buttons["goal-condition"].firstMatch.label.contains("降到"))
        let save = app.buttons["保存"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let complete = app.buttons["goal-achievement-complete"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 8) && complete.isHittable)
        snap(app, "A5-体重-达成弹层")
        app.buttons["继续保持进行中"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已达成"].firstMatch.waitForExistence(timeout: 6))
    }

    private func beginAudit(_ title: String, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_GOAL_PROGRESS_DATA"] + (dark ? ["UITEST_GOAL_DARK"] : [])
        app.launch()
        skipOnboardingIfNeeded(app)
        openGoalList(app)
        let create = app.buttons["goal-new"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        create.tap()
        let name = app.descendants(matching: .any)["goal-title"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText(title)
        return app
    }

    private func pickAuditSource(_ app: XCUIApplication, query: String, prefix: String, group: String? = nil) {
        app.buttons["goal-progress-source"].firstMatch.tap()
        let search = app.textFields["goal-source-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        if let group {
            let filter = app.buttons["goal-source-group-" + group].firstMatch
            XCTAssertTrue(filter.isHittable, "各来源分组应在首屏")
            filter.tap()
        }
        if !query.isEmpty {
            search.tap()
            search.typeText(query)
        }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "goal-source-" + prefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        scrollToTap(app, row)
    }

    private func enterAuditTarget(_ value: String, in app: XCUIApplication) {
        let target = app.textFields["goal-target"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 6))
        target.tap()
        target.typeText(value)
        app.buttons["goal-hide-keyboard"].firstMatch.tap()
    }

    private func saveAuditGoal(_ app: XCUIApplication) {
        let save = app.buttons["创建目标"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 6) && save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["goal-detail-manage"].firstMatch.waitForExistence(timeout: 10))
    }

    func testAuditSavingUsesExistingBalance() {
        let app = beginAudit("走查·攒够应急金")
        pickAuditSource(app, query: "验收·应急金", prefix: "ledger-account_balance-", group: "finance")
        XCTAssertTrue(app.buttons["goal-condition"].label.contains("余额达到"))
        enterAuditTarget("10000", in: app)
        let condition = app.buttons["goal-condition"].firstMatch
        condition.tap()
        app.buttons["账户余额增加"].firstMatch.tap()
        XCTAssertTrue(condition.label.contains("余额增加"))

        pickAuditSource(app, query: "验收·应急金", prefix: "ledger-account_balance-", group: "finance")
        XCTAssertTrue(condition.label.contains("余额增加"), "重选同一账户时保留余额增加的模式")
        condition.tap()
        app.buttons["账户余额达到"].firstMatch.tap()
        XCTAssertEqual(app.textFields["goal-target"].firstMatch.value as? String, "10000")
        snap(app, "B1-攒钱-设定")
        saveAuditGoal(app)
        XCTAssertTrue(app.staticTexts["还差 ¥2,000.00"].firstMatch.waitForExistence(timeout: 6))
        snap(app, "B2-攒钱-详情")
    }

    func testAuditHealthStepsPeriodInDarkMode() {
        let app = beginAudit("走查·本周走五万步", dark: true)
        app.buttons["goal-progress-source"].firstMatch.tap()
        let group = app.buttons["goal-source-group-health"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 6) && group.isHittable)
        snap(app, "C1-深色-来源列表")
        group.tap()
        let steps = app.buttons["goal-source-health-stepCount"].firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 6) && steps.isHittable)
        steps.tap()
        let period = app.descendants(matching: .any)["goal-cumulative-start"].firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 6))
        period.tap()
        app.buttons["从本周开始"].firstMatch.tap()
        let calendar = Calendar.current
        let today = Date()
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let date = DateFormatter()
        date.locale = Locale(identifier: "zh_CN")
        date.dateFormat = "M/d"
        XCTAssertTrue(period.label.contains(date.string(from: monday)))
        enterAuditTarget("50000", in: app)
        snap(app, "C2-深色-健康累计")
        saveAuditGoal(app)
        snap(app, "C3-深色-健康详情")
    }

    func testAuditNoInitialMeasurement() {
        let app = beginAudit("走查·降到65公斤")
        pickAuditSource(app, query: "验收·空体重", prefix: "habit-")
        XCTAssertTrue(app.staticTexts["暂无记录，首次记录将作为起点"].firstMatch.exists)
        XCTAssertTrue(app.buttons["goal-condition"].firstMatch.label.contains("降到"))
        enterAuditTarget("65", in: app)
        snap(app, "D1-无体重记录")
        saveAuditGoal(app)
        XCTAssertTrue(app.staticTexts["待记录"].firstMatch.waitForExistence(timeout: 6))
        snap(app, "D2-等待首条记录")
    }

    func testAuditActionGoalCanLinkExistingTask() {
        let app = beginAudit("走查·交付作品集")
        app.buttons["关闭"].firstMatch.tap()
        let resume = app.alerts.buttons["继续编辑"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 6))
        resume.tap()
        XCTAssertEqual(app.descendants(matching: .any)["goal-title"].firstMatch.value as? String, "走查·交付作品集")
        snap(app, "E1-行动目标")
        saveAuditGoal(app)
        let link = app.buttons["goal-link-existing-action"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 6) && link.isHittable)
        XCTAssertTrue(app.staticTexts["项目"].firstMatch.exists)
        snap(app, "E2-行动目标-首屏")
        link.tap()
        let search = app.textFields["搜索"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        search.tap()
        search.typeText("验收·打印作品集")
        let task = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "验收·打印作品集")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 6))
        task.tap()
        app.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["验收·打印作品集"].firstMatch.waitForExistence(timeout: 8))
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

        let titleField = app.descendants(matching: .any)["goal-title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 8))
        titleField.tap()
        let tempTitle = "走查·待删除闭环"
        titleField.typeText(tempTitle)
        app.buttons["创建目标"].firstMatch.tap()

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
