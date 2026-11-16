//
//  UnderstandingShadowRunUITests.swift
//  Holo
//
//  影子理解引擎全链触发（DEBUG 验收工具，2026-11-14）：
//  XCUITest 是启动参数/环境变量的官方可靠通道（simctl launch 的 - 参数会被
//  吞、SIMCTL_CHILD_ 在 launch code=4 时不达进程，均实踩）。
//  触发链：种合成数据 → 跑一轮影子（真数据链路+真模型通道）→ 产物落
//  Application Support/UnderstandingShadow 与 Documents/评审 JSON。
//  跑法：xcodebuild test -only-testing:HoloUITests/UnderstandingShadowRunUITests
//

import XCTest

final class UnderstandingShadowRunUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSeedAndRunUnderstandingShadow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UNDERSTANDING_SHADOW_RUN"] = "1"
        // 合成种子只在模拟器种（模拟器=全新库可随意种）；真机（东林日用机）跑的是
        // 真实生活数据，严禁种假数据——2026-11-16 真机验证轮启用本测试时加的闸。
        #if targetEnvironment(simulator)
        app.launchEnvironment["UNDERSTANDING_DEMO_SEED"] = "1"
        #endif
        app.launch()

        // 影子全链：取数→投影→主题→提案（真模型，每主题一次调用）→核验→台账。
        // 3 主题上限 × 每主题 ~10s 模型时延 + 启动链让路。
        // 断言走 UI 层（结果覆盖层）：测试进程查不到被测 App 的容器 Documents
        //（runner 沙盒视角不同，首版实踩误判）。
        let resultHeader = app.staticTexts["影子理解 · 试跑结果"]
        XCTAssertTrue(resultHeader.waitForExistence(timeout: 120), "120 秒内未见结果覆盖层——全链未完成")
        // 摘要全文打进测试日志（晋升行/终态行可判读）——诊断与验收双用。
        let allTexts = app.staticTexts.allElementsBoundByIndex
            .map { $0.label }
            .filter { !$0.isEmpty }
            .joined(separator: "\n▾")
        print("【影子轮摘要】\n▾\(allTexts)")
    }
}
