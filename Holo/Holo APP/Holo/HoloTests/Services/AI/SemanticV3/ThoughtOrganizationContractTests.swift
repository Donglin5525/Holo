//
//  ThoughtOrganizationContractTests.swift
//  HoloTests
//
//  想法自动整理增强 · semantic-relate 跨端契约测试（2026-11-16 方案 §4 A2 + §9 R09/R29）：
//  fixture 全部取自后端真实路由产物（docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures/
//  relate-*.json，由 fixtures/tools/generate-relate-schema4-fixtures.mjs 经 HoloBackend 真实
//  app 路由 + 校验器捕获），Swift 端用 JSONDecoder 解码真实响应体并重放客户端校验——
//  锁定 schema 4 解码形状、excludes_category 四件证据、跨 kind 反证、schema 1/2/3 回归、
//  错误封套映射与 definition 240/241 UTF-16 边界。响应形状真源在后端：后端改形状必须先
//  再生 fixture（跑生成脚本），本测试随新 fixture 更新——禁止在测试里手抄响应体。
//

import XCTest
@testable import Holo

final class ThoughtOrganizationContractTests: XCTestCase {

    // MARK: - fixture 加载（真实后端产物）

    private struct RelateFixture {
        let request: ThoughtSemanticRelateRequestDTO
        let status: Int
        /// 响应体原文（再序列化），喂 JSONDecoder 与 stub URLProtocol
        let responseJSON: Data
        /// 响应体对象视图：错误封套取码 + R29 注入变异共用
        let responseEnvelope: [String: Any]
        /// 错误场景记录的被后端拒绝的模型原始输出（供 Swift 重放同一份 decisions）
        let modelOutputDecisions: [[String: Any]]
    }

