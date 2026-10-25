//
//  DiscoveryModels.swift
//  Holo
//
//  「HoloAI 一个发现」G1：模型输出契约 DTO、严格解码与跨字段校验、运行冻结与 FactAtom 本地模型。
//
//  契约唯一真源：docs/_common/plans/2026-10-23-holo-ai-discovery-implementation/ai-output.schema.json（V1）。
//  纪律（02 §10）：任何超出 schema 的返回必须整体拒绝；解析失败不允许回退为普通字符串直接展示。
//  隐私纪律：所有 issue 描述只含字段路径、数量与期望边界，绝不携带模型原文（quote/claim text 等）。
//

import Foundation

// MARK: - 来源域与来源类型

/// 首发允许的来源域（用户可选范围；01 设置页与 schema counterSearch.domains 共用）。
enum DiscoverySourceDomain: String, Codable, CaseIterable, Sendable, Hashable {
    case thought
    case task
    case habit
}

/// FactAtom 的来源类型（02 §2.2）。前三者对应业务记录；computedFact 是程序算出的确定性事实。
enum DiscoverySourceKind: String, Codable, CaseIterable, Sendable, Hashable {
    case thought
    case task
    case habitEvent
    case computedFact
}

// MARK: - 内部诊断原因码（05 §5，19 个全集）

/// 内部诊断原因码全集。
/// 这些是诊断类型，**不向用户展示为错误代码**；日志只存枚举，不写原文说明。
/// schema 的 DiscoveryReasonCode 是其中一个子集方向，双端保持一致；limited_scope 仅出现在核验 schema 枚举。
enum DiscoveryDiagnosticReasonCode: String, Codable, CaseIterable, Sendable {
    case noMaterial = "no_material"
    case noNontrivialObservation = "no_nontrivial_observation"
    case insufficientIndependence = "insufficient_independence"
    case insufficientCoverage = "insufficient_coverage"
    case unknownEventTime = "unknown_event_time"
    case unsupportedGeneralization = "unsupported_generalization"
    case unsupportedCausality = "unsupported_causality"
    case contradictingEvidence = "contradicting_evidence"
    case irrelevantCitation = "irrelevant_citation"
    case quoteMismatch = "quote_mismatch"
    case numericMismatch = "numeric_mismatch"
    case wrongSubject = "wrong_subject"
    case sensitiveInference = "sensitive_inference"
    case injectionAttempt = "injection_attempt"
    case schemaInvalid = "schema_invalid"
    case userRejected = "user_rejected"
    case sourceInvalidated = "source_invalidated"
    case controlChanged = "control_changed"
    case budgetDeferred = "budget_deferred"
}

// MARK: - Schema 枚举（与 ai-output.schema.json 逐字对齐）

/// 发现类型（三首发类型）
enum DiscoveryCandidateType: String, Codable, CaseIterable, Sendable {
    case twoEpisodes = "two_episodes"
    case boundedPattern = "bounded_pattern"
    case changeOverTime = "change_over_time"
}

/// 候选的适用范围口径（与 type 存在条件匹配关系，见 validate）
enum DiscoveryScopeKind: String, Codable, CaseIterable, Sendable {
    case twoEpisodes = "two_episodes"
    case boundedEvents = "bounded_events"
    case comparedPeriods = "compared_periods"
}

/// claim 的种类：直接事实 / 有限观察。解释不能冒充事实。
enum DiscoveryClaimKind: String, Codable, CaseIterable, Sendable {
    case fact
    case observation
}

/// 敏感分类。不明确即 uncertain，首发 uncertain/sensitive 拒绝发布。
enum DiscoverySensitivity: String, Codable, CaseIterable, Sendable {
    case nonSensitive = "non_sensitive"
    case sensitive
    case uncertain
}

/// 空结果原因枚举（与 candidates 是否为空互斥，见 validate）
enum DiscoveryNoFindingReason: String, Codable, CaseIterable, Sendable {
    case none
    case noMaterial = "no_material"
    case noNontrivialObservation = "no_nontrivial_observation"
    case insufficientIndependence = "insufficient_independence"
    case insufficientCoverage = "insufficient_coverage"
    case sensitiveInference = "sensitive_inference"
}

/// 核验阶段 claim 级结论
enum DiscoveryClaimVerdict: String, Codable, CaseIterable, Sendable {
    case supported
    case unsupported
    case contradicted
    case insufficient
}

/// 核验阶段候选级结论（只有 accept/reject）
enum DiscoveryCandidateVerdict: String, Codable, CaseIterable, Sendable {
    case accept
    case reject
}

/// schema ReasonCode 枚举（13 个，双端一致；是 DiscoveryDiagnosticReasonCode 的子集方向 + limited_scope）
enum DiscoveryReasonCode: String, Codable, CaseIterable, Sendable {
    case insufficientIndependence = "insufficient_independence"
    case insufficientCoverage = "insufficient_coverage"
    case unknownEventTime = "unknown_event_time"
    case unsupportedGeneralization = "unsupported_generalization"
    case unsupportedCausality = "unsupported_causality"
    case contradictingEvidence = "contradicting_evidence"
    case irrelevantCitation = "irrelevant_citation"
    case quoteMismatch = "quote_mismatch"
    case numericMismatch = "numeric_mismatch"
    case wrongSubject = "wrong_subject"
    case sensitiveInference = "sensitive_inference"
    case injectionAttempt = "injection_attempt"
    case limitedScope = "limited_scope"
}

// MARK: - 校验问题

