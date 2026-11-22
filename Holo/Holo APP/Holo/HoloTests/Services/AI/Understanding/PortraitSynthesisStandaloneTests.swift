//
//  PortraitSynthesisStandaloneTests.swift
//  Holo
//
//  Phase 2：全局画像合成模型、安全底线核验器、黑名单防复活与三态流转 standalone 回归锁。
//

import Foundation

enum PortraitSynthesisStandaloneTests {

    private static var passed = 0
    private static var failed = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [PortraitSynthesis]: \(name)\n", stderr)
        }
    }

    static func run() throws {
        passed = 0
        failed = 0

        let now = Date(timeIntervalSince1970: 1_795_147_200)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortraitSynthesisTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. 解析含 Markdown 围栏的三案例合法输出
        let fencedJSON = """
        ```json
        {
          "schemaVersion": 1,
          "upserts": [
            {
              "key": "pet_cat",
              "dimension": "identity",
              "confidence": "inferred",
              "statement": "推测正在养猫",
              "evidenceSummary": "近半年有3笔猫粮支出及买猫砂待办",
              "sourceDomains": ["finance", "task"],
              "usageHint": "出行规划或居家预算时提醒宠物照料安排"
            },
            {
              "key": "coffee_sleep_link",
              "dimension": "crossDomainInsight",
              "confidence": "inferred",
              "statement": "近期晚睡且睡眠不足，可能与下午高频喝咖啡有关",
              "evidenceSummary": "近14天入睡推迟65分钟且均睡6.1h，同期14笔咖啡集中在下午",
              "sourceDomains": ["health", "finance"],
              "usageHint": "聊到疲惫或睡眠改善时温和提示调整咖啡时段"
            },
            {
              "key": "shallow_template_bad",
              "dimension": "longTermPattern",
              "confidence": "inferred",
              "statement": "最近6个月买3次猫粮，平均每隔93天一笔",
              "evidenceSummary": "账单统计",
              "sourceDomains": ["finance"],
              "usageHint": "无"
            },
            {
              "key": "habit_template_bad",
              "dimension": "recentState",
              "confidence": "inferred",
              "statement": "「戒烟」习惯进行中，期间有反复",
              "evidenceSummary": "打卡记录",
              "sourceDomains": ["habit"],
              "usageHint": "无"
            },
            {
              "key": "medical_bad",
              "dimension": "crossDomainInsight",
              "confidence": "inferred",
              "statement": "近期睡眠差，疑似抑郁症建议就医",
              "evidenceSummary": "睡眠数据",
              "sourceDomains": ["health"],
              "usageHint": "提醒就医"
            },
            {
              "key": "moral_bad",
              "dimension": "recentState",
              "confidence": "inferred",
              "statement": "近期体重上升是因为自律差和懒惰",
              "evidenceSummary": "体重与健身数据",
              "sourceDomains": ["habit"],
              "usageHint": "督促"
            }
          ],
          "retireKeys": [],
          "clarifications": [
            {
              "key": "weight_activity_gap",
              "question": "最近体重略有上升但未读到运动数据，是运动变少了还是主要没记录？",
              "reason": "Apple Health 无运动读数覆盖"
            }
          ]
        }
        ```
        """

        let delta = try PortraitDeltaParser.parse(from: fencedJSON)
        check(delta.upserts.count == 6, "应解析出 6 条原始候选")
        check(delta.clarifications.count == 1, "应解析出 1 条待求证问题")

        var store = PortraitStore()
        let report = store.apply(delta: delta, now: now)

        // 2. 校验安全底线：放行 2 条高质量洞察，精准拦下 4 条违规（算术复述/习惯模板/医疗化/道德贬损）
        check(report.upsertedKeys == ["pet_cat", "coffee_sleep_link"], "应只放行 pet_cat 与 coffee_sleep_link")
        check(report.rejectedByGate.count == 4, "应拦截 4 条底线违规（实际 \(report.rejectedByGate.count)）")
        check(store.entries["pet_cat"]?.dimension == .identity, "pet_cat 应归入 identity 维度")
        check(store.entries["pet_cat"]?.confidence == .inferred, "pet_cat 初始应为 inferred 推测态")
        check(store.entries["coffee_sleep_link"]?.dimension == .crossDomainInsight, "coffee_sleep_link 应归入 crossDomainInsight")
        check(store.clarifications["weight_activity_gap"] != nil, "应保存 1 条待求证问题")

        // 3. 用户点击「准」→ 升级为 confirmed，且后续模型更新不得降回 inferred 或被 retireKeys 静默删除
        store.confirm(key: "pet_cat", now: now)
        check(store.entries["pet_cat"]?.confidence == .confirmed, "用户确认后应升为 confirmed")
        check(store.entries["pet_cat"]?.isUserConfirmed == true, "isUserConfirmed 应为 true")

        let downgradeAttempt = PortraitDeltaEnvelope(
            upserts: [
                PortraitDeltaUpsert(
                    key: "pet_cat",
                    dimension: "identity",
                    confidence: "inferred",
                    statement: "养猫",
                    evidenceSummary: "多笔猫粮",
                    sourceDomains: ["finance"],
                    usageHint: "出行提醒"
                )
            ],
            retireKeys: ["pet_cat"],
            clarifications: []
        )
        let r2 = store.apply(delta: downgradeAttempt, now: now)
        check(r2.retiredKeys.isEmpty, "用户已确认项不得被 retireKeys 静默删除")
        check(store.entries["pet_cat"]?.confidence == .confirmed, "用户已确认项不得被模型降回 inferred")

        // 4. 用户点击「不准」→ 移出活跃画像 + 进入黑名单 + 后续模型再推同一 key 或相似语义必须被永久拦截
        store.reject(key: "coffee_sleep_link", reason: "喝的是无因咖啡", now: now)
        check(store.entries["coffee_sleep_link"] == nil, "否决后应移出活跃画像")
        check(store.rejectedBlacklist.count == 1, "否决后应进入黑名单")

        let resurrectAttempt = PortraitDeltaEnvelope(
            upserts: [
                PortraitDeltaUpsert(
                    key: "coffee_sleep_link",
                    dimension: "crossDomainInsight",
                    confidence: "inferred",
                    statement: "晚睡可能与喝咖啡有关",
                    evidenceSummary: "咖啡+睡眠",
                    sourceDomains: ["health", "finance"],
                    usageHint: "睡眠建议"
                )
            ],
            retireKeys: [],
            clarifications: []
        )
        let r3 = store.apply(delta: resurrectAttempt, now: now)
        check(r3.upsertedKeys.isEmpty, "黑名单项绝不允许复活")
        check(r3.rejectedByGate.count == 1, "黑名单复活尝试应被拦截并记录")

        // 5. 持久化读写往返 + Prompt Payload 携带黑名单
        try store.save(to: tmpDir)
        let reloaded = PortraitStore.load(directory: tmpDir)
        check(reloaded.entries["pet_cat"]?.isUserConfirmed == true, "持久化重载应保留已确认画像")
        check(reloaded.rejectedBlacklist.first?.key == "coffee_sleep_link", "持久化重载应保留黑名单")

        let dummyPacket = HoloLifeFeatureDistiller.distill(
            now: now, finance: [], sleep: [], steps: [], activeMinutes: [],
            habits: [], thoughts: [], tasks: [], goals: [], profileMarkdown: nil
        )
        let payload = reloaded.buildPromptPayload(packet: dummyPacket)
        check(payload.currentPortrait.count == 1, "请求载荷应携带当前画像")
        check(payload.rejectedBlacklist.count == 1, "请求载荷应携带黑名单喂回模型")
        check(payload.encodeJSON()?.contains("coffee_sleep_link") == true, "序列化 JSON 应包含黑名单 key")

        // 6. 校验英文词典词兜底清洗（含中文紧邻英文无空格场景：集中在night/evening时段）
        let cleanedText = PortraitTextSanitizer.sanitize("消费集中在night/evening时段，afternoon也有记录，morning较少")
        check(!cleanedText.contains("night") && !cleanedText.contains("evening") && !cleanedText.contains("afternoon") && !cleanedText.contains("morning"),
              "用户可见文案不得残留英文时段词（实际：\(cleanedText)）")
        check(cleanedText.contains("晚间和深夜") && cleanedText.contains("下午") && cleanedText.contains("上午"),
              "英文时段词应被自然替换为中文（实际：\(cleanedText)）")

        // 7. 校验真机实锤（2026-11-20 qwen3.7-flash 省略 usageHint + 自封 confirmed）：必须宽容解析且新项强制落入 inferred
        let omittedUsageHintJSON = """
        {
          "schemaVersion": 1,
          "upserts": [
            {
              "key": "work_health_tradeoff",
              "dimension": "crossDomainInsight",
              "confidence": "confirmed",
              "statement": "近期晚睡且运动量回落，减脂目标面临阻力",
              "evidenceSummary": "近14天活动时长下降38%，入睡推迟至02:10",
              "sourceDomains": ["health", "habit"]
            }
          ],
          "retireKeys": [],
          "clarifications": [
            {
              "key": "work_health_tradeoff",
              "question": "最近体重上升，是运动变少了还是没记录？"
            }
          ]
        }
        """
        let parsedOmitted = try PortraitDeltaParser.parse(from: omittedUsageHintJSON)
        check(parsedOmitted.upserts.count == 1, "省略 usageHint 时必须正常解析而非报 invalidJSON")
        var freshStore = PortraitStore()
        _ = freshStore.apply(delta: parsedOmitted, now: now)
        check(freshStore.entries["work_health_tradeoff"]?.confidence == .inferred,
              "模型新提出的条目不得越权自封 confirmed，必须先落入 inferred 供用户确认")

        print("PortraitSynthesisStandaloneTests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            throw NSError(domain: "PortraitSynthesisStandaloneTests", code: 1)
        }
    }
}
