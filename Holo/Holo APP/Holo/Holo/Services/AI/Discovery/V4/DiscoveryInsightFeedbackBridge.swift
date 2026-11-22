import Foundation

// 「一个发现」v4 反馈回流桥（2026-11-20 方案 03-I7）。
//
// 三种反馈的落点：
// - 准：portraitRefs 在 PortraitStore 升级 confirmed；无 portraitRef（纯 feature 洞察）
//   时新建 crossDomainInsight 维度、confirmed 的画像条目（statement=insight，
//   evidenceSummary=去数字后的 evidence 行）；
// - 不太准：angleKey 入 TopicStore 拒绝角度（30 天内不再出现）+ portraitRefs 进
//   PortraitStore 拒绝黑名单（永不复活）；
// - 先放一放：沿用 v3 的 7 天冷却（DiscoveryTopicStore.markDeferred，topicKey=angleKey）。
//
// 写入后发 .holoKnowledgeControlDidApply（现有知识变更通知），让评审页与记忆页同步。
@MainActor
enum DiscoveryInsightFeedbackBridge {

    enum Outcome: Equatable {
        case confirmedPortrait(keys: [String])
        case createdPortrait(key: String)
        case rejected(angleKey: String, portraitKeys: [String])
        case deferred(angleKey: String)
        case unavailable
        case persistenceFailed
    }

    /// 用户点「对，记住」。
    /// directory / topicStore 供单测注入临时目录与隔离子库；默认真实画像仓与 shared 队列。
    @discardableResult
    static func confirm(card: DiscoveryTopicStore.QueuedCard, now: Date = Date(), directory: URL? = nil, topicStore: DiscoveryTopicStore = .shared) -> Outcome {
        guard topicStore.todayCard(now: now) == card else { return .unavailable }
        let refs = card.portraitRefs ?? []
        let dir = directory ?? HoloPortraitSynthesisRuntime.storeDirectory()
        var store = PortraitStore.load(directory: dir)

        var confirmedKeys: [String] = []
        for key in refs where store.entries[key] != nil {
            store.confirm(key: key, now: now)
            confirmedKeys.append(key)
        }

        var createdKey: String?
        if confirmedKeys.isEmpty {
            // 纯 feature 洞察被确认：新画像条目承接（crossDomainInsight · confirmed）。
            let key = stableKey(for: card.angleKey ?? card.topicKey)
            let evidence = (card.evidenceLines ?? [])
                .map { DiscoveryInsightCandidateBuilder.stripNumerals($0) }
                .joined(separator: "；")
            store.entries[key] = PortraitEntry(
                key: key,
                dimension: .crossDomainInsight,
                confidence: .confirmed,
                statement: String((card.insight ?? card.body).prefix(60)),
                evidenceSummary: String(evidence.prefix(80)),
                sourceDomains: domainsForNewEntry(card),
                usageHint: "理解你的跨模块联动，辅助对话与回顾",
                updatedAt: now,
                isUserConfirmed: true
            )
            createdKey = key
        }
        do { try store.save(to: dir) }
        catch { return .persistenceFailed }

        topicStore.consumeToday(card, now: now)
        if let angle = card.angleKey { topicStore.markInsightAngleShown(angle, now: now) }
        NotificationCenter.default.post(name: .holoKnowledgeControlDidApply, object: nil)

        if let createdKey { return .createdPortrait(key: createdKey) }
        return .confirmedPortrait(keys: confirmedKeys)
    }

    /// 用户点「不太准确」。
    @discardableResult
    static func reject(card: DiscoveryTopicStore.QueuedCard, now: Date = Date(), directory: URL? = nil, topicStore: DiscoveryTopicStore = .shared) -> Outcome {
        guard topicStore.todayCard(now: now) == card else { return .unavailable }
        let refs = card.portraitRefs ?? []
        if !refs.isEmpty {
            let dir = directory ?? HoloPortraitSynthesisRuntime.storeDirectory()
            var store = PortraitStore.load(directory: dir)
            for key in refs {
                store.reject(key: key, reason: "发现卡「不太准」", now: now)
            }
            do { try store.save(to: dir) }
            catch { return .persistenceFailed }
        }

        // 先消费这张卡并写入当天标记，再把它的命题和角度加入拒绝记录。
        topicStore.consumeToday(card, now: now)
        topicStore.markRejected(card.topicKey)
        let angle = card.angleKey ?? card.topicKey
        topicStore.markInsightAngleRejected(angle, now: now)
        NotificationCenter.default.post(name: .holoKnowledgeControlDidApply, object: nil)
        return .rejected(angleKey: angle, portraitKeys: refs)
    }

    /// 用户点「先放一放」：沿用 v3 的 7 天冷却。
    @discardableResult
    static func deferCard(card: DiscoveryTopicStore.QueuedCard, now: Date = Date(), topicStore: DiscoveryTopicStore = .shared) -> Outcome {
        guard topicStore.consumeToday(card, now: now) else { return .unavailable }
        topicStore.markDeferred(card.topicKey, now: now)
        return .deferred(angleKey: card.angleKey ?? card.topicKey)
    }

    // MARK: - 工具

    /// 新画像条目 key：insight_ 前缀 + 角度键 djb2 稳定哈希（同角度同 key，幂等覆盖）。
    private static func stableKey(for angleKey: String) -> String {
        var hash: UInt32 = 5381
        for scalar in angleKey.unicodeScalars {
            hash = (hash << 5) &+ hash &+ scalar.value
        }
        return "insight_\(String(format: "%08x", hash))"
    }

    private static func domainsForNewEntry(_ card: DiscoveryTopicStore.QueuedCard) -> [String] {
        // 卡片未带 sourceDomains 字段——从证据行无法还原，按洞察正文启发映射；
        // 仅作画像展示用途，错误不影响数据正确性。
        var domains: [String] = []
        let text = card.body
        if text.contains("花") || text.contains("买") || text.contains("下单") || text.contains("账") { domains.append("finance") }
        if text.contains("睡") || text.contains("步") || text.contains("运动") { domains.append("health") }
        if text.contains("打卡") || text.contains("断签") || text.contains("习惯") { domains.append("habit") }
        if text.contains("任务") || text.contains("逾期") { domains.append("task") }
        if domains.isEmpty { domains = ["thought"] }
        return domains
    }
}
