//
//  MatterVerticalSliceUITests.swift
//  Holo
//
//  Matter「进行中的事」首版纵向切片走查（方案 §17-M3 / §18.2 对抗 fixture 的确定性部分）：
//  合成种子（-MatterDemoSeed）→ 首页焦点卡 → 详情八区 → 撤销自动更新回滚 → 完成 → 焦点卡退出。
//  通道：XCUITest（idb AX 桥在 iOS 26 不可用）。
//

import XCTest

final class MatterVerticalSliceUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_matter_slice"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-matterStorageEnabled", "1",
            "-matterActivationEnabled", "1",
            "-matterScopedChatEnabled", "1",
            "-MatterDemoSeed",
            "-SkipOnboardingIfPossible",
        ]
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        app.launch()
    }

    @discardableResult
    func shoot(_ name: String, settle: UInt32 = 1) -> Bool {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    func testFocusCardDetailRevertComplete() throws {
        // ── 首页焦点卡出现（种子生效）──
        let cardTitle = app.staticTexts["国庆日本旅行"].firstMatch
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 10), "首页焦点卡应出现（种子 + flag 开启）")
        shoot("01-home-focuscard")

        // ── 点焦点卡进详情 ──
        cardTitle.tap()
        XCTAssertTrue(app.staticTexts["HOLO 判断"].firstMatch.waitForExistence(timeout: 6), "详情页应打开")
        XCTAssertTrue(app.staticTexts["现在最值得做"].firstMatch.exists, "②现在最值得做 区块应存在")
        XCTAssertTrue(app.staticTexts["还没解决 · 4"].firstMatch.exists, "④还没解决 应为 4 项")
        XCTAssertTrue(app.staticTexts["已经解决 · 1"].firstMatch.exists, "⑤已经解决 应为 1 项")
        shoot("02-detail-top")

        // ── 撤销自动更新：已经解决 → 回到未解决 ──
        let revert = app.buttons["matterRevertButton"].firstMatch
        assertTrueRevealAndTap(revert)
        sleep(2)
        XCTAssertFalse(
            app.staticTexts["已经解决 · 1"].firstMatch.exists,
            "撤销后「已经解决 · 1」应消失（东京住宿回到未解决）"
        )
        XCTAssertTrue(
            app.staticTexts["还没解决 · 5"].firstMatch.waitForExistence(timeout: 4),
            "撤销后「还没解决」应变为 5 项"
        )
        shoot("03-after-revert")

        // ── 完成这件事（头部直接按钮 → 确认弹层）──
        let completeButton = app.buttons["matterCompleteButton"].firstMatch
        XCTAssertTrue(completeButton.waitForExistence(timeout: 4), "详情页应有「完成这件事」按钮")
        completeButton.tap()
        let confirm = app.buttons["确认完成"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "应出现完成确认弹层（用户显式触发红线）")
        shoot("04-complete-confirm")
        confirm.tap()
        sleep(2)

        // ── 完成后的页内变化：完成入口消失（lifecycle 已不是 active）──
        sleep(1)
        XCTAssertFalse(
            app.buttons["matterCompleteButton"].firstMatch.exists,
            "完成后「完成这件事」入口应消失"
        )
        shoot("04b-detail-completed")

        // ── 关闭详情回首页：焦点卡应退出焦点位（0 件 active）──
        let closeButton = app.buttons["关闭"].firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3), "详情 sheet 应有关闭按钮")
        closeButton.tap()
        sleep(2)
        shoot("05-home-after-complete")
        XCTAssertFalse(
            app.staticTexts["国庆日本旅行"].firstMatch.exists,
            "完成后首页焦点卡应消失"
        )
    }

    /// 撤销按钮在页面底部：滚动到它真正可点（isHittable）再点。
    private func assertTrueRevealAndTap(_ element: XCUIElement) {
        var attempts = 0
        while (!(element.isHittable && element.exists)) && attempts < 8 {
            app.swipeUp()
            attempts += 1
            sleep(1)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 4), "撤销按钮应存在")
        print("[DIAG] revert hittable=\(element.isHittable) frame=\(element.frame) exists=\(element.exists)")
        // AXPress 在 iOS 26 对该 SwiftUI 小按钮静默失效；改走坐标合成触摸（与真实手指一致）
        let center = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        sleep(1)
        print("[DIAG] after tap hittable=\(element.isHittable) exists=\(element.exists)")
    }
}