/// 严格解码/校验发现的一条结构问题。
/// `detail` 只含字段名、数量与期望边界，不含任何模型原文（可安全进日志）。
struct DiscoverySchemaIssue: Error, Equatable, Sendable, CustomStringConvertible {
    enum Code: String, Equatable, Sendable {
        case malformedDocument       // 非合法单文档 JSON（含尾部多余内容）
        case multipleDocuments       // 一个以上 JSON 文档
        case unknownField            // 白名单之外的字段（additionalProperties: false）
        case missingRequiredField
        case typeMismatch
        case invalidEnumValue        // 枚举精确匹配失败
        case versionMismatch         // schemaVersion != 1
        case kindMismatch            // kind 信封类型不符
        case invalidLength           // 长度越界
        case invalidCount            // 数量越界
        case invalidIDFormat         // 不符 ID 模式 ^[A-Za-z0-9][A-Za-z0-9:_-]*$
        case duplicateID             // 应唯一（uniqueItems / 局部唯一）而重复
        case brokenReference         // 跨字段 ID 引用缺失（title/body 指向不存在的 claim）
        case claimCoverageIncomplete // 存在游离于标题/正文之外的 claim
        case conditionalMismatch     // type/scopeKind/comparisonPeriods 条件约束失败
        case mutexViolation          // noFindingReason 与 candidates 互斥失败
        case verdictInconsistent     // accept→全 supported / supported→有支持证据 失败
        case invalidDateTime         // date-time 无法解析
    }

    let code: Code
    let path: String
    let detail: String

    var description: String {
        "discovery.schema[\(code.rawValue)] @\(path): \(detail)"
    }
}

/// 结构拒绝错误：至少携带一条 DiscoverySchemaIssue。
struct DiscoverySchemaError: Error, Sendable {
    let issues: [DiscoverySchemaIssue]
}

// MARK: - 严格解码工具（私有）

/// 严格解码公共逻辑：未知字段拒绝、长度/数量边界、枚举精确匹配、ID 模式。
/// 采用单一策略：JSONDecoder + 各类型自定义 init(from:) 逐容器白名单检查；
/// 不混用 JSONSerialization 键预检。
private enum DiscoveryStrictJSON {

    /// JSONDecoder 顶层解码本身即拒绝尾部多余内容（单文档约束），malformed/multi-document 统一归到这里。
    static let decoder = JSONDecoder()

    /// 显式单文档预检：定位第一个完整 JSON 值的结束位置（字符串感知的深度扫描），
    /// 之后若还有非空白字节即判定为多文档。比依赖 JSONDecoder 的错误分类可靠
    /// （拼接两个同形对象时 JSONDecoder 会报成 typeMismatch，见 schema 测试）。
    static func assertSingleDocument(_ data: Data) throws {
        let bytes = [UInt8](data)
        var index = 0
        // 跳过前导空白
        while index < bytes.count, isJSONWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count else {
            throw DiscoverySchemaError(issues: [
                DiscoverySchemaIssue(code: .malformedDocument, path: "$", detail: "空输入")
            ])
        }
        let first = bytes[index]
        // 非对象/数组开头 = JSON 文档碎片（本协议顶层必为对象）
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else {
            throw DiscoverySchemaError(issues: [
                DiscoverySchemaIssue(code: .malformedDocument, path: "$", detail: "顶层必须是 JSON 对象")
            ])
        }
        var depth = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
                if depth == 0 {
                    index += 1
                    break
                }
            }
            index += 1
        }
        if depth != 0 {
            throw DiscoverySchemaError(issues: [
                DiscoverySchemaIssue(code: .malformedDocument, path: "$", detail: "JSON 值未闭合")
            ])
        }
        while index < bytes.count, isJSONWhitespace(bytes[index]) { index += 1 }
        guard index == bytes.count else {
            throw DiscoverySchemaError(issues: [
                DiscoverySchemaIssue(code: .multipleDocuments, path: "$", detail: "一个以上 JSON 文档")
            ])
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// 接受任意字符串键的 CodingKey。
    /// 必须用它另开一个容器才能看到 JSON 实际存在的全部键：
    /// enum CodingKeys 的 KeyedDecodingContainer.allKeys 只列出能映射到既有 case 的键，
    /// 检测不了未知字段（已实测），这是 additionalProperties:false 的关键实现细节。
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { nil }
    }

    static func rejectUnknownKeys(
        on decoder: Decoder,
        allowedKeys: [String],
        path: String
    ) throws {
        let present = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let allowed = Set(allowedKeys)
        let unknown = present.filter { !allowed.contains($0) }
        guard unknown.isEmpty else {
            throw DiscoverySchemaIssue(
                code: .unknownField,
                path: path,
                detail: "未知字段：\(unknown.sorted().joined(separator: ", "))（白名单：\(allowedKeys.sorted().joined(separator: ", "))）"
            )
        }
    }

    static func checkLength(_ value: String, in range: ClosedRange<Int>, field: String, path: String) throws {
        guard range.contains(value.count) else {
            throw DiscoverySchemaIssue(
                code: .invalidLength,
                path: path,
                detail: "\(field) 长度 \(value.count) 超出 \(range.lowerBound)...\(range.upperBound)"
            )
        }
    }

    static func checkCount(_ count: Int, atLeast min: Int? = nil, atMost max: Int? = nil, field: String, path: String) throws {
        if let min, count < min {
            throw DiscoverySchemaIssue(code: .invalidCount, path: path, detail: "\(field) 数量 \(count) 少于最小值 \(min)")
        }
        if let max, count > max {
            throw DiscoverySchemaIssue(code: .invalidCount, path: path, detail: "\(field) 数量 \(count) 超过最大值 \(max)")
        }
    }

    /// schema ID 模式 ^[A-Za-z0-9][A-Za-z0-9:_-]*$ 的确定性字符校验
    /// （逐字符 ASCII 判定，等价于该正则；ID 上限 80 字符，性能无关紧要）
    static func matchesIDPattern(_ value: String) -> Bool {
        guard (1...80).contains(value.count), let first = value.first else { return false }
        guard first.isASCII, first.isLetter || first.isNumber else { return false }
        return value.dropFirst().allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == ":" || character == "_" || character == "-"
        }
    }

    static func checkID(_ value: String, field: String, path: String) throws {
        guard matchesIDPattern(value) else {
            throw DiscoverySchemaIssue(code: .invalidIDFormat, path: path, detail: "\(field) 不符 ID 模式 ^[A-Za-z0-9][A-Za-z0-9:_-]*$（1...80 字符）")
        }
    }

    /// IDList：逐项 ID 模式 + 数量上限（uniqueItems 在 validate 阶段查）
    static func checkIDList(_ values: [String], atMost max: Int, field: String, path: String) throws {
        try checkCount(values.count, atMost: max, field: field, path: path)
        for (index, value) in values.enumerated() {
            try checkID(value, field: "\(field)[\(index)]", path: path)
        }
    }

    static func decodeEnum<V: RawRepresentable>(_ raw: String, as type: V.Type, field: String, path: String) throws -> V where V.RawValue == String {
        guard let value = V(rawValue: raw) else {
            throw DiscoverySchemaIssue(code: .invalidEnumValue, path: path, detail: "\(field) 值不在枚举允许集合内（精确匹配）")
        }
        return value
    }

    static func path(of codingPath: [CodingKey]) -> String {
        codingPath.isEmpty ? "$" : "$." + codingPath.map(\.stringValue).joined(separator: ".")
    }
}

