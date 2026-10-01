//
//  HabitPauseSmokeUITests.swift
//  Holo
//
//  习惯暂停冒烟走查：Plus 态全链（长按暂停 → 弹层确认 → 折叠区 → 恢复回来）
//  与免费态门控（长按暂停 → 付费墙拦截）。
//  通道：XCUITest（idb 不可用环境的 UI 走查替代）；Plus 态走 HOLO_DEBUG_PLUS=1 本地摆拍。
//

import XCTest

final class HabitPauseSmokeUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_pause_smoke"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
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

    private func buttonContaining(_ keywords: [String]) -> XCUIElement? {
        for keyword in keywords {
            let pred = NSPredicate(format: "label CONTAINS %@", keyword)
            let match = app.buttons.containing(pred).firstMatch
            if match.exists { return match }
        }
        return nil
    }

    /// subscript（app.buttons["x"]）按 identifier 匹配，本工程按钮大多只设 label；
    /// 精确点击一律走 label 谓词。
    private func buttonByLabel(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// 首页 → 习惯模块
    private func enterHabitsModule() -> Bool {
        for label in ["习惯", "習慣"] {
            let match = app.buttons[label].firstMatch
            if match.waitForExistence(timeout: 8) {
                match.tap()
                sleep(2)
                return true
            }
        }
        print("[NAV] 首页习惯入口未找到")
        return false
    }

    /// 建一个习惯：优先「散步」快速模板卡，否则走「添加」自定义（ASCII 名避开中文键盘）
    /// - Returns: 实际建成的习惯名（用于磁贴定位）
    @discardableResult
    private func createHabitIfNeeded() -> String? {
        // 已建过（用例幂等）：散步磁贴在墙上且模板卡已消失
        // （模板卡标题也叫「散步」，必须排除模板卡在场的情况）
        let templateCard = buttonContaining(["散步、點擊創建", "散步、点击创建"])
        let templateOnWall = templateCard?.exists ?? false
        if app.staticTexts["散步"].exists && !templateOnWall { return "散步" }

        // 快速模板：点卡即建
        if let card = buttonContaining(["散步、點擊創建", "散步、点击创建"]), card.exists {
            card.tap()
            if let save = buttonContaining(["儲存", "保存"]), save.waitForExistence(timeout: 3) {
                save.tap()
                sleep(1)
                return "散步"
            }
            print("[CREATE-TPL] 模板卡点后未见保存按钮，dump: " + app.buttons.allElementsBoundByIndex.prefix(30).map { "\($0.label)" }.joined(separator: " ;; "))
            app.buttons["取消"].firstMatch.tap()
        }

        guard let add = buttonContaining(["添加", "加號", "加号", "＋"]), add.exists else {
            print("[CREATE] 添加按钮未找到")
            print("[AX-BUTTONS] " + app.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.label)|\($0.identifier)" }.joined(separator: " ;; "))
            shoot("PAX_buttons_dump")
            return nil
        }
        add.tap()
        let nameField = app.textFields.firstMatch
        guard nameField.waitForExistence(timeout: 4) else {
            print("[CREATE] 名称输入框未找到")
            return nil
        }
        nameField.tap()
        nameField.typeText("PauseMe1")
        guard let saveBtn = buttonContaining(["儲存", "保存"]), saveBtn.exists else {
            print("[CREATE] 儲存按钮未找到")
            app.buttons["取消"].firstMatch.tap()
            return nil
        }
        saveBtn.tap()
        sleep(1)
        return "PauseMe1"
    }

    /// 长按磁贴呼出菜单，点「暂停」
    private func longPressTileAndTapPause(habitName: String) -> Bool {
        let tile = app.staticTexts[habitName].firstMatch
        guard tile.waitForExistence(timeout: 5) else {
            print("[PAUSE] 磁贴文本未找到: \(habitName)")
            return false
        }
        tile.press(forDuration: 1.2)
        sleep(1)
        // contextMenu 菜单项按 label 精确找「暂停」
        let pauseItem = app.buttons.matching(
            NSPredicate(format: "label == %@", "暂停")
        ).firstMatch
        guard pauseItem.waitForExistence(timeout: 4) else {
            print("[PAUSE] 长按菜单无「暂停」项")
            shoot("P01_no_pause_menu")
            return false
        }
        pauseItem.tap()
        return true
    }

    // MARK: - Plus 态全链

    func test_Plus态_暂停全链_折叠区与恢复() throws {
        app.launchEnvironment["HOLO_DEBUG_PLUS"] = "1"
        app.launch()

        guard enterHabitsModule() else { return }
        shoot("P10_habits_page")

        guard let name = createHabitIfNeeded() else { return }
        shoot("P11_habit_created")

        // 1. 长按 → 暂停
        guard longPressTileAndTapPause(habitName: name) else { return }

        // 2. 暂停弹层出现：说明文案 + 确认按钮（subscript 按 identifier 匹配，这里必须走 label 谓词）
        let sheetHint = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "连续进度会原样保留")
        ).firstMatch
        let confirmBtn = app.buttons.matching(
            NSPredicate(format: "label == %@", "暂停")
        ).firstMatch
        let sheetShown = sheetHint.waitForExistence(timeout: 4) || confirmBtn.waitForExistence(timeout: 2)
        XCTAssertTrue(sheetShown, "暂停弹层未出现")
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 4), "暂停弹层确认按钮未出现")
        shoot("P12_pause_sheet")

        // 3. 确认暂停 → 磁贴消失，折叠区出现
        confirmBtn.tap()
        sleep(2)
        shoot("P13_after_pause")

        let pausedSection = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "已暂停")
        ).firstMatch
        XCTAssertTrue(pausedSection.waitForExistence(timeout: 4), "「已暂停」折叠区未出现")
        XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 3), "暂停后磁贴仍在墙上")

        // 4. 展开折叠区 → 行内恢复
        pausedSection.tap()
        sleep(1)
        shoot("P14_paused_expanded")

        let resumeBtn = buttonByLabel("恢复")
        XCTAssertTrue(resumeBtn.waitForExistence(timeout: 4), "折叠区内未找到恢复按钮")
        resumeBtn.tap()
        sleep(2)
        shoot("P15_after_resume")

        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 4), "恢复后磁贴未回到墙上")
        print("[RESULT] Plus态暂停全链 PASS")
    }

    // MARK: - 免费态门控

    func test_免费态_暂停入口弹付费墙() throws {
        app.launch()

        guard enterHabitsModule() else { return }
        guard let name = createHabitIfNeeded() else { return }

        guard longPressTileAndTapPause(habitName: name) else { return }

        // 付费墙：标题含「习惯暂停」
        let paywall = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "使用习惯暂停")
        ).firstMatch
        XCTAssertTrue(paywall.waitForExistence(timeout: 6), "免费态暂停未弹付费墙")
        shoot("P20_paywall")
        print("[RESULT] 免费态门控 PASS")
    }
}

/// 等待元素消失的辅助（XCUITest 原生没有 waitForNonExistence）
private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !exists { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return !exists
    }
}
