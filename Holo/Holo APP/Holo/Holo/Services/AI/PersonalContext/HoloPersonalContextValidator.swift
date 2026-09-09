//
//  HoloPersonalContextValidator.swift
//  Holo
//
//  通用个人情境萃取结果的结构校验与语义核验适配（实施方案 §6 步骤 4-6）。
//
//  - 结构校验：JSON 可解析、长度、来源/修订存在、quote 逐字命中、循环依赖、
//    禁止动作字段（响应 schema 之外的字段在解码时被丢弃，天然防注入）。
//  - 语义核验：独立验证 prompt 的批量 verdict 适配；模型自报 declared 不是免审通行证。
//  - 纯逻辑，可 standalone 编译。
//

import Foundation

// MARK: - 萃取响应 DTO（模型输出形态，与载荷 V1 分离）

nonisolated struct HoloContextExtractionBasisDTO: Decodable, Equatable, Sendable {
    var sourceID: String
    var quote: String?
    var stance: String?
    var revision: String?

    private enum CodingKeys: String, CodingKey {
        case sourceID, quote, stance, revision
    }

    init(sourceID: String, quote: String? = nil, stance: String? = nil, revision: String? = nil) {
        self.sourceID = sourceID
        self.quote = quote
        self.stance = stance
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        stance = try c.decodeIfPresent(String.self, forKey: .stance)
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
    }
}

nonisolated struct HoloContextExtractionCandidateDTO: Decodable, Equatable, Sendable {
    var candidateRef: String
    var statement: String
    var relationText: String?
    var subjects: [HoloContextPartyRef]?
    var objects: [HoloContextPartyRef]?
    var facets: [HoloContextFacet]?
    var epistemicStatus: String?
    var applicability: HoloContextApplicabilityV1?
    var temporal: HoloContextTemporalV1?
    var basis: [HoloContextExtractionBasisDTO]
    var openQuestions: [String]?
    /// 模型给出的合并目标（输入候选的 candidateRef）；程序验证后才采纳。
    var mergeInto: String?

    private enum CodingKeys: String, CodingKey {
        case candidateRef, statement, relationText, subjects, objects, facets
        case epistemicStatus, applicability, temporal, basis, openQuestions, mergeInto
    }

    init(
        candidateRef: String,
        statement: String,
        relationText: String? = nil,
        subjects: [HoloContextPartyRef]? = nil,
        objects: [HoloContextPartyRef]? = nil,
        facets: [HoloContextFacet]? = nil,
        epistemicStatus: String? = nil,
        applicability: HoloContextApplicabilityV1? = nil,
        temporal: HoloContextTemporalV1? = nil,
        basis: [HoloContextExtractionBasisDTO],
        openQuestions: [String]? = nil,
        mergeInto: String? = nil
    ) {
        self.candidateRef = candidateRef
        self.statement = statement
        self.relationText = relationText
        self.subjects = subjects
        self.objects = objects
        self.facets = facets
        self.epistemicStatus = epistemicStatus
        self.applicability = applicability
        self.temporal = temporal
        self.basis = basis
        self.openQuestions = openQuestions
        self.mergeInto = mergeInto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidateRef = try c.decode(String.self, forKey: .candidateRef)
        statement = try c.decode(String.self, forKey: .statement)
        relationText = try c.decodeIfPresent(String.self, forKey: .relationText)
        subjects = try c.decodeIfPresent([HoloContextPartyRef].self, forKey: .subjects)
        objects = try c.decodeIfPresent([HoloContextPartyRef].self, forKey: .objects)
        facets = try c.decodeIfPresent([HoloContextFacet].self, forKey: .facets)
        epistemicStatus = try c.decodeIfPresent(String.self, forKey: .epistemicStatus)
        applicability = try c.decodeIfPresent(HoloContextApplicabilityV1.self, forKey: .applicability)
        temporal = try c.decodeIfPresent(HoloContextTemporalV1.self, forKey: .temporal)
        basis = (try? c.decode([HoloContextExtractionBasisDTO].self, forKey: .basis)) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions)
        mergeInto = try c.decodeIfPresent(String.self, forKey: .mergeInto)
    }
}

