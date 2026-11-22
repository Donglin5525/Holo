//
//  HoloPortraitSynthesisModels.swift
//  Holo
//
//  Phase 2：五维度动态用户画像 + 跨模块洞察模型、轻量安全底线核验器与本地画像仓。
//  纯 Swift、零 App 依赖（standalone 可直接回归测试）。
//
//  核心原则（2026-11-20 东林拍板）：
//  1. 敢推断 + 标明推测态 + 一键纠正：低风险生活画像允许单域重复直接形成「推测态」，
//     安全底线仅拦截医疗诊断/道德贬损/浅层算术复述/已否决黑名单。
//  2. 五维度结构化组织：identity / longTermPattern / preference / recentState / crossDomainInsight。
//  3. 用户一键「不准」立即移出活跃画像并永久写入黑名单，下次合成原样喂回模型，永不复活。
//

import Foundation

// MARK: - 五维度与三态置信度

nonisolated enum PortraitDimension: String, Codable, CaseIterable, Sendable {
    case identity            // 基础属性与生活角色（如「养猫（推测）」、职业）
    case longTermPattern     // 长期行为与节律（如「长期每日喝咖啡」）
    case preference          // 偏好与边界（如「回复简洁直接」）
    case recentState         // 近期状态与变化（14~30天相对基线波动）
    case crossDomainInsight  // 跨模块洞察与假设（如「晚睡可能与下午喝咖啡有关」）

    var displayTitle: String {
        switch self {
        case .identity: return "属性与角色"
        case .longTermPattern: return "长期行为与节律"
        case .preference: return "偏好与边界"
        case .recentState: return "近期状态与变化"
        case .crossDomainInsight: return "跨模块洞察"
        }
    }
}

nonisolated enum PortraitConfidence: String, Codable, Sendable {
    case confirmed           // 用户自述 / 档案 / 用户点击「准」
    case inferred            // AI 综合推断，自动温和生效，带「推测」角标可一键纠偏
    case needsClarification  // 数据覆盖不足或存在歧义，不作断言，转化为轻追问
}

// MARK: - 持久化画像节点 / 待求证 / 黑名单

nonisolated struct PortraitEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var dimension: PortraitDimension
    var confidence: PortraitConfidence
    var statement: String
    var evidenceSummary: String
    var sourceDomains: [String]
    var usageHint: String
    var updatedAt: Date
    var isUserConfirmed: Bool
}

nonisolated struct PortraitClarification: Codable, Equatable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var question: String
    var reason: String
    var createdAt: Date
}

nonisolated struct PortraitRejectedItem: Codable, Equatable, Sendable {
    var key: String
    var statement: String
    var reason: String?
    var rejectedAt: Date
}

// MARK: - 服务端返回契约（portrait_synthesis）

nonisolated struct PortraitDeltaUpsert: Codable, Equatable, Sendable {
    var key: String
    var dimension: String
    var confidence: String
    var statement: String
    var evidenceSummary: String
    var sourceDomains: [String]
    var usageHint: String

    init(
        key: String,
        dimension: String,
        confidence: String,
        statement: String,
        evidenceSummary: String = "",
        sourceDomains: [String] = [],
        usageHint: String = ""
    ) {
        self.key = key
        self.dimension = dimension
        self.confidence = confidence
        self.statement = statement
        self.evidenceSummary = evidenceSummary
        self.sourceDomains = sourceDomains
        self.usageHint = usageHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        dimension = try c.decodeIfPresent(String.self, forKey: .dimension) ?? PortraitDimension.crossDomainInsight.rawValue
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? PortraitConfidence.inferred.rawValue
        statement = try c.decode(String.self, forKey: .statement)
        evidenceSummary = try c.decodeIfPresent(String.self, forKey: .evidenceSummary) ?? ""
        sourceDomains = try c.decodeIfPresent([String].self, forKey: .sourceDomains) ?? []
        usageHint = try c.decodeIfPresent(String.self, forKey: .usageHint) ?? ""
    }
}

