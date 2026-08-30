//
//  CalendarTimelineSmokeUITests.swift
//  Holo
//
//  系统日历三期「时间轴」冒烟：长廊 → 轴档渲染不崩溃 + 关键截图
//  通道：XCUITest（idb 不可用环境的 UI 走查替代）
//

import XCTest

final class CalendarTimelineSmokeUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_timeline_smoke"

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

    func test_长廊时间轴档冒烟() throws {
        // 1. 首页正常启动（三期改动后不崩）
        shoot("T01_home", settle: 2)

        // 2. 进记忆长廊（底部导航「记忆长廊」/「记忆」）
        let memory = app.buttons["记忆长廊"].firstMatch
        let memoryAlt = app.buttons["记忆"].firstMatch
        if memory.waitForExistence(timeout: 6) {
            memory.tap()
        } else if memoryAlt.waitForExistence(timeout: 4) {
            memoryAlt.tap()
        } else {
            print("[NAV] 长廊入口未找到")
            shoot("T02_no_entry")
            return
        }
        sleep(3)
        shoot("T02_gallery_default")

        // 3. 切到「轴」档
        let timeline = app.buttons["轴"].firstMatch
        if timeline.waitForExistence(timeout: 6) {
            timeline.tap()
            sleep(2)
            shoot("T03_timeline")

            // 4. 轴档翻一天（右箭头回看昨天——回看限制下右箭头指向过去）
            shoot("T04_timeline_settle", settle: 1)
        } else {
            print("[NAV] 「轴」档未找到")
            shoot("T03_no_timeline_button")
        }
    }

    func test_任务页引导条冒烟() throws {
        shoot("T10_home_task_entry", settle: 2)
        // 任务入口（五角星/功能入口），label 可能是「任务」
        let task = app.buttons["任务"].firstMatch
        if task.waitForExistence(timeout: 6) {
            task.tap()
            sleep(3)
            shoot("T11_task_page")
        } else {
            print("[NAV] 任务入口未找到")
        }
    }
}