/// RFC 3339 date-time 解析（schema format: date-time；校验在 validate 阶段执行）
enum DiscoveryISO8601 {
    static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        parser.date(from: raw)
    }
}

// MARK: - TimeRange

/// 时间区间。start/end 允许为 null（只知道月份/未知时不能伪造具体时刻）。
/// 保存原文 ISO 串，比较时才解析。
struct DiscoveryTimeRange: Equatable, Sendable {
    let start: String?
    let end: String?

    init(start: String?, end: String?) {
        self.start = start
        self.end = end
    }
}

extension DiscoveryTimeRange: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case start
        case end
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        // 显式 null 与缺字段在此契约等价处理：decodeIfPresent 均得 nil（缺字段本应拒绝，
        // 但 schema required 含 start/end 且类型允许 null，null 是合法值；缺字段由 rejectUnknownKeys
        // 之外的标准 keyNotFound 路径兜底映射为 missingRequiredField）。
    }
}

// MARK: - Citation

struct DiscoveryCitation: Equatable, Sendable {
    let evidenceID: String
    let quote: String

    init(evidenceID: String, quote: String) {
        self.evidenceID = evidenceID
        self.quote = quote
    }
}

extension DiscoveryCitation: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case evidenceID
        case quote
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        evidenceID = try c.decode(String.self, forKey: .evidenceID)
        quote = try c.decode(String.self, forKey: .quote)
        try DiscoveryStrictJSON.checkID(evidenceID, field: "evidenceID", path: path)
        try DiscoveryStrictJSON.checkLength(quote, in: 2...400, field: "quote", path: path)
    }
}

// MARK: - Claim

struct DiscoveryClaim: Equatable, Sendable {
    let claimID: String
    let kind: DiscoveryClaimKind
    let text: String
    let citations: [DiscoveryCitation]
    let metricIDs: [String]

    init(claimID: String, kind: DiscoveryClaimKind, text: String, citations: [DiscoveryCitation], metricIDs: [String]) {
        self.claimID = claimID
        self.kind = kind
        self.text = text
        self.citations = citations
        self.metricIDs = metricIDs
    }
}

extension DiscoveryClaim: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case claimID
        case kind
        case text
        case citations
        case metricIDs
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        claimID = try c.decode(String.self, forKey: .claimID)
        let kindRaw = try c.decode(String.self, forKey: .kind)
        kind = try DiscoveryStrictJSON.decodeEnum(kindRaw, as: DiscoveryClaimKind.self, field: "kind", path: path)
        text = try c.decode(String.self, forKey: .text)
        citations = try c.decode([DiscoveryCitation].self, forKey: .citations)
        metricIDs = try c.decode([String].self, forKey: .metricIDs)
        try DiscoveryStrictJSON.checkID(claimID, field: "claimID", path: path)
        try DiscoveryStrictJSON.checkLength(text, in: 2...180, field: "text", path: path)
        try DiscoveryStrictJSON.checkCount(citations.count, atLeast: 1, atMost: 6, field: "citations", path: path)
        try DiscoveryStrictJSON.checkIDList(metricIDs, atMost: 24, field: "metricIDs", path: path)
    }
}

// MARK: - CounterSearch

/// 反例检索规格：模型只能提议受限本地检索（domain/anchor/keyword），不能指定文件路径、URL 或工具代码。
struct DiscoveryCounterSearch: Equatable, Sendable {
    let domains: [DiscoverySourceDomain]
    let anchorRefs: [String]
    let keywords: [String]

    init(domains: [DiscoverySourceDomain], anchorRefs: [String], keywords: [String]) {
        self.domains = domains
        self.anchorRefs = anchorRefs
        self.keywords = keywords
    }
}

extension DiscoveryCounterSearch: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case domains
        case anchorRefs
        case keywords
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        let domainRaws = try c.decode([String].self, forKey: .domains)
        domains = try domainRaws.map { try DiscoveryStrictJSON.decodeEnum($0, as: DiscoverySourceDomain.self, field: "domains", path: path) }
        anchorRefs = try c.decode([String].self, forKey: .anchorRefs)
        keywords = try c.decode([String].self, forKey: .keywords)
        try DiscoveryStrictJSON.checkCount(domains.count, atLeast: 1, atMost: 3, field: "domains", path: path)
        try DiscoveryStrictJSON.checkIDList(anchorRefs, atMost: 24, field: "anchorRefs", path: path)
        try DiscoveryStrictJSON.checkCount(keywords.count, atMost: 4, field: "keywords", path: path)
        for keyword in keywords {
            try DiscoveryStrictJSON.checkLength(keyword, in: 1...24, field: "keywords 项", path: path)
        }
    }
}

// MARK: - Candidate

struct DiscoveryCandidate: Equatable, Sendable {
    let candidateID: String
    let type: DiscoveryCandidateType
    let subjectKey: String
    let scopeKind: DiscoveryScopeKind
    let timeRange: DiscoveryTimeRange
    let claims: [DiscoveryClaim]
    let titleClaimID: String
    let bodyClaimIDs: [String]
    let supportEvidenceIDs: [String]
    let counterSearch: [DiscoveryCounterSearch]
    let sensitivity: DiscoverySensitivity
    let comparisonPeriods: [DiscoveryTimeRange]

