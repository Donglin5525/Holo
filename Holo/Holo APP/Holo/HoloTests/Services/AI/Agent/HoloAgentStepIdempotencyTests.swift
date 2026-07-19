//
//  HoloAgentStepIdempotencyTests.swift
//  HoloTests
//
//  Holo Agent 稳定执行 — Phase 4（§8.2/8.3，P0-7）
//  APIClient step 感知重试与重试归并验证（MockURLProtocol 拦截，无真实网络）：
//  - 409 STEP_IN_PROGRESS → 独立退避重试同一请求，最终成功
//  - 409 STEP_ID_CONFLICT → 不重试，直接抛 typed error
//  - 重试归并：APIClient 是唯一 HTTP 重试层（单轮 LLM 不再双层叠加）
//  - HoloAgentLLMClient 端到端：旧的「LLMClient 整体重试 × APIClient 重试」乘法已消除
//

import XCTest
@testable import Holo

final class HoloAgentStepIdempotencyTests: XCTestCase {

    // MARK: - MockURLProtocol

    /// 脚本化响应的 URLProtocol：按队列依次返回 (statusCode, body)，统计请求数。
    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        static var requestCount = 0
        static var scriptedResponses: [(status: Int, body: String)] = []
        /// 最后一条请求的 body（验证 step 三字段用）
        static var lastRequestBody: Data?

