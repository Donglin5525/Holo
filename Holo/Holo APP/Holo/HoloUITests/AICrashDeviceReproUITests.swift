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
}
