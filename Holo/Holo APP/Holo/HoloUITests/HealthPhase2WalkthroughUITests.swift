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

    /// 指标卡（详情入口）：label 形如「睡眠、7.3、目标 8.0h」，以「名称、」开头。
    /// 不能用 CONTAINS 裸名称：看板底部近 7 天趋势区还有同名「睡眠/步数」切换标签，
    /// firstMatch 曾误中底部标签导致点击不跳详情（2026-09-20 验收定性后修正定位口径）。
    private func metricChip(_ variants: [String]) -> XCUIElement {
        let subs = variants.map { "label BEGINSWITH '" + $0 + "、'" }.joined(separator: " OR ")
        return app.buttons.matching(NSPredicate(format: subs)).firstMatch
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
        let sleepChip = metricChip(["睡眠"])
        _ = sleepChip.waitForExistence(timeout: 8)
        sleepChip.tap()
        let timeline = anyElement(labelContains: ["整晚睡眠时间轴", "整晚睡眠時間軸"])
        XCTAssertTrue(timeline.waitForExistence(timeout: 12), "睡眠详情应有整晚睡眠时间轴卡")
        sleep(1)
        attach("02_sleep_detail_timeline")
    }

    func test_phase2_stepsDetail_showsActivityPatternCard() throws {
        openHealthDashboard()
        let stepsChip = metricChip(["步数", "步數"])
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

    // MARK: - 边缘右滑返回（2026-09-16 睡眠详情黑屏事故回归锁定）
    // 事故：外层常驻根手势在 push 页面时未让位，把整个健康模块连同详情页
    // 滑出屏幕外（黑屏 1.2s + 错位冻结）。修复后详情页右滑只滑详情页本身。
    // 注意：边缘手势验证必须走 XCUITest 注入通道，idb 对这类手势不可靠（在档经验）。

    private func edgeSwipeRight() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// 必须断言 isHittable：事故路径里整个模块被 .offset 滑出屏外后元素仍留在
    /// AX 树上（offset 只挪渲染不挪 AX 存在性），只断言 existence 会假绿。
    /// isHittable 需在窗口内轮询：右滑返回是「滑出动画+延迟回调+pop 转场」的链路，
    /// 拖拽结束瞬间采样会落在转场中途（看板仍被详情页盖住）造成假红；
    /// 若模块真卡死屏外（事故症状），轮询超时仍会失败，防护不弱化。（2026-09-20 验收修正）
    @discardableResult
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(200_000)
        }
        return element.isHittable
    }

    func test_phase2_sleepDetail_edgeSwipeBack_returnsToDashboard() throws {
        openHealthDashboard()
        let sleepChip = metricChip(["睡眠"])
        _ = sleepChip.waitForExistence(timeout: 8)
        sleepChip.tap()
        XCTAssertTrue(
            anyElement(labelContains: ["恢复洞察", "恢復洞察"]).waitForExistence(timeout: 12),
            "应已进入睡眠详情页"
        )

        edgeSwipeRight()

        // 必须断言 isHittable：事故路径里整个模块被 .offset 滑出屏外后元素仍留在
        // AX 树上（offset 只挪渲染不挪 AX 存在性），只断言 existence 会假绿。
        let vitalsEntry = button(labelContains: ["身体状态", "身體狀態"])
        XCTAssertTrue(vitalsEntry.waitForExistence(timeout: 8), "睡眠详情页边缘右滑应返回健康看板")
        XCTAssertTrue(waitHittable(vitalsEntry), "健康看板应在屏幕内可交互（事故症状=整个模块停在屏外不可见）")
        XCTAssertFalse(
            anyElement(labelContains: ["恢复洞察", "恢復洞察"]).exists,
            "不应停留在睡眠详情页"
        )
    }

    func test_phase2_healthRoot_edgeSwipe_closesModule() throws {
        openHealthDashboard()

        edgeSwipeRight()

        XCTAssertTrue(
            button(labelContains: ["记忆长廊", "記憶長廊"]).waitForExistence(timeout: 8),
            "健康页根层边缘右滑应关闭模块回到首页"
        )
    }

    // MARK: - 日期导航三期（2026-09-19）：
    // 1) 日期胶囊可点出日历弹层，跨月跳转任意历史日期（未来置灰的观感走人工走查）
    // 2) 看板/详情内容区左右滑动切天（左缘 24pt 让位边缘返回手势）
    // 定位约定：日期按钮的 label 含「今天 ·」；切走后天导航条出现精确 label「今天」的快捷按钮。

    /// 生成 N 天前的日历格子文案（zh 简/繁同形，附英文兜底）
    private func dayCellLabel(daysAgo: Int) -> [String] {
        guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) else { return [] }
        let zh = DateFormatter()
        zh.dateFormat = "M月d日"
        let en = DateFormatter()
        en.dateFormat = "MMM d"
        return [zh.string(from: date), en.string(from: date)]
    }

    /// 内容区横向拖拽（避开左缘排除带与右缘）。
    /// 方向约定与产品一致：右滑 = 手指向右移动 = 切前一天；左滑 = 手指向左移动 = 切后一天。
    /// （2026-09-20 验收修正：原实现方向写反，标称「右滑」实际手指向左，在今天封顶下必失败）
    /// dy 取 0.82：避开指标卡（误触会进详情）与底部趋势标签，落在无点击行为的内容区。
    private func horizontalContentDrag(rightward: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: rightward ? 0.3 : 0.7, dy: 0.82))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: rightward ? 0.7 : 0.3, dy: 0.82))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func todayQuickButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == '今天'")).firstMatch
    }

    func test_health_calendarSheet_jumpToPastDate() throws {
        openHealthDashboard()
        let dateButton = button(labelContains: ["今天 ·"])
        XCTAssertTrue(dateButton.waitForExistence(timeout: 8), "看板应有日期胶囊（今天态）")
        dateButton.tap()

        XCTAssertTrue(
            anyElement(labelContains: ["选择日期", "選擇日期"]).waitForExistence(timeout: 8),
            "点日期文案应弹出日历选择弹层"
        )
        sleep(1)
        attach("10_calendar_sheet")

        let cellVariants = dayCellLabel(daysAgo: 3)
        let subs = cellVariants.map { "label CONTAINS '" + $0 + "'" }.joined(separator: " OR ")
        let cell = app.buttons.matching(NSPredicate(format: subs)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "日历上应能找到 3 天前的日期格子")
        cell.tap()

        XCTAssertFalse(
            anyElement(labelContains: ["选择日期", "選擇日期"]).waitForExistence(timeout: 4),
            "点选日期后弹层应自动关闭"
        )
        XCTAssertTrue(todayQuickButton().waitForExistence(timeout: 5), "切到历史日期后导航条应出现「今天」快捷按钮")
        sleep(1)
        attach("11_calendar_jumped")

        // 「今天」快捷按钮一键回今天
        todayQuickButton().tap()
        XCTAssertTrue(
            button(labelContains: ["今天 ·"]).waitForExistence(timeout: 5),
            "点「今天」应回到今天"
        )
    }

    func test_healthDashboard_daySwipe_switchesDate() throws {
        openHealthDashboard()
        XCTAssertTrue(button(labelContains: ["今天 ·"]).waitForExistence(timeout: 8))

        // 右滑 → 前一天
        horizontalContentDrag(rightward: true)
        XCTAssertTrue(todayQuickButton().waitForExistence(timeout: 5), "看板右滑应切到前一天")
        XCTAssertFalse(button(labelContains: ["今天 ·"]).exists, "日期胶囊不应仍显示今天")

        // 左滑 → 回今天
        horizontalContentDrag(rightward: false)
        XCTAssertTrue(button(labelContains: ["今天 ·"]).waitForExistence(timeout: 5), "看板左滑应切回今天")

        // 今天封顶：再左滑不越界，仍是今天
        horizontalContentDrag(rightward: false)
        XCTAssertTrue(
            button(labelContains: ["今天 ·"]).waitForExistence(timeout: 5),
            "今天再左滑不应切到未来"
        )
    }

    func test_healthDetail_daySwipe_andEdgeBackCoexist() throws {
        openHealthDashboard()
        let sleepChip = metricChip(["睡眠"])
        _ = sleepChip.waitForExistence(timeout: 8)
        sleepChip.tap()
        XCTAssertTrue(
            anyElement(labelContains: ["恢复洞察", "恢復洞察"]).waitForExistence(timeout: 12),
            "应已进入睡眠详情页"
        )

        // 详情页右滑 → 前一天
        horizontalContentDrag(rightward: true)
        XCTAssertTrue(todayQuickButton().waitForExistence(timeout: 5), "详情页右滑应切到前一天")

        // 左滑 → 回今天
        horizontalContentDrag(rightward: false)
        XCTAssertTrue(button(labelContains: ["今天 ·"]).waitForExistence(timeout: 5), "详情页左滑应切回今天")

        // 边缘右滑只应返回看板，不应顺带切天（看板日期仍是今天）
        edgeSwipeRight()
        let vitalsEntry = button(labelContains: ["身体状态", "身體狀態"])
        XCTAssertTrue(vitalsEntry.waitForExistence(timeout: 8), "详情页边缘右滑应返回健康看板")
        XCTAssertTrue(waitHittable(vitalsEntry), "健康看板应在屏幕内可交互")
        XCTAssertTrue(
            button(labelContains: ["今天 ·"]).waitForExistence(timeout: 5),
            "边缘右滑返回不应顺带切换日期"
        )
    }
}
