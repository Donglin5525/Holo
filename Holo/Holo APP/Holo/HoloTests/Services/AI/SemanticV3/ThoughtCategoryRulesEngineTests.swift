//
//  ThoughtCategoryRulesEngineTests.swift
//  HoloTests
//
//  想法自动整理增强 W1（2026-11-16 方案 §4 A2）类别规则层引擎面测试：
//  schema 4 编解码、差量写入（保留/负向撤销/容量排序/影子记录）、
//  legacy/shadow/live 三模式隔离、统一评估版本键与去重、协议错误落回。
//  覆盖验收矩阵 R01-R10 的引擎面；契约测试（后端真实 fixture）另行单独补。
//  全程零真实网络（Schema4RelayURLProtocol 拦截并回显请求封套）。
//

import CoreData
import XCTest
@testable import Holo

final class ThoughtCategoryRulesEngineTests: XCTestCase {

    // MARK: - Mock URLProtocol（回显请求封套 + 脚本化 decisions）

    /// 拦截 semantic-relate：解析请求 JSON 交给脚本闭包生成响应；
    /// operationId/textRevision 原样回显（客户端封套校验需要）。
    private final class Schema4RelayURLProtocol: URLProtocol, @unchecked Sendable {
        static var handler: (([String: Any]) -> (status: Int, body: String))?
        static var lastRequestJSON: [String: Any]?

        static func reset(_ handler: (([String: Any]) -> (status: Int, body: String))? = nil) {
            Self.handler = handler
            Self.lastRequestJSON = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let bodyData: Data
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var streamed = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    streamed.append(buffer, count: read)
                }
                bodyData = streamed.isEmpty ? (request.httpBody ?? Data()) : streamed
            } else {
                bodyData = request.httpBody ?? Data()
            }
            let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
            Self.lastRequestJSON = json
            let (status, text) = Self.handler?(json) ?? (500, #"{"error":{"code":"UNSCRIPTED","message":"unscripted"}}"#)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeProvider() -> HoloBackendAIProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Schema4RelayURLProtocol.self]
        return HoloBackendAIProvider(baseURL: "https://mock.local",
                                     apiClient: APIClient(urlSession: URLSession(configuration: config)))
    }

    /// 用请求里的候选/目标文本构造一条 decision 字典。
    /// Optional 一律条件写入（JSONSerialization 不接受 Optional 值；缺键=解码为 nil）。
    private func decisionDict(ref: String, relation: String, targetText: String,
                              representativeRef: String? = nil, representativeQuote: String? = nil,
                              sharedSubject: String? = nil) -> [String: Any] {
        var item: [String: Any] = ["candidateRef": ref, "relation": relation]
        if relation == "same_thread" || relation == "fits_category" || relation == "excludes_category" {
            let quote = String(targetText.prefix(8))
            item["quote"] = quote
            item["rangeUTF16"] = [0, quote.utf16.count]
            if let representativeRef { item["representativeRef"] = representativeRef }
            if let representativeQuote { item["representativeQuote"] = representativeQuote }
            if relation == "same_thread" { item["sharedSubject"] = sharedSubject ?? "测试主题" }
        }
        return item
    }

    // MARK: - 环境与工具

    private var modeKey: String { "thought_semantic_v3_category_rules_mode" }
    private var pilotKey: String { "thought_semantic_v3_category_rules_pilot_samples" }