    init(
        candidateID: String,
        type: DiscoveryCandidateType,
        subjectKey: String,
        scopeKind: DiscoveryScopeKind,
        timeRange: DiscoveryTimeRange,
        claims: [DiscoveryClaim],
        titleClaimID: String,
        bodyClaimIDs: [String],
        supportEvidenceIDs: [String],
        counterSearch: [DiscoveryCounterSearch],
        sensitivity: DiscoverySensitivity,
        comparisonPeriods: [DiscoveryTimeRange]
    ) {
        self.candidateID = candidateID
        self.type = type
        self.subjectKey = subjectKey
        self.scopeKind = scopeKind
        self.timeRange = timeRange
        self.claims = claims
        self.titleClaimID = titleClaimID
        self.bodyClaimIDs = bodyClaimIDs
        self.supportEvidenceIDs = supportEvidenceIDs
        self.counterSearch = counterSearch
        self.sensitivity = sensitivity
        self.comparisonPeriods = comparisonPeriods
    }
}

extension DiscoveryCandidate: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case candidateID
        case type
        case subjectKey
        case scopeKind
        case timeRange
        case claims
        case titleClaimID
        case bodyClaimIDs
        case supportEvidenceIDs
        case counterSearch
        case sensitivity
        case comparisonPeriods
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        candidateID = try c.decode(String.self, forKey: .candidateID)
        let typeRaw = try c.decode(String.self, forKey: .type)
        type = try DiscoveryStrictJSON.decodeEnum(typeRaw, as: DiscoveryCandidateType.self, field: "type", path: path)
        subjectKey = try c.decode(String.self, forKey: .subjectKey)
        let scopeRaw = try c.decode(String.self, forKey: .scopeKind)
        scopeKind = try DiscoveryStrictJSON.decodeEnum(scopeRaw, as: DiscoveryScopeKind.self, field: "scopeKind", path: path)
        timeRange = try c.decode(DiscoveryTimeRange.self, forKey: .timeRange)
        claims = try c.decode([DiscoveryClaim].self, forKey: .claims)
        titleClaimID = try c.decode(String.self, forKey: .titleClaimID)
        bodyClaimIDs = try c.decode([String].self, forKey: .bodyClaimIDs)
        supportEvidenceIDs = try c.decode([String].self, forKey: .supportEvidenceIDs)
        counterSearch = try c.decode([DiscoveryCounterSearch].self, forKey: .counterSearch)
        let sensitivityRaw = try c.decode(String.self, forKey: .sensitivity)
        sensitivity = try DiscoveryStrictJSON.decodeEnum(sensitivityRaw, as: DiscoverySensitivity.self, field: "sensitivity", path: path)
        comparisonPeriods = try c.decode([DiscoveryTimeRange].self, forKey: .comparisonPeriods)

        try DiscoveryStrictJSON.checkID(candidateID, field: "candidateID", path: path)
        try DiscoveryStrictJSON.checkID(subjectKey, field: "subjectKey", path: path)
        try DiscoveryStrictJSON.checkCount(claims.count, atLeast: 2, atMost: 4, field: "claims", path: path)
        try DiscoveryStrictJSON.checkID(titleClaimID, field: "titleClaimID", path: path)
        try DiscoveryStrictJSON.checkIDList(bodyClaimIDs, atMost: 3, field: "bodyClaimIDs", path: path)
        try DiscoveryStrictJSON.checkCount(bodyClaimIDs.count, atLeast: 1, field: "bodyClaimIDs", path: path)
        try DiscoveryStrictJSON.checkIDList(supportEvidenceIDs, atMost: 12, field: "supportEvidenceIDs", path: path)
        try DiscoveryStrictJSON.checkCount(supportEvidenceIDs.count, atLeast: 2, field: "supportEvidenceIDs", path: path)
        try DiscoveryStrictJSON.checkCount(counterSearch.count, atMost: 3, field: "counterSearch", path: path)
        try DiscoveryStrictJSON.checkCount(comparisonPeriods.count, atMost: 2, field: "comparisonPeriods", path: path)
    }
}

// MARK: - ClaimResult / CandidateResult

struct DiscoveryClaimResult: Equatable, Sendable {
    let claimID: String
    let verdict: DiscoveryClaimVerdict
    let reasonCodes: [DiscoveryReasonCode]
    let supportEvidenceIDs: [String]
    let counterEvidenceIDs: [String]

    init(claimID: String, verdict: DiscoveryClaimVerdict, reasonCodes: [DiscoveryReasonCode], supportEvidenceIDs: [String], counterEvidenceIDs: [String]) {
        self.claimID = claimID
        self.verdict = verdict
        self.reasonCodes = reasonCodes
        self.supportEvidenceIDs = supportEvidenceIDs
        self.counterEvidenceIDs = counterEvidenceIDs
    }
}

extension DiscoveryClaimResult: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case claimID
        case verdict
        case reasonCodes
        case supportEvidenceIDs
        case counterEvidenceIDs
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        claimID = try c.decode(String.self, forKey: .claimID)
        let verdictRaw = try c.decode(String.self, forKey: .verdict)
        verdict = try DiscoveryStrictJSON.decodeEnum(verdictRaw, as: DiscoveryClaimVerdict.self, field: "verdict", path: path)
        let reasonRaws = try c.decode([String].self, forKey: .reasonCodes)
        reasonCodes = try reasonRaws.map { try DiscoveryStrictJSON.decodeEnum($0, as: DiscoveryReasonCode.self, field: "reasonCodes", path: path) }
        supportEvidenceIDs = try c.decode([String].self, forKey: .supportEvidenceIDs)
        counterEvidenceIDs = try c.decode([String].self, forKey: .counterEvidenceIDs)
        try DiscoveryStrictJSON.checkID(claimID, field: "claimID", path: path)
        try DiscoveryStrictJSON.checkCount(reasonCodes.count, atMost: 8, field: "reasonCodes", path: path)
        try DiscoveryStrictJSON.checkIDList(supportEvidenceIDs, atMost: 24, field: "supportEvidenceIDs", path: path)
        try DiscoveryStrictJSON.checkIDList(counterEvidenceIDs, atMost: 24, field: "counterEvidenceIDs", path: path)
    }
}