        static func reset(responses: [(Int, String)]) {
            requestCount = 0
            scriptedResponses = responses
            lastRequestBody = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            MockURLProtocol.requestCount += 1
            if let bodyStream = request.httpBodyStream {
                MockURLProtocol.lastRequestBody = Data(reading: bodyStream)
            } else {
                MockURLProtocol.lastRequestBody = request.httpBody
            }
            let (status, body) = MockURLProtocol.scriptedResponses.isEmpty
                ? (500, #"{"error":{"code":"UNSCRIPTED","message":"unscripted"}}"#)
                : MockURLProtocol.scriptedResponses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private struct OKResponse: Decodable { let ok: Bool }

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(urlSession: URLSession(configuration: config))
    }

    private func makeRequest() -> APIRequest {
        APIRequest(
            baseURL: "https://mock.local",
            path: "/v1/ai/chat/completions",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: HoloBackendChatCompletionRequest(
                purpose: "agent_loop", messages: [], stream: false, responseFormat: nil
            )
        )
    }

    // MARK: - §8.2 STEP_IN_PROGRESS / STEP_ID_CONFLICT

    /// 409 STEP_IN_PROGRESS → 独立退避重试同一请求（幂等协议的一部分），最终成功。
    func testAPIClient_stepInProgress退避后成功() async throws {
        MockURLProtocol.reset(responses: [
            (409, #"{"error":{"code":"STEP_IN_PROGRESS","message":"processing"}}"#),
            (409, #"{"error":{"code":"STEP_IN_PROGRESS","message":"processing"}}"#),
            (200, #"{"ok":true}"#)
        ])
        let client = makeClient()

        let response: OKResponse = try await client.send(makeRequest())

        XCTAssertTrue(response.ok)
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "两次 STEP_IN_PROGRESS 后第三次成功，实际 \(MockURLProtocol.requestCount)")
    }

    /// STEP_IN_PROGRESS 超过退避上限 → 抛 stepInProgress（不再无限等待）。
    func testAPIClient_stepInProgress超上限抛出() async throws {
        MockURLProtocol.reset(responses: Array(repeating:
            (409, #"{"error":{"code":"STEP_IN_PROGRESS","message":"processing"}}"#), count: 10))
        let client = makeClient()

        do {
            let _: OKResponse = try await client.send(makeRequest())
            XCTFail("持续 STEP_IN_PROGRESS 应在退避上限后抛出")
        } catch let error as APIError {
            guard case .stepInProgress = error else {
                return XCTFail("应抛 stepInProgress，实际 \(error)")
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 4, "首次 + 3 次退避重试，实际 \(MockURLProtocol.requestCount)")
    }

    /// 409 STEP_ID_CONFLICT → 不重试，直接抛 typed error（协议冲突是终态）。
    func testAPIClient_stepIdConflict不重试() async throws {
        MockURLProtocol.reset(responses: Array(repeating:
            (409, #"{"error":{"code":"STEP_ID_CONFLICT","message":"different payload"}}"#), count: 10))
        let client = makeClient()

        do {
            let _: OKResponse = try await client.send(makeRequest())
            XCTFail("STEP_ID_CONFLICT 应直接抛出")
        } catch let error as APIError {
            guard case .stepIdConflict(let message) = error else {
                return XCTFail("应抛 stepIdConflict，实际 \(error)")
            }
            XCTAssertEqual(message, "different payload")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "STEP_ID_CONFLICT 不得重试，实际 \(MockURLProtocol.requestCount)")
    }

    // MARK: - Phase 4 任务5：重试归并（单一 retry owner）

    /// APIClient 是唯一 HTTP 重试层：retryable 500 按预算重试（首次 + 2 次），第三次成功。
    func testAPIClient_普通错误单层重试预算() async throws {
        MockURLProtocol.reset(responses: [
            (500, #"{"error":{"code":"BOOM","message":"boom"}}"#),
            (500, #"{"error":{"code":"BOOM","message":"boom"}}"#),
            (200, #"{"ok":true}"#)
        ])
        let client = makeClient()

        let response: OKResponse = try await client.send(makeRequest())

        XCTAssertTrue(response.ok)
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "首次 + 2 次重试，实际 \(MockURLProtocol.requestCount)")
    }

    /// HoloAgentLLMClient 端到端：旧的「LLMClient 睡 2s 整体重试 × APIClient 重试」乘法已消除——
    /// 单轮 LLM 的 HTTP 调用数只由 APIClient 一层决定（retryable×2 后成功 = 3 次，旧实现最坏 6 次）。
    @MainActor
    func testLLMClient_单轮不再双层重试() async throws {
        MockURLProtocol.reset(responses: [
            (500, #"{"error":{"code":"BOOM","message":"boom"}}"#),
            (500, #"{"error":{"code":"BOOM","message":"boom"}}"#),
            (200, #"{"id":"r1","choices":[{"index":0,"message":{"role":"assistant","content":"{}"},"finish_reason":"stop"}]}"#)
        ])
        // 需要 AI 数据处理同意（provider 前置检查）；测试后还原
        let consentKey = "holo_ai_dataProcessingConsentGranted"
        let previousConsent = UserDefaults.standard.object(forKey: consentKey) as? Bool
        HoloAIDataProcessingConsent.shared.grant()
        defer {
            if let previousConsent {
                UserDefaults.standard.set(previousConsent, forKey: consentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: consentKey)
            }
        }

        let apiClient = makeClient()
        let provider = HoloBackendAIProvider(baseURL: "https://mock.local", apiClient: apiClient)
        let llmClient = HoloAgentLLMClient(provider: provider)

        let content = try await llmClient.next(messages: [
            HoloAgentMessage(role: .user, content: "q", toolRequestID: nil, toolName: nil,
                             timestamp: Date(), tokenEstimate: nil)
        ])

        XCTAssertEqual(content, "{}")
        XCTAssertEqual(MockURLProtocol.requestCount, 3,
                       "单轮 LLM 只允许 APIClient 一层重试（旧双层实现最坏 6 次），实际 \(MockURLProtocol.requestCount)")
    }

    /// LLMClient 透传 step 三字段到请求体（§8.1）。
    @MainActor
    func testLLMClient_step三字段写入请求体() async throws {
        MockURLProtocol.reset(responses: [
            (200, #"{"id":"r1","choices":[{"index":0,"message":{"role":"assistant","content":"{}"},"finish_reason":"stop"}]}"#)
        ])
        let consentKey = "holo_ai_dataProcessingConsentGranted"
        let previousConsent = UserDefaults.standard.object(forKey: consentKey) as? Bool
        HoloAIDataProcessingConsent.shared.grant()
        defer {
            if let previousConsent {
                UserDefaults.standard.set(previousConsent, forKey: consentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: consentKey)
            }
        }

        let provider = HoloBackendAIProvider(baseURL: "https://mock.local", apiClient: makeClient())
        let llmClient = HoloAgentLLMClient(provider: provider)
        let record = HoloAgentLLMRequestRecord(
            runID: "run-9", stepID: "llm-2-3", requestHash: "deadbeef",
            status: .prepared, responseHash: nil
        )

        _ = try await llmClient.next(messages: [
            HoloAgentMessage(role: .user, content: "q", toolRequestID: nil, toolName: nil,
                             timestamp: Date(), tokenEstimate: nil)
        ], step: record)

        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["runId"] as? String, "run-9")
        XCTAssertEqual(json["stepId"] as? String, "llm-2-3")
        XCTAssertEqual(json["requestHash"] as? String, "deadbeef")
    }
}

private extension Data {
    /// 从 InputStream 读出全部数据（MockURLProtocol 捕获请求体用）。
    init(reading stream: InputStream) {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        self = data
    }
}