    private func configureCategoryRules(_ mode: ThoughtSemanticFeatureFlags.CategoryRulesMode, pilot: [UUID]) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        ThoughtSemanticFeatureFlags.setCategoryRulesPilotSamples(pilot.map {
            .init(thoughtID: $0, role: "test")
        })
        ThoughtSemanticFeatureFlags.resetSchema4ServerGateForTesting()
    }

    private func resetCategoryRules() {
        UserDefaults.standard.removeObject(forKey: modeKey)
        UserDefaults.standard.removeObject(forKey: pilotKey)
        ThoughtSemanticFeatureFlags.resetSchema4ServerGateForTesting()
    }

    override func setUp() {
        super.setUp()
        resetCategoryRules()
        Schema4RelayURLProtocol.reset()
    }

    override func tearDown() {
        resetCategoryRules()
        Schema4RelayURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() async throws -> (ThoughtSemanticStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-rules-test-\(UUID().uuidString)")
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        return (store, root)
    }

    @discardableResult
    private func insertTopic(_ ctx: NSManagedObjectContext, title: String, classification: Bool,
                             definition: String? = nil, deleted: Bool = false) throws -> Topic {
        let topic = ctx.insertTestObject(Topic.self)
        topic.id = UUID()
        topic.title = title
        topic.status = classification ? Topic.TopicStatus.classification.rawValue : Topic.TopicStatus.active.rawValue
        topic.titleSource = "user"
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        topic.topicRevision = 1
        topic.categoryDefinition = definition
        if deleted { topic.deletedAt = Date() }
        try ctx.save()
        return topic
    }

    @discardableResult
    private func insertThought(_ ctx: NSManagedObjectContext, content: String) throws -> Thought {
        let thought = ctx.insertTestObject(Thought.self)
        thought.id = UUID()
        thought.content = content
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        try ctx.save()
        return thought
    }

    @discardableResult
    private func insertLink(_ ctx: NSManagedObjectContext, thought: Thought, topic: Topic,
                            source: ThoughtTopicLink.LinkSource, state: ThoughtTopicLink.LinkState = .active) throws -> ThoughtTopicLink {
        let link = ctx.insertTestObject(ThoughtTopicLink.self)
        link.id = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
        link.thought = thought
        link.topic = topic
        link.sourceEnum = source
        link.stateEnum = state
        link.visibilityEnum = source == .userManual ? .userVisible : .internalOnly
        link.consentGeneration = 0
        link.createdAt = Date()
        link.updatedAt = Date()
        try ctx.save()
        return link
    }

    private func links(of thought: Thought, in ctx: NSManagedObjectContext) throws -> [ThoughtTopicLink] {
        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "thought == %@", thought)
        return try ctx.fetch(request)
    }

    // MARK: - 三模式策略函数（R10）

    /// 默认 legacy：未配置时任何想法都不进 schema 4。
    func testCoverageDefaultsToLegacy() {
        let thoughtID = UUID()
        XCTAssertNil(ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: thoughtID))
        XCTAssertEqual(ThoughtSemanticFeatureFlags.categoryRulesMode(), .legacy)
    }

    /// 模式 × 样本范围 × 服务端闸的同一策略函数裁决。
    func testCoverageRequiresModeAndPilotSampleAndServerGate() {
        let pilot = UUID()
        let other = UUID()
        configureCategoryRules(.shadow, pilot: [pilot])
        XCTAssertEqual(ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: pilot), .shadow)
        XCTAssertNil(ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: other), "非隔离样本一律 legacy")

        UserDefaults.standard.set("live", forKey: modeKey)
        XCTAssertEqual(ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: pilot), .live)

        // 服务端闸：拒判后停发新版请求，所有样本回落 legacy
        ThoughtSemanticFeatureFlags.markSchema4ServerRejected()
        XCTAssertFalse(ThoughtSemanticFeatureFlags.schema4ServerAvailable)
        XCTAssertNil(ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: pilot))
        ThoughtSemanticFeatureFlags.resetSchema4ServerGateForTesting()
    }

    // MARK: - 规则送审判据（R04：UTF-16 计数边界 240 / 历史超限不截断）

    func testRulePayloadLengthBoundaryInUTF16Units() {
        XCTAssertEqual(ThoughtTopicVerifier.schema4RulePayload(rawDefinition: nil), .noUserRule)
        XCTAssertEqual(ThoughtTopicVerifier.schema4RulePayload(rawDefinition: "   \n "), .noUserRule)

        // BMP 字符：240/241 边界
        let bmp240 = String(repeating: "收", count: 240)
        let bmp241 = String(repeating: "收", count: 241)
        XCTAssertEqual(ThoughtTopicVerifier.schema4RulePayload(rawDefinition: bmp240), .user(definition: bmp240))
        guard case .skip(let reason240) = ThoughtTopicVerifier.schema4RulePayload(rawDefinition: bmp241) else {
            return XCTFail("241 UTF-16 必须拒绝")
        }
        XCTAssertEqual(reason240, "category_definition_too_long")

        // 代理对：emoji 每个占 2 个 UTF-16 单位——120 个=240 通过，121 个=242 拒绝
        let emoji240 = String(repeating: "💡", count: 120)
        let emoji242 = String(repeating: "💡", count: 121)
        XCTAssertEqual(ThoughtTopicVerifier.schema4RulePayload(rawDefinition: emoji240), .user(definition: emoji240))
        if case .user = ThoughtTopicVerifier.schema4RulePayload(rawDefinition: emoji242) {
            XCTFail("242 UTF-16（121 个代理对）必须按 UTF-16 计数拒绝，不能按字符数放行")
        }

        // 外缘空白裁剪后再计数；历史超限保持原文不静默截断
        XCTAssertEqual(ThoughtTopicVerifier.schema4RulePayload(rawDefinition: "  \(bmp240)  \n"), .user(definition: bmp240))
    }

    // MARK: - schema 4 关系约束（R09：跨 kind / 证据缺失）

    func testSchema4RelationCrossKindConstraints() throws {
        // 合法组合
        try ThoughtTopicVerifier.validateSchema4RelationConstraints(relation: "fits_category", kind: "category", definitionSource: "user")
        try ThoughtTopicVerifier.validateSchema4RelationConstraints(relation: "excludes_category", kind: "category", definitionSource: "user")
        try ThoughtTopicVerifier.validateSchema4RelationConstraints(relation: "same_thread", kind: "thread", definitionSource: "none")
        try ThoughtTopicVerifier.validateSchema4RelationConstraints(relation: "none", kind: "category", definitionSource: "none")

        func expectViolation(_ relation: String, kind: String?, source: String?, reason: String,
                             file: StaticString = #filePath, line: UInt = #line) {
            do {
                try ThoughtTopicVerifier.validateSchema4RelationConstraints(relation: relation, kind: kind, definitionSource: source)
                XCTFail("应抛协议错误：\(relation)/\(kind ?? "nil")/\(source ?? "nil")", file: file, line: line)
            } catch ThoughtTopicVerifierError.responseContractViolation(let code) {
                XCTAssertEqual(code, reason, file: file, line: line)
            } catch {
                XCTFail("错误类型不符：\(error)", file: file, line: line)
            }
        }
        expectViolation("same_thread", kind: "category", source: "user", reason: "relation_cross_kind")
        expectViolation("fits_category", kind: "thread", source: "none", reason: "relation_cross_kind")
        expectViolation("excludes_category", kind: "thread", source: "none", reason: "relation_cross_kind")
        expectViolation("excludes_category", kind: "category", source: "none", reason: "excludes_category_requires_user_rule")
        expectViolation("confidence_hack", kind: "category", source: "user", reason: "relation_enum")
    }

    /// excludes_category 四件套证据：任一缺失/错位即协议错误（不降级、不产空回执）。
    func testSchema4ExclusionEvidenceCompleteness() throws {
        let chunk = "整理了今天的站会记录，纯纪要。"
        let rule = "收录全部会议纪要，纯会议纪要一律排除"
        // 完整证据通过
        try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
            quote: "整理了今天的站会记录", rangeUTF16: [0, 10], chunkText: chunk,
            representativeRef: "definition", representativeQuote: "纯会议纪要一律排除", ruleDefinition: rule)

        func expectEvidenceViolation(quote: String? = "整理了今天的站会记录", rangeUTF16: [Int]? = [0, 10],
                                     representativeRef: String? = "definition",
                                     representativeQuote: String? = "纯会议纪要一律排除",
                                     ruleDefinition: String? = rule,
                                     file: StaticString = #filePath, line: UInt = #line) {
            do {
                try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
                    quote: quote, rangeUTF16: rangeUTF16, chunkText: chunk,
                    representativeRef: representativeRef, representativeQuote: representativeQuote,
                    ruleDefinition: ruleDefinition)
                XCTFail("证据不全必须抛协议错误", file: file, line: line)
            } catch ThoughtTopicVerifierError.responseContractViolation(let code) {
                XCTAssertEqual(code, "excludes_category_evidence", file: file, line: line)
            } catch {
                XCTFail("错误类型不符：\(error)", file: file, line: line)
            }
        }
        expectEvidenceViolation(quote: nil)
        expectEvidenceViolation(rangeUTF16: nil)
        expectEvidenceViolation(quote: "原文里没有这句话", rangeUTF16: [0, 8])       // 目标侧不逐字
        expectEvidenceViolation(rangeUTF16: [0, 999])                               // 越界区间
        expectEvidenceViolation(representativeRef: "R0")                            // 排除证据必须引用规则
        expectEvidenceViolation(representativeRef: nil)
        expectEvidenceViolation(representativeQuote: nil)
        expectEvidenceViolation(representativeQuote: "")                            // 空 repQuote
        expectEvidenceViolation(representativeQuote: "规则里没有的短语")               // 规则侧不逐字
        expectEvidenceViolation(ruleDefinition: nil)                                // 无规则可回源
    }

    /// 服务端拒判识别：灰度关闭/请求契约拒绝/协议违约 → 停发新版；额度/网络类不算。
    func testSchema4ProtocolRejectionClassification() {
        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.backendError(statusCode: 503, code: "THOUGHT_SCOPE_RULES_DISABLED", message: "off", requestId: nil)))
        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.backendError(statusCode: 400, code: "INVALID_REQUEST", message: "bad", requestId: nil)))
        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.httpError(statusCode: 400, message: "bad")))
        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            ThoughtTopicVerifierError.responseContractViolation(reason: "envelope")))
        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(APIError.decodingError(NSError(domain: "test", code: 1))))
        XCTAssertFalse(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.backendError(statusCode: 429, code: "BUDGET_EXCEEDED", message: "quota", requestId: nil)))
        XCTAssertFalse(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.backendError(statusCode: 502, code: "MODEL_OUTPUT_INVALID", message: "model", requestId: nil)))
        XCTAssertFalse(ThoughtTopicVerifier.isSchema4ProtocolRejection(APIError.networkUnavailable))
    }

    // MARK: - 差量选型纯函数（R01/R05/R07）

    private func verdict(_ topicID: UUID, kind: String = "category", relation: String,
                         citesUserRule: Bool = false, recallScore: Float = 0,
                         consistentNone: Bool = false) -> ThoughtSchema4CandidateVerdict {
        ThoughtSchema4CandidateVerdict(topicID: topicID, kind: kind, relation: relation,
                                       citesUserRule: citesUserRule, verifierQuote: "q", verifierRangeUTF16: [0, 1],
                                       recallScore: recallScore, consistentNone: consistentNone)
    }

    /// 未召回/未送判/非明确负向的既有 AI 归属一律保留；只有明确负向才撤销。
    func testSelectionDifferentialRetentionAndNegativeRevocation() {
        let covered = UUID(), uncovered = UUID(), excluded = UUID()
        let threadAllNone = UUID(), threadMixed = UUID(), categoryNone = UUID()
        let verdicts = [
            verdict(excluded, relation: "excludes_category"),                     // 类别明确排除 → 撤销
            verdict(threadAllNone, kind: "thread", relation: "none", consistentNone: true),  // 脉络全段一致 none → 撤销
            verdict(threadMixed, kind: "thread", relation: "none", consistentNone: false),  // 脉络非一致 none → 保留
            verdict(categoryNone, relation: "none"),                              // 类别普通 none 只拒新增 → 保留
            verdict(covered, relation: "insufficient"),                           // 依据不足 → 保留
        ]
        let selection = ThoughtTopicVerifier.selectSchema4Outcome(
            verdicts: verdicts, existingAutoActiveTopicIDs: [covered, uncovered, excluded, threadAllNone, threadMixed, categoryNone])
        XCTAssertEqual(selection.revokedTopicIDs, [excluded, threadAllNone], "只有明确负向才撤销")
        XCTAssertEqual(selection.retainedTopicIDs, [covered, uncovered, threadMixed, categoryNone],
                       "未覆盖/非负向的既有自动归属全部保留")
        XCTAssertTrue(selection.affirmed.isEmpty)
        XCTAssertTrue(selection.capacityDeferredTopicIDs.isEmpty)
    }

    /// 容量排序：引用用户规则的类别匹配 > 双侧证据同脉络 > 代表例匹配；
    /// 同档按召回质量、稳定 ID 平局；既有归属先占额、历史超限不加新项。
    func testSelectionCapacityRankingAndShadowDeferral() {
        let ruleFit = UUID(), threadHit = UUID(), repFit = UUID(), tieA = UUID(), tieB = UUID()
        // 三档各一 + 同档两个（召回分不同）
        let verdicts = [
            verdict(repFit, relation: "fits_category", recallScore: 0.9),            // 档 2
            verdict(threadHit, kind: "thread", relation: "same_thread", recallScore: 0.6),  // 档 1
            verdict(ruleFit, relation: "fits_category", citesUserRule: true, recallScore: 0.1),  // 档 0
            verdict(tieA, kind: "thread", relation: "same_thread", recallScore: 0.8), // 档 1 高分
            verdict(tieB, kind: "thread", relation: "same_thread", recallScore: 0.7), // 档 1 低分
        ]
        // 场景一：已有 1 条保留 → 剩 2 个名额：ruleFit、tieA 入选；其余落容量影子
        let first = ThoughtTopicVerifier.selectSchema4Outcome(verdicts: verdicts, existingAutoActiveTopicIDs: [UUID()])
        XCTAssertEqual(first.affirmed.map(\.topicID), [ruleFit, tieA], "档位优先，同档召回分高者优先")
        XCTAssertEqual(first.capacityDeferredTopicIDs, [tieB, threadHit, repFit], "超出记录容量原因（影子记录，按落选时的排序）")

        // 场景二：历史超限（既有 3 条全保留）→ 只不加新项
        let full = ThoughtTopicVerifier.selectSchema4Outcome(verdicts: verdicts,
            existingAutoActiveTopicIDs: [UUID(), UUID(), UUID()])
        XCTAssertTrue(full.affirmed.isEmpty, "历史超限时本轮不加新项")
        XCTAssertEqual(full.capacityDeferredTopicIDs.count, 5, "全部正项记容量原因")

        // 场景三：既有归属本轮再获正向 → 只续期不占新名额
        let reaffirm = ThoughtTopicVerifier.selectSchema4Outcome(verdicts: [verdict(ruleFit, relation: "fits_category", citesUserRule: true)],
            existingAutoActiveTopicIDs: [ruleFit, UUID(), UUID()])
        XCTAssertEqual(reaffirm.affirmed.map(\.topicID), [ruleFit])
        XCTAssertTrue(reaffirm.affirmed[0].scoreFeaturesJSON.contains("reaffirmed"), "续期留痕")
        XCTAssertTrue(reaffirm.capacityDeferredTopicIDs.isEmpty)
    }

    /// 同档稳定 ID 平局：召回分相同 → topicID.uuidString 升序。
    func testSelectionStableIDTiebreak() {
        let high = UUID(), low = UUID()
        let (a, b) = (high.uuidString > low.uuidString ? (low, high) : (high, low))
        let verdicts = [
            verdict(high, kind: "thread", relation: "same_thread", recallScore: 0.5),
            verdict(low, kind: "thread", relation: "same_thread", recallScore: 0.5),
        ]
        let selection = ThoughtTopicVerifier.selectSchema4Outcome(verdicts: verdicts, existingAutoActiveTopicIDs: [])
        XCTAssertEqual(selection.affirmed.map(\.topicID), [a, b], "稳定 ID 平局，杜绝 UUID 任意裁决")
    }

    // MARK: - DTO 编码（R09：schema 1/2/3 编码零变化）

    func testCandidateDTOEncodingKeepsSchema3ShapeUnchanged() throws {
        let legacy = ThoughtSemanticRelateRequestDTO.Candidate(
            ref: "P0", title: "主题", summary: nil, kind: "category",
            definition: "旧定义", representatives: [.init(ref: "R0", text: "代表例")])
        let legacyJSON = try JSONEncoder().encode(legacy)
        let legacyString = String(data: legacyJSON, encoding: .utf8) ?? ""
        XCTAssertFalse(legacyJSON.isEmpty)
        XCTAssertTrue(legacyString.contains("\"definitionSource\"") == false,
                      "definitionSource 为 nil 时不得编码（schema 1/2/3 字节不变）")

        let v4 = ThoughtSemanticRelateRequestDTO.Candidate(
            ref: "P0", title: "主题", summary: nil, kind: "category",
            definition: "用户规则", definitionSource: "user",
            representatives: [.init(ref: "R0", text: "代表例")])
        let v4JSON = try JSONEncoder().encode(v4)
        let v4String = String(data: v4JSON, encoding: .utf8) ?? ""
        XCTAssertTrue(v4String.contains("\"definitionSource\":\"user\""), "schema 4 编码 definitionSource")

        // schema 1/2/3 响应解码路径不受影响（无新字段的旧响应可解码）
        let responseJSON = #"{"schemaVersion":3,"operationId":"op","textRevision":"h","decisions":[{"candidateRef":"P0","relation":"fits_category","quote":"代表","rangeUTF16":[0,2]}]}"#
        let response = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self, from: Data(responseJSON.utf8))
        XCTAssertEqual(response.schemaVersion, 3)
        XCTAssertEqual(response.decisions.first?.relation, "fits_category")
    }

    // MARK: - 统一评估版本键与去重（R06/R10：v4 回执不污染 v3）

    func testSchema4EvaluationVersionKeySpaces() {
        let key1 = ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: "catalog:live:brief=x:1", mode: "shadow", contentHash: "hash-a")
        XCTAssertEqual(key1, ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: "catalog:live:brief=x:1", mode: "shadow", contentHash: "hash-a"), "同输入同键")
        XCTAssertTrue(key1.hasPrefix("thought_semantic_v4:shadow:"), "schema 与模式进前缀")
        XCTAssertNotEqual(key1, ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: "catalog:live:brief=x:1", mode: "live", contentHash: "hash-a"), "shadow/live 空间分隔")
        XCTAssertNotEqual(key1, ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: "catalog:live:brief=x:1", mode: "shadow", contentHash: "hash-b"), "正文版本进键")
        XCTAssertNotEqual(key1, ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: "catalog2:live:brief=x:1", mode: "shadow", contentHash: "hash-a"), "目录/规则版本进键")
    }

    func testRelationRecordDedupSeparatesV4AndV3Spaces() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let thoughtID = UUID()
        let contentHash = "hash-1"
        let catalog = "thought_semantic_v3.2:abc:live"

        // 只有 v3 回执：v4 层激活时不算完成（需按 v4 口径重评）
        try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: thoughtID,
            contentHash: contentHash, scoreFeatures: "{}", verifierResult: "no_match",
            state: "evaluated", engineVersion: try await store.relationEvaluationVersion(catalogVersion: catalog),
            expiryDays: 14)
        configureCategoryRules(.shadow, pilot: [thoughtID])
        let v3OnlyHit = try await store.hasRelationRecord(thoughtID: thoughtID, contentHash: contentHash, evaluationVersion: catalog)
        XCTAssertFalse(v3OnlyHit, "v3 回执不满足 v4 判重——两个版本空间互不可见")

        // 写入 v4 回执（含空结果哨兵）后：同版本持久化空结果不重复入队
        let v4Key = ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: try await store.relationEvaluationVersion(catalogVersion: catalog),
            mode: "shadow", contentHash: contentHash)
        try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: thoughtID,
            contentHash: contentHash, scoreFeatures: "{}", verifierResult: "no_match",
            state: "shadow", engineVersion: v4Key, expiryDays: 14)
        let v4Hit = try await store.hasRelationRecord(thoughtID: thoughtID, contentHash: contentHash, evaluationVersion: catalog)
        XCTAssertTrue(v4Hit)

        // 服务端闸回落 legacy 后：判重回 v3 空间（v4 回执不污染 v3 语义）
        ThoughtSemanticFeatureFlags.markSchema4ServerRejected()
        let legacyHit = try await store.hasRelationRecord(thoughtID: thoughtID, contentHash: contentHash, evaluationVersion: catalog)
        XCTAssertFalse(legacyHit, "回落 legacy 后按 v3 口径判重")
        ThoughtSemanticFeatureFlags.resetSchema4ServerGateForTesting()
        await store.close()
    }

    // MARK: - 诊断记录（R04/R10：category_definition_too_long 等）

    func testCategoryRulesDiagnosticRoundTrip() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let thoughtID = UUID(), topicID = UUID()
        try await store.recordCategoryRulesDiagnostic(thoughtID: thoughtID, topicID: topicID,
            contentHash: "h", reason: "category_definition_too_long", mode: "shadow")
        // 同键幂等覆盖，不堆行
        try await store.recordCategoryRulesDiagnostic(thoughtID: thoughtID, topicID: topicID,
            contentHash: "h2", reason: "category_definition_too_long", mode: "live")
        try await store.recordCategoryRulesDiagnostic(thoughtID: thoughtID, topicID: thoughtID,
            contentHash: "h2", reason: "schema4_server_rejected", mode: "shadow")
        let diagnostics = try await store.categoryRulesDiagnostics(thoughtID: thoughtID)
        XCTAssertEqual(diagnostics.map { $0.reason }, ["schema4_server_rejected", "category_definition_too_long"])
        XCTAssertEqual(diagnostics.first(where: { $0.reason == "category_definition_too_long" })?.mode, "live", "幂等覆盖取最新")
        await store.close()
    }

    // MARK: - 端到端 · shadow 模式（R02/R03/R10：只留诊断与回执，不写正式关系）

    func testShadowModeEvaluatesSchema4WithoutFormalWrites() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        let rule = "收录全部会议纪要，纯会议纪要一律排除"
        let ruleTopic = try insertTopic(ctx, title: "会议纪要", classification: true, definition: rule)
        let noneTopic = try insertTopic(ctx, title: "碎碎念", classification: true)
        let member = try insertThought(ctx, content: "评审会全程记录在案。")
        try insertLink(ctx, thought: member, topic: ruleTopic, source: .userManual)
        let target = try insertThought(ctx, content: "整理了今天的站会记录，纯纪要。")
        let contentHash = ThoughtSemanticText.contentHash(target.content)

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // R03：给无规则类别存一份 AI brief——schema 4 不得把它升格为规则
        try await store.saveCategoryBrief(.init(topicID: noneTopic.id, version: 1,
            definition: "AI 起草的生活片段定义", exclusions: ["纯转载"],
            basisMemberCount: 5, basisRemovalCount: 1, updatedAt: Date()))

        configureCategoryRules(.shadow, pilot: [target.id])
        Schema4RelayURLProtocol.reset { [unowned self] request in
            let targetText = ((request["target"] as? [String: Any])?["text"] as? String) ?? ""
            let candidates = request["candidates"] as? [[String: Any]] ?? []
            let decisions = candidates.map { candidate -> [String: Any] in
                if (candidate["definitionSource"] as? String) == "user" {
                    return self.decisionDict(ref: candidate["ref"] as! String, relation: "excludes_category",
                                             targetText: targetText, representativeRef: "definition",
                                             representativeQuote: "纯会议纪要一律排除")
                }
                return self.decisionDict(ref: candidate["ref"] as! String, relation: "none", targetText: targetText)
            }
            let body: [String: Any] = ["schemaVersion": 4, "operationId": request["operationId"] ?? "",
                                       "textRevision": request["textRevision"] ?? "", "decisions": decisions]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (200, String(data: data, encoding: .utf8) ?? "{}")
        }
        HoloAIDataProcessingConsent.shared.grant()
        defer { HoloAIDataProcessingConsent.shared.revoke() }

        let result = try await ThoughtTopicVerifier.shadowEvaluate(
            thoughtID: target.id, redactedText: ThoughtIndexV2Policy.redactedText(forUpload: target.content),
            contentHash: contentHash,
            targetVector: SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) }),
            store: store, index: nil, context: ctx, provider: makeProvider(),
            calibration: .seed, consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration)

        // shadow 不写任何正式关系
        XCTAssertTrue(result?.isEmpty ?? true)
        XCTAssertTrue(try links(of: target, in: ctx).isEmpty, "shadow 模式不得写正式关系")

        // 请求形状：schema 4、definitionSource、类别不带 AI 摘要、brief 不升格、类别只带用户纳入例
        let requestJSON = try XCTUnwrap(Schema4RelayURLProtocol.lastRequestJSON)
        XCTAssertEqual(requestJSON["schemaVersion"] as? Int, 4)
        let candidates = try XCTUnwrap(requestJSON["candidates"] as? [[String: Any]])
        let ruleCandidate = try XCTUnwrap(candidates.first { ($0["title"] as? String) == "会议纪要" })
        XCTAssertEqual(ruleCandidate["definitionSource"] as? String, "user")
        XCTAssertEqual(ruleCandidate["definition"] as? String, rule)
        XCTAssertNil(ruleCandidate["summary"], "类别不传 AI 主题摘要作为默认证据")
        let ruleReps = try XCTUnwrap(ruleCandidate["representatives"] as? [[String: Any]])
        XCTAssertEqual(ruleReps.compactMap { $0["ref"] as? String }, [member.id.uuidString], "类别代表例=合规用户纳入例")

        let noneCandidate = try XCTUnwrap(candidates.first { ($0["title"] as? String) == "碎碎念" })
        XCTAssertEqual(noneCandidate["definitionSource"] as? String, "none")
        XCTAssertNil(noneCandidate["definition"], "存量 AI brief 不升格为规则")

        // 回执：v4 版本空间的负向影子行 + 哨兵（同版本空/负结果不重复入队）
        let negativeRow = try await store.relationCandidateState(thoughtID: target.id, topicID: ruleTopic.id)
        XCTAssertEqual(negativeRow?.state, "shadow_negative")
        XCTAssertEqual(negativeRow?.verifierResult, "excludes_category")
        XCTAssertTrue(negativeRow?.engineVersion?.hasPrefix("thought_semantic_v4:shadow:") ?? false)
        let catalogVersion = await ThoughtTopicVerifier.evaluationVersion(context: ctx)
        let shadowHit = try await store.hasRelationRecord(thoughtID: target.id, contentHash: contentHash,
                                                          evaluationVersion: catalogVersion)
        XCTAssertTrue(shadowHit)
        await store.close()
    }

    // MARK: - 端到端 · live 模式差量落库（R01/R05/R07）

    func testLiveModeDifferentialCommit() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        // 目录：已删主题（未召回）+ 规则主题（既有归属，判排除）+ 三条正项候选 + 手动归属主题
        let ruleText = "收录全部会议纪要，纯会议纪要一律排除"
        let ruleTopic = try insertTopic(ctx, title: "会议纪要", classification: true, definition: ruleText)
        let deletedTopic = try insertTopic(ctx, title: "旧类别", classification: true, deleted: true)
        let fitRuleTopic = try insertTopic(ctx, title: "产品判断", classification: true, definition: "收录我对产品的判断")
        let fitRepTopic = try insertTopic(ctx, title: "代表例类别", classification: true)
        let manualTopic = try insertTopic(ctx, title: "手动类别", classification: true)
        let threadTopic = try insertTopic(ctx, title: "跑步训练", classification: false)

        let target = try insertThought(ctx, content: "整理了今天的站会记录，纯纪要。")
        let ruleMember = try insertThought(ctx, content: "评审会全程记录在案。")
        let fitRepMember = try insertThought(ctx, content: "这个工具顺手但判断力要练。")
        let threadMember = try insertThought(ctx, content: "今天跑了五公里。")
        try insertLink(ctx, thought: ruleMember, topic: ruleTopic, source: .userManual)
        try insertLink(ctx, thought: fitRepMember, topic: fitRepTopic, source: .userManual)
        try insertLink(ctx, thought: threadMember, topic: threadTopic, source: .legacyUnknown)
        // 既有归属：规则主题（本轮判排除→撤销）、已删主题（未召回→保留）、手动主题（不占额不动）
        try insertLink(ctx, thought: target, topic: ruleTopic, source: .aiV3)
        try insertLink(ctx, thought: target, topic: deletedTopic, source: .aiV3)
        try insertLink(ctx, thought: target, topic: manualTopic, source: .userManual)
        let contentHash = ThoughtSemanticText.contentHash(target.content)

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        configureCategoryRules(.live, pilot: [target.id])
        Schema4RelayURLProtocol.reset { [unowned self] request in
            let targetText = ((request["target"] as? [String: Any])?["text"] as? String) ?? ""
            var decisions: [[String: Any]] = []
            for candidate in (request["candidates"] as? [[String: Any]] ?? []) {
                let ref = candidate["ref"] as! String
                let title = candidate["title"] as! String
                let reps = candidate["representatives"] as? [[String: Any]] ?? []
                switch title {
                case "会议纪要":
                    decisions.append(self.decisionDict(ref: ref, relation: "excludes_category", targetText: targetText,
                        representativeRef: "definition", representativeQuote: "纯会议纪要一律排除"))
                case "产品判断":
                    decisions.append(self.decisionDict(ref: ref, relation: "fits_category", targetText: targetText,
                        representativeRef: "definition", representativeQuote: "产品的判断"))
                case "跑步训练":
                    decisions.append(self.decisionDict(ref: ref, relation: "same_thread", targetText: targetText,
                        representativeRef: (reps.first?["ref"] as? String) ?? "R0",
                        representativeQuote: String((reps.first?["text"] as? String ?? "跑步").prefix(4))))
                case "代表例类别":
                    decisions.append(self.decisionDict(ref: ref, relation: "fits_category", targetText: targetText,
                        representativeRef: (reps.first?["ref"] as? String) ?? "R0",
                        representativeQuote: String((reps.first?["text"] as? String ?? "工具").prefix(4))))
                default:
                    decisions.append(self.decisionDict(ref: ref, relation: "none", targetText: targetText))
                }
            }
            let body: [String: Any] = ["schemaVersion": 4, "operationId": request["operationId"] ?? "",
                                       "textRevision": request["textRevision"] ?? "", "decisions": decisions]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (200, String(data: data, encoding: .utf8) ?? "{}")
        }

        HoloAIDataProcessingConsent.shared.grant()
        defer { HoloAIDataProcessingConsent.shared.revoke() }

        let affirmed = try await ThoughtTopicVerifier.evaluateAndCommit(
            thoughtID: target.id, redactedText: ThoughtIndexV2Policy.redactedText(forUpload: target.content),
            contentHash: contentHash,
            targetVector: SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) }),
            store: store, index: nil, context: ctx, provider: makeProvider(),
            calibration: .seed, consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration)

        ctx.refreshAllObjects()
        let linkStates = try Dictionary(uniqueKeysWithValues: links(of: target, in: ctx).map { link in
            (link.topic?.id ?? UUID(), (link.sourceEnum, link.stateEnum, link.engineVersion ?? ""))
        })
        // 撤销：只有明确负向（规则排除）的既有 AI 归属被撤销
        XCTAssertEqual(linkStates[ruleTopic.id]?.1, .superseded, "excludes_category 撤销既有 AI 归属")
        // 保留：未召回主题（已删）的既有 AI 归属不动；手动关系不动
        XCTAssertEqual(linkStates[deletedTopic.id]?.1, .active, "未召回主题的既有 AI 归属保留")
        XCTAssertEqual(linkStates[manualTopic.id]?.0, .userManual)
        XCTAssertEqual(linkStates[manualTopic.id]?.1, .active, "类别 none 不撤销手动关系")
        // 容量：既有保留 1 条（已删主题）→ 剩 2 个名额给规则匹配 + 同脉络；代表例匹配落影子
        XCTAssertEqual(Set(affirmed?.map(\.topicID) ?? []), [fitRuleTopic.id, threadTopic.id],
                       "排序：引用用户规则的类别匹配 > 双侧证据同脉络 > 代表例匹配")
        XCTAssertEqual(linkStates[fitRuleTopic.id]?.1, .active)
        XCTAssertEqual(linkStates[fitRuleTopic.id]?.2, "thought_semantic_v4")
        XCTAssertEqual(linkStates[threadTopic.id]?.1, .active)
        XCTAssertNil(linkStates[fitRepTopic.id], "容量未入的正项不写正式关系（影子记录）")

        // 影子记录：容量原因 + 负向撤销留痕 + v4 哨兵防重复入队
        let deferredRow = try await store.relationCandidateState(thoughtID: target.id, topicID: fitRepTopic.id)
        XCTAssertEqual(deferredRow?.state, "capacity_deferred")
        XCTAssertTrue(deferredRow?.scoreFeatures?.contains("auto_attribution_limit") ?? false, "超出记录容量原因")
        let revokedRow = try await store.relationCandidateState(thoughtID: target.id, topicID: ruleTopic.id)
        XCTAssertEqual(revokedRow?.state, "negative_revoked")
        let catalogVersion = await ThoughtTopicVerifier.evaluationVersion(context: ctx)
        let liveHit = try await store.hasRelationRecord(thoughtID: target.id, contentHash: contentHash,
                                                        evaluationVersion: catalogVersion)
        XCTAssertTrue(liveHit)
        await store.close()
    }

    // MARK: - 端到端 · 服务端拒 → 停发新版请求（R10：落回 legacy，不重试风暴）

    func testSchema4ServerRejectionLatchesToLegacy() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        let topic = try insertTopic(ctx, title: "会议纪要", classification: true)
        let target = try insertThought(ctx, content: "整理了今天的站会记录，纯纪要。")
        let contentHash = ThoughtSemanticText.contentHash(target.content)

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        configureCategoryRules(.shadow, pilot: [target.id])
        Schema4RelayURLProtocol.reset { _ in
            (400, #"{"error":{"code":"INVALID_REQUEST","message":"schemaVersion must be 1, 2, 3 or 4"}}"#)
        }
        HoloAIDataProcessingConsent.shared.grant()
        defer { HoloAIDataProcessingConsent.shared.revoke() }

        do {
            _ = try await ThoughtTopicVerifier.shadowEvaluate(
                thoughtID: target.id, redactedText: ThoughtIndexV2Policy.redactedText(forUpload: target.content),
                contentHash: contentHash,
                targetVector: SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) }),
                store: store, index: nil, context: ctx, provider: makeProvider(),
                calibration: .seed, consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration)
            XCTFail("服务端拒应原错误上抛")
        } catch {
            // 既有归属保留、不生成空结果回执：错误按既有封套映射上抛
        }

        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(APIError.httpError(statusCode: 400, message: "bad")))
        XCTAssertFalse(ThoughtSemanticFeatureFlags.schema4ServerAvailable, "拒判后停发新版请求")
        XCTAssertNil(ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: target.id), "后续样本回落 legacy")
        let diagnostics = try await store.categoryRulesDiagnostics(thoughtID: target.id)
        XCTAssertTrue(diagnostics.contains { $0.reason == "schema4_server_rejected" }, "拒判留诊断")
        // 不生成空结果回执：v4 判重无记录（闸已回落 → 按 v3 口径也无记录）
        let catalogVersion = await ThoughtTopicVerifier.evaluationVersion(context: ctx)
        let rejectedBatchHit = try await store.hasRelationRecord(thoughtID: target.id, contentHash: contentHash,
                                                                 evaluationVersion: catalogVersion)
        XCTAssertFalse(rejectedBatchHit)
        _ = topic
        await store.close()
    }

    // MARK: - 端到端 · 晚到回执不覆盖当前判断（R06：请求在途时模式被改 → 重排当前批）

    func testInFlightPolicyChangeCancelsCommit() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        let topic = try insertTopic(ctx, title: "会议纪要", classification: true, definition: "收录全部会议纪要")
        let target = try insertThought(ctx, content: "整理了今天的站会记录。")
        let contentHash = ThoughtSemanticText.contentHash(target.content)

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        configureCategoryRules(.live, pilot: [target.id])
        Schema4RelayURLProtocol.reset { [unowned self] request in
            // 响应返回前用户/侧通道把模式改回 legacy（UserDefaults 线程安全，可在协议线程写）
            UserDefaults.standard.set("legacy", forKey: "thought_semantic_v3_category_rules_mode")
            let targetText = ((request["target"] as? [String: Any])?["text"] as? String) ?? ""
            let decisions = (request["candidates"] as? [[String: Any]] ?? []).map {
                self.decisionDict(ref: $0["ref"] as! String, relation: "fits_category", targetText: targetText,
                                  representativeRef: "definition", representativeQuote: "收录全部会议纪要")
            }
            let body: [String: Any] = ["schemaVersion": 4, "operationId": request["operationId"] ?? "",
                                       "textRevision": request["textRevision"] ?? "", "decisions": decisions]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (200, String(data: data, encoding: .utf8) ?? "{}")
        }
        HoloAIDataProcessingConsent.shared.grant()
        defer { HoloAIDataProcessingConsent.shared.revoke() }

        do {
            _ = try await ThoughtTopicVerifier.evaluateAndCommit(
                thoughtID: target.id, redactedText: ThoughtIndexV2Policy.redactedText(forUpload: target.content),
                contentHash: contentHash,
                targetVector: SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) }),
                store: store, index: nil, context: ctx, provider: makeProvider(),
                calibration: .seed, consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration)
            XCTFail("策略在途变化应取消提交")
        } catch is CancellationError {
            // 过期重排当前批：晚到回执不落库
        }
        ctx.refreshAllObjects()
        XCTAssertTrue(try links(of: target, in: ctx).isEmpty, "取消后无任何正式关系写入")
        let legacyCatalog = await ThoughtTopicVerifier.evaluationVersion(context: ctx)
        let staleReceiptHit = try await store.hasRelationRecord(thoughtID: target.id, contentHash: contentHash,
                                                                evaluationVersion: legacyCatalog)
        XCTAssertFalse(staleReceiptHit, "不生成空结果回执，交队列按新模式重排")
        _ = topic
        await store.close()
    }

    // MARK: - 端到端 · 规则超限跳过评判（R04：留诊断、保留既有归属）

    func testOverlongDefinitionSkipsJudgmentWithDiagnostic() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        let longRule = String(repeating: "收", count: 241)
        let topic = try insertTopic(ctx, title: "会议纪要", classification: true, definition: longRule)
        let target = try insertThought(ctx, content: "整理了今天的站会记录。")
        try insertLink(ctx, thought: target, topic: topic, source: .aiV3)
        let contentHash = ThoughtSemanticText.contentHash(target.content)

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        configureCategoryRules(.live, pilot: [target.id])
        // 唯一候选被跳过 → 无请求发出；脚本未配置时任何请求都会命中 UNSCRIPTED 500
        Schema4RelayURLProtocol.reset { _ in (500, #"{"error":{"code":"UNSCRIPTED","message":"no"}}"#) }
        HoloAIDataProcessingConsent.shared.grant()
        defer { HoloAIDataProcessingConsent.shared.revoke() }

        _ = try await ThoughtTopicVerifier.evaluateAndCommit(
            thoughtID: target.id, redactedText: ThoughtIndexV2Policy.redactedText(forUpload: target.content),
            contentHash: contentHash,
            targetVector: SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) }),
            store: store, index: nil, context: ctx, provider: makeProvider(),
            calibration: .seed, consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration)

        XCTAssertNil(Schema4RelayURLProtocol.lastRequestJSON, "超限类别跳过评判，不发请求")
        let diagnostics = try await store.categoryRulesDiagnostics(thoughtID: target.id)
        XCTAssertTrue(diagnostics.contains { $0.topicID == topic.id && $0.reason == "category_definition_too_long" },
                      "历史超限留诊断，不静默截断")
        ctx.refreshAllObjects()
        let existing = try links(of: target, in: ctx)
        XCTAssertEqual(existing.first?.stateEnum, .active, "超限类别保留既有 AI 归属及用户决定")
        await store.close()
    }
}
