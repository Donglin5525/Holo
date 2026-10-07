//
//  ThoughtP1PerceptionSmokeUITests.swift
//  HoloUITests
//
//  P1 感知层视觉冒烟（2026-09-27）：想法卡片双行/侧栏身份说明/主题页构成行与
//  交集标签的静态截图采集，供只读判读（不做行为断言——行为由手势门禁 G0-G13 锁定）。
//  截图写 /tmp/thought-p1-smoke/，无破坏性操作。
//

import XCTest

final class ThoughtP1PerceptionSmokeUITests: XCTestCase {

    private static let dir = "/tmp/thought-p1-smoke"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    @discardableResult
    private func shoot(_ name: String, settle: UInt32 = 1) -> Bool {
        sleep(settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    private func button(labelContains variants: [String]) -> XCUIElement {
        let subs = variants.map { "label CONTAINS '" + $0 + "'" }.joined(separator: " OR ")
        return app.buttons.matching(NSPredicate(format: subs)).firstMatch
    }

    private func anyElement(labelContains variants: [String]) -> XCUIElement {
        let subs = variants.map { "label CONTAINS '" + $0 + "'" }.joined(separator: " OR ")
        return app.descendants(matching: .any).matching(NSPredicate(format: subs)).firstMatch
    }

    func test_p1_perception_smoke_screenshots() throws {
        // 首页 → 想法模块
        let tile = button(labelContains: ["想法"])
        _ = tile.waitForExistence(timeout: 15)
        tile.tap()
        _ = button(labelContains: ["打开导航侧栏"]).waitForExistence(timeout: 12)
        sleep(1)
        shoot("01-thought-list-card-rows")

        // 开侧栏：身份说明文案 + 主题行成员数
        button(labelContains: ["打开导航侧栏"]).tap()
        sleep(1)
        shoot("02-sidebar-identity-subtitles")

        // 主题列表（切主题分组）后进第一个主题详情：构成行 + 交集标签
        let topicsTab = app.buttons["主题"]
        if topicsTab.waitForExistence(timeout: 4) {
            topicsTab.tap()
            sleep(1)
            shoot("03-sidebar-topics-with-counts")
            let topicRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '条想法'")).firstMatch
            if topicRow.exists {
                topicRow.tap()
                sleep(2)
                shoot("04-topic-detail-split-and-chips")
            } else {
                print("[SHOT] 无主题行可点（空主题列表），跳过详情截图")
            }
        }

        // 断言只保证链路到达，不做视觉判定（视觉由只读判读负责）
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(Self.dir)/01-thought-list-card-rows.png"))
    }
}