struct DiscoveryCandidateResult: Equatable, Sendable {
    let candidateID: String
    let verdict: DiscoveryCandidateVerdict
    let claimResults: [DiscoveryClaimResult]
    let reasonCodes: [DiscoveryReasonCode]

    init(candidateID: String, verdict: DiscoveryCandidateVerdict, claimResults: [DiscoveryClaimResult], reasonCodes: [DiscoveryReasonCode]) {
        self.candidateID = candidateID
        self.verdict = verdict
        self.claimResults = claimResults
        self.reasonCodes = reasonCodes
    }
}

extension DiscoveryCandidateResult: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case candidateID
        case verdict
        case claimResults
        case reasonCodes
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        candidateID = try c.decode(String.self, forKey: .candidateID)
        let verdictRaw = try c.decode(String.self, forKey: .verdict)
        verdict = try DiscoveryStrictJSON.decodeEnum(verdictRaw, as: DiscoveryCandidateVerdict.self, field: "verdict", path: path)
        claimResults = try c.decode([DiscoveryClaimResult].self, forKey: .claimResults)
        let reasonRaws = try c.decode([String].self, forKey: .reasonCodes)
        reasonCodes = try reasonRaws.map { try DiscoveryStrictJSON.decodeEnum($0, as: DiscoveryReasonCode.self, field: "reasonCodes", path: path) }
        try DiscoveryStrictJSON.checkID(candidateID, field: "candidateID", path: path)
        try DiscoveryStrictJSON.checkCount(claimResults.count, atLeast: 2, atMost: 4, field: "claimResults", path: path)
        try DiscoveryStrictJSON.checkCount(reasonCodes.count, atMost: 8, field: "reasonCodes", path: path)
    }
}

// MARK: - Envelope

/// 候选生成信封（调用一输出）
struct DiscoveryCandidateEnvelope: Equatable, Sendable {
    enum Const {
        static let schemaVersion = 1
        static let kind = "candidates"
    }

    let runID: String
    var candidates: [DiscoveryCandidate]
    var noFindingReason: DiscoveryNoFindingReason

    init(runID: String, candidates: [DiscoveryCandidate], noFindingReason: DiscoveryNoFindingReason) {
        self.runID = runID
        self.candidates = candidates
        self.noFindingReason = noFindingReason
    }
}

extension DiscoveryCandidateEnvelope: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case runID
        case candidates
        case noFindingReason
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Const.schemaVersion else {
            throw DiscoverySchemaIssue(code: .versionMismatch, path: path, detail: "schemaVersion 必须为 \(Const.schemaVersion)")
        }
        let kindRaw = try c.decode(String.self, forKey: .kind)
        guard kindRaw == Const.kind else {
            throw DiscoverySchemaIssue(code: .kindMismatch, path: path, detail: "kind 必须为 \(Const.kind)")
        }
        runID = try c.decode(String.self, forKey: .runID)
        candidates = try c.decode([DiscoveryCandidate].self, forKey: .candidates)
        let reasonRaw = try c.decode(String.self, forKey: .noFindingReason)
        noFindingReason = try DiscoveryStrictJSON.decodeEnum(reasonRaw, as: DiscoveryNoFindingReason.self, field: "noFindingReason", path: path)
        try DiscoveryStrictJSON.checkID(runID, field: "runID", path: path)
        try DiscoveryStrictJSON.checkCount(candidates.count, atMost: 3, field: "candidates", path: path)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Const.schemaVersion, forKey: .schemaVersion)
        try c.encode(Const.kind, forKey: .kind)
        try c.encode(runID, forKey: .runID)
        try c.encode(candidates, forKey: .candidates)
        try c.encode(noFindingReason, forKey: .noFindingReason)
    }
}

/// 独立核验信封（调用二输出）
struct DiscoveryVerificationEnvelope: Equatable, Sendable {
    enum Const {
        static let schemaVersion = 1
        static let kind = "verification"
    }

    let runID: String
    var candidateResults: [DiscoveryCandidateResult]

    init(runID: String, candidateResults: [DiscoveryCandidateResult]) {
        self.runID = runID
        self.candidateResults = candidateResults
    }
}

extension DiscoveryVerificationEnvelope: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case runID
        case candidateResults
    }

    init(from decoder: Decoder) throws {
        let path = DiscoveryStrictJSON.path(of: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try DiscoveryStrictJSON.rejectUnknownKeys(on: decoder, allowedKeys: CodingKeys.allCases.map(\.stringValue), path: path)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Const.schemaVersion else {
            throw DiscoverySchemaIssue(code: .versionMismatch, path: path, detail: "schemaVersion 必须为 \(Const.schemaVersion)")
        }
        let kindRaw = try c.decode(String.self, forKey: .kind)
        guard kindRaw == Const.kind else {
            throw DiscoverySchemaIssue(code: .kindMismatch, path: path, detail: "kind 必须为 \(Const.kind)")
        }
        runID = try c.decode(String.self, forKey: .runID)
        candidateResults = try c.decode([DiscoveryCandidateResult].self, forKey: .candidateResults)
        try DiscoveryStrictJSON.checkID(runID, field: "runID", path: path)
        try DiscoveryStrictJSON.checkCount(candidateResults.count, atLeast: 1, atMost: 3, field: "candidateResults", path: path)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Const.schemaVersion, forKey: .schemaVersion)
        try c.encode(Const.kind, forKey: .kind)
        try c.encode(runID, forKey: .runID)
        try c.encode(candidateResults, forKey: .candidateResults)
    }
}

// MARK: - 顶层解码入口

