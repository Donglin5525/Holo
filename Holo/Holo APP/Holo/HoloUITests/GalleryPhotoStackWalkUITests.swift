//
//  GalleryPhotoStackWalkUITests.swift
//  Holo
//  记忆长廊多图想法卡走查：点侧片翻页、滑动翻页、页码点与一次性提示。
//  依赖截图模式种子（memory-gallery-multi-photo 路由）提供三图想法。
//

import XCTest

final class GalleryPhotoStackWalkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWalkGalleryPhotoStack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["HOLO_APP_STORE_SCREENSHOT_ROUTE"] = "memory-gallery-multi-photo"
        app.launch()

        let outDir = URL(fileURLWithPath: "/tmp/holo_gallery_walk")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        func snap(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: outDir.appendingPathComponent(name))
            print("[GalleryWalk] saved \(name)")
        }

        // 页码点计数是多图卡的唯一稳定锚点
        let counter = app.staticTexts["1 / 3"]
        XCTAssertTrue(counter.waitForExistence(timeout: 60), "多图想法卡未上屏（未找到 1 / 3 计数）")
        sleep(2)
        snap("01-initial.png")

        let counterFrame = counter.frame
        print("[GalleryWalk] counter frame = \(counterFrame)")
        // 右侧露出照片条中心（实测条带约 296–380pt）
        func tapRightStrip(_ extraDx: CGFloat) {
            let tapPoint = app.coordinate(
                withNormalizedOffset: .zero
            ).withOffset(CGVector(
                dx: counterFrame.midX + 94 + extraDx,
                dy: counterFrame.midY - 99
            ))
            tapPoint.tap()
        }
        tapRightStrip(0)
        sleep(2)

        var counter2 = app.staticTexts["2 / 3"]
        if !counter2.waitForExistence(timeout: 3) {
            print("[GalleryWalk] first tap missed, retry deeper")
            snap("02a-retry.png")
            tapRightStrip(10)
            sleep(2)
            counter2 = app.staticTexts["2 / 3"]
        }
        XCTAssertTrue(counter2.waitForExistence(timeout: 5), "点侧片后应翻到 2 / 3")
        snap("02-after-tap-side-photo.png")

        // 在照片堆上向左滑 → 翻到第 3 张
        func drag(_ x0: CGFloat, _ x1: CGFloat) {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x0, dy: counterFrame.midY - 70))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x1, dy: counterFrame.midY - 70))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        drag(counterFrame.midX, 50)
        sleep(2)

        XCTAssertTrue(app.staticTexts["3 / 3"].waitForExistence(timeout: 5), "滑动后应翻到 3 / 3")
        // 首次翻片后一次性提示应消失
        let hint = app.staticTexts["左右滑动，翻看下一张"]
        XCTAssertFalse(hint.exists, "翻过一次后提示应已收起")
        snap("03-after-swipe.png")

        // 再向左滑一次 → 循环回第 1 张
        drag(counterFrame.midX, 50)
        sleep(2)
        XCTAssertTrue(app.staticTexts["1 / 3"].waitForExistence(timeout: 5), "循环翻片应回到 1 / 3")
        snap("04-after-swipe-back.png")
    }
}
