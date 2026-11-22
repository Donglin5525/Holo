import Foundation
import os

// 「一个发现」v4 请求服务（2026-11-20 方案 03-I3）。
//
// 编排：本机开关 → 每日一次标记 → 画像+特征包+挖掘器提案 → CandidateBuilder →
// HoloBackendAIProvider.chatInsightStreaming（必须流式，后端缓冲校验+SSE 心跳）→
// 端侧终检 → CardBuilder → 入队 DiscoveryTopicStore。
//
// 出卡矩阵（2026-11-21 真机两轮实报后修正，取代方案 I3 原回落矩阵）：
// - 后端明确拒稿 → 当天不出卡；传输失败或端侧无法使用的响应不产生卡片，允许恢复。
// - none_worthwhile / insufficient_data → 当天不出卡（宁缺毋滥）；
// - 数据不足（portrait+features<3）→ 不请求、不出卡。
// 原设计回落 v3（含不联网的本机兜底文案）——基线已定谳 v3 卡及格率 0%/纯复述 100%，
// 失败时塞一张已知垃圾卡违背改造本意（东林真机两轮实报「还在数数字」定谳）。
@MainActor
enum DiscoveryInsightService {

    private static let logger = Logger(subsystem: "com.holo.app", category: "DiscoveryInsight")
    private static var refreshTask: Task<Bool, Never>?

    /// 评审页的重载共享同一次生成，界面取消等待时仍可完成写入。
    @discardableResult
    static func refreshIfNeeded(
        proposals: [HoloKnowledgeRevision],
        now: Date = Date()
    ) async -> Bool {
        guard DiscoveryFeatureFlags.insightV2Enabled,
              HoloAIDataProcessingConsent.shared.isGranted else { return false }
        if let refreshTask { return await refreshTask.value }
        let store = DiscoveryTopicStore.shared
        store.discardLegacyQueueIfNeeded()
        guard store.canRequestInsight(now: now) else { return false }

        let task = Task { await generate(proposals: proposals, store: store, now: now) }
        refreshTask = task
        defer { refreshTask = nil }
        return await task.value
    }

    private static func generate(
        proposals: [HoloKnowledgeRevision],
        store: DiscoveryTopicStore,
        now: Date
    ) async -> Bool {
        // 材料组装与请求。
        guard let built = await buildMaterials(proposals: proposals, store: store, now: now) else {
            return noCardToday(reason: "材料不足")
        }
        do {
            let draft = try await requestInsight(packet: built.packet)
            guard HoloAIDataProcessingConsent.shared.isGranted else { return false }
            return applyDraft(draft, built: built, store: store, now: now)
        } catch is InsightDraftParser.ParseError {
            store.markInvalidInsightResponse(now: now)
            return noCardToday(reason: "响应解码失败")
        } catch {
            logger.error("v4 洞察请求失败，当天不出卡: \(String(describing: error), privacy: .public)")
            return noCardToday(reason: "error")
        }
    }

    /// 材料组装：画像仓 + 七域特征包 + 挖掘器提案 → 候选包（2026-11-21 I5 抽出，自动生成与点名共用）。
    private static func buildMaterials(
        proposals: [HoloKnowledgeRevision],
        store: DiscoveryTopicStore,
        now: Date
    ) async -> DiscoveryInsightCandidateBuilder.Output? {
        let portraitStore = HoloPortraitSynthesisRuntime.loadStore()
        guard let featurePacket = await HoloLifeFeatureDataSource.buildPacket(now: now) else { return nil }
        return DiscoveryInsightCandidateBuilder.build(
            portraitStore: portraitStore,
            featurePacket: featurePacket,
            proposals: proposals,
            recentTopics: store.recentAngleKeys(now: now),
            rejectedAngles: store.rejectedAngleKeys,
            now: now
        )
    }

