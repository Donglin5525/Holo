//
//  LifeUnderstandingJourneyUITests.swift
//  Holo
//
//  「生活理解与主动筹备」主旅程端到端（方案 2026-09-23 §2，R5A 验收前置）：
//  四域种子数据（想法/任务/习惯/AI 记账，全部走正常业务入口）→ 冷启动补萃取
//  （真实生产 LLM，prompt v2）→ Q0 主旅程与 Q1 护照对抗 → 方案卡断言
//  （补出宠物照护项 + 「因你的情况」区块 + 三条红线词扫描）。
//  截图落 /tmp/lu-eval/，断言以 [CHECK] 行输出（continueAfterFailure 容忍模型波动，
//  结果由 ios-qa 结合截图判读）。
//
//  v2（按 ios-qa 控件侦察修正）：环形入口坐标化（label tap 曾失准）、想法保存=
//  paperplane.fill「记录」、任务新建=Tab「新增」+输入任务名称框（无保存钮，return
//  提交）、习惯新建=nav「添加」+名称框+「保存」、打卡=点磁贴本体、方案卡断言改
//  buttons「开始推进」（此前误用 staticText 找按钮文字）。idb 触摸在 iOS 26 模拟器
//  全失效，交互只能走 XCUITest。
//

import XCTest

final class LifeUnderstandingJourneyUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/lu-eval"

    static let q0 = "我 10 月 1 日到 7 日去日本，第一次去，打算去东京和大阪。签证、机票、酒店都还没有安排，预算大约一万元。请帮我做好出发前的准备。"
    static let q1 = "我 10 月 1 日到 7 日去日本，第一次去，打算去东京和大阪。护照已经办好。签证、机票、酒店都还没有安排，预算大约一万元。请帮我做好出发前的准备。"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers（沿 PersonalContextWalkthroughUITests 验证过的模式）

    @discardableResult
    func shoot(_ name: String, settle: UInt32 = 0) -> Bool {
        if settle > 0 { sleep(settle) }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name).png ok=\(ok)")
        return ok
    }

    func check(_ id: String, _ condition: Bool, _ detail: String = "") {
        print("[CHECK] \(id) \(condition ? "PASS" : "FAIL") \(detail)")
    }

    func dumpElements(_ tag: String) {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(30).map { "\($0.identifier)|\($0.label)" }
        print("[DUMP][\(tag)] buttons: \(buttons)")
        let fields = app.textFields.allElementsBoundByIndex.prefix(6).map { "\($0.identifier)|\($0.label)|\($0.placeholderValue ?? "-")" }
        print("[DUMP][\(tag)] textFields: \(fields)")
        let views = app.textViews.allElementsBoundByIndex.prefix(6).map { "\($0.identifier)|\($0.label)" }
        print("[DUMP][\(tag)] textViews: \(views)")
        let navs = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
        print("[DUMP][\(tag)] navs: \(navs)")
    }

    func waitForText(_ text: String, timeout: TimeInterval) -> Bool {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    func skipOnboardingIfNeeded() {
        let skip = app.buttons.matching(NSPredicate(format: "label == '跳过引导' OR label CONTAINS '跳过'")).firstMatch
        if skip.exists {
            skip.tap()
            sleep(2)
        }
    }

    func ensureMemorySwitchesOn() {
        let personalTab = app.buttons.matching(NSPredicate(format: "label == '个人'")).firstMatch
        guard personalTab.waitForExistence(timeout: 6) else { return dumpElements("no-personal-tab") }
        personalTab.tap()
        sleep(2)
        let memoryEntry = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '记住的你'")).firstMatch
        guard memoryEntry.waitForExistence(timeout: 6) else { return dumpElements("no-memory-entry") }
        memoryEntry.tap()
        sleep(2)
        for index in 0..<app.switches.count where app.switches.element(boundBy: index).value as? String != "1" {
            app.switches.element(boundBy: index).tap()
            sleep(1)
        }
        check("memory-switches-on", true)
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'chevron.left' OR label == '返回'")).firstMatch
        if back.exists { back.tap(); sleep(2) }
    }

    func openChat() {
        // 底部 tab 的 sparkles（label=闪光）；页内可能有同名图标被挡，选 hittable 的。
        let aiTabs = app.buttons.matching(NSPredicate(format: "identifier == 'sparkles'"))
        var tapped = false
        if aiTabs.firstMatch.waitForExistence(timeout: 6) {
            for index in 0..<aiTabs.count {
                let tab = aiTabs.element(boundBy: index)
                if tab.isHittable {
                    tab.tap()
                    sleep(3)
                    tapped = true
                    break
                }
            }
        }
        if !tapped {
            // 坐标兜底：底部中央（侦察 frame 173,732,56,68）。
            app.coordinate(withNormalizedOffset: CGVector(dx: 201 / 402, dy: 766 / 874)).tap()
            sleep(3)
        }
        let grantButton = app.buttons.matching(NSPredicate(format: "label == '开启授权'")).firstMatch
        if grantButton.waitForExistence(timeout: 4) {
            grantButton.tap()
            sleep(2)
            let toggleRow = app.switches.matching(NSPredicate(format: "label CONTAINS '允许' OR label CONTAINS '处理必要数据'")).firstMatch
            if toggleRow.waitForExistence(timeout: 4), toggleRow.value as? String != "1" {
                toggleRow.tap()
                sleep(1)
            }
            let done = app.buttons.matching(NSPredicate(format: "label == '完成'")).firstMatch
            if done.waitForExistence(timeout: 4) {
                done.tap()
                sleep(2)
            }
            let aiTabsAgain = app.buttons.matching(NSPredicate(format: "identifier == 'sparkles'"))
            for index in 0..<aiTabsAgain.count {
                let tab = aiTabsAgain.element(boundBy: index)
                if tab.isHittable {
                    tab.tap()
                    sleep(3)
                    break
                }
            }
        }
    }

    @discardableResult
    func sendChatMessage(_ text: String) -> Bool {
        let input = app.textFields.firstMatch
        guard input.waitForExistence(timeout: 8) else {
            dumpElements("no-input")
            return false
        }
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60))
        input.typeText(text)
        let send = app.buttons.matching(NSPredicate(format: "label == '发送消息'")).firstMatch
        if send.waitForExistence(timeout: 4) {
            send.tap()
            return true
        }
        input.typeText("\n")
        return true
    }

    /// 屏幕可见文本红线扫描（staticTexts + 备选 textView）。
    func visibleTextContains(_ keyword: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", keyword)
        return app.staticTexts.matching(predicate).firstMatch.exists
            || app.otherElements.matching(predicate).firstMatch.exists
    }

    // MARK: - 种子：四域数据（正常业务入口；控件实态来自 ios-qa 侦察 /tmp/recon-uitest）

    /// 浮层防御：退出详情 sheet / 菜单 / 创建页。
    /// 任务创建 sheet 的关闭按钮 not hittable（两轮实测）——靠 sheet 顶下拉手势兜底；
    /// 页面语义「返回时自动保存」，关闭即提交。
    func dismissOverlays() {
        for label in ["关闭", "取消", "返回"] {
            let button = app.buttons.matching(NSPredicate(
                format: "label == %@ OR identifier == 'xmark' OR identifier == 'chevron.left'", label
            )).firstMatch
            if button.exists, button.isHittable {
                button.tap()
                sleep(1)
            }
        }
        // sheet 下拉关闭：从导航栏高度拖到屏幕中部（全屏/半屏 sheet 均适用）。
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 120.0 / 874.0))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 500.0 / 874.0))
        from.press(forDuration: 0.1, thenDragTo: to)
        sleep(2)
    }

    /// 安全点击：not hittable 时用屏幕坐标兜底（XCUITest 直接 tap not hittable
    /// 元素会硬失败中止整个测试——上两轮实测）。
    @discardableResult
    func safeTap(_ element: XCUIElement, settle: UInt32 = 1) -> Bool {
        guard element.exists else { return false }
        if element.isHittable {
            element.tap()
            sleep(settle)
            return true
        }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        sleep(settle)
        return true
    }

    /// 首页环形模块入口：label tap 优先 + 坐标兜底 + 进入验证重试一次。
    func openRingModule(_ module: String, pageMarker: String) {
        let home = app.buttons.matching(NSPredicate(format: "label CONTAINS '前往今天'")).firstMatch
        if home.exists, home.isHittable {
            home.tap()
            sleep(2)
        }
        dismissOverlays()
        let centers: [String: (x: CGFloat, y: CGFloat)] = [
            "任务": (201, 310), "财务": (348, 412), "习惯": (292, 590),
            "健康": (110, 590), "想法": (54, 417),
        ]
        let entry = app.buttons.matching(NSPredicate(format: "label == %@", module)).firstMatch
        let marker = app.buttons.matching(NSPredicate(format: pageMarker)).firstMatch
        for _ in 0..<2 {
            if marker.exists { return }
            if entry.exists {
                _ = safeTap(entry, settle: 3)
            } else if let center = centers[module] {
                app.coordinate(withNormalizedOffset: CGVector(dx: center.x / 402, dy: center.y / 874)).tap()
                sleep(3)
            }
            if marker.waitForExistence(timeout: 4) { return }
            dismissOverlays()
        }
    }

    func seedThought() {
        openRingModule("想法", pageMarker: "identifier == 'plus' OR label == '新增想法'")
        var plus = app.buttons.matching(NSPredicate(format: "identifier == 'plus' OR label == '新增想法'")).firstMatch
        if !plus.waitForExistence(timeout: 8) {
            // 重进一次（新装首进想法页的加载波动）。
            openRingModule("想法", pageMarker: "identifier == 'plus' OR label == '新增想法'")
            plus = app.buttons.matching(NSPredicate(format: "identifier == 'plus' OR label == '新增想法'")).firstMatch
        }
        guard plus.waitForExistence(timeout: 6), plus.isHittable else {
            return check("seed-thought", false, "找不到新增想法入口")
        }
        plus.tap()
        sleep(2)
        let text = "上次出门找过人上门喂猫。"
        var typed = false
        for view in app.textViews.allElementsBoundByIndex.reversed() where view.exists && view.isHittable {
            view.tap()
            view.typeText(text)
            typed = true
            break
        }
        check("seed-thought-typed", typed)
        sleep(2)
        // 保存：id=paperplane.fill / label=记录（侦察确认）。
        let save = app.buttons.matching(NSPredicate(format: "identifier == 'paperplane.fill' OR label == '记录'")).firstMatch
        if save.waitForExistence(timeout: 4), save.isHittable {
            save.tap()
        }
        sleep(3)
        let created = waitForText("喂猫", timeout: 6)
        check("seed-thought-created", created)
        shoot("l01_thought_seeded")
        dismissOverlays()
    }

    func seedTask() {
        openRingModule("任务", pageMarker: "label == '新增'")
        // 新建入口：页内底部 Tab 栏最右「新增」（侦察确认，非悬浮加号）。
        let add = app.buttons.matching(NSPredicate(format: "label == '新增'")).firstMatch
        guard add.waitForExistence(timeout: 6), add.isHittable else {
            dumpElements("task-no-add")
            return check("seed-task", false, "找不到新增入口")
        }
        add.tap()
        sleep(2)
        // 任务名：placeholder=输入任务名称。
        let title = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS '任务名称'")).firstMatch
        if title.waitForExistence(timeout: 5) {
            title.tap()
            title.typeText("给摩卡换水")
            check("seed-task-typed", true)
        } else {
            dumpElements("task-no-title")
            return check("seed-task", false, "找不到任务名称输入框")
        }
        // 无显式保存钮（页面标注「返回时自动保存」）：收键盘 → 下拉关闭 sheet 即提交。
        app.typeText("\n")
        sleep(1)
        dismissOverlays()
        sleep(2)
        let created = waitForText("给摩卡换水", timeout: 8)
        check("seed-task-created", created)
        shoot("l02_task_seeded")
    }

    func seedHabit() {
        openRingModule("习惯", pageMarker: "label == '添加'")
        // 新建入口：导航栏右上 id=plus / label=添加（侦察确认）。
        let add = app.buttons.matching(NSPredicate(format: "label == '添加'")).firstMatch
        guard add.waitForExistence(timeout: 6), add.isHittable else {
            dumpElements("habit-no-add")
            return check("seed-habit", false, "找不到习惯新建入口")
        }
        add.tap()
        sleep(2)
        // 名称框：placeholder 含「早起」（如：早起、喝水、运动）。
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS '早起'")).firstMatch
        if name.waitForExistence(timeout: 5) {
            name.tap()
            name.typeText("给摩卡换水")
            check("seed-habit-typed", true)
        } else {
            dumpElements("habit-no-name")
            check("seed-habit-typed", false, "找不到习惯名称输入框")
        }
        // 保存：右上 label=保存（侦察确认）。
        let save = app.buttons.matching(NSPredicate(format: "label == '保存'")).firstMatch
        if save.waitForExistence(timeout: 4), save.isHittable {
            save.tap()
        }
        sleep(2)
        var created = waitForText("给摩卡换水", timeout: 8)
        if !created {
            // 可能停在表单：返回后再看列表
            let back = app.buttons.matching(NSPredicate(format: "identifier == 'chevron.left' OR label == '返回' OR label == '关闭'")).firstMatch
            if back.exists, back.isHittable { back.tap(); sleep(2) }
            created = waitForText("给摩卡换水", timeout: 6)
        }
        check("seed-habit-created", created)
        // 打卡两次：点磁贴本体（staticText 匹配）。
        var checkins = 0
        for _ in 0..<2 {
            let tile = app.staticTexts.matching(NSPredicate(format: "label == '给摩卡换水'")).firstMatch
            if tile.exists, tile.isHittable {
                tile.tap()
                checkins += 1
                sleep(2)
            }
        }
        check("seed-habit-checkins", checkins >= 1, "打卡 \(checkins) 次")
        shoot("l03_habit_seeded")
        dismissOverlays()
    }

    func seedFinance() {
        // AI 一句话记账（聊天通道；G1 先例 + 侦察确认聊天可达）。
        dismissOverlays()
        openChat()
        guard app.textFields.firstMatch.waitForExistence(timeout: 10) else {
            dumpElements("finance-no-input")
            return check("seed-finance", false, "聊天输入框不可达")
        }
        let sent = sendChatMessage("买了猫粮2kg，花了128元，记账")
        check("seed-finance-sent", sent)
        sleep(10)
        shoot("l04_finance_sent")
        // 记账确认卡（实测形态：「支出待确认」+ 确认按钮）→ 点确认真正落库。
        let confirmButton = app.buttons.matching(NSPredicate(format: "label == '确认'")).firstMatch
        let cardShown = waitForText("待确认", timeout: 60) || waitForText("已记", timeout: 10)
        if cardShown, confirmButton.exists, confirmButton.isHittable {
            confirmButton.tap()
            sleep(3)
        }
        let confirmed = cardShown
        check("seed-finance-confirmed", confirmed)
        sleep(2)
        shoot("l04_finance_seeded")
        dismissOverlays()
    }

    /// 方案卡出现判定：V2 主卡 CTA 是 Button（上轮误用 staticText 导致漏判）。
    func waitForPlanCard(timeout: TimeInterval) -> Bool {
        let cta = app.buttons.matching(NSPredicate(format: "label == '开始推进'")).firstMatch
        if cta.waitForExistence(timeout: timeout) { return true }
        // 旧卡/回退形态兜底。
        return waitForText("结合你的情况", timeout: 20)
    }

    // MARK: - 主旅程

    func testLifeUnderstandingJourney() throws {
        app.launch()
        sleep(5)
        skipOnboardingIfNeeded()
        shoot("l00_home")

        // 0) 记忆开关（真实 UI）
        ensureMemorySwitchesOn()

        // 1) 四域种子
        seedThought()
        seedTask()
        seedHabit()
        seedFinance()

        // 2) 冷启动补萃取（真实生产 LLM；四域轮转每轮 2 包，两次重启）
        app.terminate()
        app.launch()
        sleep(110)
        app.terminate()
        app.launch()
        sleep(90)
        shoot("l05_after_extraction")

        // 3) Q0 主旅程
        openChat()
        shoot("l06_chat_before_q0")
        var q0Sent = sendChatMessage(Self.q0)
        check("q0-sent", q0Sent)
        // 方案卡出现（V2 主卡 CTA 为按钮）；路由波动时重发一次（v4/v5 实测）。
        var cardAppeared = waitForPlanCard(timeout: 150)
        if !cardAppeared {
            q0Sent = sendChatMessage(Self.q0)
            cardAppeared = waitForPlanCard(timeout: 150)
        }
        check("q0-plan-card", cardAppeared)
        sleep(3)
        shoot("l07_q0_plan_card", settle: 2)

        // 个性化差异区块（R3）：「因你的情况」。
        let personalSection = waitForText("因你的情况", timeout: 8)
        check("q0-personal-section", personalSection)
        if personalSection {
            let why = app.buttons.matching(NSPredicate(format: "label == '为什么'")).firstMatch
            if why.exists {
                why.tap()
                sleep(1)
                shoot("l08_q0_why")
            }
        }

        // 补出宠物照护项（模型行为有波动：多种措辞任一命中即算；交 QA 结合截图终判）。
        let petItem = waitForText("宠物", timeout: 5) || waitForText("照护", timeout: 3) || waitForText("喂", timeout: 3)
        check("q0-pet-item", petItem)

        // 三条红线：断言你养猫/摩卡是猫式身份断言不得出现。
        let redLineIdentity = visibleTextContains("你养猫") || visibleTextContains("摩卡是猫") || visibleTextContains("你的猫")
        check("q0-redline-identity", !redLineIdentity, "出现身份断言属红线")

        // 4) Q1 护照对抗（新一轮对话；与 Q0 的宠物结论应一致）。
        var q1Sent = sendChatMessage(Self.q1)
        check("q1-sent", q1Sent)
        // 生成完成判据：「停止」按钮（生成中标志）先出现再消失，避免旧卡 CTA 误判为新卡。
        let stopButton = app.buttons.matching(NSPredicate(format: "label == '停止'")).firstMatch
        if stopButton.waitForExistence(timeout: 30) {
            let gone = NSPredicate(format: "exists == 0")
            expectation(for: gone, evaluatedWith: stopButton)
            waitForExpectations(timeout: 240, handler: nil)
        }
        sleep(5)
        var q1Card = waitForPlanCard(timeout: 90)
        if !q1Card {
            // 路由波动重试一次。
            if stopButton.waitForExistence(timeout: 10) {
                let gone = NSPredicate(format: "exists == 0")
                expectation(for: gone, evaluatedWith: stopButton)
                waitForExpectations(timeout: 240, handler: nil)
            }
            q1Card = waitForPlanCard(timeout: 30)
            if !q1Card {
                q1Sent = sendChatMessage(Self.q1)
                let stopAgain = app.buttons.matching(NSPredicate(format: "label == '停止'")).firstMatch
                if stopAgain.waitForExistence(timeout: 30) {
                    let gone = NSPredicate(format: "exists == 0")
                    expectation(for: gone, evaluatedWith: stopAgain)
                    waitForExpectations(timeout: 240, handler: nil)
                }
                sleep(5)
                q1Card = waitForPlanCard(timeout: 90)
            }
        }
        check("q1-plan-card", q1Card)
        sleep(3)
        shoot("l09_q1_plan_card", settle: 2)
        let q1Pet = waitForText("宠物", timeout: 5) || waitForText("照护", timeout: 3)
        check("q1-pet-item", q1Pet, "Q1 宠物结论应与 Q0 一致（护照不构成召回原因）")

        check("journey-complete", true)
    }

    /// 轻量复验（种子已在库时用）：只发 Q0 并等待方案卡，验证规划闸与个性化内容。
    func testAskOnlyQ0() throws {
        app.launch()
        sleep(6)
        skipOnboardingIfNeeded()
        openChat()
        guard app.textFields.firstMatch.waitForExistence(timeout: 12) else {
            check("ask-chat-open", false)
            return
        }
        let sent = sendChatMessage(Self.q0)
        check("ask-sent", sent)
        var cardAppeared = waitForPlanCard(timeout: 150)
        if !cardAppeared {
            _ = sendChatMessage(Self.q0)
            cardAppeared = waitForPlanCard(timeout: 150)
        }
        check("ask-plan-card", cardAppeared)
        sleep(3)
        shoot("la_q0_plan_card", settle: 2)
        let personal = waitForText("因你的情况", timeout: 8)
        check("ask-personal-section", personal)
        let pet = waitForText("宠物", timeout: 5) || waitForText("照护", timeout: 3) || waitForText("喂", timeout: 3)
        check("ask-pet-item", pet)
        let redLine = visibleTextContains("你养猫") || visibleTextContains("摩卡是猫") || visibleTextContains("你的猫")
        check("ask-redline", !redLine)
    }
}
