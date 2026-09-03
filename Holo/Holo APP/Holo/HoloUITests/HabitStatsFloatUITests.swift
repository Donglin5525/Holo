//
//  HabitStatsFloatUITests.swift
//  Holo
//
//  习惯统计页「月份切换条滚动悬浮」走查：建 3 个习惯 → 统计设置启用 → 下滑验证悬浮条出现/可切月/回落消失
//  通道：XCUITest（idb 不可用环境的 UI 走查替代）
//

import XCTest

final class HabitStatsFloatUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_stats_float"

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

    /// label 包含任一关键词的按钮（模板卡 label 形如「散步、點選建立」；简繁都试）
    private func buttonContaining(_ keywords: [String]) -> XCUIElement? {
        for keyword in keywords {
            let pred = NSPredicate(format: "label CONTAINS %@", keyword)
            let match = app.buttons.containing(pred).firstMatch
            if match.exists { return match }
        }
        return nil
    }

    /// 通过右上角 + 自定义建一个习惯（ASCII 名字，避开中文键盘）
    private func createHabitViaPlus(named name: String) -> Bool {
        guard let add = buttonContaining(["加號", "加号", "＋"]), add.exists else {
            print("[CREATE] + 按钮未找到")
            return false
        }
        add.tap()
        let nameField = app.textFields.firstMatch
        guard nameField.waitForExistence(timeout: 4) else {
            print("[CREATE] 名称输入框未找到")
            app.buttons["取消"].firstMatch.tap()
            return false
        }
        nameField.tap()
        nameField.typeText(name)
        guard let saveBtn = buttonContaining(["儲存", "保存"]), saveBtn.exists else {
            print("[CREATE] 儲存按钮未找到(\(name))")
            app.buttons["取消"].firstMatch.tap()
            return false
        }
        saveBtn.tap()
        sleep(1)
        return true
    }

    /// 底部 tab 按钮：优先 identifier，兜底用 label + 位于屏幕底部区域判断
    private func bottomTab(_ identifier: String, labels: [String]) -> XCUIElement? {
        let byId = app.buttons[identifier].firstMatch
        if byId.exists { return byId }
        let threshold = app.frame.maxY - 160
        for label in labels {
            let group = app.buttons.matching(NSPredicate(format: "label == %@", label))
            for i in 0..<group.count {
                let el = group.element(boundBy: i)
                if el.exists, el.frame.minY > threshold { return el }
            }
        }
        return nil
    }

    func test_统计页月份条滚动悬浮() throws {
        // 1. 首页 → 习惯模块
        var entry: XCUIElement?
        for label in ["习惯", "習慣"] {
            let match = app.buttons[label].firstMatch
            if match.waitForExistence(timeout: 8) { entry = match; break }
        }
        guard let habitEntry = entry else {
            print("[NAV] 首页习惯入口未找到")
            shoot("T01_no_entry")
            return
        }
        habitEntry.tap()
        sleep(2)
        shoot("T01_habits_page")

        // 2. 建 3 个习惯：优先快速模板，找不到模板就走 + 自定义
        let plan: [(keywords: [String], fallbackName: String)] = [
            (["散步"], "Walk1"),
            (["閱讀", "阅读"], "Read2"),
            (["早睡"], "Sleep3")
        ]
        var created = 0
        for item in plan {
            if let card = buttonContaining(item.keywords), card.exists {
                card.tap()
                if let save = buttonContaining(["儲存", "保存"]), save.exists {
                    save.tap()
                    created += 1
                    sleep(1)
                    continue
                }
                app.buttons["取消"].firstMatch.tap()
            }
            if createHabitViaPlus(named: item.fallbackName) { created += 1 }
        }
        print("[CREATE] 已建习惯数: \(created)")
        shoot("T02_habits_created")

        guard created >= 2 else {
            print("[ABORT] 习惯数不足，统计页内容不足以滚动")
            return
        }

        // 3. 进统计设置 tab，把每个习惯的「统计」胶囊点亮
        guard let settingsTab = bottomTab("habit_tab_settings", labels: ["設定", "设置"]) else {
            print("[NAV] 统计设置 tab 未找到")
            shoot("T03_no_settings_tab")
            return
        }
        settingsTab.tap()
        sleep(2)
        shoot("T03_stats_settings")

        // 页面内的「统计」胶囊与底部 tab 栏同名：排除落在屏幕底部 tab 区域的。
        // 胶囊已暴露 isSelected trait：未点亮的点一次，已亮的不动
        let tabFrame = settingsTab.frame
        let pillQuery = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "统计", "統計")
        )
        var enabled = 0
        for i in 0..<pillQuery.count {
            let pill = pillQuery.element(boundBy: i)
            guard pill.exists, pill.frame.maxY < tabFrame.minY - 8 else { continue }
            if !pill.isSelected {
                pill.tap()
                enabled += 1
            }
        }
        print("[ENABLE] 已点亮统计胶囊: \(enabled)")
        shoot("T04_pills_enabled")

        // 4. 回统计 tab
        guard let statsTab = bottomTab("habit_tab_stats", labels: ["統計", "统计"]) else {
            print("[NAV] 统计 tab 未找到")
            shoot("T05_no_stats_tab")
            return
        }
        statsTab.tap()
        sleep(2)
        shoot("T05_stats_top")

        // 悬浮条的容器 identifier 向下覆盖子按钮：悬浮条内左箭头以
        // "habit_stats_switcher_floating" 暴露，与原位条的 prev/next 天然区分
        let floatingPrev = app.buttons["habit_stats_switcher_floating"].firstMatch

        // 5. 顶部时悬浮条不存在
        XCTAssertFalse(floatingPrev.exists, "未滚动时悬浮月份条不应出现")

        // 6. 下滑两屏，悬浮条应出现
        app.swipeUp()
        app.swipeUp()
        sleep(2)
        var appeared = floatingPrev.waitForExistence(timeout: 2)
        if !appeared { sleep(1); appeared = floatingPrev.exists }
        shoot("T06_scrolled_floating")
        XCTAssertTrue(appeared, "下滑后悬浮月份条应出现")

        // 7. 点悬浮条上的左箭头切月
        if appeared {
            floatingPrev.tap()
            sleep(2)
            shoot("T07_after_month_switch")
            print("[SWITCH] 已点悬浮条左箭头切月")
        }

        // 8. 滑回顶部，悬浮条应消失
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        shoot("T08_back_top")
        XCTAssertFalse(floatingPrev.exists, "回到顶部后悬浮月份条应消失")
    }
}
