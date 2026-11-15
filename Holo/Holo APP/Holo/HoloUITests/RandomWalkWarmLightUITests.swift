//
//  RandomWalkWarmLightUITests.swift
//  Holo
//
//  随机漫步暖光动画门禁（11-15 四报定谳用）：
//  - 打开长廊 → 点 ✨随机漫步 → traveling 窗口内连续截帧 + 采样 ticks 探针
//  - 帧与采样序列落 /tmp/holo_walk_uitest/，测试后由数值探针/判读闭环
//  - 诊断模式：不断言（空库走空态也允许跑完，只记录轨迹）
//

import XCTest

final class RandomWalkWarmLightUITests: XCTestCase {

    static let dir = "/tmp/holo_walk_uitest"

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
    }

    /// 长廊无旧数据时漫步走空态——测试仍采样但记录 empty。
    func test_漫步暖光过程帧采样() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(3)

        // 进记忆长廊
        let memory = app.buttons["记忆长廊"].firstMatch
        let memoryAlt = app.buttons["记忆"].firstMatch
        if memory.waitForExistence(timeout: 8) {
            memory.tap()
        } else if memoryAlt.waitForExistence(timeout: 4) {
            memoryAlt.tap()
        } else {
            XCTFail("长廊入口未找到")
            return
        }
        sleep(3)

        // 点 ✨随机漫步（顶栏直达）
        let walk = app.buttons["随机漫步"].firstMatch
        XCTAssertTrue(walk.waitForExistence(timeout: 8), "随机漫步入口未出现")
        walk.tap()

        // traveling 窗口采样：每 0.25s 截帧 + ticks 探针 + 状态文本，共 4s
        var samples: [String] = []
        var sawWarmLightStamp = false
        for i in 0..<16 {
            let shotOK = (try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: "\(Self.dir)/frame_\(String(format: "%02d", i)).png"))) != nil
            let ticksQuery = app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH 'ticks:'")).firstMatch
            let ticks = ticksQuery.exists ? ticksQuery.label : ""
            let phaseHints = ["正在找一段旧日记录", "还没有可漫步的旧日", "暂时无法载入旧日记录",
                              "再走一天", "在长廊看这天", "想起那一天"]
                .filter { app.staticTexts[$0].exists || app.buttons[$0].exists }
            if phaseHints.contains("想起那一天") { sawWarmLightStamp = true }
            samples.append("frame=\(i) shot=\(shotOK) ticks='\(ticks)' hints=\(phaseHints)")
            usleep(250_000)
        }
        samples.forEach { print("[WALK-PROBE] \($0)") }

        // 门禁断言（真机/模拟器通用）：
        // ① 动画窗口内出现过暖光过场文字「想起那一天」（=过场层挂载且驱动推进到 30%+）
        // ② 终态抵达（「再走一天」出现）或如实空态（「还没有可漫步的旧日」）——
        //    空态不算失败，但 sawWarmLightStamp 在有数据时必须成立。
        let arrived = samples.last?.contains("再走一天") ?? false
        let empty = samples.last?.contains("还没有可漫步的旧日") ?? false
        if empty {
            print("[WALK-SUMMARY] 空态库，动画断言豁免（无旧日可漫步）")
        } else {
            XCTAssertTrue(sawWarmLightStamp,
                          "暖光过场未出现：16 拍内未见「想起那一天」过场文字（TimelineView 未驱动或过场层未挂载）")
            XCTAssertTrue(arrived, "漫步未抵达终态（未见「再走一天」）")
            print("[WALK-SUMMARY] sawWarmLightStamp=\(sawWarmLightStamp) arrived=\(arrived)")
        }
    }
}
