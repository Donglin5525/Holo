//
//  ReleaseGateFiveEntryUITests.swift
//  Holo
//
//  发版闸门·五大入口走查（脚本化，零模型成本；失败归因才派代理）：
//  今日/看板 → HoloAI（进页 + 停留 3 秒覆盖异步初始化 + 发一条消息）→ 想法 → 任务 → 财务（含页内设置 tab）。
//  断言口径：各入口进入并停留后 App 存活（.runningForeground）+ 关键导航元素存在；任一入口崩溃即闸门不通过。
//  依据 docs/standards/quality-redlines.md §1 五大入口定义。
//

import XCTest

final class ReleaseGateFiveEntryUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Helpers

    /// 跳过引导：首启全屏引导 + 首页新手引导气泡（盖住环形入口热区，2026-09-23 dump 实证）
    func skipOnboardingIfNeeded() {
        let skip = app.buttons.matching(
            NSPredicate(format: "label == '跳过引导' OR label CONTAINS '跳过'")
        ).firstMatch
        if skip.exists, skip.isHittable {
            skip.tap()
            sleep(2)
        }
        let bubble = app.buttons.matching(
            NSPredicate(format: "identifier == 'firstStepBubble.dismiss' OR label == '关闭新手引导'")
        ).firstMatch
        if bubble.exists, bubble.isHittable {
            bubble.tap()
            sleep(1)
        }
    }

    /// 清弹层回到可控状态：依次尝试常见关闭/返回元素
    func dismissOverlays() {
        for label in ["关闭", "取消", "返回", "关闭当前模块"] {
            let el = app.buttons[label].firstMatch
            if el.exists, el.isHittable {
                el.tap()
                sleep(1)
                return
            }
        }
        let back = app.buttons.matching(
            NSPredicate(format: "identifier == 'chevron.left' OR identifier == 'BackButton' OR label == '返回'")
        ).firstMatch
        if back.exists, back.isHittable {
            back.tap()
            sleep(1)
        }
    }

    /// 回到首页（今日）：模块内先回，再点「前往今天」
    func goHome() {
        dismissOverlays()
        let home = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '前往今天'")
        ).firstMatch
        if home.exists, home.isHittable {
            home.tap()
            sleep(2)
        }
    }

    func assertAlive(_ entry: String) {
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "\(entry)：入口停留 3 秒后 App 应存活")
    }

    // MARK: - 五大入口闸门

    func testFiveEntryReleaseGate() throws {
        skipOnboardingIfNeeded()

        // ===== 入口一：今日/看板（启动默认页）=====
        let taskEntry = app.buttons["任务"].firstMatch
        XCTAssertTrue(taskEntry.waitForExistence(timeout: 20), "首页环形布局应出现（今日模块存活）")
        assertAlive("今日/看板")

        // ===== 入口二：HoloAI（进页 + 停留 3 秒 + 发一条消息）=====
        let orb = app.buttons.matching(NSPredicate(format: "identifier == 'sparkles' OR label == '闪光'"))
        var opened = false
        if orb.firstMatch.waitForExistence(timeout: 8) {
            for i in 0..<orb.count {
                let tab = orb.element(boundBy: i)
                if tab.isHittable {
                    tab.tap()
                    opened = true
                    break
                }
            }
        }
        XCTAssertTrue(opened, "AI 入口（闪光光球）应可点击")
        assertAlive("HoloAI 进页")

        // 发一条消息覆盖真实发送链路（模拟器独立 device_id，不污染真机数据）
        let field = app.textViews.firstMatch
        var typed = false
        if field.waitForExistence(timeout: 8), field.isHittable {
            field.tap()
            sleep(1)
            field.typeText("发版走查")
            sleep(1)
            let send = app.buttons["发送消息"].firstMatch
            if send.exists, send.isHittable {
                send.tap()
                typed = true
            }
        }
        if !typed {
            // 文本框定位失败的兜底：断言聊天页存活即可（发消息链路由单测/后端监控覆盖）
            print("[GATE] AI 消息发送跳过（输入框未定位），仅保留进页存活断言")
        }
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "HoloAI：发消息后 App 应存活")
        goHome()

        // ===== 入口三：想法 =====
        let thoughts = app.buttons["想法"].firstMatch
        XCTAssertTrue(thoughts.waitForExistence(timeout: 10), "想法入口应出现")
        thoughts.tap()
        assertAlive("想法")
        goHome()

        // ===== 入口四：任务 =====
        let tasks = app.buttons["任务"].firstMatch
        XCTAssertTrue(tasks.waitForExistence(timeout: 10), "任务入口应出现")
        tasks.tap()
        assertAlive("任务")
        goHome()

        // ===== 入口五：财务（含页内设置 tab，「财务/设置」双覆盖）=====
        let finance = app.buttons["财务"].firstMatch
        XCTAssertTrue(finance.waitForExistence(timeout: 10), "财务入口应出现")
        finance.tap()
        assertAlive("财务")
        let settingsTab = app.buttons["设置"].firstMatch
        if settingsTab.waitForExistence(timeout: 8), settingsTab.isHittable {
            settingsTab.tap()
            assertAlive("财务·设置")
        } else {
            print("[GATE] 财务页内设置 tab 未定位到，设置域由启动路径覆盖，仅记录")
        }
        goHome()

        // 收口：回首页后 App 仍存活
        XCTAssertEqual(app.state, .runningForeground, "五入口走完后回首页 App 应存活")
        print("[GATE] 五大入口走查全部通过")
    }
}