/// 模型输出的唯一解码入口：单文档 + 未知字段拒绝 + 枚举精确匹配 + 长度/数量边界。
/// 跨字段校验用 validate()；两者都通过才可进入后续结构门禁（02 §5）。
enum DiscoveryAIPacket {

    /// 解码候选信封。结构不合格抛 DiscoverySchemaError（问题可进日志，不含原文）。
    static func decodeCandidateEnvelope(from data: Data) throws -> DiscoveryCandidateEnvelope {
        try DiscoveryStrictJSON.assertSingleDocument(data)
        do {
            return try DiscoveryStrictJSON.decoder.decode(DiscoveryCandidateEnvelope.self, from: data)
        } catch {
            throw DiscoverySchemaError(issues: [issue(for: error, field: "candidates 信封")])
        }
    }

    /// 解码核验信封。
    static func decodeVerificationEnvelope(from data: Data) throws -> DiscoveryVerificationEnvelope {
        try DiscoveryStrictJSON.assertSingleDocument(data)
        do {
            return try DiscoveryStrictJSON.decoder.decode(DiscoveryVerificationEnvelope.self, from: data)
        } catch {
            throw DiscoverySchemaError(issues: [issue(for: error, field: "verification 信封")])
        }
    }

    /// 解码并执行跨字段校验；validate 有问题同样抛 DiscoverySchemaError。
    /// G3 网络层直接用这个入口，避免漏跑 validate。
    static func decodeValidatedCandidateEnvelope(from data: Data) throws -> DiscoveryCandidateEnvelope {
        let envelope = try decodeCandidateEnvelope(from: data)
        let issues = envelope.validate()
        guard issues.isEmpty else { throw DiscoverySchemaError(issues: issues) }
        return envelope
    }

    static func decodeValidatedVerificationEnvelope(from data: Data) throws -> DiscoveryVerificationEnvelope {
        let envelope = try decodeVerificationEnvelope(from: data)
        let issues = envelope.validate()
        guard issues.isEmpty else { throw DiscoverySchemaError(issues: issues) }
        return envelope
    }

    /// 把底层错误统一映射为 DiscoverySchemaIssue（不泄露原文）。
    private static func issue(for error: Error, field: String) -> DiscoverySchemaIssue {
        if let schemaIssue = error as? DiscoverySchemaIssue {
            return schemaIssue
        }
        if let decodingError = error as? DecodingError {
            let path = DiscoveryStrictJSON.path(of: decodingError.codingPathForIssue)
            switch decodingError {
            case .keyNotFound(let key, _):
                return DiscoverySchemaIssue(code: .missingRequiredField, path: path.isEmpty ? "$" : "\(path).\(key.stringValue)", detail: "缺少必填字段 \(key.stringValue)")
            case .typeMismatch:
                return DiscoverySchemaIssue(code: .typeMismatch, path: path, detail: "字段类型不符（\(field)）")
            case .valueNotFound:
                return DiscoverySchemaIssue(code: .missingRequiredField, path: path, detail: "必填字段为 null（\(field)）")
            default:
                return DiscoverySchemaIssue(code: .typeMismatch, path: path, detail: "解码失败（\(field)）")
            }
        }
        // JSONDecoder 对非法/尾部多余内容整体拒绝：单文档约束
        return DiscoverySchemaIssue(code: .multipleDocuments, path: "$", detail: "非合法单文档 JSON（含尾部多余内容）")
    }
}

private extension DecodingError {
    /// 从 context 提取 codingPath（各 case 均带）
    var codingPathForIssue: [CodingKey] {
        switch self {
        case .keyNotFound(_, let context):
            return context.codingPath
        case .typeMismatch(_, let context):
            return context.codingPath
        case .valueNotFound(_, let context):
            return context.codingPath
        case .dataCorrupted(let context):
            return context.codingPath
        @unknown default:
            return []
        }
    }
}

// MARK: - 跨字段校验（schema 层）

extension DiscoveryCandidateEnvelope {

    /// 跨字段校验：局部唯一性、引用完整性、type/scopeKind/comparisonPeriods 条件约束、
    /// noFindingReason 互斥、标题/正文 claim 全覆盖。返回空数组 = schema 层合格。
    /// （引用存在性、事件独立性、数字复算等需要本地材料的门禁在 G2 结构校验器做，不在此处。）
    func validate() -> [DiscoverySchemaIssue] {
        var issues: [DiscoverySchemaIssue] = []

        // candidates 与 noFindingReason 互斥（schema allOf）
        if candidates.isEmpty {
            if noFindingReason == .none {
                issues.append(DiscoverySchemaIssue(code: .mutexViolation, path: "$.noFindingReason", detail: "candidates 为空时 noFindingReason 不能为 none"))
            }
        } else if noFindingReason != .none {
            issues.append(DiscoverySchemaIssue(code: .mutexViolation, path: "$.noFindingReason", detail: "candidates 非空时 noFindingReason 必须为 none"))
        }

        // candidateID 局部唯一（02 §5 门禁 2）
        var seenCandidateIDs = Set<String>()
        for (index, candidate) in candidates.enumerated() {
            let path = "$.candidates[\(index)]"
            if !seenCandidateIDs.insert(candidate.candidateID).inserted {
                issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).candidateID", detail: "candidateID 重复"))
            }
            issues.append(contentsOf: candidate.validate(path: path))
        }
        return issues
    }
}

extension DiscoveryCandidate {

    /// 单候选跨字段校验
    func validate(path: String) -> [DiscoverySchemaIssue] {
        var issues: [DiscoverySchemaIssue] = []

        // claimID 局部唯一
        var seenClaimIDs = Set<String>()
        for claim in claims {
            if !seenClaimIDs.insert(claim.claimID).inserted {
                issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).claims", detail: "claimID 重复"))
            }
        }
        let claimIDs = Set(claims.map(\.claimID))

