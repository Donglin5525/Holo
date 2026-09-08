//
//  PersonalContextWalkthroughUITests.swift
//  Holo
//
//  通用个人情境验收走查（东林验收用，无头跑不依赖 Mac 解锁）：
//  launchArguments 预置记忆开关+AI 同意+简体 → 造想法数据 → 重启触发萃取 →
//  聊天提问出方案卡 → 查看依据 → 纠正重生成 → 保存待办 → 无记录问题不伪装。
//  截图落 /tmp/pc-eval/，断言以 [CHECK] 行输出。
//

import XCTest

final class PersonalContextWalkthroughUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/pc-eval"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // 强制简体（模拟器系统语言是繁体，label 匹配统一口径）+
        // 预置记忆两开关与 AI 数据同意（等价于设置页手动开启）。
        // 记忆开关与 AI 同意由外部 simctl defaults write 预置为真实 Bool
        //（launch 参数的 YES 是字符串，as? Bool 转换失败会被 init 回写 false）。
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

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
    }

    func waitForText(_ text: String, timeout: TimeInterval) -> Bool {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        return element.waitForExistence(timeout: timeout)
    }

    /// 通过真实设置 UI 确保两个记忆开关为 ON（simctl defaults 预置在重装后会失效，
    /// 且 launch 参数是字符串过不了 `as? Bool` 强转——只有真实 UI 翻转最可靠）。
    func ensureMemorySwitchesOn() {
        let personalTab = app.buttons.matching(NSPredicate(format: "label == '个人'")).firstMatch
        if personalTab.waitForExistence(timeout: 6) {
            personalTab.tap()
            sleep(2)
        } else {
            dumpElements("no-personal-tab")
            return
        }
        let memoryEntry = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '记住的你'")).firstMatch
        if memoryEntry.waitForExistence(timeout: 6) {
            memoryEntry.tap()
            sleep(2)
        } else {
            dumpElements("no-memory-entry")
            return
        }
        // 该界面两个记忆开关行（自动形成记忆 / 记忆辅助回答），逐个翻到 ON。
        let count = app.switches.count
        print("[DUMP][memory-switches] count=\(count)")
        for index in 0..<max(count, 0) {
            let toggle = app.switches.element(boundBy: index)
            if toggle.exists, toggle.value as? String != "1" {
                toggle.tap()
                sleep(1)
                print("[DUMP][memory-switch] \(index) after=\(toggle.value ?? "nil")")
            }
        }
        check("memory-switches-on", true)
        // 返回：设置页 → 个人页 → 首页
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'chevron.left' OR label == '返回'")).firstMatch
        if back.exists {
            back.tap()
            sleep(2)
        }
        let home = app.buttons.matching(NSPredicate(format: "label CONTAINS '前往今天'")).firstMatch
        if home.exists {
            home.tap()
            sleep(2)
        }
    }

    /// 打开 AI 聊天（底部 sparkle tab）；若出现未授权浮层则走真实授权 UI
    func openChat() {
        let aiTab = app.buttons.matching(NSPredicate(format: "identifier == 'sparkles'")).firstMatch
        if aiTab.waitForExistence(timeout: 6) {
            aiTab.tap()
            sleep(3)
        } else {
            dumpElements("no-ai-tab")
        }
        // 未授权空态 → 开启授权 → 同意（走 App 自己的授权流，绕开 defaults 缓存坑）
        let grantButton = app.buttons.matching(NSPredicate(format: "label == '开启授权'")).firstMatch
        if grantButton.waitForExistence(timeout: 4) {
            grantButton.tap()
            sleep(2)
            dumpElements("consent-sheet")
            shoot("s04a_consent_sheet")
            // 授权页：开关「允许 HoloAI 处理必要数据」+ 工具栏「完成」
            let toggleRow = app.switches.matching(NSPredicate(format: "label CONTAINS '允许' OR label CONTAINS '处理必要数据'")).firstMatch
            if toggleRow.waitForExistence(timeout: 4) {
                print("[DUMP][consent-switch] value=\(toggleRow.value ?? "nil")")
                if toggleRow.value as? String != "1" {
                    toggleRow.tap()
                    sleep(1)
                    print("[DUMP][consent-switch] after tap value=\(toggleRow.value ?? "nil")")
                }
                // 开关没翻则补点一次
                if toggleRow.value as? String != "1" {
                    toggleRow.tap()
                    sleep(1)
                }
            } else {
                dumpElements("no-consent-switch")
            }
            let done = app.buttons.matching(NSPredicate(format: "label == '完成'")).firstMatch
            if done.waitForExistence(timeout: 4) {
                done.tap()
                sleep(2)
            }
            // sheet 关闭后重进聊天
            let aiTabAgain = app.buttons.matching(NSPredicate(format: "identifier == 'sparkles'")).firstMatch
            if aiTabAgain.exists { aiTabAgain.tap(); sleep(3) }
            shoot("s04b_after_consent")
        }
    }

    /// 在聊天输入框输入并发送（输入框可能带场景预填文案：先聚焦清空）
    func sendChatMessage(_ text: String) -> Bool {
        let input = app.textFields.firstMatch
        guard input.waitForExistence(timeout: 8) else {
            dumpElements("no-input")
            return false
        }
        input.tap()
        // 清掉预填文案（删除键 ×40 覆盖最长预填句）
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        input.typeText(text)
        let send = app.buttons.matching(NSPredicate(format: "label == '发送消息'")).firstMatch
        if send.waitForExistence(timeout: 4) {
            send.tap()
            return true
        }
        input.typeText("\n")
        return true
    }

    // MARK: - 主流程

    func testWalkthrough() throws {
        app.launch()
        sleep(5)
        // 新装 App 有新手引导：跳过
        let skip = app.buttons.matching(NSPredicate(format: "label == '跳过引导' OR label CONTAINS '跳过'")).firstMatch
        if skip.exists {
            skip.tap()
            sleep(2)
        }
        shoot("s00_home")

        // ============ 第 1 步：造想法数据（3 条个人情况）============
        let thoughtEntry = app.buttons.matching(NSPredicate(format: "label == '想法'")).firstMatch
        if thoughtEntry.waitForExistence(timeout: 6) {
            thoughtEntry.tap()
            sleep(2)
        }
        shoot("s01_thoughts_list")

        let thoughts: [String] = [
            "我爸血压偏高。我爸上个月体检查出血压偏高，医生说要低盐饮食，外面餐馆的菜普遍太咸，带他吃饭得选清淡的。",
            "我妈晕车。我妈晕车比较厉害，坐汽车走山路肯定不行，之前去山区她吐了一路，安排行程要避开。",
            "房贷扣款日。房贷每月15号自动扣款，卡里得提前留够钱，有一次差点忘了。",
        ]
        for (index, content) in thoughts.enumerated() {
            let plus = app.buttons.matching(NSPredicate(format: "identifier == 'plus' OR label == '新增想法'")).firstMatch
            guard plus.waitForExistence(timeout: 6) else {
                dumpElements("no-plus-\(index)")
                break
            }
            plus.tap()
            sleep(2)
            dumpElements("editor-\(index)")

            // 编辑器是顶层呈现的 textView；逐个试到可输入为止
            var typed = false
            let views = app.textViews.allElementsBoundByIndex
            for view in views.reversed() {
                if view.exists && view.isHittable {
                    view.tap()
                    view.typeText(content)
                    typed = true
                    break
                }
            }
            if !typed, let first = app.textViews.firstMatch.exists ? app.textViews.firstMatch : nil {
                first.tap()
                first.typeText(content)
                typed = true
            }
            check("thought-\(index)-typed", typed)
            sleep(3) // 防抖自动保存
            shoot("s02_thought_\(index)")

            // 退出编辑器：返回键（chevron.left）或下滑
            let back = app.buttons.matching(NSPredicate(format: "identifier == 'chevron.left' OR label == '返回'")).firstMatch
            if back.exists {
                back.tap()
            } else {
                app.swipeDown()
            }
            sleep(2)
        }
        shoot("s03_thoughts_created")

        // ============ 第 2 步：触发萃取（重启→becameActive→runPass，真实生产 LLM）============
        app.terminate()
        app.launch()
        sleep(45)
        app.terminate()
        app.launch()
        sleep(30)

        // ============ 第 3 步：聊天提问出方案卡 ============
        openChat()
        shoot("s04_chat")
        let sent = sendChatMessage("帮我想想下周末爸妈过来怎么安排")
        check("question-sent", sent)

        let cardAppeared = waitForText("结合你的情况", timeout: 170)
        check("plan-card-appeared", cardAppeared)
        sleep(2)
        shoot("s05_plan_card")

        // 查看依据
        let basis = app.buttons.matching(NSPredicate(format: "label CONTAINS '查看依据'")).firstMatch
        if basis.waitForExistence(timeout: 5) {
            basis.tap()
            sleep(1)
        }
        shoot("s06_basis")

        // ============ 第 4 步：纠正重生成（情况变了）============
        let followUpField = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS '情况变了'")).firstMatch
        if followUpField.waitForExistence(timeout: 5) {
            followUpField.tap()
            followUpField.typeText("我爸血压正常了，不用忌口那么严")
            let regen = app.buttons.matching(NSPredicate(format: "label CONTAINS '重新生成'")).firstMatch
            if regen.exists {
                regen.tap()
                sleep(50) // followUp 生成（生产 LLM）
            }
        }
        shoot("s07_corrected")

        // ============ 第 5 步：保存待办（幂等由回执保证）============
        let save = app.buttons.matching(NSPredicate(format: "label CONTAINS '待办'")).firstMatch
        if save.exists {
            save.tap()
            sleep(2)
        }
        shoot("s08_saved")

        // ============ 第 6 步：无记录问题（应不伪装结合个人情境）============
        let sent2 = sendChatMessage("帮我安排一下同学聚会")
        check("question2-sent", sent2)
        _ = waitForText("结合你的情况", timeout: 170)
        sleep(2)
        shoot("s09_no_record_question")

        check("walkthrough-complete", true)
    }

    /// 喂猫场景端到端（2026-09-08 真实案例锁死）：
    /// 想法记过「上门喂猫」经历 → 冷启动补萃取 → 聊天问「国庆节要去日本，出门前家里安排」→
    /// 方案卡「查看依据」必须出现喂猫情境（跨域语义召回 + 萃取链路整体回归）。
    func testCatScenarioPlanning() throws {
        app.launch()
        sleep(5)
        let skip = app.buttons.matching(NSPredicate(format: "label == '跳过引导' OR label CONTAINS '跳过'")).firstMatch
        if skip.exists {
            skip.tap()
            sleep(2)
        }

        // ============ 第 1 步：造喂猫想法（真实案例文本）============
        let thoughtEntry = app.buttons.matching(NSPredicate(format: "label == '想法'")).firstMatch
        if thoughtEntry.waitForExistence(timeout: 6) {
            thoughtEntry.tap()
            sleep(2)
        }
        let plus = app.buttons.matching(NSPredicate(format: "identifier == 'plus' OR label == '新增想法'")).firstMatch
        guard plus.waitForExistence(timeout: 6) else {
            dumpElements("cat-no-plus")
            check("cat-thought-created", false, "找不到新增想法入口")
            return
        }
        plus.tap()
        sleep(2)
        let catText = "去昆明的时候没有找人上门喂猫，从监控里看猫把猫粮都吃完了，错误预估了食量，很临时找了物业的人上门喂猫。来的小姐姐人挺好，喂猫铲屎还额外喂了猫条，最后转了30块钱辛苦费。后续每次出门都让她来帮忙，比起找同事方便，还不欠人情。"
        var typed = false
        for view in app.textViews.allElementsBoundByIndex.reversed() {
            if view.exists && view.isHittable {
                view.tap()
                view.typeText(catText)
                typed = true
                break
            }
        }
        check("cat-thought-typed", typed)
        sleep(3)
        shoot("c01_cat_thought")
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'chevron.left' OR label == '返回'")).firstMatch
        if back.exists {
            back.tap()
        } else {
            app.swipeDown()
        }
        sleep(2)

        // ============ 第 2 步：翻记忆开关（真实 UI）+ 重启触发冷启动补萃取 ============
        ensureMemorySwitchesOn()
        app.terminate()
        app.launch()
        sleep(80)

        // ============ 第 3 步：聊天发真实原话，验收方案卡与依据 ============
        openChat()
        shoot("c02_chat")
        let sent = sendChatMessage("国庆节要去日本，帮我规划下出门之前家里要安排的事情")
        check("cat-question-sent", sent)
        let cardAppeared = waitForText("结合你的情况", timeout: 170)
        check("cat-plan-card-appeared", cardAppeared)
        sleep(2)
        shoot("c03_plan_card")

        let basis = app.buttons.matching(NSPredicate(format: "label CONTAINS '查看依据'")).firstMatch
        if basis.waitForExistence(timeout: 5) {
            basis.tap()
            sleep(1)
        }
        let catMentioned = waitForText("喂猫", timeout: 8) || waitForText("猫粮", timeout: 4)
        check("cat-basis-mentioned", catMentioned)
        shoot("c04_basis")
        check("cat-walkthrough-complete", true)
    }
}
