//
//  CalendarPickerWalkUITests.swift
//  Holo
//
//  「显示的日历」选择页改版走查：设置页汇总行 → 独立选择页（分组/全选）+ 关键截图
//  通道：XCUITest（宿主侧 AX/坐标通道在 iOS 26 模拟器上不可靠）
//
//  用例分组：
//  - test_显示的日历选择页走查   原始冒烟
//  - test_A1_A5_主路径全链路     A 组：汇总行/选择页结构/组头状态机/单行勾选/计数同步
//  - test_B1_全部取消勾选到零    B1：清零不崩、设置页同步 0
//  - test_B2_Holo日历取消再勾回  B2：徽章稳定
//  - test_B3_日历总开关收起展开  B3：launchArguments 两端态对比（参数域只读，无法运行中点开关）
//  - test_B4_权限被拒降级态      B4：需先 simctl revoke 再单独跑本用例
//  - test_B5_勾选变化后首页回归  B5：勾选链路不崩、首页空态正常
//  - test_C1_深色模式走查        C1：深色下汇总行+选择页+恢复浅色
//

import XCTest

final class CalendarPickerWalkUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_picker_walk"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // 预置日历总开关为开（@AppStorage 走参数域），免去定位无 label 的 Toggle
        app.launchArguments += ["-com.holo.schedule.enabled", "YES"]
        app.launch()
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func shoot(_ name: String, settle: UInt32 = 1) -> Bool {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    // MARK: - 通用导航与定位辅助

    @discardableResult
    func openSettings() -> Bool {
        let settings = app.buttons["设置"].firstMatch
        guard settings.waitForExistence(timeout: 6) else {
            print("[NAV] 设置入口未找到")
            return false
        }
        settings.tap()
        sleep(1)
        return true
    }

    /// 双向滚动直到目标可点（先向上滚，找不到再向下滚）
    @discardableResult
    func scrollTo(_ el: XCUIElement, maxSwipes: Int = 10) -> Bool {
        for _ in 0..<maxSwipes {
            if el.exists && el.isHittable { return true }
            app.swipeUp()
            sleep(1)
        }
        for _ in 0..<maxSwipes {
            if el.exists && el.isHittable { return true }
            app.swipeDown()
            sleep(1)
        }
        return el.exists && el.isHittable
    }

    /// 返回第一个可点的指定 label 文本（过滤同页其他不可见同名元素，如 tab bar）
    func anyHittableText(_ label: String) -> XCUIElement? {
        let els = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
        for i in 0..<els.count {
            let el = els.element(boundBy: i)
            if el.exists && el.isHittable { return el }
        }
        return nil
    }

    /// 读「已选 X/Y」计数（优先可点元素：选择页 toolbar 与设置页汇总行同 label）
    func readSelectedCount() -> (Int, Int)? {
        let els = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已选 '"))
        var fallback: String? = nil
        for i in 0..<els.count {
            let el = els.element(boundBy: i)
            if !el.exists { continue }
            if el.isHittable {
                fallback = el.label
                break
            }
            if fallback == nil { fallback = el.label }
        }
        guard let label = fallback else { return nil }
        let body = label.replacingOccurrences(of: "已选 ", with: "")
        let parts = body.split(separator: "/")
        guard parts.count == 2,
              let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (x, y)
    }

    /// 找某组头同一行的组级「全选/全不选」按钮；Holo 组应返回 nil
    func groupButton(nearTitle title: String) -> XCUIElement? {
        guard let header = anyHittableText(title) else { return nil }
        let hy = header.frame.minY
        let btns = app.buttons.matching(NSPredicate(format: "label == '全选' OR label == '全不选'"))
        for i in 0..<btns.count {
            let b = btns.element(boundBy: i)
            if b.exists && b.isHittable && abs(b.frame.minY - hy) < 40 { return b }
        }
        return nil
    }

    /// 循环点完所有可见的组级按钮（全选→组变全不选；遇到屏幕外的组自动上滚）
    @discardableResult
    func tapAllGroupButtons(label: String, max: Int = 8) -> Int {
        var n = 0
        var consecutiveMiss = 0
        for _ in 0..<max {
            let btn = app.buttons[label].firstMatch
            if btn.exists && btn.isHittable {
                btn.tap()
                n += 1
                sleep(1)
                consecutiveMiss = 0
            } else if btn.exists {
                app.swipeUp()
                sleep(1)
                consecutiveMiss += 1
                if consecutiveMiss > 2 { break }
            } else {
                break
            }
        }
        return n
    }

    /// 打开选择页（进设置 → 滚到汇总行 → 点击）
    @discardableResult
    func openPicker() -> Bool {
        guard openSettings() else { return false }
        let summary = app.staticTexts["显示的日历"].firstMatch
        guard scrollTo(summary) else {
            print("[NAV] 汇总行未找到（权限可能未授权）")
            return false
        }
        summary.tap()
        sleep(1)
        return app.navigationBars["显示的日历"].waitForExistence(timeout: 4)
    }

    func tapPickerBack() {
        let back = app.navigationBars["显示的日历"].buttons.element(boundBy: 0)
        if back.exists {
            back.tap()
            sleep(1)
        } else {
            print("[NAV] 选择页返回按钮未找到")
        }
    }

    /// 定位选择页里可点的日历行（过滤压屏同名元素，如首页底下的「Holo」）
    func hittableRow(_ label: String) -> XCUIElement? {
        if let row = anyHittableText(label) { return row }
        let el = app.staticTexts[label].firstMatch
        if scrollTo(el) { return el }
        return nil
    }

    /// 收尾恢复：勾选恢复成只有「日历」勾选
    func restoreCalendarOnlySelection() {
        guard openPicker() else { return }
        tapAllGroupButtons(label: "全不选")
        // Holo 组无组级按钮，组级清零够不到它：计数仍 >0 时手动取消
        var count = readSelectedCount()
        if let v = count, v.0 > 0, let holo = hittableRow("Holo") {
            holo.tap()
            sleep(1)
        }
        // 此时应为 0，勾回「日历」
        count = readSelectedCount()
        if let v = count, v.0 == 0, let row = hittableRow("日历") {
            row.tap()
            sleep(1)
        }
        print("[NAV] 恢复后计数=\(String(describing: readSelectedCount()))")
        shoot("S_restore_calendar_only")
        tapPickerBack()
    }

    // MARK: - 原始冒烟

    func test_显示的日历选择页走查() throws {
        shoot("W01_home", settle: 2)
        guard openSettings() else { shoot("W02_no_settings"); return }

        guard openPicker() else {
            shoot("W05_no_summary_row")
            return
        }
        shoot("W06_picker_page", settle: 2)

        tapAllGroupButtons(label: "全选")
        shoot("W07_picker_subscribed_all_selected", settle: 1)
        tapAllGroupButtons(label: "全不选")
        shoot("W08_picker_subscribed_deselected", settle: 1)

        tapPickerBack()
        shoot("W09_back_to_settings", settle: 1)
    }

    // MARK: - A 组：主路径

    func test_A1_A5_主路径全链路() throws {
        guard openSettings() else { shoot("R00_no_settings"); return }
        let summary = app.staticTexts["显示的日历"].firstMatch
        guard scrollTo(summary) else {
            print("[NAV] A1 汇总行未找到")
            shoot("R01_no_summary")
            return
        }

        // A1：汇总行文案与计数
        let subtitle = app.staticTexts["勾选后才在 Holo 展示、供 AI 读取"].firstMatch
        let count0 = readSelectedCount()
        print("[NAV] A1 副标题=\(subtitle.exists) 计数=\(String(describing: count0))")
        XCTAssertTrue(subtitle.exists, "A1 汇总行副标题缺失")
        XCTAssertNotNil(count0, "A1 汇总行「已选 X/Y」计数缺失")
        shoot("R01_settings_summary")

        // A2：选择页结构
        summary.tap()
        sleep(1)
        XCTAssertTrue(app.navigationBars["显示的日历"].waitForExistence(timeout: 4), "A2 选择页导航标题缺失")

        let explain = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '勾选的日历会显示在 Holo 日历页'")).firstMatch
        let holoGroup = app.staticTexts["Holo 专属"].firstMatch
        let badge = app.staticTexts["任务同步写入"].firstMatch
        let subGroup = app.staticTexts["订阅"].firstMatch
        let subHint = app.staticTexts["· 默认不勾选"].firstMatch
        let toolbarCount = readSelectedCount()
        print("[NAV] A2 说明卡=\(explain.exists) Holo组=\(holoGroup.exists) 徽章=\(badge.exists) 订阅组=\(subGroup.exists) 默认不勾选=\(subHint.exists) 计数=\(String(describing: toolbarCount))")
        XCTAssertTrue(explain.exists, "A2 AI 说明卡缺失")
        XCTAssertTrue(holoGroup.exists, "A2 Holo 专属组缺失")
        XCTAssertTrue(badge.exists, "A2 任务同步写入徽章缺失")
        if subGroup.exists {
            XCTAssertTrue(subHint.exists, "A2 订阅组缺少「· 默认不勾选」")
        } else {
            print("[NAV] A2 模拟器无订阅日历，「· 默认不勾选」待真机验证")
        }
        XCTAssertNil(groupButton(nearTitle: "Holo 专属"), "A2 Holo 组不应有组级全选按钮")
        XCTAssertNotNil(toolbarCount, "A2 导航栏「已选 X/N」缺失")
        shoot("R02_picker_page", settle: 2)

        // A3：组头按钮状态机（取第一个可见的组级按钮）
        let btns = app.buttons.matching(NSPredicate(format: "label == '全选' OR label == '全不选'"))
        var a3Btn: XCUIElement? = nil
        for i in 0..<btns.count {
            let b = btns.element(boundBy: i)
            if b.exists && b.isHittable { a3Btn = b; break }
        }
        if let btn = a3Btn {
            let c0 = readSelectedCount()
            let l0 = btn.label
            btn.tap()
            sleep(1)
            let c1 = readSelectedCount()
            let l1 = btn.label
            let flipped = (l0 == "全选" && l1 == "全不选") || (l0 == "全不选" && l1 == "全选")
            let delta = (c0 != nil && c1 != nil) ? abs(c1!.0 - c0!.0) : 0
            print("[NAV] A3 按钮 \(l0)→\(l1) 计数 \(String(describing: c0))→\(String(describing: c1))")
            XCTAssertTrue(flipped, "A3 组头按钮文案未翻转（\(l0)→\(l1)）")
            XCTAssertGreaterThan(delta, 0, "A3 组级点击后计数未变化")
            shoot("R03_group_toggled")
            btn.tap()
            sleep(1)
            print("[NAV] A3 还原后按钮=\(btn.label)")
        } else {
            print("[NAV] A3 未找到可点的组级按钮（账户组可能不可见）")
        }

        // A4：单行点击勾选翻转
        let rowName = app.staticTexts["中国大陆节假日"].firstMatch.exists ? "中国大陆节假日" : "生日"
        let row = app.staticTexts[rowName].firstMatch
        if scrollTo(row) {
            let c0 = readSelectedCount()
            row.tap()
            sleep(1)
            let c1 = readSelectedCount()
            let delta = (c0 != nil && c1 != nil) ? abs(c1!.0 - c0!.0) : 0
            print("[NAV] A4 行「\(rowName)」点击 计数 \(String(describing: c0))→\(String(describing: c1))")
            XCTAssertEqual(delta, 1, "A4 单行点击后计数应 ±1")
            shoot("R04_row_toggled")
            row.tap()
            sleep(1)
            let c2 = readSelectedCount()
            XCTAssertEqual(c2?.0, c0?.0, "A4 二次点击未还原计数")
        } else {
            print("[NAV] A4 测试行「\(rowName)」不可见，跳过")
        }

        // A5：返回设置页计数一致
        tapPickerBack()
        let cBack = readSelectedCount()
        print("[NAV] A5 返回后计数=\(String(describing: cBack))（进页前=\(String(describing: count0))）")
        XCTAssertEqual(cBack?.0, count0?.0, "A5 返回设置页后计数与进页前不一致")
        shoot("R05_back_settings", settle: 1)
    }

    // MARK: - B 组：交互合理性

    func test_B1_全部取消勾选到零() throws {
        guard openPicker() else { shoot("R06_B1_no_picker"); return }

        // 先全部勾上（组数少，循环点「全选」）
        tapAllGroupButtons(label: "全选")
        let cAll = readSelectedCount()
        print("[NAV] B1 全选后=\(String(describing: cAll))")
        shoot("R07_all_selected")

        // 再全部清零（组级按钮够不到 Holo 组——设计上无组级按钮，按计数补点 Holo 行）
        tapAllGroupButtons(label: "全不选")
        var cZero = readSelectedCount()
        if let v = cZero, v.0 > 0, let holo = hittableRow("Holo") {
            holo.tap()
            sleep(1)
            cZero = readSelectedCount()
        }
        print("[NAV] B1 清零后=\(String(describing: cZero))")
        shoot("R08_zero_selected", settle: 2)
        XCTAssertEqual(cZero?.0, 0, "B1 未清零")
        XCTAssertEqual(app.state, .runningForeground, "B1 清零后 app 异常退出")

        // 设置页同步 0
        tapPickerBack()
        let cSettings = readSelectedCount()
        print("[NAV] B1 设置页计数=\(String(describing: cSettings))")
        XCTAssertEqual(cSettings?.0, 0, "B1 设置页计数未同步为 0")
        shoot("R09_settings_zero", settle: 1)

        restoreCalendarOnlySelection()
    }

    func test_B2_Holo日历取消再勾回() throws {
        guard openPicker() else { shoot("R10_B2_no_picker"); return }
        guard let holoRow = hittableRow("Holo") else {
            print("[NAV] B2 Holo 行未找到")
            return
        }
        let badge = app.staticTexts["任务同步写入"].firstMatch
        let c0 = readSelectedCount()

        holoRow.tap()
        sleep(1)
        let c1 = readSelectedCount()
        let delta1 = (c0 != nil && c1 != nil) ? abs(c1!.0 - c0!.0) : 0
        print("[NAV] B2 点击Holo行 计数 \(String(describing: c0))→\(String(describing: c1)) 徽章仍在=\(badge.exists)")
        XCTAssertTrue(badge.exists, "B2 取消勾选后徽章消失")
        XCTAssertEqual(delta1, 1, "B2 点击 Holo 行后计数应 ±1")
        shoot("R10_holo_deselected")

        holoRow.tap()
        sleep(1)
        let c2 = readSelectedCount()
        print("[NAV] B2 再点Holo行 计数 \(String(describing: c1))→\(String(describing: c2)) 徽章仍在=\(badge.exists)")
        XCTAssertTrue(badge.exists, "B2 勾回后徽章消失")
        XCTAssertEqual(c2?.0, c0?.0, "B2 二次点击后计数未还原")
        shoot("R11_holo_reselected")
    }

    func test_B3_日历总开关收起展开() throws {
        // 场景1：默认（无参数，开关关）→ 区块收起只剩开关行
        app.terminate()
        app.launchArguments = []
        app.launch()
        sleep(2)
        guard openSettings() else { return }
        let summary = app.staticTexts["显示的日历"].firstMatch
        var foundTitle = false
        for _ in 0..<10 {
            if anyHittableText("日历") != nil { foundTitle = true; break }
            app.swipeUp()
            sleep(1)
        }
        print("[NAV] B3 关态：日历标题=\(foundTitle) 汇总行=\(summary.exists) 任务同步行=\(app.staticTexts["任务同步到日历"].firstMatch.exists)")
        XCTAssertTrue(foundTitle, "B3 关闭态下「日历」标题行缺失")
        XCTAssertFalse(summary.exists, "B3 关闭态不应显示汇总行")
        shoot("R12_toggle_off_collapsed")

        // 场景2：预置开 → 展开
        app.terminate()
        app.launchArguments += ["-com.holo.schedule.enabled", "YES"]
        app.launch()
        sleep(2)
        guard openSettings() else { return }
        let summary2 = app.staticTexts["显示的日历"].firstMatch
        let expanded = scrollTo(summary2)
        print("[NAV] B3 开态：汇总行=\(expanded)")
        XCTAssertTrue(expanded, "B3 开启后汇总行未出现")
        shoot("R13_toggle_on_expanded", settle: 1)
    }

    /// 收尾：勾选恢复成只有「日历」勾选 + 外观切回跟随系统，并补拍设置页汇总行
    func test_Z_收尾恢复() throws {
        restoreCalendarOnlySelection()

        // 外观切回跟随系统（可能残留深色）
        let sysPred = NSPredicate(format: "label BEGINSWITH '跟随系统'")
        var switchedBack = false
        for _ in 0..<3 {
            let sysBtn = app.buttons.matching(sysPred).firstMatch
            guard scrollTo(sysBtn) else { continue }
            app.swipeDown()
            sleep(1)
            let visible = app.buttons.matching(sysPred).firstMatch
            if visible.exists && visible.isHittable {
                visible.tap()
                switchedBack = true
                sleep(2)
                break
            }
        }
        print("[NAV] 收尾：跟随系统 tap=\(switchedBack)")

        // 滚到日历区块补拍汇总行（恢复后应为「已选 1/Y」）
        guard openSettings() else { return }
        let summary = app.staticTexts["显示的日历"].firstMatch
        if scrollTo(summary) {
            print("[NAV] 收尾：设置页汇总行计数=\(String(describing: readSelectedCount()))")
            shoot("R09b_settings_restored", settle: 1)
        }
    }

    // MARK: - selectionConfigured 修复复验

    /// 复验 2（前置：bash 已 terminate app、杀 cfprefsd 缓存、删容器 plist）：首次激活仍自动补默认勾选
    func test_V2_首启默认勾选回归() throws {
        // 删 plist 后 App 视为全新安装，可能停在 onboarding 引导页
        let skip = app.buttons["跳过"].firstMatch
        if skip.waitForExistence(timeout: 4) {
            skip.tap()
            sleep(2)
        }

        guard openPicker() else { shoot("V2_no_picker"); return }
        let count = readSelectedCount()
        print("[NAV] V2 首启默认计数=\(String(describing: count))")
        shoot("V2_first_launch_default", settle: 1)

        // 默认勾选 = 非订阅、非生日；模拟器 4 日历（Holo/日历/生日/中国大陆节假日）→ 应为 2
        XCTAssertEqual(count?.0, 2, "V2 首启默认勾选数应为 2（Holo+日历）")
        // 佐证：订阅组与生日组头应显示「全选」（组内无勾选），说明未勾的正是这两组
        if let subBtn = groupButton(nearTitle: "订阅") {
            XCTAssertEqual(subBtn.label, "全选", "V2 订阅组默认不应勾选")
        } else {
            print("[NAV] V2 订阅组按钮未找到")
        }
        if let otherBtn = groupButton(nearTitle: "Other") {
            XCTAssertEqual(otherBtn.label, "全选", "V2 生日默认不应勾选")
        } else {
            print("[NAV] V2 Other 组按钮未找到")
        }
    }

    /// 复验 1（核心）：全部取消到 0 → 重启 → 仍 0/N，不回弹默认值
    func test_V1_清零重启不回弹() throws {
        guard openPicker() else { shoot("V1_no_picker"); return }

        // 清零：组级全不选（够不到 Holo 组）+ 手动取消 Holo 行
        tapAllGroupButtons(label: "全选")
        tapAllGroupButtons(label: "全不选")
        if let c = readSelectedCount(), c.0 > 0, let holo = hittableRow("Holo") {
            holo.tap()
            sleep(1)
        }
        let cZero = readSelectedCount()
        print("[NAV] V1 清零后=\(String(describing: cZero))")
        XCTAssertEqual(cZero?.0, 0, "V1 未清零")
        shoot("V1_zero_before_relaunch", settle: 1)

        // 重启（保留 setUp 的 launchArguments）
        app.terminate()
        sleep(1)
        app.launch()
        sleep(3)

        guard openPicker() else {
            print("[NAV] V1 重启后进选择页失败")
            shoot("V1_no_picker_after_relaunch")
            return
        }
        let cAfter = readSelectedCount()
        print("[NAV] V1 重启后=\(String(describing: cAfter))")
        XCTAssertEqual(cAfter?.0, 0, "V1 重启后勾选回弹默认值，selectionConfigured 未生效")
        shoot("V1_zero_after_relaunch", settle: 1)
        tapPickerBack()
    }

    /// 前置：bash 先执行 `xcrun simctl privacy <udid> revoke calendar com.holo.Holo` 再跑本用例
    func test_B4_权限被拒降级态() throws {
        guard openSettings() else { return }
        let summary = app.staticTexts["显示的日历"].firstMatch
        var found = false
        for _ in 0..<10 {
            if anyHittableText("日历权限被拒绝") != nil { found = true; break }
            app.swipeUp()
            sleep(1)
        }
        print("[NAV] B4 拒绝行=\(found) 汇总行=\(summary.exists)")
        XCTAssertTrue(found, "B4 权限被拒态未显示「日历权限被拒绝」引导行")
        XCTAssertFalse(summary.exists, "B4 权限被拒态不应显示汇总行")
        shoot("R14_permission_denied", settle: 1)
    }

    func test_B5_勾选变化后首页回归() throws {
        // 勾选变化：全部勾上
        guard openPicker() else { shoot("R15_B5_no_picker"); return }
        tapAllGroupButtons(label: "全选")
        print("[NAV] B5 全选后=\(String(describing: readSelectedCount()))")
        tapPickerBack()

        // 回首页：关设置 sheet（导航栏 leading 关闭按钮）
        let closeBtn = app.navigationBars.buttons.element(boundBy: 0)
        if closeBtn.exists {
            closeBtn.tap()
            sleep(1)
        }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "B5 勾选变化后 app 崩溃/退后台")
        shoot("R15_home_after_selection", settle: 1)

        // 今日日程摘要条（有定时日程才出现）：能点到就进今日看板
        let barText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '场 ·'")).firstMatch
        if barText.exists && barText.isHittable {
            barText.tap()
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "B5 进入今日看板后崩溃")
            shoot("R16_daily_kanban")
        } else {
            print("[NAV] B5 今日无定时日程，摘要条未出现（空态表现：首页正常）")
            shoot("R16_home_empty_state")
        }

        restoreCalendarOnlySelection()
    }

    // MARK: - C 组：画面合理性

    func test_C1_深色模式走查() throws {
        guard openSettings() else { return }

        // 外观区切深色
        let dark = app.buttons["深色模式"].firstMatch
        guard scrollTo(dark) else {
            print("[NAV] C1 深色模式按钮未找到")
            shoot("D00_no_dark_btn")
            return
        }
        dark.tap()
        sleep(2)

        // 深色下设置页汇总行
        let summary = app.staticTexts["显示的日历"].firstMatch
        guard scrollTo(summary) else {
            print("[NAV] C1 深色下汇总行未找到")
            shoot("D01_no_summary_dark")
            return
        }
        shoot("D01_settings_dark", settle: 1)

        // 深色下进选择页（tap 后校验导航栏，失败重试一次）
        var entered = false
        for attempt in 0..<2 {
            let summary = app.staticTexts["显示的日历"].firstMatch
            guard scrollTo(summary) else { break }
            sleep(1)
            summary.tap()
            if app.navigationBars["显示的日历"].waitForExistence(timeout: 3) {
                entered = true
                break
            }
            print("[NAV] C1 深色下进选择页失败，重试 \(attempt)")
        }
        if entered {
            let explain = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '勾选的日历会显示在 Holo 日历页'")).firstMatch
            let badge = app.staticTexts["任务同步写入"].firstMatch
            print("[NAV] C1 深色选择页：说明卡=\(explain.exists) 徽章=\(badge.exists) 计数=\(String(describing: readSelectedCount()))")
            shoot("D02_picker_dark", settle: 2)
            // 滚到底看订阅组/行分隔线深色表现
            app.swipeUp()
            sleep(1)
            shoot("D02b_picker_dark_bottom")
            tapPickerBack()
        } else {
            print("[NAV] C1 深色下未能进入选择页")
            shoot("D02_no_picker_dark")
        }

        // 切回跟随系统（行按钮的辅助文本是聚合 label，用前缀匹配；行贴导航栏下沿时 tap 易失效，额外下滚+重试）
        let sysPred = NSPredicate(format: "label BEGINSWITH '跟随系统'")
        var switchedBack = false
        for _ in 0..<3 {
            let sysBtn = app.buttons.matching(sysPred).firstMatch
            guard scrollTo(sysBtn) else { continue }
            app.swipeDown()
            sleep(1)
            let visible = app.buttons.matching(sysPred).firstMatch
            if visible.exists && visible.isHittable {
                visible.tap()
                switchedBack = true
                sleep(2)
                break
            }
        }
        print("[NAV] C1 跟随系统 tap=\(switchedBack)")
        shoot("D03_restored_light", settle: 1)
        shoot("D03b_after_follow_system", settle: 1)
    }
}