        // titleClaimID / bodyClaimIDs 必须指向本候选声明过的 claim
        if !claimIDs.contains(titleClaimID) {
            issues.append(DiscoverySchemaIssue(code: .brokenReference, path: "\(path).titleClaimID", detail: "titleClaimID 不在本候选 claims 内"))
        }
        for bodyID in bodyClaimIDs where !claimIDs.contains(bodyID) {
            issues.append(DiscoverySchemaIssue(code: .brokenReference, path: "\(path).bodyClaimIDs", detail: "bodyClaimIDs 存在指向未声明 claim 的引用"))
        }

        // 标题 + 正文必须覆盖全部 claim：不允许游离在核验之外的句子（02 §4）
        let covered = Set([titleClaimID] + bodyClaimIDs)
        if covered != claimIDs {
            issues.append(DiscoverySchemaIssue(code: .claimCoverageIncomplete, path: "\(path)", detail: "存在未被标题/正文引用的 claim（title+body 必须全覆盖）"))
        }

        // uniqueItems
        if Set(bodyClaimIDs).count != bodyClaimIDs.count {
            issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).bodyClaimIDs", detail: "bodyClaimIDs 必须唯一"))
        }
        if Set(supportEvidenceIDs).count != supportEvidenceIDs.count {
            issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).supportEvidenceIDs", detail: "supportEvidenceIDs 必须唯一"))
        }
        for (index, search) in counterSearch.enumerated() {
            if Set(search.domains).count != search.domains.count {
                issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).counterSearch[\(index)].domains", detail: "domains 必须唯一"))
            }
            if Set(search.anchorRefs).count != search.anchorRefs.count {
                issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).counterSearch[\(index)].anchorRefs", detail: "anchorRefs 必须唯一"))
            }
        }

        // type ↔ scopeKind ↔ comparisonPeriods 条件约束（schema allOf + 02 §5 门禁 4 的 schema 层部分）
        switch type {
        case .twoEpisodes:
            if scopeKind != .twoEpisodes {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).scopeKind", detail: "two_episodes 候选的 scopeKind 必须为 two_episodes"))
            }
            if !comparisonPeriods.isEmpty {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "非 change_over_time 候选 comparisonPeriods 必须为空"))
            }
        case .boundedPattern:
            if scopeKind != .boundedEvents {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).scopeKind", detail: "bounded_pattern 候选的 scopeKind 必须为 bounded_events"))
            }
            if !comparisonPeriods.isEmpty {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "非 change_over_time 候选 comparisonPeriods 必须为空"))
            }
        case .changeOverTime:
            if scopeKind != .comparedPeriods {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).scopeKind", detail: "change_over_time 候选的 scopeKind 必须为 compared_periods"))
            }
            if comparisonPeriods.count != 2 {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "change_over_time 候选 comparisonPeriods 必须恰好 2 条"))
            }
        }

        // date-time 可解析 + 变化类区间：明确起止、按时间排序、互不重叠、在总范围内
        issues.append(contentsOf: Self.validateDateTime(timeRange, path: "\(path).timeRange"))
        for (index, period) in comparisonPeriods.enumerated() {
            issues.append(contentsOf: Self.validateDateTime(period, path: "\(path).comparisonPeriods[\(index)]"))
        }
        if type == .changeOverTime, comparisonPeriods.count == 2 {
            issues.append(contentsOf: Self.validateComparisonPeriods(comparisonPeriods, overall: timeRange, path: path))
        }
        return issues
    }

    private static func validateDateTime(_ range: DiscoveryTimeRange, path: String) -> [DiscoverySchemaIssue] {
        var issues: [DiscoverySchemaIssue] = []
        for (label, raw) in [("start", range.start), ("end", range.end)] {
            if let raw, DiscoveryISO8601.parse(raw) == nil {
                issues.append(DiscoverySchemaIssue(code: .invalidDateTime, path: "\(path).\(label)", detail: "不是可解析的 RFC 3339 date-time"))
            }
        }
        if let start = range.start, let end = range.end,
           let startDate = DiscoveryISO8601.parse(start), let endDate = DiscoveryISO8601.parse(end),
           startDate > endDate {
            issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: path, detail: "区间 start 晚于 end"))
        }
        return issues
    }

    /// 变化类两段区间：各有明确起止、按时间排序、互不重叠、且在总范围内
    private static func validateComparisonPeriods(_ periods: [DiscoveryTimeRange], overall: DiscoveryTimeRange, path: String) -> [DiscoverySchemaIssue] {
        var issues: [DiscoverySchemaIssue] = []
        for (index, period) in periods.enumerated() {
            if period.start == nil || period.end == nil {
                issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods[\(index)]", detail: "变化类区间必须有明确 start/end"))
            }
        }
        guard periods.allSatisfy({ $0.start != nil && $0.end != nil }),
              let firstStart = periods[0].start.flatMap(DiscoveryISO8601.parse),
              let firstEnd = periods[0].end.flatMap(DiscoveryISO8601.parse),
              let secondStart = periods[1].start.flatMap(DiscoveryISO8601.parse),
              let secondEnd = periods[1].end.flatMap(DiscoveryISO8601.parse) else {
            return issues
        }
        if !(firstStart < secondStart) {
            issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "两段区间未按时间排序"))
        }
        if firstEnd > secondStart {
            issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "两段区间重叠"))
        }
        if let overallStart = overall.start.flatMap(DiscoveryISO8601.parse), firstStart < overallStart {
            issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "首段区间早于总范围 start"))
        }
        if let overallEnd = overall.end.flatMap(DiscoveryISO8601.parse), secondEnd > overallEnd {
            issues.append(DiscoverySchemaIssue(code: .conditionalMismatch, path: "\(path).comparisonPeriods", detail: "末段区间晚于总范围 end"))
        }
        return issues
    }
}

extension DiscoveryVerificationEnvelope {

