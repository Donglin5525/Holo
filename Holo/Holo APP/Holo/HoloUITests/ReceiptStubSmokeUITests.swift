//
//  ReceiptStubSmokeUITests.swift
//  HoloUITests
//
//  账票根空态改版冒烟（2026-09-27 拍板：B 空态 + 打印机有票态）。
//
//  已知环境限制（HEAD worktree 对照实证，非本功能引入）：
//  记一笔 sheet 内 ScrollView 信息行（账户/票根行）对模拟器合成触摸无响应，
//  真机手指不受影响。因此贴票链路用 launch argument 直通 photosPicker 验证，
//  信息行入口本身由东林真机验收覆盖。
//

import XCTest

final class ReceiptStubSmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openAddTransactionSheet(app: XCUIApplication) {
        let financeTile = app.buttons["财务"].firstMatch
        XCTAssertTrue(financeTile.waitForExistence(timeout: 15), "首页应有财务磁贴")
        financeTile.tap()

        let addEntry = app.buttons["记一笔"].firstMatch
        XCTAssertTrue(addEntry.waitForExistence(timeout: 10), "财务页应有记一笔入口")
        addEntry.tap()
    }

    /// 空态：信息卡有票根行、键盘收起后可点（hittable）；
    /// 直通 photosPicker 选图 → 票根吐出上屏、行值变「1 张 · 再贴」
    /// 根因实验探针：UITEST_NO_KEYPAD 让键盘不弹，排除遮挡变量后观察信息行点击
    func testProbe0_touchableScope() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_NO_KEYPAD"]
        app.launch()

        openAddTransactionSheet(app: app)

        let accountRow = app.buttons["账户、现金"].firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 5))
        print("RECEIPT_PROBE accountRowHittable=\(accountRow.isHittable)")
        accountRow.tap()
        sleep(1)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "probe-after-account-tap"
        shot.lifetime = .keepAlways
        add(shot)

        let accountPopup = app.staticTexts["选择账户"].firstMatch.exists
        print("RECEIPT_PROBE accountPopupShown=\(accountPopup)")
    }

    func testAttachReceiptViaPickerAndStubAppears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_AUTO_OPEN_RECEIPT_PICKER"]
        app.launch()

        openAddTransactionSheet(app: app)

        let receiptRow = app.buttons["transactionSheet.receiptRow"]
        XCTAssertTrue(receiptRow.waitForExistence(timeout: 10), "信息卡应有票根行（空态值=添加）")

        // 直通模式下系统相册已在最上层（sheet 弹出即打开），无需收键盘
        let attach1 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attach1.name = "01-picker-open"
        attach1.lifetime = .keepAlways
        add(attach1)

        // 点一张照片（UIImagePickerController 相册模式，单选点击即返回；网格第一列第一行）
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.42)).tap()
        }

        // 选图 → 压缩落库 → 票根从出票缝吐出
        let stub = app.buttons["transaction.receiptStub.0"]
        XCTAssertTrue(stub.waitForExistence(timeout: 10), "选图后票根应出现在出票舞台")

        let attach2 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attach2.name = "02-stub-attached"
        attach2.lifetime = .keepAlways
        add(attach2)

        // 信息卡行值从「添加」变「1 张 · 再贴」
        let oneStubText = app.staticTexts["1 张 · 再贴"].firstMatch
        XCTAssertTrue(oneStubText.waitForExistence(timeout: 5), "票根行应显示「1 张 · 再贴」")
    }
}