nonisolated struct PortraitDeltaClarification: Codable, Equatable, Sendable {
    var key: String
    var question: String
    var reason: String

    init(key: String, question: String, reason: String = "") {
        self.key = key
        self.question = question
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        question = try c.decode(String.self, forKey: .question)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

nonisolated struct PortraitDeltaEnvelope: Codable, Equatable, Sendable {
    var schemaVersion: Int?
    var upserts: [PortraitDeltaUpsert]
    var retireKeys: [String]
    var clarifications: [PortraitDeltaClarification]

    init(
        schemaVersion: Int? = 1,
        upserts: [PortraitDeltaUpsert] = [],
        retireKeys: [String] = [],
        clarifications: [PortraitDeltaClarification] = []
    ) {
        self.schemaVersion = schemaVersion
        self.upserts = upserts
        self.retireKeys = retireKeys
        self.clarifications = clarifications
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        upserts = try c.decodeIfPresent([PortraitDeltaUpsert].self, forKey: .upserts) ?? []
        retireKeys = try c.decodeIfPresent([String].self, forKey: .retireKeys) ?? []
        clarifications = try c.decodeIfPresent([PortraitDeltaClarification].self, forKey: .clarifications) ?? []
    }
}

nonisolated enum PortraitDeltaParseError: Error, LocalizedError, Equatable {
    case emptyResponse
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "portrait_synthesis 返回空内容"
        case .invalidJSON: return "portrait_synthesis 返回非法 JSON"
        }
    }
}

nonisolated enum PortraitDeltaParser {
    /// 兼容模型偶尔带 ```json ... ``` 围栏的输出，提取最外层 JSON 对象并解码。
    static func parse(from raw: String) throws -> PortraitDeltaEnvelope {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PortraitDeltaParseError.emptyResponse }

        let cleaned: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            cleaned = String(trimmed[start...end])
        } else {
            throw PortraitDeltaParseError.invalidJSON
        }
        guard let data = cleaned.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PortraitDeltaEnvelope.self, from: data) else {
            throw PortraitDeltaParseError.invalidJSON
        }
        return envelope
    }
}

// MARK: - 轻量安全底线核验器

nonisolated struct PortraitGateDecision: Equatable, Sendable {
    var accepted: Bool
    var reason: String?
}

nonisolated enum PortraitSafetyGate {

    /// 安全底线（仅拦硬违规，不扼杀合理生活画像推断）：
    /// 1) 医疗诊断词；2) 人格/道德贬损词；3) 浅层算术/模板复述；4) 命中用户已否决黑名单。
    private static let bannedPatterns: [(pattern: String, label: String)] = [
        ("抑郁症|焦虑症|确诊|诊断为|建议就医|患者", "医疗化断言"),
        ("懒惰|自律差|缺乏毅力|拖延症|社恐|孤僻|上瘾|成瘾|自制力差", "道德或人格贬损"),
        ("平均每隔|习惯进行中|期间有反复|每[0-9]+天一笔", "浅层算术或模板复述")
    ]

    static func evaluate(
        upsert: PortraitDeltaUpsert,
        blacklist: [PortraitRejectedItem]
    ) -> PortraitGateDecision {
        let key = upsert.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let stmt = upsert.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !stmt.isEmpty else {
            return PortraitGateDecision(accepted: false, reason: "空 key 或空命题")
        }
        guard PortraitDimension(rawValue: upsert.dimension) != nil else {
            return PortraitGateDecision(accepted: false, reason: "未知维度:\(upsert.dimension)")
        }
        guard PortraitConfidence(rawValue: upsert.confidence) != nil else {
            return PortraitGateDecision(accepted: false, reason: "未知置信态:\(upsert.confidence)")
        }

        // 命中黑名单（同 key 或语句高度重合）→ 永久拦截，防复活。
        for blocked in blacklist {
            if blocked.key.lowercased() == key.lowercased() {
                return PortraitGateDecision(accepted: false, reason: "命中用户已否决黑名单(\(blocked.key))")
            }
            if !blocked.statement.isEmpty && (stmt.contains(blocked.statement) || blocked.statement.contains(stmt)) {
                return PortraitGateDecision(accepted: false, reason: "语义命中已否决项(\(blocked.statement))")
            }
        }

        for rule in bannedPatterns {
            if let regex = try? NSRegularExpression(pattern: rule.pattern) {
                let range = NSRange(stmt.startIndex..., in: stmt)
                if regex.firstMatch(in: stmt, range: range) != nil {
                    return PortraitGateDecision(accepted: false, reason: "安全底线[\(rule.label)]")
                }
            }
        }

        return PortraitGateDecision(accepted: true, reason: nil)
    }
}

// MARK: - 请求载荷与本地画像仓（PortraitStore）