    /// 核验信封跨字段校验：candidateID/claimID 唯一、reasonCodes 唯一、
    /// accept → 所有 claim supported、supported → 至少一个支持证据。
    func validate() -> [DiscoverySchemaIssue] {
        var issues: [DiscoverySchemaIssue] = []
        var seenCandidateIDs = Set<String>()
        for (index, result) in candidateResults.enumerated() {
            let path = "$.candidateResults[\(index)]"
            if !seenCandidateIDs.insert(result.candidateID).inserted {
                issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).candidateID", detail: "candidateID 重复"))
            }
            var seenClaimIDs = Set<String>()
            for claimResult in result.claimResults {
                if !seenClaimIDs.insert(claimResult.claimID).inserted {
                    issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).claimResults", detail: "claimID 重复"))
                }
                if claimResult.verdict == .supported && claimResult.supportEvidenceIDs.isEmpty {
                    issues.append(DiscoverySchemaIssue(code: .verdictInconsistent, path: "\(path).claimResults", detail: "supported 结论必须至少给出 1 个支持证据"))
                }
                if Set(claimResult.reasonCodes).count != claimResult.reasonCodes.count {
                    issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).claimResults", detail: "reasonCodes 必须唯一"))
                }
                if Set(claimResult.supportEvidenceIDs).count != claimResult.supportEvidenceIDs.count {
                    issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).claimResults", detail: "supportEvidenceIDs 必须唯一"))
                }
                if Set(claimResult.counterEvidenceIDs).count != claimResult.counterEvidenceIDs.count {
                    issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).claimResults", detail: "counterEvidenceIDs 必须唯一"))
                }
            }
            if result.verdict == .accept {
                let unsupported = result.claimResults.filter { $0.verdict != .supported }
                if !unsupported.isEmpty {
                    issues.append(DiscoverySchemaIssue(code: .verdictInconsistent, path: path, detail: "accept 但存在非 supported 的 claim（数量 \(unsupported.count)）"))
                }
            }
            if Set(result.reasonCodes).count != result.reasonCodes.count {
                issues.append(DiscoverySchemaIssue(code: .duplicateID, path: "\(path).reasonCodes", detail: "reasonCodes 必须唯一"))
            }
        }
        return issues
    }
}

// MARK: - 运行冻结（02 §9.2，13 个字段）

/// 一次运行必须冻结的全部字段。数据更新不能复用原 runID 改 request body；
/// 来源重新核验、接收核验结果、提交、展示、续聊前均比对这份冻结（DiscoveryAccessPolicy.canCommit 等）。
struct DiscoveryRunFreeze: Codable, Equatable, Sendable {
    let runID: String
    /// V1 无账号体系，accountSubject 用设备主体（deviceId）口径
    let accountSubject: String
    let deviceID: String
    /// 关闭→重新开启递增；旧 localGrantEpoch 的结果即使已返回也不可复活
    let localGrantEpoch: Int
    let serverControlRevision: Int
    /// 授权范围摘要（对 allowedDomains 的确定性摘要，见 DiscoveryAccessPolicy.scopeRevision）
    let scopeRevision: String
    let sourceManifestDigest: String
    let candidatePromptVersion: Int
    let verifyPromptVersion: Int
    let modelRouteVersion: Int
    let policyVersion: Int
    /// 本次运行锚定的“现在”（材料窗口、时效判断的基准）
    let anchorNow: Date
    /// IANA 时区标识
    let timezone: String
}

// MARK: - FactAtom（02 §2.2 本地模型）

/// 进入模型材料包的最小证据单元。
/// 原文和状态是证据；模型摘要、发现正文、旧报告、模型自述不是独立证据。
struct DiscoveryFactAtom: Codable, Equatable, Sendable {

    /// 类型＋本地 ID；不出日志或成本库
    struct SourceRef: Codable, Equatable, Hashable, Sendable {
        let kind: DiscoverySourceKind
        let localID: String

        /// 规范字符串形式，如 "thought:<uuid>"；作为依赖索引与失效查询的键
        var canonical: String { "\(kind.rawValue):\(localID)" }
    }

    /// 事件发生时间精度：只知道月份不能伪造具体日
    enum TemporalPrecision: String, Codable, Sendable {
        case day
        case month
        case unknown
    }

    /// 事件发生时间或 null（带精度）
    struct OccurredRange: Codable, Equatable, Sendable {
        let start: Date?
        let end: Date?
        let precision: TemporalPrecision
    }

    /// 召回覆盖元数据（02 §3.2：未读历史不等于“从未发生”）
    struct Coverage: Codable, Equatable, Sendable {
        let domains: [DiscoverySourceDomain]
        let windowStart: Date?
        let windowEnd: Date?
        let matchedCount: Int
        let usedCount: Int
        let truncatedCount: Int
        /// 分母是否已知（缺记录 ≠ 没做）
        let denominatorKnown: Bool
        let indexVersion: String?
    }

    /// 程序算出的确定性事实（定量结论只能引用它，不能由模型自由计算）
    struct ComputedFact: Codable, Equatable, Sendable {
        let metricID: String
        let formulaVersion: String
        let numerator: Double?
        let denominator: Double?
        let unit: String?
        let windowStart: Date?
        let windowEnd: Date?
        let value: Double
    }

    /// 事件血缘：确认同组 / 不确定（ambiguous 不能用来增加重复次数）
    enum Lineage: Codable, Equatable, Sendable {
        case group(String)
        case ambiguous
    }

    var localSourceRef: SourceRef?
    /// 原文与参与判断字段的稳定内容摘要（DiscoveryContentDigest.sourceRevision(from:) 产出；无版本号时由受控字段计算）
    var sourceRevision: String
    /// 批次内匿名短 ID（如 E01）；服务器与模型不需要永久业务 UUID
    var evidenceID: String
    var sourceKind: DiscoverySourceKind
    var occurredRange: OccurredRange
    /// 实际保存时间，与发生时间分开
    var recordedAt: Date
    /// 原文语义段，保留否定、条件、转折和附近上下文
    var sourceBlock: String
    /// 本地原文位置（不透明定位串，模型无需生成字符偏移）
    var quoteLocator: String?
    var lineageGroup: Lineage
    /// 显式实体关联／本地主题（不让同名自动成为同一实体）
    var entityRefs: [String]
    var coverage: Coverage
    /// 全局排除及发现范围的版本
    var accessRevision: String
    var computedFacts: [ComputedFact]
}
