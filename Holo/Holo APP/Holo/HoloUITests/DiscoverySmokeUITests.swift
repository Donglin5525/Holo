//
//  DiscoverySmokeUITests.swift
//  Holo
//
//  「一个发现」冒烟走查（2026-10-23 交付闸门）：
//  ① AI 聊天页常驻行=深度分析/周期回放/规划目标，今日状态已下线，发现胶囊默认不出现（未开启）；
//  ② 右上角齿轮（Release 同样可见）→ 正式 HoloAI 统一设置页可达，主条目「一个发现」在位；
//  ③ 「一个发现」子页可达（开关+状态行），各状态可操作不崩溃。
//  断言口径：AX identifier 精确匹配 + App 存活；不截图不判读（视觉归只读判读代理另跑）。
//

import XCTest

final class DiscoverySmokeUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 播种器路由直达 AI 聊天页（带种子数据，跳过空态分支）
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "ai-analysis"
        app.launch()
        sleep(4)
    }

    private func skipOnboardingIfNeeded() {
        let skip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '跳过'")
        ).firstMatch
        if skip.exists, skip.isHittable {
            skip.tap()
            sleep(2)
        }
    }

    func test_常驻行_今日状态下线_三常驻项在位_发现胶囊默认不出现() {
        skipOnboardingIfNeeded()
        // 三常驻项（01 §1：其他三个沿用当前真实流程）
        XCTAssertTrue(existsAfter(el: app.buttons["深度分析"], timeout: 8), "深度分析胶囊应在常驻行")
        XCTAssertTrue(existsAfter(el: app.buttons["周期回放"], timeout: 4), "周期回放胶囊应在常驻行")
        XCTAssertTrue(existsAfter(el: app.buttons["规划目标"], timeout: 4), "规划目标胶囊应在常驻行")
        // 今日状态已替换（拍板：一个发现替换今日状态）
        XCTAssertFalse(app.buttons["今日状态"].exists, "今日状态入口应已下线")
        // 未开启：发现胶囊不渲染（01 §1 默认未开启=无胶囊，不暗示已分析）
        XCTAssertFalse(app.otherElements["chat.discovery.capsule"].exists
                       || app.buttons["chat.discovery.capsule"].exists,
                       "未开启时不应出现发现胶囊")
        XCTAssertEqual(app.state, .runningForeground, "聊天页存活")
    }

    func test_齿轮_统一HoloAI设置页可达_主条目在位() {
        skipOnboardingIfNeeded()
        // 右上角设置齿轮（ChatNavBar；Release 同样可见——01 §4 正式入口一）
        let gear = app.buttons["chat.nav.aiSettings"].firstMatch
        XCTAssertTrue(existsAfter(el: gear, timeout: 8), "顶部设置入口应存在")
        gear.tap()
        sleep(2)
        // 统一页主条目「一个发现」（AX：settings.holoai.main.discovery）
        let discoveryRow = firstExisting(
            identifiers: ["settings.holoai.main.discovery"],
            labels: ["一个发现"]
        )
        XCTAssertTrue(discoveryRow != nil, "统一设置页应有「一个发现」主条目")
        XCTAssertEqual(app.state, .runningForeground, "统一设置页存活")
    }

    func test_发现子页_开关与状态行可达() {
        skipOnboardingIfNeeded()
        let gear = app.buttons["chat.nav.aiSettings"].firstMatch
        XCTAssertTrue(existsAfter(el: gear, timeout: 8))
        gear.tap()
        sleep(2)
        let discoveryRow = firstExisting(
            identifiers: ["settings.holoai.main.discovery"],
            labels: ["一个发现"]
        )
        guard let row = discoveryRow else {
            XCTFail("「一个发现」主条目缺失，无法进入子页")
            return
        }
        row.tap()
        sleep(2)
        // 子页：功能开关 + 状态行（settings.discovery.toggle / status）
        XCTAssertTrue(
            firstExisting(identifiers: ["settings.discovery.toggle"], labels: nil) != nil
                || firstExisting(identifiers: nil, labels: ["已关闭", "有一个发现", "正在准备", "暂不可用"]) != nil,
            "发现子页应有开关或状态行"
        )
        XCTAssertEqual(app.state, .runningForeground, "发现子页存活")
    }

    // MARK: - Helpers

    func test_发现打开可核对财务规律并记住() {
        app.terminate()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "ai-actions"
        app.launchArguments += [
            "-holo.discovery.enabled", "YES",
            "-holo_ai_dataProcessingConsentGranted", "YES",
            "-holo.discovery.localFinanceReview", "YES"
        ]
        app.launch()
        skipOnboardingIfNeeded()
        let capsule = app.buttons["chat.discovery.capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 20), "开启后无需等待云端候选就能进入")
        capsule.tap()
        let pattern = app.staticTexts["chat.discovery.review.pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 20), "真实财务取数应在整理后形成观察")
        XCTAssertTrue(pattern.label.contains("支出"))
        app.buttons["chat.discovery.review.evidenceToggle"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "个记账日")).firstMatch.exists)
        app.buttons["chat.discovery.review.evidenceToggle"].tap()
        app.buttons["chat.discovery.review.confirm"].tap()
        XCTAssertTrue(app.staticTexts["chat.discovery.review.receipt"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["chat.discovery.review.receipt"].label.contains("已记住"))
    }

    func test_聊天页可输入并发送_覆盖旧走查漏掉的TextField() {
        skipOnboardingIfNeeded()
        // ChatInputView 使用纵向 TextField；只找 textViews 会把真实发送路径静默跳过。
        let textField = app.textFields.firstMatch
        let textView = app.textViews.firstMatch
        let input: XCUIElement
        if textField.waitForExistence(timeout: 5), textField.isHittable {
            input = textField
        } else {
            XCTAssertTrue(textView.waitForExistence(timeout: 5) && textView.isHittable,
                          "聊天输入框必须真实可操作：\(app.debugDescription)")
            input = textView
        }
        input.tap()
        input.typeText("发现链路验收")
        let send = app.buttons["发送消息"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled, "发送按钮应可用")
        send.tap()
        let cleared = NSPredicate { _, _ in
            !(input.value as? String ?? "").contains("发现链路验收")
        }
        expectation(for: cleared, evaluatedWith: input)
        waitForExpectations(timeout: 8)
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "覆盖发送及异步初始化后仍存活")
    }

    @discardableResult
    private func existsAfter(el: XCUIElement, timeout: TimeInterval) -> Bool {
        el.waitForExistence(timeout: timeout)
    }

    private func firstExisting(identifiers: [String]?, labels: [String]?) -> XCUIElement? {
        if let identifiers {
            for id in identifiers {
                let el = app.otherElements[id].firstMatch
                if el.exists { return el }
                let btn = app.buttons[id].firstMatch
                if btn.exists { return btn }
                let cell = app.cells[id].firstMatch
                if cell.exists { return cell }
            }
        }
        if let labels {
            for label in labels {
                let el = app.staticTexts[label].firstMatch
                if el.exists { return el }
                let btn = app.buttons[label].firstMatch
                if btn.exists { return btn }
            }
        }
        return nil
    }
}