    /// #filePath 向上搜索仓库内 fixture 目录（从 HoloTests 源文件逐级上溯，
    /// 找到含 docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures 的祖先目录；
    /// 不写死层数，工程目录再挪一层也不破）。
    private static let fixturesDirectory: URL = {
        let marker = URL(fileURLWithPath: "docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures",
                         isDirectory: true)
        var dir = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker.path).path) {
                return dir.appendingPathComponent(marker.path)
            }
            dir.deleteLastPathComponent()
        }
        fatalError("找不到契约 fixture 目录：\(marker.path)")
    }()

    private func loadFixture(_ name: String) throws -> RelateFixture {
        let raw = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent(name))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], "fixture 结构损坏：\(name)")
        let requestObject = try XCTUnwrap(root["request"] as? [String: Any])
        let request = try JSONDecoder().decode(ThoughtSemanticRelateRequestDTO.self,
                                               from: JSONSerialization.data(withJSONObject: requestObject))
        let responseEnvelope = try XCTUnwrap(root["response"] as? [String: Any])
        let modelOutputDecisions = (root["modelOutput"] as? [String: Any])?["decisions"] as? [[String: Any]] ?? []
        return .init(request: request,
                     status: try XCTUnwrap(root["status"] as? Int),
                     responseJSON: try JSONSerialization.data(withJSONObject: responseEnvelope),
                     responseEnvelope: responseEnvelope,
                     modelOutputDecisions: modelOutputDecisions)
    }

    private func errorCode(_ envelope: [String: Any]) -> String? {
        (envelope["error"] as? [String: Any])?["code"] as? String
    }

    private func decision(_ response: ThoughtSemanticRelateResponseDTO, _ ref: String) throws
        -> ThoughtSemanticRelateResponseDTO.Decision {
        try XCTUnwrap(response.decisions.first { $0.candidateRef == ref }, "缺 decision：\(ref)")
    }

    private func candidate(_ request: ThoughtSemanticRelateRequestDTO, _ ref: String) throws
        -> ThoughtSemanticRelateRequestDTO.Candidate {
        try XCTUnwrap(request.candidates.first { $0.ref == ref }, "缺 candidate：\(ref)")
    }

    /// 断言闭包抛出协议违约（ThoughtTopicVerifierError.responseContractViolation）且 reason 相符。
    private func expectContractViolation(_ reason: String,
                                         file: StaticString = #filePath, line: UInt = #line,
                                         _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("应抛协议错误：\(reason)", file: file, line: line)
        } catch ThoughtTopicVerifierError.responseContractViolation(let code) {
            XCTAssertEqual(code, reason, file: file, line: line)
        } catch {
            XCTFail("错误类型不符：\(error)", file: file, line: line)
        }
    }

    // MARK: - 真实 APIClient 错误映射通道（stub 只回放 fixture 响应）

    private final class FixtureServingURLProtocol: URLProtocol, @unchecked Sendable {
        static var status: Int = 200
        static var body: Data = Data()

        static func serve(_ status: Int, _ body: Data) {
            Self.status = status
            Self.body = body
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeProvider() -> HoloBackendAIProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureServingURLProtocol.self]
        return HoloBackendAIProvider(baseURL: "https://contract-fixture.local",
                                     apiClient: APIClient(urlSession: URLSession(configuration: config)))
    }

    /// 用 fixture 的 status/response 走一次真实 semanticRelate（真 provider → 真 APIClient
    /// 错误映射），返回上抛错误。授权状态用后恢复，不污染其他测试。
    private func postRelateThroughClient(_ fixture: RelateFixture) async throws -> Error {
        FixtureServingURLProtocol.serve(fixture.status, fixture.responseJSON)
        let consent = HoloAIDataProcessingConsent.shared
        let wasGranted = consent.isGranted
        consent.grant()
        defer { if wasGranted { consent.grant() } else { consent.revoke() } }
        do {
            _ = try await makeProvider().semanticRelate(fixture.request)
        } catch {
            return error
        }
        struct UnexpectedSuccess: Error {}
        throw UnexpectedSuccess()
    }

    override func setUp() {
        super.setUp()
        FixtureServingURLProtocol.serve(200, Data())
    }

    // MARK: - 1. schema 4 成功响应：解码 + 字段逐项 + 证据重放

    func testSchema4SuccessFixtureDecodesAndEvidenceValidates() throws {
        let fixture = try loadFixture("relate-schema4-success.json")
        let request = fixture.request
        let response = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self, from: fixture.responseJSON)

        // 封套回显（客户端 envelope 守卫校验的三要素）
        XCTAssertEqual(response.schemaVersion, 4)
        XCTAssertEqual(response.operationId, request.operationId)
        XCTAssertEqual(response.textRevision, request.textRevision)
        XCTAssertEqual(response.decisions.count, request.candidates.count)

        // 请求侧 schema 4 字段解码：kind/definitionSource 必在、thread 无规则
        let ruleCandidate = try candidate(request, "P0")
        let fitCandidate = try candidate(request, "P1")
        let threadCandidate = try candidate(request, "P2")
        XCTAssertEqual(ruleCandidate.kind, "category")
        XCTAssertEqual(ruleCandidate.definitionSource, "user")
        XCTAssertEqual(threadCandidate.kind, "thread")
        XCTAssertEqual(threadCandidate.definitionSource, "none")
        XCTAssertNil(threadCandidate.definition)

        // P0 excludes_category：四件证据齐备（目标 quote + rangeUTF16 + representativeRef=definition + 规则逐字引用）
        let excluded = try decision(response, "P0")
        XCTAssertEqual(excluded.relation, "excludes_category")
        XCTAssertEqual(excluded.quote, "整理了今天的站会记录")
        XCTAssertEqual(excluded.rangeUTF16, [0, 10])
        XCTAssertEqual(excluded.representativeRef, "definition")
        XCTAssertEqual(excluded.representativeQuote, "纯会议纪要一律排除")

        // P1 fits_category：definition 依据 + 目标侧逐字
        let fitted = try decision(response, "P1")
        XCTAssertEqual(fitted.relation, "fits_category")
        XCTAssertEqual(fitted.quote, "整理了今天的站会记录")
        XCTAssertEqual(fitted.rangeUTF16, [0, 10])
        XCTAssertEqual(fitted.representativeRef, "definition")
        XCTAssertEqual(fitted.representativeQuote, "收录全部会议纪要")

        // P2 thread none：无证据字段
        let none = try decision(response, "P2")
        XCTAssertEqual(none.relation, "none")
        XCTAssertNil(none.quote)
        XCTAssertNil(none.rangeUTF16)
        XCTAssertNil(none.representativeRef)

        // 客户端校验重放（与后端 §4 A2 同口径）：三条决策的通道交叉约束全部通过
        XCTAssertNoThrow(try ThoughtTopicVerifier.validateSchema4RelationConstraints(
            relation: excluded.relation, kind: ruleCandidate.kind, definitionSource: ruleCandidate.definitionSource))
        XCTAssertNoThrow(try ThoughtTopicVerifier.validateSchema4RelationConstraints(
            relation: fitted.relation, kind: fitCandidate.kind, definitionSource: fitCandidate.definitionSource))
        XCTAssertNoThrow(try ThoughtTopicVerifier.validateSchema4RelationConstraints(
            relation: none.relation, kind: threadCandidate.kind, definitionSource: threadCandidate.definitionSource))

        // 证据逐字回源：目标侧 range 精确、规则侧引用可回源
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim(excluded.quote ?? "", in: request.target.text,
                                                            rangeUTF16: excluded.rangeUTF16))
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim(fitted.quote ?? "", in: request.target.text,
                                                            rangeUTF16: fitted.rangeUTF16))
        XCTAssertNoThrow(try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
            quote: excluded.quote, rangeUTF16: excluded.rangeUTF16, chunkText: request.target.text,
            representativeRef: excluded.representativeRef, representativeQuote: excluded.representativeQuote,
            ruleDefinition: ruleCandidate.definition))
        XCTAssertTrue(ruleCandidate.definition?.contains(excluded.representativeQuote ?? "") ?? false)
        XCTAssertTrue(fitCandidate.definition?.contains(fitted.representativeQuote ?? "") ?? false)
    }

    // MARK: - 2. R09 跨 kind 反证：后端 502 整批拒绝 + Swift 校验同口径拒绝

    func testSchema4CrossKindRelationsStayProtocolErrors() async throws {
        let fixture = try loadFixture("relate-schema4-relation-cross-kind-502.json")
        // 后端真实行为：类别判 same_thread → 502 MODEL_OUTPUT_INVALID，不生成空结果回执
        XCTAssertEqual(fixture.status, 502)
        XCTAssertEqual(errorCode(fixture.responseEnvelope), "MODEL_OUTPUT_INVALID")

        // Swift 重放同一份被拒 decisions：关系串取自 fixture 的 modelOutput，
        // kind/definitionSource 取自 fixture 请求候选——两端必须同口径拒绝
        let rejected = try XCTUnwrap(fixture.modelOutputDecisions.first)
        let relation = try XCTUnwrap(rejected["relation"] as? String)
        let categoryCandidate = try candidate(fixture.request, "P0")
        let threadCandidate = try candidate(fixture.request, "P1")
        expectContractViolation("relation_cross_kind") {
            try ThoughtTopicVerifier.validateSchema4RelationConstraints(
                relation: relation, kind: categoryCandidate.kind, definitionSource: categoryCandidate.definitionSource)
        }
        expectContractViolation("relation_cross_kind") {
            try ThoughtTopicVerifier.validateSchema4RelationConstraints(
                relation: "fits_category", kind: threadCandidate.kind, definitionSource: threadCandidate.definitionSource)
        }
        expectContractViolation("relation_cross_kind") {
            try ThoughtTopicVerifier.validateSchema4RelationConstraints(
                relation: "excludes_category", kind: threadCandidate.kind, definitionSource: threadCandidate.definitionSource)
        }
        // 合法组合仍放行（关系串均出现在真实 fixture 输出中）
        XCTAssertNoThrow(try ThoughtTopicVerifier.validateSchema4RelationConstraints(
            relation: "fits_category", kind: categoryCandidate.kind, definitionSource: categoryCandidate.definitionSource))
        XCTAssertNoThrow(try ThoughtTopicVerifier.validateSchema4RelationConstraints(
            relation: "same_thread", kind: threadCandidate.kind, definitionSource: threadCandidate.definitionSource))

        // 502 错误封套经真实 APIClient 映射到既有类型；属模型侧输出问题，
        // 不触发 schema4 停发闸（isSchema4ProtocolRejection=false，与引擎测试口径一致）
        let error = try await postRelateThroughClient(fixture)
        guard case APIError.backendError(let statusCode, let code, let message, _) = error else {
            return XCTFail("502 应映射 APIError.backendError，实得：\(error)")
        }
        XCTAssertEqual(statusCode, 502)
        XCTAssertEqual(code, "MODEL_OUTPUT_INVALID")
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.backendError(statusCode: statusCode, code: code, message: message, requestId: nil)))
    }

    // MARK: - 3. R09 excludes_category 证据不全：后端 502 + Swift 校验拒绝

    func testSchema4ExclusionEvidenceIncompleteIsRefused() throws {
        let fixture = try loadFixture("relate-schema4-excludes-evidence-incomplete-502.json")
        // 后端真实行为：representativeQuote 无法回源用户规则 → 502，不降级、不产空回执
        XCTAssertEqual(fixture.status, 502)
        XCTAssertEqual(errorCode(fixture.responseEnvelope), "MODEL_OUTPUT_INVALID")

        // Swift 重放后端拒绝的同一份 decisions：唯一断点是规则侧引用不可回源
        let rejected = try XCTUnwrap(fixture.modelOutputDecisions.first)
        let ruleCandidate = try candidate(fixture.request, "P0")
        expectContractViolation("excludes_category_evidence") {
            try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
                quote: rejected["quote"] as? String,
                rangeUTF16: rejected["rangeUTF16"] as? [Int],
                chunkText: fixture.request.target.text,
                representativeRef: rejected["representativeRef"] as? String,
                representativeQuote: rejected["representativeQuote"] as? String,
                ruleDefinition: ruleCandidate.definition)
        }
        // R09 缺 representativeQuote（nil / 空）同样必须拒绝，不得当作排除
        expectContractViolation("excludes_category_evidence") {
            try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
                quote: rejected["quote"] as? String,
                rangeUTF16: rejected["rangeUTF16"] as? [Int],
                chunkText: fixture.request.target.text,
                representativeRef: rejected["representativeRef"] as? String,
                representativeQuote: nil,
                ruleDefinition: ruleCandidate.definition)
        }
        expectContractViolation("excludes_category_evidence") {
            try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
                quote: rejected["quote"] as? String,
                rangeUTF16: rejected["rangeUTF16"] as? [Int],
                chunkText: fixture.request.target.text,
                representativeRef: rejected["representativeRef"] as? String,
                representativeQuote: "",
                ruleDefinition: ruleCandidate.definition)
        }
    }

    // MARK: - 4. R09 schema 1/2/3 回归：真实旧响应解码不变

    func testLegacySchemaFixturesDecodeUnchanged() throws {
        // schema 1：V1 契约 same_thread 无 representative 证据字段（DTO 解码须容忍缺失）
        let v1 = try loadFixture("relate-schema1-success.json")
        let v1Response = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self, from: v1.responseJSON)
        XCTAssertEqual(v1Response.schemaVersion, 1)
        XCTAssertEqual(v1Response.operationId, v1.request.operationId)
        XCTAssertEqual(v1Response.decisions.count, v1.request.candidates.count)
        let v1Same = try decision(v1Response, "P0")
        XCTAssertEqual(v1Same.relation, "same_thread")
        XCTAssertEqual(v1Same.quote, "跑了五公里")
        XCTAssertEqual(v1Same.rangeUTF16, [2, 7])
        XCTAssertNil(v1Same.representativeRef)
        XCTAssertNil(v1Same.representativeQuote)
        XCTAssertNil(v1Same.sharedSubject)
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim(v1Same.quote ?? "", in: v1.request.target.text,
                                                            rangeUTF16: v1Same.rangeUTF16))

        // schema 2：双侧证据（R0 逐字引用 + sharedSubject）
        let v2 = try loadFixture("relate-schema2-success.json")
        let v2Response = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self, from: v2.responseJSON)
        XCTAssertEqual(v2Response.schemaVersion, 2)
        XCTAssertEqual(v2Response.operationId, v2.request.operationId)
        XCTAssertEqual(v2Response.decisions.count, v2.request.candidates.count)
        let v2Same = try decision(v2Response, "P0")
        XCTAssertEqual(v2Same.relation, "same_thread")
        XCTAssertEqual(v2Same.quote, "今天跑了五公里")
        XCTAssertEqual(v2Same.rangeUTF16, [0, 7])
        XCTAssertEqual(v2Same.representativeRef, "R0")
        XCTAssertEqual(v2Same.representativeQuote, "左膝不舒服")
        XCTAssertEqual(v2Same.sharedSubject, "个人跑步训练")
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim(v2Same.quote ?? "", in: v2.request.target.text,
                                                            rangeUTF16: v2Same.rangeUTF16))
        let v2Rep = try XCTUnwrap(v2.request.candidates.first { $0.ref == "P0" }?.representatives.first { $0.ref == "R0" })
        XCTAssertTrue(v2Rep.text.contains(v2Same.representativeQuote ?? ""))

        // schema 3：双通道 fits_category（definition 依据、无 sharedSubject 字段）
        let v3 = try loadFixture("relate-schema3-success.json")
        let v3Response = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self, from: v3.responseJSON)
        XCTAssertEqual(v3Response.schemaVersion, 3)
        XCTAssertEqual(v3Response.operationId, v3.request.operationId)
        XCTAssertEqual(v3Response.decisions.count, v3.request.candidates.count)
        let v3Fit = try decision(v3Response, "P0")
        XCTAssertEqual(v3Fit.relation, "fits_category")
        XCTAssertEqual(v3Fit.quote, "判断力反而要刻意练习")
        XCTAssertEqual(v3Fit.rangeUTF16, [6, 16])
        XCTAssertEqual(v3Fit.representativeRef, "definition")
        XCTAssertEqual(v3Fit.representativeQuote, "个人观察与反思")
        XCTAssertNil(v3Fit.sharedSubject)
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim(v3Fit.quote ?? "", in: v3.request.target.text,
                                                            rangeUTF16: v3Fit.rangeUTF16))
        let v3Category = try candidate(v3.request, "P0")
        XCTAssertEqual(v3Category.kind, "category")
        XCTAssertNil(v3Category.definitionSource, "旧协议请求不带 definitionSource（解码不变）")
        XCTAssertTrue(v3Category.definition?.contains(v3Fit.representativeQuote ?? "") ?? false)
    }

    // MARK: - 5. R29 反证内置：对真实 fixture 注入错字段/错类型必须拒绝

    func testR29InjectedMutationsAreRefused() throws {
        let fixture = try loadFixture("relate-schema4-success.json")

        // 注入① rangeUTF16 越界：可解码（形状合法）但逐字校验必须拒绝
        var envelope = fixture.responseEnvelope
        var decisions = envelope["decisions"] as? [[String: Any]] ?? []
        decisions[0]["rangeUTF16"] = [0, 9999]
        envelope["decisions"] = decisions
        let overflowResponse = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self,
                                                        from: JSONSerialization.data(withJSONObject: envelope))
        let overflow = try decision(overflowResponse, "P0")
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim(overflow.quote ?? "", in: fixture.request.target.text,
                                                             rangeUTF16: overflow.rangeUTF16))
        expectContractViolation("excludes_category_evidence") {
            try ThoughtTopicVerifier.validateSchema4ExclusionEvidence(
                quote: overflow.quote, rangeUTF16: overflow.rangeUTF16, chunkText: fixture.request.target.text,
                representativeRef: overflow.representativeRef, representativeQuote: overflow.representativeQuote,
                ruleDefinition: fixture.request.candidates.first?.definition)
        }

        // 注入② 错类型（rangeUTF16 变字符串）：JSONDecoder 解码必须失败
        var typeConfused = fixture.responseEnvelope
        var typeDecisions = typeConfused["decisions"] as? [[String: Any]] ?? []
        typeDecisions[0]["rangeUTF16"] = "0-10"
        typeConfused["decisions"] = typeDecisions
        XCTAssertThrowsError(try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self,
                                                      from: JSONSerialization.data(withJSONObject: typeConfused))) { error in
            XCTAssertTrue(error is DecodingError, "错类型必须是 DecodingError，实得：\(error)")
        }

        // 注入③ definitionSource 非法值（ai）：后端真实 400 INVALID_REQUEST（fixture 锚定），
        // Swift 侧 excludes_category 通道同口径拒绝
        let invalidSource = try loadFixture("relate-schema4-definition-source-invalid-400.json")
        XCTAssertEqual(invalidSource.status, 400)
        XCTAssertEqual(errorCode(invalidSource.responseEnvelope), "INVALID_REQUEST")
        XCTAssertEqual(invalidSource.request.candidates.first?.definitionSource, "ai",
                       "请求 DTO 解码如实保留非法值，拦截责任在通道校验")
        expectContractViolation("excludes_category_requires_user_rule") {
            try ThoughtTopicVerifier.validateSchema4RelationConstraints(
                relation: "excludes_category", kind: "category", definitionSource: "ai")
        }
    }

    // MARK: - 6. THOUGHT_SCOPE_RULES_DISABLED 503 错误封套 → 既有错误类型

    func testDisabledGate503EnvelopeMapsToExistingBackendError() async throws {
        let fixture = try loadFixture("relate-schema4-disabled-503.json")
        // 后端真实行为：灰度闸默认关闭，schema 4 请求拿稳定错误码
        XCTAssertEqual(fixture.status, 503)
        XCTAssertEqual(errorCode(fixture.responseEnvelope), "THOUGHT_SCOPE_RULES_DISABLED")

        // 经真实 provider → APIClient 错误映射（5xx → APIError.backendError）。
        // 503 在 HTTP 层按可重试处理（1/2/4 秒退避共 3 次重试后上抛，本测试约 7 秒），
        // 停发新版请求的闸在验证器层（isSchema4ProtocolRejection），与此分层一致。
        let error = try await postRelateThroughClient(fixture)
        guard case APIError.backendError(let statusCode, let code, let message, _) = error else {
            return XCTFail("503 应映射 APIError.backendError，实得：\(error)")
        }
        XCTAssertEqual(statusCode, 503)
        XCTAssertEqual(code, "THOUGHT_SCOPE_RULES_DISABLED")
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(ThoughtTopicVerifier.isSchema4ProtocolRejection(
            APIError.backendError(statusCode: statusCode, code: code, message: message, requestId: nil)),
            "灰度关闭属协议拒绝：验证器停发 schema 4 请求并留诊断")
    }

    // MARK: - 7. UTF-16 口径：definition 恰 240（含代理对）/ 241 双端同判

    func testDefinitionUTF16BoundaryMirrorsBackend240And241() throws {
        // 恰 240（118 BMP + 61 个 🏃 代理对 = 240 单位）：后端真实接受（200 fixture）
        let accepted = try loadFixture("relate-schema4-definition-240.json")
        XCTAssertEqual(accepted.status, 200)
        let definition240 = try XCTUnwrap(accepted.request.candidates.first?.definition)
        XCTAssertEqual(definition240.utf16.count, 240)
        XCTAssertTrue(definition240.utf16.contains { $0 >= 0xD800 && $0 <= 0xDFFF },
                      "边界样本必须含代理对（emoji 按 2 个 UTF-16 单位计数）")
        XCTAssertEqual(ThoughtTopicVerifier.schema4RulePayload(rawDefinition: definition240),
                       .user(definition: definition240),
                       "后端放行 240 ⇒ 客户端送审判据同口径放行（含脱敏无感）")
        let response = try JSONDecoder().decode(ThoughtSemanticRelateResponseDTO.self, from: accepted.responseJSON)
        XCTAssertEqual(response.schemaVersion, 4)
        XCTAssertEqual(response.decisions.first?.relation, "none")

        // 恰 241（119 BMP + 61 个 🏃 = 241 单位）：后端真实拒绝（400 fixture）
        let refused = try loadFixture("relate-schema4-definition-241.json")
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(errorCode(refused.responseEnvelope), "INVALID_REQUEST")
        let definition241 = try XCTUnwrap(refused.request.candidates.first?.definition)
        XCTAssertEqual(definition241.utf16.count, 241)
        guard case .skip(let reason) = ThoughtTopicVerifier.schema4RulePayload(rawDefinition: definition241) else {
            return XCTFail("241 UTF-16 客户端必须按 skip 拒绝送审")
        }
        XCTAssertEqual(reason, "category_definition_too_long",
                       "后端 400 ⇒ 客户端同口径跳过评判（留诊断、不静默截断）")
    }
}