nonisolated struct PortraitSynthesisRequestPayload: Codable, Sendable {
    var currentPortrait: [PortraitBriefItem]
    var featurePacket: CrossDomainFeaturePacket
    var rejectedBlacklist: [PortraitBlacklistItem]

    struct PortraitBriefItem: Codable, Sendable {
        var key: String
        var dimension: String
        var confidence: String
        var statement: String
    }

    struct PortraitBlacklistItem: Codable, Sendable {
        var key: String
        var statement: String
        var reason: String?
    }

    func encodeJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated struct PortraitApplyReport: Equatable, Sendable {
    var upsertedKeys: [String]
    var retiredKeys: [String]
    var rejectedByGate: [String]
    var clarificationCount: Int
}

nonisolated struct PortraitStore: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var lastSynthesizedAt: Date?
    var lastAnomalySignature: String?
    var entries: [String: PortraitEntry] = [:]
    var clarifications: [String: PortraitClarification] = [:]
    var rejectedBlacklist: [PortraitRejectedItem] = []

    static let fileName = "portrait_store.json"

    static func load(directory: URL) -> PortraitStore {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(PortraitStore.self, from: data) else {
            return PortraitStore()
        }
        // 兼容清理已落盘旧条目中的英文时段词（如 night/evening → 深夜/晚间）。
        for (key, var entry) in decoded.entries {
            entry.statement = PortraitTextSanitizer.sanitize(entry.statement)
            entry.evidenceSummary = PortraitTextSanitizer.sanitize(entry.evidenceSummary)
            entry.usageHint = PortraitTextSanitizer.sanitize(entry.usageHint)
            decoded.entries[key] = entry
        }
        for (key, var item) in decoded.clarifications {
            item.question = PortraitTextSanitizer.sanitize(item.question)
            item.reason = PortraitTextSanitizer.sanitize(item.reason)
            decoded.clarifications[key] = item
        }
        return decoded
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    func buildPromptPayload(packet: CrossDomainFeaturePacket) -> PortraitSynthesisRequestPayload {
        let current = entries.values
            .sorted { $0.key < $1.key }
            .map {
                PortraitSynthesisRequestPayload.PortraitBriefItem(
                    key: $0.key,
                    dimension: $0.dimension.rawValue,
                    confidence: $0.confidence.rawValue,
                    statement: $0.statement
                )
            }
        let blocked = rejectedBlacklist.map {
            PortraitSynthesisRequestPayload.PortraitBlacklistItem(
                key: $0.key,
                statement: $0.statement,
                reason: $0.reason
            )
        }
        return PortraitSynthesisRequestPayload(
            currentPortrait: current,
            featurePacket: packet,
            rejectedBlacklist: blocked
        )
    }

    /// 应用一轮 portrait_synthesis 增量（过轻量安全底线 + 黑名单守卫）。
    mutating func apply(delta: PortraitDeltaEnvelope, now: Date) -> PortraitApplyReport {
        var upsertedKeys: [String] = []
        var retiredKeys: [String] = []
        var rejectedByGate: [String] = []

        for key in delta.retireKeys {
            // 用户已亲手确认的长期条目不因单轮模型建议被静默删除。
            if let existing = entries[key], !existing.isUserConfirmed {
                entries.removeValue(forKey: key)
                retiredKeys.append(key)
            }
        }

        for item in delta.upserts.prefix(6) {
            let verdict = PortraitSafetyGate.evaluate(upsert: item, blacklist: rejectedBlacklist)
            guard verdict.accepted,
                  let dim = PortraitDimension(rawValue: item.dimension),
                  let conf = PortraitConfidence(rawValue: item.confidence) else {
                rejectedByGate.append("[\(item.key)] \(verdict.reason ?? "未通过核验")")
                continue
            }
            // 保留已确认状态：若用户此前点过「准」，模型更新措辞时不得降回 inferred；
            // 反之，模型新提出的条目一律先落入 inferred（「值得确认」），不得越权自封 confirmed。
            let wasConfirmed = entries[item.key]?.isUserConfirmed ?? false
            let finalConf: PortraitConfidence = wasConfirmed ? .confirmed : (conf == .needsClarification ? .needsClarification : .inferred)
            entries[item.key] = PortraitEntry(
                key: item.key,
                dimension: dim,
                confidence: finalConf,
                statement: PortraitTextSanitizer.sanitize(String(item.statement.prefix(60))),
                evidenceSummary: PortraitTextSanitizer.sanitize(String(item.evidenceSummary.prefix(80))),
                sourceDomains: item.sourceDomains,
                usageHint: PortraitTextSanitizer.sanitize(String(item.usageHint.prefix(60))),
                updatedAt: now,
                isUserConfirmed: wasConfirmed
            )
            upsertedKeys.append(item.key)
        }

        // 每轮只保留最新 1 条待求证问题，避免打扰堆积。
        if let firstClarification = delta.clarifications.first {
            let key = firstClarification.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBlocked = rejectedBlacklist.contains { $0.key.lowercased() == key.lowercased() }
            if !key.isEmpty && !isBlocked {
                clarifications[key] = PortraitClarification(
                    key: key,
                    question: PortraitTextSanitizer.sanitize(String(firstClarification.question.prefix(60))),
                    reason: PortraitTextSanitizer.sanitize(String(firstClarification.reason.prefix(60))),
                    createdAt: now
                )
            }
        }

        lastSynthesizedAt = now
        return PortraitApplyReport(
            upsertedKeys: upsertedKeys,
            retiredKeys: retiredKeys,
            rejectedByGate: rejectedByGate,
            clarificationCount: delta.clarifications.prefix(1).count
        )
    }

    /// 用户点击「准」：升级为已确认。
    mutating func confirm(key: String, now: Date) {
        guard var entry = entries[key] else { return }
        entry.confidence = .confirmed
        entry.isUserConfirmed = true
        entry.updatedAt = now
        entries[key] = entry
    }

    /// 用户点击「不准」：立即移出活跃画像并永久写入黑名单，防复活。
    mutating func reject(key: String, reason: String? = nil, now: Date) {
        let statement = entries[key]?.statement ?? clarifications[key]?.question ?? key
        entries.removeValue(forKey: key)
        clarifications.removeValue(forKey: key)
        if !rejectedBlacklist.contains(where: { $0.key.lowercased() == key.lowercased() }) {
            rejectedBlacklist.append(PortraitRejectedItem(
                key: key,
                statement: statement,
                reason: reason,
                rejectedAt: now
            ))
        }
    }

    /// 返回按五维度分组的活跃画像（供 UI 与对话注入消费）。
    func entries(in dimension: PortraitDimension, confidenceFilter: PortraitConfidence? = nil) -> [PortraitEntry] {
        entries.values
            .filter { entry in
                entry.dimension == dimension
                    && (confidenceFilter == nil || entry.confidence == confidenceFilter)
            }
            .sorted { ($0.isUserConfirmed ? 0 : 1, $0.updatedAt) < ($1.isUserConfirmed ? 0 : 1, $1.updatedAt) }
    }

    /// 待用户在「值得确认」页表态的推测态画像与跨模块洞察数量（含待求证轻追问）。
    var pendingReviewCount: Int {
        entries.values.filter { $0.confidence == .inferred }.count + clarifications.count
    }

    /// 已确立进入「已记住」页的画像数量。
    var confirmedCount: Int {
        entries.values.filter { $0.confidence == .confirmed }.count
    }
}

// MARK: - 用户可见文案兜底清洗（严禁英文词典词透出给普通用户）

nonisolated enum PortraitTextSanitizer {
    /// 使用 ASCII 字母边界 (?<![A-Za-z])...(?![A-Za-z])，解决 ICU 中 \b 在中文紧邻英文
    /// （如「集中在night/evening时段」）时不触发边界匹配的根因。
    private static let replacements: [(pattern: String, zh: String)] = [
        ("(?i)(?<![A-Za-z])night\\s*/\\s*evening(?![A-Za-z])", "晚间和深夜"),
        ("(?i)(?<![A-Za-z])evening\\s*/\\s*night(?![A-Za-z])", "晚间和深夜"),
        ("(?i)(?<![A-Za-z])morning(?![A-Za-z])", "上午"),
        ("(?i)(?<![A-Za-z])afternoon(?![A-Za-z])", "下午"),
        ("(?i)(?<![A-Za-z])evening(?![A-Za-z])", "晚间"),
        ("(?i)(?<![A-Za-z])night(?![A-Za-z])", "深夜"),
        ("(?i)(?<![A-Za-z])coverage(?![A-Za-z])", "数据覆盖度"),
    ]

    static func sanitize(_ text: String) -> String {
        var result = text
        for rule in replacements {
            if let regex = try? NSRegularExpression(pattern: rule.pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.zh)
            }
        }
        return result
    }
}
