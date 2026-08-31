//
//  HoloCloudAnalysisQAUITests.swift
//  Holo
//
//  【临时验收脚本】云端深度分析全流程驱动（QA 专用，验收后删除）：
//  财务页查数据 → 记 3 笔支出（含备注 TIMA音乐盛典测试）→ AI 对话发起深度分析
//  → 首次同意云端隐私说明 → 二次发起触发云端轨道 → 等待结果卡片并全程截图。
//

import XCTest

final class HoloCloudAnalysisQAUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_cloud_test/uitest"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    // MARK: - Helpers

    @discardableResult
    func shoot(_ name: String) -> Bool {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let ok = (try? png.write(to: URL(fileURLWithPath: "\(Self.dir)/\(name).png"))) != nil
        print("[SHOT] \(name) ok=\(ok)")
        return ok
    }

    func labelCount(_ text: String) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).count
    }

    /// 中文输入：优先 typeText，失败（值未变化）走共享剪贴板粘贴（模拟器与宿主同剪贴板）
    /// 全程用坐标点按聚焦，避免界面重渲染时元素快照失效中断用例
    func typeChinese(into field: XCUIElement, text: String) {
        var frame: CGRect? = nil
        for _ in 0..<10 {
            if field.exists && field.isHittable {
                frame = field.frame
                break
            }
            sleep(1)
        }
        guard let f = frame else {
            print("[TYPE] 输入框始终不可点，跳过输入")
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        sleep(1)
        if field.exists { field.typeText(text) }
        sleep(1)
        let after = (field.exists ? (field.value as? String) : nil) ?? ""
        if after.contains(String(text.prefix(4))) {
            print("[TYPE] typeText 成功: \(after)")
            return
        }
        print("[TYPE] typeText 失败(after='\(after)')，改用剪贴板粘贴")
        UIPasteboard.general.string = text
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.midX, dy: f.midY)).press(forDuration: 1.4)
        sleep(1)
        let paste = app.menuItems["粘贴"].firstMatch.exists
            ? app.menuItems["粘贴"].firstMatch
            : app.menuItems["Paste"].firstMatch
        if paste.exists {
            paste.tap()
            sleep(1)
        }
        print("[TYPE] 粘贴后 value='\((field.exists ? (field.value as? String) : nil) ?? "")'")
    }

    /// 点可点击的 checkmark（键盘遮挡的数字键盘 ✓ 不可点，须点表单右上角保存 ✓）
    @discardableResult
    func tapHittableCheckmark() -> Bool {
        let saves = app.buttons.matching(NSPredicate(format: "identifier == 'checkmark'"))
        for i in 0..<saves.count {
            let b = saves.element(boundBy: i)
            if b.isHittable {
                b.tap()
                print("[SAVE] tapped hittable checkmark #\(i)")
                return true
            }
        }
        print("[SAVE] 无可点击 checkmark")
        return false
    }

    /// 按元素帧坐标点按（绕过元素类型差异）
    func tapByCoord(_ el: XCUIElement) -> Bool {
        guard el.exists else { return false }
        let f = el.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        return true
    }

    // MARK: - 记一笔（单笔）

    /// 子分类：canSave 要求 selectedCategory.isSubCategory == true，必须选到二级分类
    func addExpense(amount: String, subCategory: String, parentToDrill: String?, note: String?, idx: Int) {
        let fab = app.buttons["添加"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 8), "记一笔悬浮按钮未找到")
        fab.tap()
        sleep(2)
        XCTAssertTrue(app.staticTexts["记一笔"].firstMatch.waitForExistence(timeout: 5), "记账表单未打开")
        shoot("u1\(idx)_sheet")

        // 金额：数字键盘默认展开，直接按数字键
        for ch in amount {
            let key = app.buttons[String(ch)].firstMatch
            if key.exists { key.tap() } else { print("[ADD] 键 \(ch) 未找到") }
            usleep(150_000)
        }
        sleep(1)

        // 分类：先点父类下钻（如需要），再点二级子分类
        if let parent = parentToDrill {
            let parentText = app.staticTexts[parent].firstMatch
            if tapByCoord(parentText) {
                print("[ADD] 已下钻父类 \(parent)")
                sleep(1)
            } else {
                print("[ADD] 父类 \(parent) 未找到")
            }
        }
        var catOK = false
        for q in [app.buttons[subCategory].firstMatch, app.staticTexts[subCategory].firstMatch] {
            if q.exists {
                _ = tapByCoord(q)
                catOK = true
                sleep(1)
                break
            }
        }
        print("[ADD] 子分类 \(subCategory) \(catOK ? "已选" : "未找到！")")

        // 备注（有则填；填完点键盘辅助条「完成」收起系统键盘）
        if let note = note {
            let nameField = app.textFields["名称"].firstMatch
            if nameField.exists {
                typeChinese(into: nameField, text: note)
                sleep(1)
                let done = app.buttons["完成"].firstMatch
                if done.exists { done.tap(); sleep(1) }
            } else {
                print("[ADD] 名称输入框未找到")
            }
        }

        // 保存
        if !tapHittableCheckmark() {
            print("[ADD] checkmark 未找到，dump 当前元素")
            print(app.debugDescription)
        }
        sleep(2)
        // 确认表单已关闭；未关则再补一次可点击的 checkmark
        if app.staticTexts["记一笔"].firstMatch.exists {
            print("[ADD] 表单未关闭，补按")
            tapHittableCheckmark()
            sleep(2)
        }
        shoot("u1\(idx)_after_save")
    }

    // MARK: - 主流程

    func testCloudDeepAnalysisBaseline() throws {
        try FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        app.launch()
        sleep(5)
        shoot("u01_home")

        // ========== 1. 财务页：查现有数据 ==========
        let finance = app.buttons["财务"].firstMatch
        XCTAssertTrue(finance.waitForExistence(timeout: 15), "首页财务按钮未找到")
        finance.tap()
        sleep(3)
        shoot("u02_finance")
        print("[DATA] 财务页含¥文本数 = \(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '¥'")).count)")

        // ========== 2. 记 3 笔支出（已有数据则跳过） ==========
        let emptyHint = app.staticTexts["点击 + 按钮记一笔"].firstMatch
        if emptyHint.waitForExistence(timeout: 4) {
            addExpense(amount: "88", subCategory: "早餐", parentToDrill: nil, note: nil, idx: 0)
            addExpense(amount: "3316", subCategory: "音乐", parentToDrill: "娱乐", note: "TIMA音乐盛典测试", idx: 1)
            addExpense(amount: "45", subCategory: "晚餐", parentToDrill: nil, note: nil, idx: 2)
        } else {
            print("[DATA] 账本已有数据，跳过造数")
        }

        // ========== 3. 进入 AI 对话页（先退出财务模块回首页，再点底部 AI 圆球） ==========
        for _ in 0..<3 {
            let backBtn = app.buttons["返回"].firstMatch
            if backBtn.exists {
                backBtn.tap()
                sleep(2)
            } else { break }
        }
        shoot("u05_back_home")
        let orb = app.buttons["闪光"].firstMatch
        XCTAssertTrue(orb.waitForExistence(timeout: 8), "AI 圆球未找到")
        orb.tap()
        sleep(3)
        shoot("u06_chat")

        var input = app.textFields["输入消息..."].firstMatch
        if !input.waitForExistence(timeout: 6) {
            // AI 数据处理授权门禁：点「开启授权」→ 打开开关 → 完成
            let gate = app.buttons["开启授权"].firstMatch
            if gate.waitForExistence(timeout: 6) {
                shoot("u06b_ai_gate")
                gate.tap()
                print("[FLOW] 已点开启授权")
                sleep(2)
                let toggle = app.switches.firstMatch
                if toggle.waitForExistence(timeout: 6) {
                    // 点开关本体（行右侧），最多试 3 次直到状态翻转为 1
                    for attempt in 0..<3 {
                        if (toggle.value as? String) == "1" { break }
                        let f = toggle.frame
                        let dx = f.maxX - 20   // 开关在行右侧
                        let dy = f.midY
                        app.coordinate(withNormalizedOffset: .zero)
                            .withOffset(CGVector(dx: dx, dy: dy)).tap()
                        sleep(1)
                        print("[FLOW] 开关点按尝试 \(attempt + 1)，value=\((toggle.value as? String) ?? "?")")
                    }
                    if (toggle.value as? String) == "1" {
                        print("[FLOW] 授权开关已开")
                    } else {
                        print("[FLOW] 授权开关未打开，继续尝试完成")
                    }
                    sleep(1)
                    shoot("u06c_toggle")
                } else {
                    print("[FLOW] 未找到授权开关")
                }
                let done = app.buttons["完成"].firstMatch
                if done.exists {
                    done.tap()
                    print("[FLOW] 已点完成")
                }
                // 等待授权 sheet 关闭且聊天界面稳定（最多 15 秒）
                for _ in 0..<15 {
                    if !app.buttons["开启授权"].firstMatch.exists
                        && !app.buttons["完成"].firstMatch.exists {
                        break
                    }
                    sleep(1)
                }
                sleep(2)
                shoot("u06d_after_gate")
            }
            input = app.textFields["输入消息..."].firstMatch
            if !input.waitForExistence(timeout: 8) {
                orb.tap()
                sleep(3)
                input = app.textFields["输入消息..."].firstMatch
            }
        }
        if !input.exists {
            print("[CHAT] 输入框未找到，dump 当前页面元素（截断）")
            let desc = app.debugDescription
            print(String(desc.prefix(4000)))
        }
        XCTAssertTrue(input.waitForExistence(timeout: 10), "聊天输入框未找到")
        shoot("u07_chat_ready")

        // ========== 4. 第一次发送（触发隐私说明，本次本地分析） ==========
        let prompt = "帮我深度分析一下我最近的消费结构，看看有什么问题"
        typeChinese(into: input, text: prompt)
        shoot("u08_typed")
        let send = app.buttons["发送消息"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 8), "发送按钮未找到")
        send.tap()
        sleep(2)

        // 隐私说明 sheet（只出现一次）
        let consent = app.buttons["知道了，下次开始用云端分析"].firstMatch
        if consent.waitForExistence(timeout: 12) {
            shoot("u09_privacy_sheet")
            consent.tap()
            print("[FLOW] 已同意云端隐私说明")
            sleep(2)
            // 本次仍本地分析：重新发送一次以进入云端轨道
            let input2 = app.textFields["输入消息..."].firstMatch
            if input2.waitForExistence(timeout: 6) {
                typeChinese(into: input2, text: prompt)
                let send2 = app.buttons["发送消息"].firstMatch
                if send2.exists { send2.tap() }
                print("[FLOW] 二次发送以触发云端分析")
            }
        } else {
            print("[FLOW] 未出现隐私 sheet（可能已同意过），本次即云端轨道")
        }
        sleep(3)
        shoot("u10_sent")

        // ========== 5. 等待结果（最长 12 分钟），每 20 秒采样 ==========
        var done = false
        for round in 0..<36 {
            sleep(20)
            let deep = labelCount("深度分析")
            let evidence = labelCount("证据") + labelCount("依据")
            print("[WAIT] round=\(round) 深度分析=\(deep) 证据/依据=\(evidence)")
            if deep >= 2 && round > 1 {
                sleep(6)
                shoot("u11_result_r\(round)")
                done = true
                break
            }
            if round % 3 == 2 { shoot("u10_wait_r\(round)") }
        }
        shoot("u12_final")
        print("[RESULT] done=\(done) 深度分析=\(labelCount("深度分析")) 证据=\(labelCount("证据")) 依据=\(labelCount("依据")) 近180天=\(labelCount("近180天")) TIMA=\(labelCount("TIMA"))")
    }
}
