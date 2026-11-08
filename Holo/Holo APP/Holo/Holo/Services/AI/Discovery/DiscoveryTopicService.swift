import Foundation

/// 「一个发现」v3 选题服务（2026-11-08 方案 §5.2）：观察形状 → 服务端模型选题+文案填空
/// → 本机回填真值+终审 → 入展示队列。任何失败都降级本机规则选题（挖掘器现成文案），
/// 功能永不卡死（旧版 15 层事故的第一教训）。
///
/// 隐私口径：上送清单只有形状（域/类型/方向/周数/天数），无金额、无健康数值、无正文；
/// 模型文案里的数字全部由本机回填——模型自始至终看不到任何数值。
@MainActor
enum DiscoveryTopicService {

    /// 从挖掘器提案组装形状候选（measured 字段是挖掘器的数字真值载体，不上送）。
    static func candidates(from proposals: [HoloKnowledgeRevision], now: Date = Date()) -> [DiscoveryTopicCandidate] {
        let store = DiscoveryTopicStore.shared
        let rejected = store.rejectedTopics
        let deferred = store.deferredActiveKeys(now: now)
        let shown = Set(store.shownTopics)
        return proposals
            .filter { proposal in
                guard let key = topicKey(of: proposal) else { return false }
                return !rejected.contains(key) && !deferred.contains(key)
            }
            .compactMap { proposal in
                guard let domain = domainName(of: proposal),
                      let shape = shape(of: proposal) else { return nil }
                let key = topicKey(of: proposal)!
                return DiscoveryTopicCandidate(
                    id: shape.observationId,
                    domain: domain,
                    kind: shape.kind,
                    direction: shape.direction,
                    label: shape.label,
                    freshness: shown.contains(key) ? "seen" : "new",
                    topicKey: key,
                    slots: shape.slots
                )
            }
    }

    /// 选题主流程：队列该补货时调用。返回是否成功入队（供测试与日志）。
    @discardableResult
    static func refreshIfNeeded(
        proposals: [HoloKnowledgeRevision],
        language: String = Locale.current.identifier.hasPrefix("zh-Hant") ? "zh-Hant" : (Locale.current.languageCode == "en" ? "en" : "zh-Hans"),
        now: Date = Date()
    ) async -> Bool {
        let store = DiscoveryTopicStore.shared
        // 每天一张：队列空才补货（一次一张，逐日消费）。
        guard store.queue.isEmpty else { return false }
        let pool = candidates(from: proposals, now: now)
        guard !pool.isEmpty else { return false }

        // 服务端选题（模型文案）。失败/无选择 → 本机规则降级。
        if let card = await selectFromServer(pool: pool, proposals: proposals, language: language, now: now) {
            store.enqueue(card)
            return true
        }
        if let fallback = localFallback(pool: pool, proposals: proposals, now: now) {
            store.enqueue(fallback)
            return true
        }
        return false
    }

    // MARK: - 服务端选题

    static func selectFromServer(
        pool: [DiscoveryTopicCandidate],
        proposals: [HoloKnowledgeRevision],
        language: String,
        now: Date
    ) async -> DiscoveryTopicStore.QueuedCard? {
        let store = DiscoveryTopicStore.shared
        let body = DiscoveryTopicRequestBody(
            requestId: UUID().uuidString,
            language: language,
            poolFingerprint: String(format: "%040x", abs(pool.hashValue)),
            recentTopics: Array(store.shownTopics.suffix(20)),
            candidates: pool
        )
        let request = APIRequest(
            baseURL: HoloBackendEnvironment.baseURL,
            path: "/v1/discovery/topic",
            method: .post,
            headers: ["X-Holo-Device-Id": HoloBackendDeviceIdentity.shared.deviceId],
            body: body,
            timeoutInterval: 35
        )
        do {
            let response: DiscoveryTopicResponse = try await APIClient.shared.send(request)
            guard let selection = response.selection else { return nil }
            return try? buildCard(selection: selection, pool: pool, proposals: proposals, now: now)
        } catch {
            // 断网/503/超时/解码失败——统一走本机降级（调用方处理）。
            return nil
        }
    }

