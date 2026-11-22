//
//  HabitPlanAVisualWalkthroughUITests.swift
//  HoloUITests
//
//  方案A（2026-10-12）视觉一致性走查：弹层近7天/···管理菜单/单习惯回顾对比卡+
//  每周完成率走势/创建表单后果行/测量型链路。截图双通道：XCTAttachment +
//  写入 runner Documents（宿主侧从 CoreSimulator 容器捞取，与 HTML 原型逐屏对照）。
//

import XCTest

final class HabitPlanAVisualWalkthroughUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1" // 播种数据 + 免引导
        app.terminate()
        app.launch()
    }

    // MARK: 截图双通道

    private func snap(_ name: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HabitPlanA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let png = try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: dir.appendingPathComponent("\(name).png")) {
            _ = png
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: 导航（与 V2 走查同款）

    @discardableResult
    private func enterHabitsModule() -> Bool {
        for label in ["习惯", "習慣"] {
            let match = app.buttons[label].firstMatch
            guard match.waitForExistence(timeout: 8) else { continue }
            let add = app.buttons["habit.add"].firstMatch
            for _ in 0..<2 {
                if add.exists { return true }
                if match.isHittable { match.tap() }
                if add.waitForExistence(timeout: 5) { return true }
            }
        }
        return false
    }

    private func waitFor(_ identifier: String, _ timeout: TimeInterval) -> Bool {
        app.otherElements[identifier].firstMatch.waitForExistence(timeout: timeout)
            || app.buttons[identifier].firstMatch.waitForExistence(timeout: timeout)
    }

    private func tapIdentifier(_ identifier: String) {
        let target = app.otherElements[identifier].firstMatch
        if target.exists { target.tap(); return }
        app.buttons[identifier].firstMatch.tap()
    }

    /// 按钮文案包含匹配（SwiftUI Button label 是 HStack 拼接全文，精确匹配不可靠）
    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 弹层已打开的信号：底部入口组出现（identifier 挂在非交互容器上 XCUITest 查不到，
    /// 一律用入口按钮 label 判断——与 V2 走查同口径）
    private func waitSheetOpened(_ timeout: TimeInterval) -> Bool {
        button(containing: "完整回顾").waitForExistence(timeout: timeout)
    }

    /// 打开播种习惯（晨间阅读，打卡型）的「今天的记录」弹层
    private func openSeededHabitSheet() -> Bool {
        let name = button(containing: "晨间阅读")
        if name.waitForExistence(timeout: 6) {
            name.tap()
            return waitSheetOpened(6)
        }
        app.swipeUp(velocity: .fast)
        if name.waitForExistence(timeout: 4) {
            name.tap()
            return waitSheetOpened(6)
        }
        return false
    }

    /// ··· 菜单（accessibilityLabel「习惯管理」；identifier 与 label 双通道）
    @discardableResult
    private func tapManageMenu() -> Bool {
        let byLabel = button(containing: "习惯管理")
        if byLabel.waitForExistence(timeout: 3) { byLabel.tap(); return true }
        let byId = app.buttons["habit.todayrecord.manage"].firstMatch
        if byId.waitForExistence(timeout: 2) { byId.tap(); return true }
        let other = app.otherElements["habit.todayrecord.manage"].firstMatch
        if other.waitForExistence(timeout: 2) { other.tap(); return true }
        return false
    }

    // MARK: 主走查

    func test01_打卡型_弹层与管理菜单与长期回顾() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        XCTAssertTrue(openSeededHabitSheet(), "未打开习惯弹层")

        // 弹层=操作层：近7天块在场（30 天大图已撤）——由弹层结构与入口断言
        XCTAssertTrue(waitFor("habit.todayrecord.manage", 4) || button(containing: "习惯管理").exists,
                      "缺 ··· 管理菜单")
        XCTAssertTrue(button(containing: "完整回顾").waitForExistence(timeout: 3),
                      "缺「完整回顾」入口")
        app.swipeUp(velocity: .fast) // 弹层拉到 large：露出底部入口组（截图与原型同视角）
        Thread.sleep(forTimeInterval: 0.8)
        snap("shot-02-sheet-checkin")

        // ··· 菜单展开态
        if !tapManageMenu() {
            tapIdentifier("habit.todayrecord.manage")
        }
        XCTAssertTrue(button(containing: "删除习惯").waitForExistence(timeout: 4), "菜单缺删除项")
        XCTAssertTrue(button(containing: "归档习惯").waitForExistence(timeout: 2), "菜单缺归档项")
        snap("shot-03-manage-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap() // 收起菜单

        // 完整回顾 → 单习惯回顾页（对比卡 + 每周完成率 + 日历）
        let review = button(containing: "完整回顾")
        XCTAssertTrue(review.waitForExistence(timeout: 4), "回顾入口消失")
        review.tap()
        XCTAssertTrue(waitFor("habit.single.range.d30", 8), "未进入单习惯回顾（范围切换条缺失）")
        Thread.sleep(forTimeInterval: 1.4) // 等图表渲染稳定
        snap("shot-04-review-checkin")
        XCTAssertTrue(app.staticTexts["每周完成率"].firstMatch.exists
                      || app.staticTexts["每周天数"].firstMatch.exists, "打卡型缺每周走势块")

        // 打卡型：每周走势与记录日历上下并存（东林拍板的原型屏C形态）
        XCTAssertTrue(app.staticTexts["记录日历"].firstMatch.waitForExistence(timeout: 4),
                      "打卡型缺常驻记录日历")
        XCTAssertTrue(app.staticTexts["每周完成率"].firstMatch.exists
                      || app.staticTexts["每周天数"].firstMatch.exists, "打卡型缺每周走势块")
        snap("shot-04b-review-checkin-calendar")

        // 内联范围切换：点「近30天」即切（不弹窗）
        let d30 = app.buttons["habit.single.range.d30"].firstMatch
        XCTAssertTrue(d30.waitForExistence(timeout: 4), "缺近30天档")
        d30.tap()
        Thread.sleep(forTimeInterval: 1.0)
        snap("shot-04c-review-checkin-d30")

        // 必点「全部」档：曾因 distantPast 死循环卡死闪退（真机实锤），10 秒内须完成渲染
        let allChip = app.buttons["habit.single.range.all"].firstMatch
        XCTAssertTrue(allChip.waitForExistence(timeout: 4), "缺全部档")
        allChip.tap()
        XCTAssertTrue(app.staticTexts["记录日历"].firstMatch.waitForExistence(timeout: 10),
                      "点「全部」后页面未在 10 秒内完成渲染（卡死回归）")
        Thread.sleep(forTimeInterval: 1.0)
        snap("shot-04d-review-checkin-all")

        // 稀疏态必测：只有 1 条记录的「拉伸」（图表须收缩形态而不是硬画残图）
        if app.buttons["habit.single.back"].firstMatch.waitForExistence(timeout: 3) {
            app.buttons["habit.single.back"].firstMatch.tap()
        }
        if app.buttons["habit.tab.today"].firstMatch.waitForExistence(timeout: 4) {
            app.buttons["habit.tab.today"].firstMatch.tap()
        }
        let sparseRow = button(containing: "拉伸")
        if sparseRow.waitForExistence(timeout: 5) {
            sparseRow.tap()
            if waitSheetOpened(5) {
                Thread.sleep(forTimeInterval: 0.6)
                app.swipeUp(velocity: .fast) // 内容滚到底：主按钮完整入镜
                Thread.sleep(forTimeInterval: 0.4)
                snap("shot-09-sparse-sheet")
                let sparseReview = button(containing: "查看长期回顾")
                if sparseReview.waitForExistence(timeout: 4) {
                    sparseReview.tap()
                    if waitFor("habit.single.range.d30", 8) {
                        Thread.sleep(forTimeInterval: 1.2)
                        snap("shot-10-sparse-review")
                    }
                }
            }
        }
    }

    func test02_创建表单后果行与测量型链路() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")

        // 创建表单：三卡后果行
        tapIdentifier("habit.add")
        let measureCard = button(containing: "测量")
        XCTAssertTrue(measureCard.waitForExistence(timeout: 6), "未见记录方式三卡")
        Thread.sleep(forTimeInterval: 0.5)
        snap("shot-05-form")

        // 创建测量型习惯 Weight（typeText 不支持中文输入）
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4), "未见名称输入")
        nameField.tap()
        nameField.typeText("Weight")
        measureCard.tap()
        app.buttons["保存"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.2)

        // 回今天页找 Weight 行，开弹层走测量输入
        XCTAssertTrue(waitFor("habit.tab.today", 6), "未回今天页")
        let row = button(containing: "Weight")
        var found = row.waitForExistence(timeout: 6)
        if !found {
            app.swipeUp(velocity: .fast)
            found = row.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(found, "未见新建的 Weight 习惯行")
        if !row.isHittable || row.frame.maxY > 680 {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.4)
        }
        row.tap()
        XCTAssertTrue(waitSheetOpened(6), "Weight 弹层未打开")
        snap("shot-06-sheet-measure-empty")
        app.swipeUp(velocity: .fast) // 弹层拉到 large：半高档位下主动作在屏外，坐标点击点不中
        Thread.sleep(forTimeInterval: 0.4)

        // 主动作 → 测量输入 → 保存（identifier 精确定位：文案匹配会命中今天页行内同名按钮）
        let record = app.buttons["habit.todayrecord.primary"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5), "缺测量主动作")
        record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 3)
        let field = app.textFields.matching(
            NSPredicate(format: "identifier == 'habit.measure.value'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "未弹出测量输入")
        field.typeText("74.2")
        tapIdentifier("habit.record.save")
        Thread.sleep(forTimeInterval: 1.0)

        // 再记录一次（造双点折线）
        let rowAgain = button(containing: "Weight")
        if rowAgain.waitForExistence(timeout: 5) {
            rowAgain.tap()
            let again = app.buttons["habit.todayrecord.primary"].firstMatch
            if again.waitForExistence(timeout: 4) {
                again.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let field2 = app.textFields.matching(
                    NSPredicate(format: "identifier == 'habit.measure.value'")).firstMatch
                if field2.waitForExistence(timeout: 5) {
                    field2.typeText("74.6")
                    tapIdentifier("habit.record.save")
                }
            }
            // 弹层：数值型近7天迷你折线
            let rowThird = button(containing: "Weight")
            if rowThird.waitForExistence(timeout: 4) {
                rowThird.tap()
                if waitSheetOpened(5) {
                    Thread.sleep(forTimeInterval: 0.6)
                    snap("shot-07-sheet-measure")
                    // 测量型长期回顾（趋势 + 对比卡）
                    let review = button(containing: "查看长期回顾")
                    if review.waitForExistence(timeout: 4) {
                        review.tap()
                        if waitFor("habit.single.range.d30", 8) {
                            Thread.sleep(forTimeInterval: 1.2)
                            snap("shot-08-review-measure")
                        }
                    }
                }
            }
        }
    }

    func test03_数值输入无完成重按钮与单点居中() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")

        // 新建计数习惯「Squat」验证输入 + 单点稀疏态
        tapIdentifier("habit.add")
        let countSegment = app.buttons["累计"].firstMatch
        XCTAssertTrue(countSegment.waitForExistence(timeout: 6), "未见记录方式分段控件")
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4), "未见名称输入")
        nameField.tap()
        let habitName = "Squat \(UUID().uuidString.prefix(6))"
        nameField.typeText(habitName)
        countSegment.tap()
        app.buttons["保存"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.2)

        let todayTab = app.buttons["habit.tab.today"].firstMatch
        XCTAssertTrue(todayTab.waitForExistence(timeout: 6), "未回今天页")
        let row = button(containing: habitName)
        let listBottom = todayTab.frame.minY
        // LazyVStack 会把底栏后方的行暴露给无障碍树，先把目标滚到可点击区域。
        for _ in 0..<5 where !row.exists || row.frame.maxY + 12 >= listBottom {
            app.swipeUp()
        }
        XCTAssertTrue(row.exists, "未见新建的 Squat 习惯行")
        let habitID = row.identifier.replacingOccurrences(of: "habit.rowbody.", with: "")
        let record = app.buttons["habit.row.\(habitID).record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 6), "习惯行缺少直接记数量入口")
        XCTAssertLessThan(record.frame.maxY, listBottom, "记数量按钮应滑到页签的上方")
        record.tap()

        let field = app.textFields.matching(
            NSPredicate(format: "identifier == 'habit.measure.value'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "未弹出数值输入")
        Thread.sleep(forTimeInterval: 0.8)

        // 键盘工具栏不再有冗余的「完成」按钮与「保存」叠压
        XCTAssertFalse(app.buttons["完成"].exists, "数值输入键盘上方不应再出现冗余「完成」按钮")
        snap("shot-measure-input-empty")

        field.typeText("50")
        Thread.sleep(forTimeInterval: 0.4)
        snap("shot-measure-input-filled")
        tapIdentifier("habit.record.save")
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue((record.value as? String)?.hasPrefix("50") == true, "行内记录按钮应直接显示当天累计")
        record.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 6), "应能从当天累计继续记录")
        field.typeText("40")
        tapIdentifier("habit.record.save")
        let totalUpdated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH '90'"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [totalUpdated], timeout: 5), .completed)

        let decrement = app.buttons["habit.row.\(habitID).decrement"].firstMatch
        XCTAssertTrue(decrement.isHittable, "当天有记录时应可在行内直接减去一笔")
        decrement.tap()
        let totalRestored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH '50'"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [totalRestored], timeout: 5), .completed)

        // 再打开 Squat 弹层：唯一记录单点图应精致居中、无巨圆
        let rowAgain = button(containing: habitName)
        XCTAssertTrue(rowAgain.waitForExistence(timeout: 5), "保存后未见 Squat 行")
        rowAgain.tap()
        XCTAssertTrue(app.buttons["habit.todayrecord.primary"].firstMatch.waitForExistence(timeout: 6), "未重开 Squat 弹层")
        Thread.sleep(forTimeInterval: 0.8)
        snap("shot-sheet-measure-single")
    }

    func test04_创建主题后可在今天展开与收起() throws {
        XCTAssertTrue(enterHabitsModule(), "未进入习惯模块")
        tapIdentifier("habit.more")
        XCTAssertTrue(app.buttons["habit.options.folders"].waitForExistence(timeout: 6), "缺少管理文件夹入口")
        tapIdentifier("habit.options.folders")
        XCTAssertTrue(app.buttons["habit.folders.create"].waitForExistence(timeout: 6), "缺少新建文件夹入口")
        tapIdentifier("habit.folders.create")

        let name = app.textFields["habit.folders.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        name.tap()
        let folderName = "Fitness \(UUID().uuidString.prefix(6))"
        name.typeText("\(folderName)\n")
        let appearance = app.buttons["habit.folders.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let sticker = app.buttons["选择贴纸"].firstMatch
        XCTAssertTrue(sticker.waitForExistence(timeout: 5))
        sticker.tap()
        let stickerPicker = app.navigationBars["选择贴纸"]
        XCTAssertTrue(stickerPicker.waitForExistence(timeout: 5), "应打开共用贴纸选择器")
        let stickerBack = stickerPicker.buttons.firstMatch
        XCTAssertTrue(stickerBack.waitForExistence(timeout: 5), "贴纸选择器应能返回文件夹编辑")
        stickerBack.tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        app.buttons["选择 Emoji"].firstMatch.tap()
        let emoji = app.buttons["😀"].firstMatch
        XCTAssertTrue(emoji.waitForExistence(timeout: 5), "应打开共用 Emoji 选择器")
        emoji.tap()
        let reading = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'habit.folders.candidate.' AND label CONTAINS %@", "晨间阅读"
        )).firstMatch
        let readingReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: reading)
        XCTAssertEqual(XCTWaiter.wait(for: [readingReady], timeout: 5), .completed, "未找到可移入的播种习惯")
        reading.tap()
        XCTAssertTrue(reading.isSelected, "点整行应选中要移入的习惯")
        tapIdentifier("habit.folders.save")

        let back = app.navigationBars.buttons["更多选项"]
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        back.tap()
        let close = app.buttons["关闭"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        close.tap()

        let folder = button(containing: folderName)
        let row = button(containing: "晨间阅读")
        XCTAssertTrue(folder.waitForExistence(timeout: 6) && row.exists, "文件夹默认展开")
        XCTAssertTrue((folder.value as? String)?.contains("1") == true, "文件夹里应有 1 项习惯")
        folder.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 4), "收起后隐藏组内习惯")
        folder.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 4), "展开后组内习惯可直接记录")
    }
}
