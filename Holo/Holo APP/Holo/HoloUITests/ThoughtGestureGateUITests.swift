//
//  ThoughtGestureGateUITests.swift
//  HoloUITests
//
//  想法模块手势门禁套件（2026-09-26 五轮整改 R1 建立）：
//  核心手势路径的自动化回归门禁，此后想法模块任何改动必跑：
//  G1 左缘右滑返回 Holo / G2 侧栏开启时卡片滑动被门控（关侧栏不带出归档删除）/
//  G3 关闭态卡片左滑露归档删除 / G4 中部右滑不误退模块 / G5 左缘短划不退出 /
//  G6 编辑器内右滑不退模块（弹出层闸门）。
//
//  纪律（质量红线）：
//  - 全部用例无破坏性操作：只断言归档/删除按钮出现与否，绝不点按，真机跑也不动用户数据。
//  - 边缘手势 idb 合成触摸不可靠，XCUITest press+drag 是唯一可信自动化通道（在档经验）。
//  - 手势门禁必须真机跑才算数；模拟器绿只证明用例链路通，不证明真机手感（0926 整改原则）。
//

import XCTest

final class ThoughtGestureGateUITests: XCTestCase {

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

    /// 首页 → 想法模块（以「打开导航侧栏」按钮出现为达位判据，侧栏形态特有）
    @discardableResult
    private func openThoughtModule() -> XCUIElement {
        let tile = button(labelContains: ["想法"])
        _ = tile.waitForExistence(timeout: 15)
        tile.tap()
        let sidebarButton = button(labelContains: ["打开导航侧栏"])
        _ = sidebarButton.waitForExistence(timeout: 12)
        return sidebarButton
    }

    private func sidebarOpenButton() -> XCUIElement {
        button(labelContains: ["打开导航侧栏"])
    }

    // MARK: - 手势

    /// 左缘右滑（标准返回）
    private func edgeSwipeRight() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// 内容层区域左滑（露出归档/删除；侧栏开启/关闭皆可执行）
    private func swipeCardLeft() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// 屏幕中部右滑（退出模块）
    private func middleSwipeRight() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// 需要卡片数据的用例前置：干净模拟器上现场造一条种子想法
    /// （编辑器自动保存 + onDisappear 兜底，无破坏性；已有卡片则直接复用）
    @discardableResult
    private func ensureThoughtCardExists() -> Bool {
        if anyElement(labelContains: ["想法内容"]).exists { return true }
        let fab = button(labelContains: ["新增想法"])
        guard fab.waitForExistence(timeout: 5), fab.isHittable else { return false }
        fab.tap()
        let editor = anyElement(labelContains: ["记录想法", "编辑想法"])
        guard editor.waitForExistence(timeout: 8) else { return false }
        let field = app.textViews.firstMatch
        guard field.waitForExistence(timeout: 5) else { return false }
        field.tap()
        field.typeText("手势门禁种子：查了一下东京住宿，新宿性价比高")
        sleep(1)
        // 左缘右滑关编辑器（编辑器自带 swipeBackToDismiss，onDisappear 兜底保存）
        edgeSwipeRight()
        return anyElement(labelContains: ["想法内容"]).waitForExistence(timeout: 10)
    }

    // MARK: - G0 首页基线（分辨 HomeView 常驻结构的 isHittable 是否本来就 false）

    func test_g0_homeBaseline_tabHittable() throws {
        _ = app.buttons.matching(NSPredicate(format: "label CONTAINS '记忆长廊' OR label CONTAINS '記憶長廊'")).firstMatch
            .waitForExistence(timeout: 15)
        let home = button(labelContains: ["记忆长廊", "記憶長廊"])
        XCTAssertTrue(home.exists)
        XCTAssertTrue(home.isHittable, "冷启动首页记忆长廊 Tab 的 isHittable 基线")
    }

    // MARK: - G1 边缘右滑返回 Holo

    func test_g1_edgeSwipe_returnsHome() throws {
        let sidebarButton = openThoughtModule()
        XCTAssertTrue(sidebarButton.exists, "应进入想法模块（侧栏形态）")

        edgeSwipeRight()
        sleep(1)

        let home = button(labelContains: ["记忆长廊", "記憶長廊"])
        XCTAssertTrue(home.waitForExistence(timeout: 8), "左缘右滑应返回 Holo")
        XCTAssertTrue(home.isHittable, "返回后首页应可操作")
    }