    static func applyDraft(
        _ draft: InsightDraft,
        built: DiscoveryInsightCandidateBuilder.Output,
        store: DiscoveryTopicStore,
        now: Date,
        isFocusedPick: Bool = false,
        // 默认参数在非隔离上下文求值拿不到 MainActor 属性，改 nil + 函数体内解析（语义与施工图一致）。
        isPlusLocally: Bool? = nil
    ) -> Bool {
        let plusLocal = isPlusLocally ?? HoloEntitlementState.shared.isPlusActive
        if let selected = draft.selected {
            if let failure = DiscoveryInsightTerminalCheck.validate(selected, packet: built.packet) {
                store.markInvalidInsightResponse(now: now)
                logger.warning("v4 端侧终检拒绝: \(failure, privacy: .public)")
                return false
            }
            let portraitIds = Set(built.packet.portrait.map(\.id))
            var domainByRefId: [String: String] = [:]
            for feature in built.packet.features {
                domainByRefId[feature.id] = domainByRefId[feature.id] ?? feature.domain
            }
            for item in built.packet.portrait where domainByRefId[item.id] == nil {
                domainByRefId[item.id] = item.sourceDomains.first ?? "profile"
            }
            do {
                let card = try DiscoveryInsightCardBuilder.build(
                    selected: selected, slots: built.slots, portraitIds: portraitIds,
                    domainByRefId: domainByRefId, now: now
                )
                var queued = card
                if isFocusedPick { queued.isFocusedPick = true }
                store.enqueue(queued)
                // 预告：成功出卡后保存没用上的特征（已排除本次依据引用，01 §5 第 7 条）。
                store.saveTeasers(DiscoveryTeaserBuilder.build(
                    packet: built.packet, phrases: built.teaserPhrases,
                    excludingFeatureIds: Set(selected.evidence.map(\.refId))), now: now)
                if let quota = draft.quota { store.saveQuotaSnapshot(quota, now: now) }
                if !isFocusedPick { store.markInsightV2Attempted(now: now) }
                logger.info("v4 洞察入队: \(selected.angleKey, privacy: .public)")
                return true
            } catch {
                store.markInvalidInsightResponse(now: now)
                logger.warning("v4 洞察证据组装失败: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        switch draft.noneReason {
        case "quota_exhausted":
            // 撞墙不写当日尝试标记（02 审查 E2）；墙截止到恢复时刻（E1）；会员同步延迟只墙 10 分钟（E6）。
            if let quota = draft.quota { store.saveQuotaSnapshot(quota, now: now) }
            store.saveTeasers(DiscoveryTeaserBuilder.build(packet: built.packet, phrases: built.teaserPhrases), now: now)
            let syncing = draft.quota?.tier == "free" && plusLocal
            store.markInsightQuotaWalled(until: syncing ? now.addingTimeInterval(600) : draft.quota?.resetDate, now: now)
            return noCardToday(reason: syncing ? "会员状态同步中" : "每周额度已用完")
        case "none_worthwhile", "insufficient_data":
            if !isFocusedPick {
                store.markInsightV2Attempted(now: now)
                store.markInsightV2NoneWorthwhile(now: now)
                // 模型看过、确实没话说：清空预告，不再写「还注意到几件事」（01 §5 第 6 条）。
                store.clearTeasers()
            }
            return noCardToday(reason: draft.noneReason ?? "none_worthwhile")
        case "disabled":
            store.markInsightV2Attempted(now: now)
            DiscoveryFeatureFlags.markDisabledByServer()
            return noCardToday(reason: "后端开关关")
        default:
            if !isFocusedPick { store.markInsightV2Attempted(now: now) }
            return noCardToday(reason: "gate_rejected")
        }
    }

    // MARK: - Plus 点名看（2026-11-21 I5）

    enum FocusOutcome: Equatable {
        case delivered
        case nothingWorthSaying
        case changed
        case limitReached
        case failed
    }

    private static var focusTask: Task<FocusOutcome, Never>?

    static func requestFocused(
        clue: DiscoveryTeaserClue,
        proposals: [HoloKnowledgeRevision],
        now: Date = Date()
    ) async -> FocusOutcome {
        if let focusTask { return await focusTask.value }
        let task = Task { await performFocused(clue: clue, proposals: proposals, store: .shared, client: RealInsightClient(), now: now) }
        focusTask = task
        defer { focusTask = nil }
        return await task.value
    }

    static func performFocused(
        clue: DiscoveryTeaserClue,
        proposals: [HoloKnowledgeRevision],
        store: DiscoveryTopicStore,
        client: InsightClient,
        now: Date
    ) async -> FocusOutcome {
        guard HoloAIDataProcessingConsent.shared.isGranted else { return .failed }
        guard !store.isInsightQuotaWalled(now: now),
              store.focusPicksToday(now: now) < DiscoveryTopicStore.focusPicksPerDay else { return .limitReached }
        guard var built = await buildMaterials(proposals: proposals, store: store, now: now) else { return .changed }
        // 特征 id 按下标生成，重新组包后可能变化：用短句反查当前 id（02 审查 E5）。
        let ids = clue.phrases.compactMap { phrase in
            built.teaserPhrases.first(where: { $0.value == phrase })?.key
        }
        guard !ids.isEmpty, ids.count == clue.phrases.count else {
            store.removeTeaser(id: clue.id, now: now)
            return .changed
        }
        built.packet.focusFeatureIds = ids
        store.markFocusPick(now: now)
        do {
            let draft = try await requestInsight(packet: built.packet, client: client)
            let delivered = applyDraft(draft, built: built, store: store, now: now, isFocusedPick: true)
            store.removeTeaser(id: clue.id, now: now)
            if delivered { return .delivered }
            return draft.noneReason == "quota_exhausted" ? .limitReached : .nothingWorthSaying
        } catch APIError.rateLimited(_) {
            return .limitReached
        } catch {
            logger.error("点名看失败: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private static func noCardToday(reason: String) -> Bool {
        logger.info("v4 当天不出卡（\(reason, privacy: .public)）——宁缺毋滥，不回落 v3 垃圾卡")
        return false
    }

    // MARK: - 网络请求

    protocol InsightClient: Sendable {
        func stream(messages: [ChatMessageDTO]) async throws -> String
    }

    /// 默认客户端：走后端网关（SSE 心跳 + 最终 chunk），累积为完整 JSON 文本。
    private struct RealInsightClient: InsightClient {
        func stream(messages: [ChatMessageDTO]) async throws -> String {
            let provider = await MainActor.run { HoloBackendAIProvider() }
            var accumulated = ""
            for try await chunk in provider.chatInsightStreaming(messages: messages, purpose: .discoveryInsightV2) {
                accumulated += chunk
            }
            return accumulated
        }
    }

    private static func requestInsight(packet: InsightInputPacket, client: InsightClient = RealInsightClient()) async throws -> InsightDraft {
        guard let json = packet.encodeJSON() else {
            throw APIError.serverError("洞察输入包编码失败")
        }
        let raw = try await client.stream(messages: [.user(json)])
        return try InsightDraftParser.parse(from: raw)
    }
}

// MARK: - 端侧终检（03-I3：防御后端闸门遗漏；与后端共用同一组数字测试样例）

nonisolated enum DiscoveryInsightTerminalCheck {

    enum Failure: Error, Equatable, CustomStringConvertible {
        case numbersInJudgement
        case unknownReference(String)
        case slotNotAllowed(String)
        case lengthViolation
        case evidenceCount
        case emptyDomains

        var description: String {
            switch self {
            case .numbersInJudgement: return "判断句含数字"
            case .unknownReference(let id): return "未知引用\(id)"
            case .slotNotAllowed(let name): return "越界槽位\(name)"
            case .lengthViolation: return "长度越界"
            case .evidenceCount: return "证据条数越界"
            case .emptyDomains: return "领域为空"
            }
        }
    }

    static func validate(_ selected: InsightDraft.Selected, packet: InsightInputPacket) -> Failure? {
        // 数字禁令（含中文数字，样例与后端 insightGate 共用）。
        if InsightNumberDiscipline.containsNumerals(in: selected.headline)
            || InsightNumberDiscipline.containsNumerals(in: selected.insight)
            || InsightNumberDiscipline.containsNumerals(in: selected.prompt) {
            return .numbersInJudgement
        }
        // 长度红线（与后端 INSIGHT_LIMITS 同值）。
        if selected.headline.count > 18 || selected.insight.count > 90 || selected.prompt.count > 30 {
            return .lengthViolation
        }
        // 证据引用合法性。
        guard (1...3).contains(selected.evidence.count) else { return .evidenceCount }
        // 禁 uniqueKeysWithValues（守门红线：iCloud 副本天然重复 id 会抛 ObjC 异常）。
        var featureSlots: [String: Set<String>] = [:]
        for feature in packet.features {
            let names = Set(feature.slots.map(\.name))
            featureSlots[feature.id] = names.union(featureSlots[feature.id] ?? [])
        }
        let portraitIds = Set(packet.portrait.map(\.id))
        for line in selected.evidence {
            guard line.template.count <= 40 else { return .lengthViolation }
            let allowed: Set<String>
            if let slots = featureSlots[line.refId] {
                allowed = slots
            } else if portraitIds.contains(line.refId) {
                allowed = []
            } else {
                return .unknownReference(line.refId)
            }
            // 模板中出现的 {slot} 必须属于该 feature 的 slots。
            var cursor = line.template.startIndex
            while let brace = line.template[cursor...].firstIndex(of: "{") {
                guard let close = line.template[brace...].firstIndex(of: "}") else { return .slotNotAllowed("未闭合") }
                let name = String(line.template[line.template.index(after: brace)..<close])
                if !allowed.contains(name) { return .slotNotAllowed(name) }
                cursor = line.template.index(after: close)
            }
        }
        if selected.sourceDomains.isEmpty { return .emptyDomains }
        return nil
    }
}

// MARK: - 本地开关（03-I8）

/// v4 洞察本地开关：DEBUG 恒开（内测优先，后端 insightV2Enabled 才是真闸）；
/// Release 默认开、由后端 disabled 信号永久关闭（下次 App 版本更新后重置重探）。
enum DiscoveryFeatureFlags {
    private static let disabledByServerKey = "holo.discovery.insightV2.disabledByServer"

    #if DEBUG
    static var insightV2Enabled: Bool { true }
    #else
    static var insightV2Enabled: Bool { !UserDefaults.standard.bool(forKey: disabledByServerKey) }
    #endif

    static func markDisabledByServer() {
        UserDefaults.standard.set(true, forKey: disabledByServerKey)
    }
}
