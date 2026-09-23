//
//  NewEntryReconUITests.swift
//  Holo
//
//  一次性侦察：想法/任务/习惯 三模块「新建」入口与表单的无障碍定位信息。
//  输出：截图到 /tmp/recon-uitest/，元素树打印到 stdout（[TREE] 标记）。
//

import XCTest

final class NewEntryReconUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/recon-uitest"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-SkipOnboardingIfPossible"]
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

    func dumpTree(_ tag: String) {
        print("[TREE] ==== \(tag) ====")
        for b in app.buttons.allElementsBoundByIndex {
            print("[TREE] button id=\(b.identifier) label=\(b.label) frame=\(b.frame)")
        }
        for t in app.textFields.allElementsBoundByIndex {
            print("[TREE] textfield id=\(t.identifier) label=\(t.label) placeholder=\(t.value ?? "nil") frame=\(t.frame)")
        }
        for tv in app.textViews.allElementsBoundByIndex {
            print("[TREE] textview id=\(tv.identifier) label=\(tv.label) frame=\(tv.frame)")
        }
        for s in app.staticTexts.allElementsBoundByIndex.prefix(40) {
            print("[TREE] text id=\(s.identifier) label=\(s.label)")
        }
        for sw in app.switches.allElementsBoundByIndex {
            print("[TREE] switch id=\(sw.identifier) label=\(sw.label)")
        }
        print("[TREE] ==== end \(tag) ====")
    }

    func tapLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
        let candidates = [app.buttons[label], app.staticTexts[label], app.otherElements[label]]
        for c in candidates {
            if c.firstMatch.waitForExistence(timeout: timeout) {
                c.firstMatch.tap()
                return true
            }
        }
        return false
    }

    func goHome() {
        // 个人 tab 不在首页时用 terminate+launch 回首页最稳
        app.terminate()
        app.launch()
        _ = app.buttons["任务"].firstMatch.waitForExistence(timeout: 10)
    }

    func testReconThoughtsTasksHabits() throws {
        app.launch()
        XCTAssertTrue(app.buttons["任务"].firstMatch.waitForExistence(timeout: 15), "首页环形布局应出现")
        shoot("00-home")
        dumpTree("home")

        // ── 想法 ──
        XCTAssertTrue(tapLabel("想法"), "想法入口应可点")
        shoot("01-thoughts", settle: 2)
        dumpTree("thoughts")

        // ── 回首页 → 任务 ──
        goHome()
        XCTAssertTrue(tapLabel("任务"), "任务入口应可点")
        shoot("02-tasks", settle: 2)
        dumpTree("tasks")

        // ── 回首页 → 习惯 ──
        goHome()
        XCTAssertTrue(tapLabel("习惯"), "习惯入口应可点")
        shoot("03-habits", settle: 2)
        dumpTree("habits")
    }

    func testReconEditorsAndHabitCreate() throws {
        app.launch()
        XCTAssertTrue(app.buttons["任务"].firstMatch.waitForExistence(timeout: 15), "首页应出现")

        // ── 想法编辑器 ──
        _ = tapLabel("想法")
        sleep(2)
        if app.buttons["新增想法"].firstMatch.waitForExistence(timeout: 5) {
            app.buttons["新增想法"].firstMatch.tap()
            shoot("04-thought-editor", settle: 2)
            dumpTree("thought-editor")
            let back = app.buttons["返回"].firstMatch
            if back.exists { back.tap(); sleep(1) }
        }

        // ── 任务编辑器 ──
        goHome()
        _ = tapLabel("任务")
        sleep(2)
        let taskNew = app.buttons["新增"].firstMatch
        if taskNew.waitForExistence(timeout: 5) {
            taskNew.tap()
            shoot("05-task-editor", settle: 2)
            dumpTree("task-editor")
            // xmark 关闭按钮 not hittable，直接重启回首页
        }

        // ── 习惯编辑器 + 创建 + 打卡 ──
        goHome()
        _ = tapLabel("习惯")
        sleep(2)
        if app.buttons["添加"].firstMatch.waitForExistence(timeout: 5) {
            app.buttons["添加"].firstMatch.tap()
            shoot("06-habit-editor", settle: 2)
            dumpTree("habit-editor")

            // 尝试在第一个可输入控件输入名字
            let typed = app.textFields.firstMatch.waitForExistence(timeout: 3)
            if typed {
                let tf = app.textFields.firstMatch
                tf.tap()
                tf.typeText("MochaWater")
                print("[RECON] typed MochaWater into first textfield")
            } else {
                print("[RECON] no textfield found in habit editor")
            }
            shoot("07-habit-typed", settle: 1)

            // 找保存类按钮
            var saved = false
            for label in ["保存", "完成", "添加", "确定", "创建"] {
                let b = app.buttons[label].firstMatch
                if b.waitForExistence(timeout: 2) {
                    b.tap()
                    print("[RECON] tapped save button label=\(label)")
                    saved = true
                    break
                }
            }
            if !saved { print("[RECON] no save button found by common labels") }
            sleep(2)
            shoot("08-habit-saved")
            dumpTree("habit-after-save")

            // 尝试打卡：找带 + 的按钮
            var checked = false
            for b in app.buttons.allElementsBoundByIndex {
                if b.label == "+" {
                    b.tap()
                    print("[RECON] tapped + at \(b.frame)")
                    checked = true
                    break
                }
            }
            if !checked { print("[RECON] no + checkin button found") }
            sleep(2)
            shoot("09-habit-checked")
            dumpTree("habit-after-check")
        }
    }
}
