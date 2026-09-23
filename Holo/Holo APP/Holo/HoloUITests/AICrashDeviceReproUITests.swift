//
//  AICrashDeviceReproUITests.swift
//  Holo
//
//  真机「点 HoloAI 闪退」自动化复现门禁（2026-09-17）：
//  主线程栈溢出型崩溃依赖真机 1MB 栈与真实聊天数据，模拟器 8MB 栈天然测不出——
//  本测试是唯一可信判据，聊天入口链路改动后必须在本测试通过后才允许交付真机。
//

import XCTest

final class AICrashDeviceReproUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAIEntrySurvivesOnDevice() throws {
        let app = XCUIApplication()
        app.launch()

        // 落首页（首启迁移/回填等异步启动链让路）
        sleep(6)

        // 底部导航中央「闪光」= HoloAI 入口
        let orb = app.buttons["闪光"].firstMatch
        XCTAssertTrue(orb.waitForExistence(timeout: 10), "AI 入口未找到")

        orb.tap()

        // 覆盖进页渲染 + .task 异步初始化窗口
        sleep(8)

        guard app.state == .runningForeground else {
            XCTFail("进入 HoloAI 后 App 退出（栈溢出闪退复现）")
            return
        }

        // 再进一次：退出 AI 页 → 重进（崩溃曾在重进路径出现）
        let close = app.buttons["关闭"].firstMatch
        if close.waitForExistence(timeout: 4) {
            close.tap()
            sleep(2)
            if orb.exists {
                orb.tap()
                sleep(5)
            }
        }

        XCTAssertTrue(app.state == .runningForeground, "重进 HoloAI 后 App 退出")
    }

    /// 语音按钮二级交互门禁（2026-09-23 增）：
    /// 当日语音按钮闪退实锤=.ips「Thread stack size exceeded」，触发路径是
    /// activeSheet 状态变化驱动 ChatView body 重求值（点按钮即崩，与录音权限无关）。
    /// 入口门禁（上面的用例）测不到这条路径——凡 ChatView 及其子件有改动，
    /// 本用例与入口用例都必须在本测试通过后才允许交付真机。
    func testVoiceButtonSurvivesOnDevice() throws {
        let app = XCUIApplication()
        app.launch()

        sleep(6)

        let orb = app.buttons["闪光"].firstMatch
        XCTAssertTrue(orb.waitForExistence(timeout: 10), "AI 入口未找到")
        orb.tap()

        // 覆盖进页渲染 + .task 异步初始化窗口
        sleep(8)

        guard app.state == .runningForeground else {
            XCTFail("进入 HoloAI 后 App 退出（栈溢出闪退复现）")
            return
        }

        // 麦克风权限首次弹窗兜底（已授过权则不出现，不影响断言）
        let micPermission = addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            for label in ["允许", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        // 第一次点语音：activeSheet 置位 → sheet 求值（当日崩溃帧即在此链上）
        let mic = app.buttons["语音输入"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 8), "语音输入按钮未找到")
        mic.tap()
        sleep(4)

        guard app.state == .runningForeground else {
            XCTFail("点击语音按钮后 App 退出（栈溢出闪退复现）")
            return
        }

        // 关弹层后重入：当日 3 秒内两次点击产生两份同签名崩溃报告，重入路径必须覆盖
        let cancel = app.buttons["取消"].firstMatch
        if cancel.waitForExistence(timeout: 4) {
            cancel.tap()
            sleep(2)
        }
        app.swipeDown(velocity: .fast) // 兜底手势关 sheet（取消按钮不可达时）
        sleep(1)
        if mic.exists {
            mic.tap()
            sleep(4)
        }

        removeUIInterruptionMonitor(micPermission)

        XCTAssertTrue(app.state == .runningForeground, "第二次点击语音按钮后 App 退出")
    }
}
