//
//  HealthPhase2WalkthroughUITests.swift
//  HoloUITests
//
//  健康二期四屏走查（无头模拟器；idb tap 在 iOS 26.3 模拟器失灵只有拖拽可用，
//  交互验证走 XCUITest——gallery-clip 审计在档经验）：
//  1. 主看板出现「身体状态」窄入口（方案 A）
//  2. 睡眠详情：阶段卡 + 整晚睡眠时间轴卡
//  3. 步数详情：「一天怎么动的」24 小时分布卡
//  4. 身体状态页：体征三项趋势 + 基线
//  控件定位用 label 简繁双语兜底（模拟器语言可能是 zh-Hant，词表在途会假红）。
//

import XCTest

final class HealthPhase2WalkthroughUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - 定位工具

    private func button(labelContains variants: [String]) -> XCUIElement {
        let subs = variants.map { "label CONTAINS '" + $0 + "'" }.joined(separator: " OR ")
        return app.buttons.matching(NSPredicate(format: subs)).firstMatch
    }

    private func anyElement(labelContains variants: [String]) -> XCUIElement {
        let subs = variants.map { "label CONTAINS '" + $0 + "'" }.joined(separator: " OR ")
        return app.descendants(matching: .any).matching(NSPredicate(format: subs)).firstMatch
    }

    /// 首页 → 健康看板（以「身体状态」入口出现为达位判据）
    private func openHealthDashboard() {
        let health = button(labelContains: ["健康"])
        _ = health.waitForExistence(timeout: 12)
        health.tap()
        _ = button(labelContains: ["身体状态", "身體狀態"]).waitForExistence(timeout: 12)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - 四屏用例

    func test_phase2_dashboard_showsVitalsEntry() throws {
        openHealthDashboard()
        XCTAssertTrue(button(labelContains: ["身体状态", "身體狀態"]).exists, "看板应有身体状态窄入口")
        sleep(1)
        attach("01_dashboard_vitals_entry")
    }

    func test_phase2_sleepDetail_showsTimelineCard() throws {
        openHealthDashboard()
        let sleepChip = button(labelContains: ["睡眠"]).firstMatch
        _ = sleepChip.waitForExistence(timeout: 8)
        sleepChip.tap()
        let timeline = anyElement(labelContains: ["整晚睡眠时间轴", "整晚睡眠時間軸"])
        XCTAssertTrue(timeline.waitForExistence(timeout: 12), "睡眠详情应有整晚睡眠时间轴卡")
        sleep(1)
        attach("02_sleep_detail_timeline")
    }

    func test_phase2_stepsDetail_showsActivityPatternCard() throws {
        openHealthDashboard()
        let stepsChip = button(labelContains: ["步数", "步數"]).firstMatch
        _ = stepsChip.waitForExistence(timeout: 8)
        stepsChip.tap()
        let pattern = anyElement(labelContains: ["一天怎么动的", "一天怎麼動的"])
        XCTAssertTrue(pattern.waitForExistence(timeout: 12), "步数详情应有 24 小时分布卡")
        sleep(1)
        attach("03_steps_detail_activity_pattern")
    }

    func test_phase2_vitalsView_showsThreeVitals() throws {
        openHealthDashboard()
        button(labelContains: ["身体状态", "身體狀態"]).tap()
        let resting = anyElement(labelContains: ["静息心率", "靜息心率"])
        XCTAssertTrue(resting.waitForExistence(timeout: 12), "身体状态页应有静息心率行")
        XCTAssertTrue(anyElement(labelContains: ["心率变异性", "心率變異性"]).exists, "应有 HRV 行")
        XCTAssertTrue(anyElement(labelContains: ["呼吸频率", "呼吸頻率"]).exists, "应有呼吸频率行")
        sleep(1)
        attach("04_vitals_view")
    }
}
