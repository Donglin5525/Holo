//
//  ThoughtImageSourceSheetUITests.swift
//  Holo
//
//  想法编辑器「添加图片」来源 sheet 首点可达 + 相册权限前置申请走查：
//  1. 编辑器聚焦（键盘在弹）后第一次点工具栏图片按钮，来源 sheet 必须出现
//     （旧 confirmationDialog 会被 UITextView 失焦竞态撤回，表现为第二次点击才弹出）；
//  2. 点「从相册选择」触发一次性相册读取权限申请（iCloud 原图自动下载的前提）；
//  3. 授权后选择器可用、本地照片可正常附加（快路径）。
//  通道：XCUITest（Mac 侧合成点击被吞环境下的可靠替代）。
//

import XCTest

final class ThoughtImageSourceSheetUITests: XCTestCase {

    var app: XCUIApplication!
    static let dir = "/tmp/holo_thought_image_sheet"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
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

    private func firstButton(containing keywords: [String]) -> XCUIElement? {
        for keyword in keywords {
            let pred = NSPredicate(format: "label CONTAINS %@", keyword)
            let match = app.buttons.containing(pred).firstMatch
            if match.exists { return match }
        }
        return nil
    }

    /// 系统权限弹窗按钮（挂 Springboard，不在 app 进程内）
    private func springboardButton(containing keywords: [String]) -> XCUIElement? {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for keyword in keywords {
            let pred = NSPredicate(format: "label CONTAINS %@", keyword)
            let match = springboard.buttons.containing(pred).firstMatch
            if match.exists { return match }
        }
        return nil
    }

    func testImageSourceSheetAppearsOnFirstTap() throws {
        // 首页 → 想法磁贴
        guard let tile = firstButton(containing: ["想法"]), tile.exists else {
            XCTFail("首页想法磁贴未找到")
            return
        }
        tile.tap()
        sleep(1)

        // 新增想法 → 编辑器
        guard let add = firstButton(containing: ["新增想法"]), add.exists else {
            shoot("fail_no_add_button")
            XCTFail("想法列表「新增想法」按钮未找到")
            return
        }
        add.tap()

        // 编辑器聚焦：模拟原 bug 场景（键盘在弹、UITextView 是第一响应者）
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), "想法编辑器未出现")
        editor.tap()
        sleep(1)
        shoot("editor_focused")

        // 第一次点工具栏「添加图片」
        guard let photoTool = firstButton(containing: ["添加图片", "新增圖片"]), photoTool.exists else {
            shoot("fail_no_photo_tool")
            XCTFail("工具栏图片按钮未找到")
            return
        }
        photoTool.tap()

        // 关键断言：不需要第二次点击，来源 sheet 应当已出现
        guard let albumRow = firstButton(containing: ["从相册选择", "從相簿選擇"]) else {
            shoot("fail_sheet_not_on_first_tap")
            XCTFail("第一次点击图片按钮后来源 sheet 未出现（弹层竞态仍在）")
            return
        }
        XCTAssertTrue(albumRow.waitForExistence(timeout: 4), "来源 sheet 未出现")
        shoot("sheet_on_first_tap")

        // 从相册选择 → 首次应触发相册读取权限系统弹窗
        albumRow.tap()
        shoot("after_album_tap", settle: 2)

        if let allow = springboardButton(containing: ["允許完整取用", "允许完整", "Allow Full Access", "允許", "Allow"]) {
            print("[AUTH] 相册权限弹窗已出现，点允许")
            allow.tap()
        } else {
            print("[AUTH] 无权限弹窗（可能此前已授权）")
        }
        shoot("picker_after_allow", settle: 2)

        // 选择器里点第一张照片（快路径：本地照片直接附加）
        let photos = app.scrollViews.firstMatch
        let imageCell = app.images.matching(NSPredicate(format: "label CONTAINS 'Photo' OR label CONTAINS '照片' OR label CONTAINS '相片'")).firstMatch
        if imageCell.exists {
            imageCell.tap()
            sleep(2)
            shoot("photo_attached")
        } else if photos.exists {
            photos.tap()
            sleep(2)
            shoot("photo_attached_fallback")
        }
    }
}