    /// 回填空位 + 终审（数字一致性/长度/残留空位），任何不过 → throw（降级）。
    static func buildCard(
        selection: DiscoveryTopicSelection,
        pool: [DiscoveryTopicCandidate],
        proposals: [HoloKnowledgeRevision],
        now: Date = Date()
    ) throws -> DiscoveryTopicStore.QueuedCard {
        guard let candidate = pool.first(where: { $0.id == selection.observationId }) else {
            throw TopicError.unknownObservation
        }
        let proposal = proposals.first { topicKey(of: $0) == (candidate.topicKey ?? candidate.id) }
        let slotValues = slotValues(for: candidate, proposal: proposal)
        var title = selection.titleTemplate
        var body = selection.bodyTemplate
        for (name, value) in slotValues {
            title = title.replacingOccurrences(of: "{\(name)}", with: value)
            body = body.replacingOccurrences(of: "{\(name)}", with: value)
        }
        // 终审①：不允许残留空位（模型用了白名单外写法或缺失值 → 降级）。
        guard !title.contains("{"), !body.contains("{") else { throw TopicError.unfilledSlot }
        // 终审②：长度红线（回填真值后的最终限制，卡片版式定死）。
        guard title.count <= 16, body.count <= 90 else { throw TopicError.length }
        // 终审③：文案中的数字必须能在槽位值里找到（数字纪律客户端版）。
        let digitsInCopy = extractNumbers(from: title + body)
        let allowed = Set(slotValues.values.flatMap { extractNumbers(from: $0) })
        guard digitsInCopy.isSubset(of: allowed) else { throw TopicError.foreignNumber }
        // 时效：跟随观察源窗口（无窗口则按 6 周默认）。
        let windowEnd = proposal?.initialEvidenceSnapshot.observationWindowTo
            ?? now.addingTimeInterval(6 * 7 * 86_400)
        return DiscoveryTopicStore.QueuedCard(
            observationId: candidate.id,
            topicKey: candidate.topicKey ?? candidate.id,
            title: title,
            body: body,
            isModelCopy: true,
            selectedAt: now,
            windowEnd: windowEnd
        )
    }

    enum TopicError: Error { case unknownObservation, unfilledSlot, length, foreignNumber }

    /// 数字纪律：从文案提取全部数字串本身（阿拉伯/全角/中文数字连续段），
    /// 用于「数字⊆槽位值」比对——中文无空格分词，比对对象必须是数字串而非整词。
    nonisolated static func extractNumbers(from text: String) -> Set<String> {
        var out = Set<String>()
        for run in text.runs(where: { $0.isNumber || "零一二两三四五六七八九十百千万亿".contains($0) }) {
            out.insert(String(run))
        }
        return out
    }


    // MARK: - 本机降级（规则选题：最新鲜+证据最多）

    static func localFallback(pool: [DiscoveryTopicCandidate], proposals: [HoloKnowledgeRevision], now: Date) -> DiscoveryTopicStore.QueuedCard? {
        // 规则：freshness=new 优先，其次槽位多（信息量大）的；稳定可解释。
        guard let best = pool.sorted(by: {
            if ($0.freshness == "new") != ($1.freshness == "new") { return $0.freshness == "new" }
            return $0.slots.count > $1.slots.count
        }).first else { return nil }
        let proposal = proposals.first { topicKey(of: $0) == (best.topicKey ?? best.id) }
        // 文案：挖掘器现成 displayText（朴素模板，无「精选」标识）。
        guard let text = proposal?.semantic.displayText else { return nil }
        let title = String(text.prefix(16))
        let windowEnd = proposal?.initialEvidenceSnapshot.observationWindowTo
            ?? now.addingTimeInterval(6 * 7 * 86_400)
        return DiscoveryTopicStore.QueuedCard(
            observationId: best.id,
            topicKey: best.topicKey ?? best.id,
            title: title,
            body: text,
            isModelCopy: false,
            selectedAt: now,
            windowEnd: windowEnd
        )
    }

    // MARK: - 形状提取（挖掘器提案 → 候选形状）

