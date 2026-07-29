//
//  HoloAgentPromptProviderTests.swift
//  HoloTests
//
//  验证 HoloAgentPromptProvider 的核心行为：
//  - 后端成功时返回后端正文（含变量渲染）
//  - 后端失败时回退到本地兜底（Debug 内嵌模板 / Release 安全占位）
//  - 返回值始终非空
//  - 后端正文中的 {{todayDate}} 等变量被正确渲染
//
//  修复 Release 编译阻塞：HoloAgentAnalysisService / HoloBackgroundContinuationManager
//  原先调用 PromptManager.shared.loadRawTemplate（DEBUG-only），Release 下不存在。
//

import XCTest
@testable import Holo

final class HoloAgentPromptProviderTests: XCTestCase {

    // MARK: - MockURLProtocol

    /// 脚本化响应的 URLProtocol：按队列依次返回 (statusCode, body)。
    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        static var scriptedResponses: [(status: Int, body: String)] = []

        static func reset(responses: [(Int, String)]) {
            scriptedResponses = responses
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (status, body) = MockURLProtocol.scriptedResponses.isEmpty
                ? (500, #"{"error":{"code":"UNSCRIPTED"}}"#)
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

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(urlSession: URLSession(configuration: config))
    }

    // MARK: - Tests

    /// 后端成功返回时，Provider 返回后端正文（已渲染变量）。
    func testBackendSuccessReturnsBackendContent() async {
        let backendContent = "你是 Agent 推理器。今天是 {{todayDate}}。"
        let body = #"{"type":"agent_loop","version":17,"content":"\#(backendContent)"}"#
        MockURLProtocol.reset(responses: [(200, body)])

        let result = await HoloAgentPromptProvider.agentLoopSystemTemplate(
            apiClient: makeClient(),
            baseURL: "https://mock.local",
            deviceIdProvider: { "test-device" }
        )

        XCTAssertFalse(result.isEmpty, "后端成功时不应返回空串")
        XCTAssertTrue(result.contains("你是 Agent 推理器"), "应返回后端正文")
        XCTAssertFalse(result.contains("{{todayDate}}"), "变量应被渲染，不应残留 {{todayDate}}")
        XCTAssertTrue(result.contains("年"), "渲染后的日期应包含中文年")
    }

    /// 后端失败（网络错误 / 500）时，Provider 回退到本地兜底，仍返回非空。
    func testBackendFailureFallsBackNonEmpty() async {
        MockURLProtocol.reset(responses: [(500, #"{"error":"server error"}"#)])

        let result = await HoloAgentPromptProvider.agentLoopSystemTemplate(
            apiClient: makeClient(),
            baseURL: "https://mock.local",
            deviceIdProvider: { "test-device" }
        )

        XCTAssertFalse(result.isEmpty, "后端失败时兜底仍应返回非空字符串")
    }

    /// 无论后端成功与否，返回值始终非空（协议保证）。
    func testAlwaysReturnsNonEmpty() async {
        // 后端返回无效 JSON
        MockURLProtocol.reset(responses: [(200, "not valid json")])

        let result = await HoloAgentPromptProvider.agentLoopSystemTemplate(
            apiClient: makeClient(),
            baseURL: "https://mock.local",
            deviceIdProvider: { "test-device" }
        )

        XCTAssertFalse(result.isEmpty, "即使后端返回无效 JSON，也应回退为非空")
    }

    /// 变量渲染器：{{todayDate}} / {{currentYear}} / {{currentTime}} 都被替换。
    func testVariableRenderer() {
        let template = "日期 {{todayDate}} ISO {{todayISODate}} 年 {{currentYear}} 时间 {{currentTime}} 月起 {{thirtyDaysAgoDate}}"
        let rendered = HoloPromptVariableRenderer.renderVariables(
            in: template,
            now: Date(timeIntervalSince1970: 1_751_600_000)
        )

        XCTAssertFalse(rendered.contains("{{"), "所有变量占位都应被替换")
        XCTAssertFalse(rendered.contains("}}"), "不应残留 }}"
    }

    /// Debug 兜底：后端失败时回退到 PromptManager 本地模板（含完整正文）。
    func testDebugFallbackContainsAgentLoopContent() async {
        MockURLProtocol.reset(responses: [(500, #"{"error":"server error"}"#)])

        let result = await HoloAgentPromptProvider.agentLoopSystemTemplate(
            apiClient: makeClient(),
            baseURL: "https://mock.local",
            deviceIdProvider: { "test-device" }
        )

#if DEBUG
        // Debug 下兜底应是 PromptManager 的本地 agentLoop 模板，含核心协议词。
        XCTAssertTrue(result.contains("JSON") || result.contains("Agent"), "Debug 兜底应含 agentLoop 协议内容")
#else
        // Release 下兜底是安全占位，不含商业正文但非空。
        XCTAssertFalse(result.isEmpty, "Release 安全占位应非空")
#endif
    }

    override func tearDown() {
        MockURLProtocol.reset(responses: [])
        super.tearDown()
    }
}
