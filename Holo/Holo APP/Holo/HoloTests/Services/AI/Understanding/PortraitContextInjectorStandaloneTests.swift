//
//  PortraitContextInjectorStandaloneTests.swift
//  Holo
//
//  Phase 4：AI 对话场景化动态画像注入器 standalone 回归锁。
//

import Foundation

enum PortraitContextInjectorStandaloneTests {

    private static var passed = 0
    private static var failed = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [PortraitContextInjector]: \(name)\n", stderr)
        }
    }

    static func run() throws {
        passed = 0
        failed = 0

        let now = Date(timeIntervalSince1970: 1_795_147_200)

        // 1. 空画像应返回 nil（零上下文噪音）
        let emptyStore = PortraitStore()
        check(HoloPortraitContextInjector.renderForChat(store: emptyStore, userText: "今天吃什么") == nil,
              "空画像不应注入任何上下文")

        // 2. 混合已确认/推测/待求证条目，校验语气规则与话题相关性排序
        var store = PortraitStore()
        store.entries["pet_cat"] = PortraitEntry(
            key: "pet_cat",
            dimension: .identity,
            confidence: .inferred,
            statement: "推测正在养猫",
            evidenceSummary: "近半年多次购买猫粮",
            sourceDomains: ["finance"],
            usageHint: "出行规划时提醒宠物喂养安排",
            updatedAt: now,
            isUserConfirmed: false
        )
        store.entries["coffee_sleep_link"] = PortraitEntry(
            key: "coffee_sleep_link",
            dimension: .crossDomainInsight,
            confidence: .inferred,
            statement: "近期晚睡可能与下午高频喝咖啡有关",
            evidenceSummary: "入睡推迟且下午咖啡高频",
            sourceDomains: ["health", "finance"],
            usageHint: "聊到疲惫或改善睡眠时温和提示",
            updatedAt: now,
            isUserConfirmed: false
        )
        store.entries["style_concise"] = PortraitEntry(
            key: "style_concise",
            dimension: .preference,
            confidence: .confirmed,
            statement: "偏好简洁直接的回复风格",
            evidenceSummary: "个人档案自述",
            sourceDomains: ["profile"],
            usageHint: "所有对话回复风格",
            updatedAt: now,
            isUserConfirmed: true
        )
        store.entries["needs_check"] = PortraitEntry(
            key: "needs_check",
            dimension: .recentState,
            confidence: .needsClarification,
            statement: "运动记录不足待确认",
            evidenceSummary: "无 HealthKit 读数",
            sourceDomains: ["health"],
            usageHint: "不直接断言",
            updatedAt: now,
            isUserConfirmed: false
        )

        // 场景 A：用户问睡眠/疲惫 → coffee_sleep_link 应排在第一位且包含 [推测] 与使用规则
        let sleepBlock = HoloPortraitContextInjector.renderForChat(
            store: store,
            userText: "最近白天总是很疲惫，晚上睡眠不好怎么调？",
            maxItems: 2
        ) ?? ""
        check(sleepBlock.contains("近期晚睡可能与下午高频喝咖啡有关"), "睡眠相关问题应命中 coffee_sleep_link")
        check(sleepBlock.contains("[跨模块洞察·推测]"), "推测项应明确标注 [推测]")
        check(!sleepBlock.contains("运动记录不足待确认"), "needsClarification 条目不得混入对话背景断言")
        check(sleepBlock.contains("话题无关时不要提及"), "应附带防打扰使用规则")

        // 场景 B：用户问出行规划 → pet_cat 应命中并入选
        let travelBlock = HoloPortraitContextInjector.renderForChat(
            store: store,
            userText: "下周出差五天要准备什么出行清单",
            maxItems: 2
        ) ?? ""
        check(travelBlock.contains("推测正在养猫"), "出行规划问题应命中 pet_cat")
        check(travelBlock.contains("[偏好与边界·已确认]"), "已确认偏好应标注 [已确认]")

        print("PortraitContextInjectorStandaloneTests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            throw NSError(domain: "PortraitContextInjectorStandaloneTests", code: 1)
        }
    }
}