nonisolated struct HoloContextExtractionResponse: Decodable, Equatable, Sendable {
    var candidates: [HoloContextExtractionCandidateDTO]
    var counterEvidence: [HoloContextCounterEvidenceDTO]

    init(
        candidates: [HoloContextExtractionCandidateDTO] = [],
        counterEvidence: [HoloContextCounterEvidenceDTO] = []
    ) {
        self.candidates = candidates
        self.counterEvidence = counterEvidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 逐候选隔离解码：单个候选字段不合法只丢该条，不拖垮整批（§4 单条隔离纪律）。
        if let rawCandidates = try? c.decode([HoloContextJSONValue].self, forKey: .candidates) {
            var decoded: [HoloContextExtractionCandidateDTO] = []
            for raw in rawCandidates {
                if let data = try? JSONEncoder().encode(raw),
                   let candidate = try? JSONDecoder().decode(HoloContextExtractionCandidateDTO.self, from: data) {
                    decoded.append(candidate)
                }
            }
            candidates = decoded
        } else {
            candidates = []
        }
        if let rawCounter = try? c.decode([HoloContextJSONValue].self, forKey: .counterEvidence) {
            var decodedCounter: [HoloContextCounterEvidenceDTO] = []
            for raw in rawCounter {
                if let data = try? JSONEncoder().encode(raw),
                   let item = try? JSONDecoder().decode(HoloContextCounterEvidenceDTO.self, from: data) {
                    decodedCounter.append(item)
                }
            }
            counterEvidence = decodedCounter
        } else {
            counterEvidence = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case candidates, counterEvidence
    }
}

nonisolated struct HoloContextCounterEvidenceDTO: Decodable, Equatable, Sendable {
    var candidateRef: String
    var basis: [HoloContextExtractionBasisDTO]

    init(candidateRef: String, basis: [HoloContextExtractionBasisDTO]) {
        self.candidateRef = candidateRef
        self.basis = basis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidateRef = try c.decode(String.self, forKey: .candidateRef)
        basis = (try? c.decode([HoloContextExtractionBasisDTO].self, forKey: .basis)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case candidateRef, basis
    }
}

// MARK: - 解析器

nonisolated enum HoloPersonalContextResponseParser {
    enum ParseError: Error, Equatable {
        case notJSON
        case emptyContent
    }

    /// 从模型原始输出中提取并解析 JSON（容忍 ```json 围栏与前缀文字）。
    static func parseExtraction(_ raw: String) throws -> HoloContextExtractionResponse {
        let json = extractJSON(from: raw)
        guard let data = json.data(using: .utf8) else { throw ParseError.notJSON }
        do {
            return try JSONDecoder().decode(HoloContextExtractionResponse.self, from: data)
        } catch {
            throw ParseError.notJSON
        }
    }

    /// 剥离围栏/前后噪声，找到第一个平衡的 JSON 对象。
    static func extractJSON(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "```\\s*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 找第一个 { 到与之平衡的 }。
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return String(text[start...])
    }
}

// MARK: - 语义核验 verdict DTO

nonisolated struct HoloContextVerificationVerdict: Decodable, Equatable, Sendable {
    nonisolated enum Verdict: String, Decodable, Equatable, Sendable {
        case supported
        case qualified
        case unsupported
    }

    var candidateRef: String
    var verdict: Verdict
    var requiredQualifiers: [String]?
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case candidateRef, verdict, requiredQualifiers, reason
    }

    init(candidateRef: String, verdict: Verdict, requiredQualifiers: [String]? = nil, reason: String? = nil) {
        self.candidateRef = candidateRef
        self.verdict = verdict
        self.requiredQualifiers = requiredQualifiers
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidateRef = try c.decode(String.self, forKey: .candidateRef)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        requiredQualifiers = try c.decodeIfPresent([String].self, forKey: .requiredQualifiers)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

nonisolated enum HoloContextVerificationParser {
    /// 解析核验响应；缺 verdicts 视为空（全部按未审核处理，不默认通过）。
    static func parse(_ raw: String) throws -> [HoloContextVerificationVerdict] {
        struct Wrapper: Decodable {
            var verdicts: [HoloContextVerificationVerdict]?
        }
        let json = HoloPersonalContextResponseParser.extractJSON(from: raw)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).verdicts) ?? []
    }
}

// MARK: - 结构校验

nonisolated enum HoloPersonalContextValidator {
    struct Finding: Equatable, Sendable {
        nonisolated enum Code: String, Equatable, Sendable {
            case emptyStatement
            case statementTooLong
            case missingBasis
            case conflictingSource
            case unknownSource
            case revisionMismatch
            case quoteNotFound
            case selfMerge
            case invalidEpistemicStatus
            case invalidFacet
        }

        var code: Code
        var candidateRef: String
        var detail: String
    }

    /// 结构校验输入包内的候选。返回 (净化后的候选, 发现的问题)。
    /// quote 必须逐字存在于对应来源的规范化纯文本；来源/修订必须来自输入包。
    static func validate(
        response: HoloContextExtractionResponse,
        packageSources: [HoloContextSourceSnapshot]
    ) -> (valid: [HoloContextExtractionCandidateDTO], findings: [Finding]) {
        let sourceIndex = HoloContextSourceIndex(packageSources)
        let sourcesByID = sourceIndex.byID
        var valid: [HoloContextExtractionCandidateDTO] = []
        var findings: [Finding] = []

        for candidate in response.candidates {
            let ref = candidate.candidateRef
            let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if statement.isEmpty {
                findings.append(Finding(code: .emptyStatement, candidateRef: ref, detail: "命题为空"))
                continue
            }
            if statement.utf16.count > 200 {
                findings.append(Finding(code: .statementTooLong, candidateRef: ref, detail: "命题超长"))
                continue
            }
            if candidate.basis.isEmpty {
                findings.append(Finding(code: .missingBasis, candidateRef: ref, detail: "缺少证据"))
                continue
            }
            if let mergeInto = candidate.mergeInto, mergeInto == ref {
                findings.append(Finding(code: .selfMerge, candidateRef: ref, detail: "自引用合并"))
                continue
            }
            if let status = candidate.epistemicStatus,
               !["declared", "observed", "inferred"].contains(status) {
                findings.append(Finding(code: .invalidEpistemicStatus, candidateRef: ref, detail: status))
                continue
            }

            var basisValid = true
            for basis in candidate.basis {
                if sourceIndex.conflictingIDs.contains(basis.sourceID) {
                    findings.append(Finding(code: .conflictingSource, candidateRef: ref, detail: "来源存在冲突修订"))
                    basisValid = false
                    break
                }
                guard let source = sourcesByID[basis.sourceID] else {
                    findings.append(Finding(code: .unknownSource, candidateRef: ref, detail: "来源不在输入包: \(basis.sourceID)"))
                    basisValid = false
                    break
                }
                if let revision = basis.revision, !revision.isEmpty, revision != source.revisionDigest {
                    findings.append(Finding(code: .revisionMismatch, candidateRef: ref, detail: "修订不一致: \(basis.sourceID)"))
                    basisValid = false
                    break
                }
                if let quote = basis.quote, !quote.isEmpty {
                    if !source.plainText.contains(quote) {
                        findings.append(Finding(code: .quoteNotFound, candidateRef: ref, detail: "引用未逐字命中: \(String(quote.prefix(20)))…"))
                        basisValid = false
                        break
                    }
                }
            }
            guard basisValid else { continue }

            var sanitized = candidate
            sanitized.statement = statement
            valid.append(sanitized)
        }
        return (valid, findings)
    }

    /// 反证的结构校验：candidateRef 必须指向本次响应内的候选，quote 必须命中。
    static func validateCounterEvidence(
        _ counterEvidence: [HoloContextCounterEvidenceDTO],
        candidateRefs: Set<String>,
        packageSources: [HoloContextSourceSnapshot]
    ) -> [HoloContextCounterEvidenceDTO] {
        let sourcesByID = HoloContextSourceIndex(packageSources).byID
        return counterEvidence.filter { evidence in
            guard candidateRefs.contains(evidence.candidateRef) else { return false }
            return evidence.basis.contains { basis in
                guard let source = sourcesByID[basis.sourceID] else { return false }
                guard basis.revision == nil || basis.revision == "" || basis.revision == source.revisionDigest else { return false }
                guard let quote = basis.quote, !quote.isEmpty else { return true }
                return source.plainText.contains(quote)
            }
        }
    }
}