    // MARK: - G2 侧栏开启时卡片滑动被门控（0926 真机实报问题的门禁锁定）

    func test_g2_sidebarOpen_cardSwipeGated_noArchiveLeak() throws {
        _ = openThoughtModule()

        // 点菜单开侧栏
        sidebarOpenButton().tap()
        sleep(1)
        XCTAssertTrue(sidebarOpenButton().frame.minX > 100, "前置：侧栏应已开启")

        // 侧栏开着时在内容层左滑（历史上会 100% 带出归档/删除）
        swipeCardLeft()
        sleep(1)

        // 关侧栏（点内容层遮罩区）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        sleep(1)
        XCTAssertLessThan(sidebarOpenButton().frame.minX, 100, "侧栏应已关闭")

        // 门控断言（2026-09-26 R1 修正判别通道）：闭合态幽灵按钮（opacity 0）在 iOS 26
        // XCUITest automation 树里常驻且 isHittable 不可靠（exists+hittable 双真，见当日 dump），
        // 泄露判定改用随露出翻转的 revealed 标识——它直接编码用户可见症状「按钮被带出」
        let leakPredicate = NSPredicate(
            format: "identifier == 'swipe-archive-revealed' OR identifier == 'swipe-delete-revealed'")
        let leakedButton = app.buttons.matching(leakPredicate).firstMatch
        let leaked = leakedButton.exists
        if leaked {
            // R1 排障：失败现场 AX 全量 dump（控制台），定位误命中元素真身
            print("=== G2 LEAK DUMP BEGIN ===")
            print("leaked frame=\(leakedButton.frame) identifier=\(leakedButton.identifier)")
            print(app.debugDescription)
            print("=== G2 LEAK DUMP END ===")
        }
        XCTAssertFalse(leaked, "侧栏开启期间的卡片左滑不应带出归档按钮（swipeGesturesEnabled 门控）")
    }

    // MARK: - G3 关闭态卡片左滑正常露出（门控不误伤）

    func test_g3_sidebarClosed_cardSwipe_revealsActions() throws {
        _ = openThoughtModule()
        XCTAssertTrue(ensureThoughtCardExists(), "前置：应有至少一条想法卡片（含现场种子）")

        swipeCardLeft()
        // 露出态标识断言（与 G2 同一判别通道，不依赖 AX 遮挡语义）
        let revealedArchive = app.buttons["swipe-archive-revealed"]
        if !revealedArchive.waitForExistence(timeout: 3) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "g3-swipe-not-revealed"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(revealedArchive.exists, "关闭态卡片左滑应露出归档按钮")
        XCTAssertTrue(revealedArchive.isHittable, "露出的归档按钮应可交互")

        // 右滑收起（不点按钮，无破坏性）
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        // revealed 标识消失即收起（waitForExistence 已负向轮询，这里留收起动画余量）
        sleep(1)
        let closed = !revealedArchive.exists
        XCTAssertTrue(closed, "右滑应收起操作按钮")
    }

    // MARK: - G4 中部右滑不误退模块（三段分区后口径更新：中部右滑=拉出侧栏属
    // 预期行为（G9 锁定），本条只锁「模块不退出」）

    func test_g4_middleSwipeRight_keepsModule() throws {
        _ = openThoughtModule()

        middleSwipeRight()

        // 侧栏拉出后按钮随内容层右移、被侧栏遮罩盖住，isHittable 不可靠；
        // 模块存续判据 = 按钮元素仍存在
        XCTAssertTrue(sidebarOpenButton().exists, "内容区右滑不得退出想法模块（拉出侧栏属预期，见 G9）")
    }

    // MARK: - G7 标签树无需越过主题长列表

    func test_g7_sidebarTagsImmediatelyAvailable_andTopicsSwitchable() throws {
        let sidebarButton = openThoughtModule()
        sidebarButton.tap()

        let tags = app.buttons["#标签"]
        let topics = app.buttons["主题"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5), "标签入口应固定在侧栏顶部")
        XCTAssertTrue(topics.exists, "主题应与标签并列切换")
        XCTAssertTrue(anyElement(labelContains: ["我的 #标签"]).exists, "默认进入标签树")

