//
//  HoloAgentResponseParserTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 3.4 Response Parser 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/HoloAgentResponseParser.swift> <本测试> \
//    -o /tmp/holo_agent_parser_test && /tmp/holo_agent_parser_test
//

import Foundation

@main
struct HoloAgentResponseParserTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test纯JSON解析成功()
        testMarkdownCodeBlock包裹解析成功()
        test旧字段text可解析为displayText()
        test缺status抛outputParseFailure可重试()
        test超过重试次数不重试()
        print("HoloAgentResponseParserTests passed")
    }

    private static let validJSON = #"{"status":"final_claims","reasoning":"证据充分","toolRequests":[],"claims":[],"warnings":[]}"#

    private static func test纯JSON解析成功() {
        let output = try? HoloAgentResponseParser.parse(validJSON, remainingRetries: 2)
        expect(output != nil, "纯 JSON 应解析成功")
        expect(output?.status == .finalClaims, "status 应为 final_claims")
    }

    private static func testMarkdownCodeBlock包裹解析成功() {
        let raw = "```json\n\(validJSON)\n```"
        let output = try? HoloAgentResponseParser.parse(raw, remainingRetries: 2)
        expect(output != nil, "markdown code block 包裹应解析成功")
        expect(output?.status == .finalClaims, "status 应为 final_claims")
    }

    private static func test旧字段text可解析为displayText() {
        let raw = #"{"status":"final_claims","reasoning":"证据充分","toolRequests":[],"claims":[{"id":"c1","text":"餐饮消费集中在晚餐","metricAssertions":[],"evidenceIDs":["e1"]}],"warnings":[]}"#
        let output = try? HoloAgentResponseParser.parse(raw, remainingRetries: 0)
        expect(output != nil, "旧字段 text 应兼容解析")
        expect(output?.claims.first?.displayText == "餐饮消费集中在晚餐", "text 应映射到 displayText")
        expect(output?.claims.first?.type == "observation", "旧响应缺 type 时应补默认值")
        expect(output?.claims.first?.confidence == 0.5, "旧响应缺 confidence 时应补默认值")
    }

    private static func test缺status抛outputParseFailure可重试() {
        let raw = #"{"reasoning":"无 status","toolRequests":[],"claims":[],"warnings":[]}"#
        do {
            _ = try HoloAgentResponseParser.parse(raw, remainingRetries: 2)
            expect(false, "缺 status 应抛 outputParseFailure")
        } catch HoloAgentError.outputParseFailure(let needsRetry) {
            expect(needsRetry == true, "remainingRetries>0 时 needsRetry 应为 true")
        } catch {
            expect(false, "应是 outputParseFailure，实际 \(error)")
        }
    }

    private static func test超过重试次数不重试() {
        let raw = "完全不是 JSON 的文本"
        do {
            _ = try HoloAgentResponseParser.parse(raw, remainingRetries: 0)
            expect(false, "非法 JSON 应抛 outputParseFailure")
        } catch HoloAgentError.outputParseFailure(let needsRetry) {
            expect(needsRetry == false, "remainingRetries=0 时 needsRetry 应为 false")
        } catch {
            expect(false, "应是 outputParseFailure，实际 \(error)")
        }
    }
}
