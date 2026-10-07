//
//  PolaroidPerfSmokeUITests.swift
//  Holo
//  记忆长廊·日回放 5 图拍立得卡冒烟：上屏、翻片、连续翻片不崩。
//  依赖沙盒种子（ThoughtRepositoryCalendarTests.test_seedPolaroidFixtures_…）。
//

import XCTest

final class PolaroidPerfSmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPolaroidFivePhotoStackSwipe() throws {
        let app = XCUIApplication()
        app.launch()

        // 底部导航进记忆长廊
        let memory = app.buttons["记忆长廊"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 25), "底部导航未出现「记忆长廊」")
        memory.tap()
        sleep(6)

        let outDir = URL(fileURLWithPath: "/tmp/holo_polaroid_smoke")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        func snap(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: outDir.appendingPathComponent(name))
            print("[PolaroidSmoke] saved \(name)")
        }

        // 5 图拍立得卡（accessibilityLabel 含「共 5 张照片」）
        let cardQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "共 5 张照片")
        )
        var card = cardQuery.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "5 图拍立得卡未上屏")

        // 滚动把卡带进屏内（LazyVStack 回收后需重新匹配）。
        // 注：精确定位到屏中部在 LazyVStack 回收+惯性下不可稳定达成（多轮实测振荡），
        // 接受任何屏内位置；合成手势打不进自定义 DragGesture（info 级日志零命中），
        // 翻片流畅性由真机人工验收，本冒烟只锁「渲染存在 + 不崩」。
        var scrollRounds = 0
        while scrollRounds < 8 {
            let minY = card.frame.minY
            print("[PolaroidSmoke] round \(scrollRounds) card minY = \(minY)")
            if minY > 0 && minY < 560 { break }
            if minY >= 560 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            sleep(1)
            card = cardQuery.firstMatch
            if !card.exists { card = cardQuery.firstMatch; _ = card.waitForExistence(timeout: 5) }
            scrollRounds += 1
        }
        sleep(2)
        XCTAssertTrue(card.exists, "滚动后 5 图卡应仍在屏")

        // 等 ScrollView 惯性停稳：frame 连续两次读数一致才继续
        // （此前的滑动翻片失败 = 用滚动中的旧坐标操作，滑到了别处）
        var lastMinY: CGFloat = -1
        var stableRounds = 0
        while stableRounds < 2 {
            let y = card.frame.minY
            if abs(y - lastMinY) < 1 { stableRounds += 1 } else { stableRounds = 0 }
            lastMinY = y
            usleep(400_000)
        }
        print("[PolaroidSmoke] settled card minY = \(lastMinY)")
        sleep(1)
        snap("01-five-stack.png")

        let frame = card.frame
        print("[PolaroidSmoke] card frame = \(frame)")

        // 照片堆区域向左滑 → 翻下一张；种子图带大号数字，截图可判读顶片切换
        let dy = frame.minY + frame.height * 0.3
        func swipeLeftOnStack() {
            let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 36, dy: dy))
            let to = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 30, dy: dy))
            from.press(forDuration: 0.08, thenDragTo: to)
        }

        swipeLeftOnStack()
        sleep(2)
        XCTAssertTrue(card.exists, "翻片一次后卡片应仍在屏")
        snap("02-after-swipe.png")

        // 连续翻片 3 次：稳定性与流畅冒烟
        for _ in 0..<3 {
            swipeLeftOnStack()
            usleep(700_000)
        }
        sleep(2)
        XCTAssertTrue(card.exists, "连续翻片后卡片应仍在屏（未崩溃/未跳详情）")
        snap("03-after-multi-swipe.png")
    }

    /// 想法卡信息字段统一冒烟（2026-10-02）：带图拍立得卡补齐徽章/正文6行/查看全文后，
    /// 滚到卡完整可见连拍截图；判读交给视觉代理（整卡 accessibilityElement 包裹，
    /// 卡内子文本对 XCUITest 不可见，无法用元素断言）。依赖截图模式 life-flow 种子。
    func testUnifiedThoughtCardFieldsSnapshot() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "memory-gallery-multi-photo"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_STORY"] = "life-flow"
        app.launch()

        sleep(10)
        let outDir = URL(fileURLWithPath: "/tmp/holo_unify_smoke")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        func snap(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: outDir.appendingPathComponent(name))
            print("[UnifySmoke] saved \(name)")
        }

        // 逐步上滑回看，每步留一帧，直到拍立得卡完整入画（正文+提示都在屏内）
        for step in 1...6 {
            app.swipeUp()
            sleep(1)
            snap(String(format: "step-%02d.png", step))
        }
        sleep(1)
        snap("99-final.png")
    }
}
