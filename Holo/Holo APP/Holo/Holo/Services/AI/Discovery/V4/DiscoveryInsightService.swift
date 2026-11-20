import Foundation
import os

// 「一个发现」v4 请求服务（2026-11-20 方案 03-I3）。
//
// 编排：本机开关 → 每日一次标记 → 画像+特征包+挖掘器提案 → CandidateBuilder →
// HoloBackendAIProvider.chatInsightStreaming（必须流式，后端缓冲校验+SSE 心跳）→
// 端侧终检 → CardBuilder → 入队 DiscoveryTopicStore。
//
// 回落矩阵（方案 I3 原文）：
// - 本地开关关 / disabled / gate_rejected / 网络与解析错误 → 回落 v3 refreshIfNeeded；
// - none_worthwhile / insufficient_data → 当天不出卡，不回落（宁缺毋滥）；
// - 数据不足（portrait+features<3）→ 不请求，走 v3。
@MainActor
enum DiscoveryInsightService {

    private static let logger = Logger(subsystem: "com.holo.app", category: "DiscoveryInsight")

    /// 每天一次入口（DiscoveryReviewSheet.reload 调用；队列空才补货，与 v3 同规则）。
    /// 返回是否成功入队 v4 卡（供测试与日志）。
    @discardableResult
    static func refreshIfNeeded(
        proposals: [HoloKnowledgeRevision],
        now: Date = Date()
    ) async -> Bool {
        let store = DiscoveryTopicStore.shared

        // 本地开关关闭（或后端曾返回 disabled）→ 直接走 v3 链路（不修改其逻辑）。
        guard DiscoveryFeatureFlags.insightV2Enabled else {
            return await DiscoveryTopicService.refreshIfNeeded(proposals: proposals, now: now)
        }
        guard !store.insightV2NoneWorthwhileToday(now: now) else { return false }
        guard !store.insightV2AttemptedToday(now: now) else { return false }
        guard store.queue.isEmpty else { return false }
        guard HoloAIDataProcessingConsent.shared.isGranted else { return false }

        // 先标记再请求：一天只尝试一次（服务端 3 次/日是重试余量，不在客户端烧）。
        store.markInsightV2Attempted(now: now)

        // 材料组装：画像仓 + 七域特征包 + 挖掘器提案。
        let portraitStore = HoloPortraitSynthesisRuntime.loadStore()
        guard let featurePacket = await HoloLifeFeatureDataSource.buildPacket(now: now) else {
            return await fallbackToV3(proposals: proposals, now: now, reason: "特征包为空")
        }
        guard let built = DiscoveryInsightCandidateBuilder.build(
            portraitStore: portraitStore,
            featurePacket: featurePacket,
            proposals: proposals,
            recentTopics: store.recentAngleKeys(now: now),
            rejectedAngles: store.rejectedAngleKeys,
            now: now
        ) else {
            return await fallbackToV3(proposals: proposals, now: now, reason: "数据不足(画像+特征<3)")
        }

        // 请求（流式；后端闸门放行后的完整 InsightDraft JSON 才会到达这里）。
        do {
            let draft = try await requestInsight(packet: built.packet)
            if let selected = draft.selected {
                let failure = DiscoveryInsightTerminalCheck.validate(selected, packet: built.packet)
                if let failure {
                    logger.warning("v4 端侧终检拒绝: \(failure, privacy: .public)")
                    return await fallbackToV3(proposals: proposals, now: now, reason: "terminal:\(failure)")
                }
                let portraitIds = Set(built.packet.portrait.map(\.id))
                var domainByRefId: [String: String] = [:]
                for feature in built.packet.features {
                    domainByRefId[feature.id] = domainByRefId[feature.id] ?? feature.domain
                }
                for item in built.packet.portrait where domainByRefId[item.id] == nil {
                    domainByRefId[item.id] = item.sourceDomains.first ?? "profile"
                }
                let card = try DiscoveryInsightCardBuilder.build(
                    selected: selected, slots: built.slots, portraitIds: portraitIds,
                    domainByRefId: domainByRefId, now: now
                )
                store.enqueue(card)
                logger.info("v4 洞察入队: \(selected.angleKey, privacy: .public)")
                return true
            }
            switch draft.noneReason {
            case "none_worthwhile", "insufficient_data":
                // 宁缺毋滥：当天不出卡，v3 也不补。
                store.markInsightV2NoneWorthwhile(now: now)
                logger.info("v4 判定无值得说的洞察(\(draft.noneReason ?? "?", privacy: .public))，当天不出卡")
                return false
            case "quota_exhausted":
                // 预算墙（2026-11-21）：不回落 v3（墙语义）、不出卡；评审页展示升级引导。
                store.markInsightQuotaWalled(now: now)
                logger.info("v4 预算墙：每周额度已用完，展示升级引导")
                return false
            case "disabled":
                DiscoveryFeatureFlags.markDisabledByServer()
                return await fallbackToV3(proposals: proposals, now: now, reason: "后端开关关")
            default:
                // gate_rejected 及未知码：后端闸门失败 ≠ 数据无价值 → v3 兜底。
                return await fallbackToV3(proposals: proposals, now: now, reason: "gate_rejected")
            }
        } catch {
            logger.error("v4 洞察请求失败，回落 v3: \(String(describing: error), privacy: .public)")
            return await fallbackToV3(proposals: proposals, now: now, reason: "error")
        }
    }

    private static func fallbackToV3(proposals: [HoloKnowledgeRevision], now: Date, reason: String) async -> Bool {
        logger.info("v4 回落 v3（\(reason, privacy: .public)）")
        return await DiscoveryTopicService.refreshIfNeeded(proposals: proposals, now: now)
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
