//
//  SwipeCloseResidentBlackScreenUITests.swift
//  Holo
//
//  常驻栈「右滑关闭→重开」黑屏回归锁（2026-10-07 真机实锤）。
//
//  背景：常驻栈重构（隐藏不销毁）后，模块视图与其内部 @State 跨关闭存活。
//  SwipeBackModifier 右滑关闭把内容 offset 推到整屏宽，旧实现依赖「关闭=卸载」
//  自然丢弃该状态；卸载不再发生后，offset 若永久残留，模块重开时内容整层
//  停在屏外 = 黑屏只剩底部标签栏。
//
//  仪器纪律（踩坑速查表在案）：
//  - automation 树不理会 accessibilityHidden——隐藏首页留下同 label 幽灵元素，
//    「回首页」类存在性断言不可靠；isHittable 被手势覆盖层大面积误报。
//  - 因此本测试以「步骤截图 + 帧打印」为主线（判读走只读代理/人工），
//    AX 断言只保留 identifier 唯一锚点（habit.title / habit.tab.today）。
//  通道：XCUITest（边缘手势唯一有效验证通道，idb 验不了边缘手势）。
//

import XCTest

final class SwipeCloseResidentBlackScreenUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_swipe_close_black"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // 全新安装跳过首启轻量引导（NSArgumentDomain 覆盖 UserDefaults）
        app.launchArguments += ["-holo_onboarding_lightweight_v1_completed", "YES"]
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    @discardableResult
    private func shoot(_ name: String, settle: UInt32 = 1) -> Bool {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    /// 首页 → 习惯模块（入口按钮 label「习惯」；幽灵元素风险由截图判读兜底）
    private func enterHabitsModule() {
        let entry = app.buttons.matching(NSPredicate(format: "label == %@", "习惯")).firstMatch
        guard entry.waitForExistence(timeout: 10) else {
            print("[NAV] 首页习惯入口未找到")
            return
        }
        entry.tap()
        sleep(2)
    }

    /// 左缘右滑关闭常驻模块：起点取页头下沿空档（避开返回按钮与习惯行按钮）
    private func edgeSwipeToClose() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.008, dy: 0.16))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.16))
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(2)
    }

    func testHabitModuleContentVisibleAfterSwipeCloseReopen() throws {
        app.launch()

        enterHabitsModule()
        let header = app.staticTexts["habit.title"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "首开：习惯页头（habit.title）不存在")
        print("[DIAG] 首开 header.frame=\(header.frame) appW=\(app.frame.width)")
        shoot("habit_1_first_open", settle: 0)

        edgeSwipeToClose()
        shoot("habit_2_after_swipe")

        if header.waitForExistence(timeout: 2) {
            print("[DIAG] 关闭后(隐藏态) header.frame=\(header.frame) appW=\(app.frame.width)")
        } else {
            print("[DIAG] 关闭后 header 不在 AX 树")
        }

        enterHabitsModule()
        shoot("habit_3_reopen", settle: 0)
        XCTAssertTrue(header.waitForExistence(timeout: 5), "重开：习惯页头（habit.title）不存在")
        print("[DIAG] 重开后 header.frame=\(header.frame) appW=\(app.frame.width)")
        // 回归锁：重开后页头横向中点必须落在屏内（offset 残留时 = 16+屏宽，必炸）
        let midX = header.frame.midX
        XCTAssertLessThan(
            midX, app.frame.width * 0.9,
            "重开后习惯页头横向中点 \(midX) ≥ 屏宽 90%：内容层停在屏外（右滑关闭残留 offset 黑屏回归）"
        )

        let tabToday = app.buttons["habit.tab.today"]
        if tabToday.waitForExistence(timeout: 3) {
            print("[DIAG] 重开后 tabToday.frame=\(tabToday.frame)")
        }
    }
}
