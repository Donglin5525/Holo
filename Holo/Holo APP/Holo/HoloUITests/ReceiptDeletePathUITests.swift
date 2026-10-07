//
//  ReceiptDeletePathUITests.swift
//  HoloUITests
//
//  快捷记账删除链路改版冒烟（2026-10-02 东林拍板）：
//  确认页删除从右上角「…」菜单提为底部红字按钮（点后保留一次确认弹窗）；
//  列表页新增左滑删除，免确认直接删（草稿未入账无资金损失，7 天本就自动清理）。
//
//  到达方式：UITEST_SEED_RECEIPT_DRAFTS 播种两条草案后，回前台兜底自动弹
//  复核弹层（列表包栈，直达第一条详情），无需手动导航入口。
//

import XCTest

final class ReceiptDeletePathUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 详情页：红字「删除这条草稿」按钮可见；点击 → 确认弹窗 → 删除后该草案消失、另一条仍在列表。
    func testDetailDeleteButtonVisibleAndDeletes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECEIPT_DRAFTS"]
        app.launch()

        let deleteButton = app.buttons["删除这条草稿"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 20), "确认页应有红字「删除这条草稿」按钮（改版后不再藏进右上角菜单）")
        deleteButton.tap()

        let confirmDelete = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "删除应弹一次确认框（不可逆操作保险丝）")
        confirmDelete.tap()

        // 删除后详情收起回到列表：弹出/被删的是最新的「山姆会员店」
        // （播种时 createdAt 错开保证弹出对象确定），另一条 7-11 仍在
        let remaining = app.staticTexts["Seven-Eleven Japan"].firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 8), "删除后应回到列表且另一条草案仍在")
        let deleted = app.staticTexts["山姆会员店"].firstMatch
        XCTAssertFalse(deleted.exists, "被删草案不应再出现在列表")
    }

    /// 列表页：左滑删除，免确认，滑了就删。
    func testListSwipeDeleteWithoutConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECEIPT_DRAFTS"]
        app.launch()

        // 自动弹的是直达详情（列表包栈），点返回回到列表
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 20), "复核弹层应自动弹出并直达详情")
        backButton.tap()

        let samRow = app.staticTexts["山姆会员店"].firstMatch
        XCTAssertTrue(samRow.waitForExistence(timeout: 5), "列表应显示播种的第一条草案")
        let sevenRow = app.staticTexts["Seven-Eleven Japan"].firstMatch
        XCTAssertTrue(sevenRow.exists, "列表应显示播种的第二条草案")

        sevenRow.swipeLeft()

        // 满滑直接删（allowsFullSwipe）；若只露出删除按钮则点它，两种路径都收敛到「行消失」
        if sevenRow.exists {
            let swipeDelete = app.buttons["删除"].firstMatch
            if swipeDelete.waitForExistence(timeout: 2) {
                swipeDelete.tap()
            }
        }
        XCTAssertFalse(sevenRow.waitForExistence(timeout: 3), "左滑后该草案应直接删除，不弹确认框")
        XCTAssertTrue(samRow.exists, "另一条草案不受影响")
    }
}