        topics.tap()
        XCTAssertTrue(anyElement(labelContains: ["管理主题"]).exists, "切换主题后应显示主题列表")
        tags.tap()
        XCTAssertTrue(anyElement(labelContains: ["我的 #标签"]).exists, "返回标签树不用重滚长列表")
    }

    // MARK: - G8 标签树纵向滚动与侧栏左滑关闭分开

    func test_g8_sidebarVerticalScrollStaysOpen_horizontalDragCloses() throws {
        let sidebarButton = openThoughtModule()
        sidebarButton.tap()
        XCTAssertGreaterThan(sidebarButton.frame.minX, 100)

        let verticalStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.7))
        let verticalEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        verticalStart.press(forDuration: 0.05, thenDragTo: verticalEnd)
        XCTAssertGreaterThan(sidebarButton.frame.minX, 100, "滚动标签树不应误关侧栏")

        let horizontalStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
        let horizontalEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.55))
        horizontalStart.press(forDuration: 0.05, thenDragTo: horizontalEnd)
        sleep(1)
        XCTAssertLessThan(sidebarButton.frame.minX, 100, "在侧栏内左滑应关闭侧栏")
    }

    // MARK: - G5 左缘短划未过阈值时不退出模块

    func test_g5_shortEdgeSwipeDoesNotExit() throws {
        _ = openThoughtModule()

        // 左缘轻扫（小位移，低于开侧栏阈值时应回弹，不断开模块）
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)

        // 模块未退出：侧栏按钮仍在
        XCTAssertTrue(sidebarOpenButton().exists, "左缘小位移不应退出模块")
    }

    // MARK: - G6 编辑器内右滑不得退出模块（2026-09-26 R1 P0 实锤的门禁锁定：
    // 旧版中部右滑的 window pan 曾摸到 fullScreenCover 弹层触摸，
    // 把编辑中的想法连同模块一起退掉；保留回归门禁防止再次引入）

    func test_g6_editorSwipeRight_moduleStaysPut() throws {
        _ = openThoughtModule()

        // 打开编辑器（点首条卡片的正文）
        XCTAssertTrue(ensureThoughtCardExists(), "前置：应有想法卡片（含现场种子）")
        let content = anyElement(labelContains: ["想法内容"])
        content.tap()
        XCTAssertTrue(anyElement(labelContains: ["编辑想法"]).waitForExistence(timeout: 8), "前置：编辑器应打开")

        // 编辑器内中部右滑
        middleSwipeRight()
        sleep(1)

        // 编辑器仍在、模块仍在（修复前：模块+编辑器一起被退掉回首页）
        XCTAssertTrue(anyElement(labelContains: ["编辑想法"]).exists, "编辑器内右滑不应关闭编辑器")
        XCTAssertTrue(sidebarOpenButton().exists, "编辑器内右滑不应退出想法模块")
    }

    // MARK: - G9-G13 三段分区门禁（2026-09-26 手势三段分区：左缘=返回首页 /
    // 中部右滑=拉出标签树 / 侧栏内左滑=收起；拉出与收起对现有手势的三条让位）

    /// G9 中部右滑拉出侧栏并停靠（G4 断言模块不退，本条断言侧栏真被拉出）
    func test_g9_middleSwipeRight_pullsSidebarOpen() throws {
        _ = openThoughtModule()

        middleSwipeRight()
        sleep(1)

        XCTAssertGreaterThan(
            sidebarOpenButton().frame.minX, 100,
            "中部右滑应把标签树侧栏拉出并停靠（按钮随内容层右移）")
    }

    /// G10 侧栏停靠开时左缘右滑一步直达首页（不得只收侧栏），且再进模块侧栏已重置
    func test_g10_sidebarOpen_edgeSwipe_returnsHomeAndResets() throws {
        let sidebarButton = openThoughtModule()
        sidebarButton.tap()
        sleep(1)
        XCTAssertGreaterThan(sidebarButton.frame.minX, 100, "前置：侧栏应已停靠开")

        edgeSwipeRight()
        sleep(2)

        let home = button(labelContains: ["记忆长廊", "記憶長廊"])
        XCTAssertTrue(home.waitForExistence(timeout: 8), "侧栏开着时左缘右滑应直达首页")
        XCTAssertTrue(home.isHittable, "返回后首页应可操作")

        // 退场重置：再进想法模块（点首页「想法」磁贴），侧栏是收起的（干净的想法流）
        let tile = button(labelContains: ["想法"])
        _ = tile.waitForExistence(timeout: 8)
        tile.tap()
        let reopened = sidebarOpenButton()
        XCTAssertTrue(reopened.waitForExistence(timeout: 12), "再次进入想法模块")
        XCTAssertLessThan(reopened.frame.minX, 100, "再次进入侧栏应为收起态（退场重置）")
    }

    /// 反复选择「全部想法」后，侧栏左边界仍应固定在屏幕左侧。
    func test_g10b_repeatedAllThoughts_keepsSidebarLeftAligned() throws {
        let openButton = openThoughtModule()
        var initialX: CGFloat?

        for _ in 0..<5 {
            openButton.tap()
            let allThoughts = app.buttons.matching(NSPredicate(format: "label == '全部想法'")).firstMatch
            XCTAssertTrue(allThoughts.waitForExistence(timeout: 5), "侧栏应显示全部想法入口")
            let currentX = allThoughts.frame.minX
            if let initialX {
                XCTAssertEqual(currentX, initialX, accuracy: 2,
                               "重复开合侧栏不应逐次改变组织树的左边界")
            } else {
                initialX = currentX
            }
            allThoughts.tap()
            XCTAssertTrue(openButton.waitForExistence(timeout: 5), "选中后应回到想法列表")
        }
    }

    /// G11 筛选 chips 行右滑：chips 容器自己滚，侧栏不被拉出（横向滚动让位①）
    /// 现状（2026-09-26）：侧栏形态下顶部筛选 chips 条不渲染
    /// （ThoughtSidebarRollout.isEnabled 时 filterBarView 退场），想法页暂无
    /// 横向滚动容器 → 让位规则①当前无用户可见触发场景，留位跳过。
    /// 顶部横滚元素回归时（V3 P1）去掉 skip，本条即生效。
    func test_g11_filterChipsSwipe_keepsSidebarClosed() throws {
        throw XCTSkip("侧栏形态暂无横向滚动容器；让位规则①为结构性防线（防横滚与拉出同向双动），顶部 chips 回归时启用")
    }

    func test_g11_filterChipsSwipe_keepsSidebarClosed_standby() throws {
        _ = openThoughtModule()

        // 定位筛选栏「全部」chip（精确等值匹配避免撞「全部想法」），行高内右滑
        let allChip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == '全部'")).firstMatch
        guard allChip.waitForExistence(timeout: 8) else {
            throw XCTSkip("侧栏形态无筛选 chips，见上")
        }
        let chipFrame = allChip.frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chipFrame.midX + 60, dy: chipFrame.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: min(chipFrame.midX + 240, app.frame.width - 8), dy: chipFrame.midY))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)

        XCTAssertLessThan(
            sidebarOpenButton().frame.minX, 100,
            "在横向滚动的筛选 chips 上右滑应让容器自己滚，不拉出侧栏")
    }

    /// G12 列表纵向滚动不拉侧栏（方向锁：纵向位移不触发横向拉出）
    func test_g12_verticalScroll_keepsSidebarClosed() throws {
        _ = openThoughtModule()

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)

        XCTAssertLessThan(
            sidebarOpenButton().frame.minX, 100,
            "纵向滚动列表不应把侧栏拉出（轴向锁）")
    }

    /// G13 卡片按钮展开态中部右滑：只收按钮、不拉侧栏（让位防双动）
    func test_g13_revealedCard_rightSwipe_collapsesOnly() throws {
        _ = openThoughtModule()
        XCTAssertTrue(ensureThoughtCardExists(), "前置：应有至少一条想法卡片（含现场种子）")

        // 左滑露出按钮
        swipeCardLeft()
        let revealedArchive = app.buttons["swipe-archive-revealed"]
        XCTAssertTrue(revealedArchive.waitForExistence(timeout: 3), "前置：归档按钮应已露出")

        // 右滑收按钮：起手必须在卡片内容区（卡片左移后按钮露出在右侧，
        // 中部起手会落在按钮上收不动）——与 G3 验证过的收起滑动同款
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)

        XCTAssertFalse(revealedArchive.exists, "右滑应收起操作按钮")
        XCTAssertLessThan(
            sidebarOpenButton().frame.minX, 100,
            "卡片展开态右滑只收按钮，不应同时拉出侧栏（防双动让位）")
    }
}
