//
//  PersonalEdgeSwipeUITests.swift
//  HoloUITests
//
//  个人页边缘右滑返回回归（2026-09-16 健康页睡眠详情黑屏同款隐患根治锁定）：
//  1. 根层右滑=关闭整个个人页回主页（原有关闭行为不回归）
//  2. 子页面（长期记忆）右滑=系统 pop 回个人页根层，而不是把整个模块关掉
//  手势必须挂在 NavigationStack 内部让位判断才有效（见 SwipeBackModifier 文档）。
//  边缘手势验证必须走 XCUITest 注入通道，idb 对这类手势不可靠（在档经验）；
//  导航断言必须 isHittable——.offset 滑出屏外只挪渲染，AX 元素仍在树里（健康页事故假绿教训）。
//

import XCTest

final class PersonalEdgeSwipeUITests: XCTestCase {

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

    private func edgeSwipeRight() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// 首页 → 个人页（以「个人档案」区出现为达位判据）
    private func openPersonalRoot() {
        let personal = button(labelContains: ["个人"])
        _ = personal.waitForExistence(timeout: 12)
        personal.tap()
        _ = anyElement(labelContains: ["个人档案"]).waitForExistence(timeout: 12)
    }

    // MARK: - 用例

    func test_personal_memorySettings_edgeSwipeBack_popsToRoot() throws {
        openPersonalRoot()
        // 入口卡文案是「Holo 记住的你」（「长期记忆」是 section 标题，不在按钮 label 里）
        let entry = button(labelContains: ["Holo 记住的你", "Holo 記住的你"])
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "个人页应有长期记忆入口")
        entry.tap()
        XCTAssertTrue(
            anyElement(labelContains: ["不会删除已有记忆", "不會刪除已有記憶"]).waitForExistence(timeout: 8),
            "应已推入长期记忆子页面"
        )

        edgeSwipeRight()

        // 根层特征必须回到「可见且可交互」：事故路径（手势挂栈外劫持）会把
        // 整个个人页滑出屏外——元素仍在 AX 树但不可交互，existence 断言挡不住。
        let rootMarker = anyElement(labelContains: ["个人档案"])
        XCTAssertTrue(rootMarker.waitForExistence(timeout: 8), "长期记忆页右滑应回到个人页根层")
        XCTAssertTrue(rootMarker.isHittable, "个人页根层应在屏幕内可交互（隐患症状=整个模块被滑出屏外）")
    }

    func test_personal_root_edgeSwipe_closesModule() throws {
        openPersonalRoot()

        edgeSwipeRight()

        XCTAssertTrue(
            button(labelContains: ["记忆长廊", "記憶長廊"]).waitForExistence(timeout: 8),
            "个人页根层边缘右滑应关闭模块回到首页"
        )
    }
}