    private struct Shape {
        var observationId: String
        var kind: String
        var direction: String
        var label: String?
        var slots: [String]
    }

    /// 从提案提取形状：obs id / 命题类型 / 方向 / 可回填槽位白名单。
    /// 挖掘器原始键保留在 semantic.objectRef（propositionID 被 make 规范化为
    /// holo-prop-<hash>）：finance-category:<id> / health-metric:<metric>。
    private static func shape(of proposal: HoloKnowledgeRevision) -> Shape? {
        guard let key = proposal.semantic.objectRef else { return nil }
        if key.hasPrefix("finance-category:") {
            return Shape(
                observationId: key,
                kind: "categoryFrequency",
                direction: directionOf(proposal),
                label: proposal.topicLabel,
                slots: ["weeks", "recordDays", "txCount", "label"]
            )
        }
        if key.hasPrefix("health-metric:") {
            return Shape(
                observationId: key,
                kind: "weekendCompare",
                direction: directionOf(proposal),
                label: proposal.topicLabel,
                slots: ["weeks", "matchWeeks", "recordDays", "label"]
            )
        }
        // 既有萃取命题（想法/任务/习惯等域）一期不参与模型选题（无数字槽位，文案无回填必要），
        // 只入池不做模型候选——返回 nil 由调用方跳过。
        return nil
    }

    private static func directionOf(_ proposal: HoloKnowledgeRevision) -> String {
        let text = proposal.semantic.displayText ?? ""
        if text.contains("高于") || text.contains("更多") || text.contains("变多") { return "higher" }
        if text.contains("低于") || text.contains("更少") || text.contains("变少") { return "lower" }
        return "contrast"
    }

    private static func domainName(of proposal: HoloKnowledgeRevision) -> String? {
        guard let first = proposal.domains.first else { return nil }
        return first.rawValue
    }

    private static func topicKey(of proposal: HoloKnowledgeRevision) -> String? {
        proposal.topicID.isEmpty ? proposal.propositionID : proposal.topicID
    }

    /// observationId 一律用 propositionID（与 shape 的键约定一致）。
    private static func observationId(of proposal: HoloKnowledgeRevision) -> String {
        proposal.propositionID
    }

    /// 槽位真值：从提案 semantic.objectValue（挖掘器 measured 数字载体）与 label 取，
    /// 绝不含金额与原始读数。财务 "days|weeks|items"；健康 "matching|weeks|days"。
    private static func slotValues(
        for candidate: DiscoveryTopicCandidate,
        proposal: HoloKnowledgeRevision?
    ) -> [String: String] {
        var values: [String: String] = [:]
        if let label = candidate.label { values["label"] = label }
        guard let measured = proposal?.semantic.objectValue else { return values }
        let parts = measured.split(separator: "|").map(String.init)
        if candidate.kind == "categoryFrequency", parts.count >= 3 {
            // days|weeks|items
            values["recordDays"] = parts[0]
            values["weeks"] = parts[1]
            values["txCount"] = parts[2]
        } else if candidate.kind == "weekendCompare", parts.count >= 2 {
            // matching|weeks|days（挖掘器 "higher|lower|total" 之外的展示口径
            // 由 statsSummary 提供天数；这里按 measured 前两段+事件数兜底）
            values["matchWeeks"] = parts[0]
            values["weeks"] = parts.count >= 3 ? parts[2] : parts[1]
            if let events = proposal?.initialEvidenceSnapshot.independentEventCount {
                values["recordDays"] = String(events)
            }
        }
        return values
    }
}

private extension String {
    /// 连续满足条件的字符段（等价 NSRegularExpression 提取，零正则开销）。
    func runs(where predicate: (Character) -> Bool) -> [SubSequence] {
        var result: [SubSequence] = []
        var start: Index?
        var index = startIndex
        while index < endIndex {
            if predicate(self[index]) {
                if start == nil { start = index }
            } else if let s = start {
                result.append(self[s..<index])
                start = nil
            }
            index = self.index(after: index)
        }
        if let s = start { result.append(self[s..<index]) }
        return result
    }
}
