//
//  TodayMatterVerticalSliceUITests.swift
//  Holo
//
//  「今天」Matter 化纵向切片走查（今日看板 Matter 化方案 §12-T5/§13.4 边界 UI 部分）
//
//  合成种子（-MatterDemoSeed）只用于 UI 边界验证；真实日本旅行旅程必须真机走 §13.5。
//  通道：XCUITest（idb AX 桥在 iOS 26 不可用）。
//

import XCTest

final class TodayMatterVerticalSliceUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_today_slice"

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

    func testTodayEntryAndPageStructure() throws {
        // ── 首页：入口按钮带「今天」可见名称与摘要（§9.4）──
        let todayEntry = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '今天'")
        ).firstMatch
        XCTAssertTrue(todayEntry.waitForExistence(timeout: 10), "首页中央入口应可见「今天」字样")
        shoot("01-home-today-entry")

        // ── 新版开启时首页不再有独立 Matter 焦点卡（避免两套焦点语义）──
        // 种子造了 active Matter；若旧焦点卡仍在会以 staticText 标题出现在首页。
        let seededTitleOnHome = app.staticTexts["国庆日本旅行"].firstMatch
        XCTAssertFalse(seededTitleOnHome.exists, "flag 开启时首页不应再渲染独立 Matter 焦点卡")
        shoot("02-home-no-duplicate-focuscard", settle: 0)

        // ── 点入口进 Today ──
        todayEntry.tap()

        // ── Today 结构：进行中的事区块 + Matter 卡（种子）+ 稳定入口 ──
        let matterHeader = app.staticTexts["进行中的事"].firstMatch
        XCTAssertTrue(matterHeader.waitForExistence(timeout: 8), "Today 应有「进行中的事」区块（0 件也不隐藏）")
        shoot("03-today-page", settle: 1)

        let matterCard = app.otherElements["todayMatterCard"].firstMatch
        let matterCardFallback = app.staticTexts["国庆日本旅行"].firstMatch
        XCTAssertTrue(matterCard.exists || matterCardFallback.exists, "种子 Matter 应出现在 Today 列表")

        // 「开始一件事」稳定入口
        let startNew = app.buttons["todayMatterStartNew"].firstMatch
        XCTAssertTrue(startNew.exists, "「开始一件事」入口应存在")
        startNew.tap()
        sleep(1)
        shoot("04-today-start-new-opens-ai", settle: 0)
    }
}