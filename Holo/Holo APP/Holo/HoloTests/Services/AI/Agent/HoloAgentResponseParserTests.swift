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
        test说明文本中可抽取JSON并归一字段别名()
        test动态查询计划缺省字段自动补齐()
        testParameters内嵌动态计划可提升为同级字段()
        test跨域查询计划缺省字段自动补齐()
        test缺status抛outputParseFailure可重试()
        test超过重试次数不重试()
        print("HoloAgentResponseParserTests passed")
    }

    private static func test动态查询计划缺省字段自动补齐() {
        let raw = #"{"status":"need_tools","reasoning":"现场计算平均睡眠","toolRequests":[{"id":"sleep-dynamic","tool":"health","query":"dynamic_query","dynamicPlan":{"source":"health.sleep","aggregations":[{"id":"average_sleep","operation":"average","field":"value","unit":"小时"}]}}],"claims":[],"warnings":[]}"#
        let output = try? HoloAgentResponseParser.parse(raw, remainingRetries: 0)
        let plan = output?.toolRequests.first?.dynamicPlan
        expect(plan?.source == "health.sleep", "应解析动态数据集")
        expect(plan?.aggregations.first?.operation == .average, "应解析动态聚合")
        expect(plan?.filters.isEmpty == true && plan?.limit == 20, "缺省安全字段应自动补齐")
    }

    /// 线上真实故障回归：旧后端 schema 诱导模型把 dynamicPlan 放进 parameters，
    /// parameters 随即不再是 [String: String]，旧 parser 会让整轮解码失败。
    private static func testParameters内嵌动态计划可提升为同级字段() {
        let raw = #"{"status":"need_tools","reasoning":"按分类比较环比","toolRequests":[{"id":"finance-comparison","tool":"finance","query":"dynamic_query","parameters":{"dynamicPlan":{"source":"finance.transactions","timeRange":{"label":"本月","start":"2026-07-01","end":"2026-08-01"},"filters":[{"field":"type","operation":"equal","value":{"type":"text","text":"expense"}}],"groupBy":[{"type":"field","field":"category"}],"aggregations":[{"id":"category_amount","operation":"sum","field":"amount","unit":"元"}],"derivations":[{"id":"category_growth","operation":"percentageChange","metricID":"category_amount","unit":"比例"}],"sort":{"metricID":"category_growth","direction":"descending"},"limit":"3","evidenceLimit":"10"},"retry":"1"}}],"claims":[],"warnings":[]}"#

        let output = try? HoloAgentResponseParser.parse(raw, remainingRetries: 0)
        let request = output?.toolRequests.first
        expect(output != nil, "parameters 内嵌 dynamicPlan 应在本地白名单修复后成功解码")
        expect(request?.dynamicPlan?.source == "finance.transactions", "内嵌 dynamicPlan 应提升为同级字段")
        expect(request?.dynamicPlan?.limit == 3, "字符串 limit 应归一为整数")
        expect(request?.dynamicPlan?.aggregations.first?.filters.isEmpty == true, "聚合 filters 缺省应补空数组")
        expect(request?.dynamicPlan?.timeRange == nil, "模型提供的字符串日期不能覆盖 runtime 的确定性时间窗口")
        expect(request?.parameters["retry"] == "1", "parameters 的标量值应保留为字符串")
        expect(request?.parameters["dynamicPlan"] == nil, "提升后 parameters 不得残留 dynamicPlan")
    }

    private static func test跨域查询计划缺省字段自动补齐() {
        let raw = #"{"status":"need_tools","reasoning":"检查关联","toolRequests":[{"id":"cross","tool":"cross_domain","query":"aligned_analysis","crossDomainPlan":{"leftSource":"health.sleep","leftField":"value","rightSource":"finance.transactions","rightField":"amount","operation":"correlation"}}],"claims":[],"warnings":[]}"#
        let output = try? HoloAgentResponseParser.parse(raw, remainingRetries: 0)
        let plan = output?.toolRequests.first?.crossDomainPlan
        expect(plan?.operation == .correlation, "应解析跨域计算操作")
        expect(plan?.minimumAlignedDays == 5, "应补齐最少对齐天数")
        expect(plan?.leftFilters.isEmpty == true && plan?.rightFilters.isEmpty == true, "应补齐过滤器")
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

    private static func test说明文本中可抽取JSON并归一字段别名() {
        let raw = """
        分析结果如下：
        {"status":"final_claims","reasoning":"证据充分","toolRequests":[],"claims":[{"id":"c1","type":"observation","displayText":"6月下半月消费约 4919 元","metricAssertions":[{"metricKey":"finance.total","value":4919,"unit":"元","evidenceIds":["e1"]}],"evidenceIds":["e1"],"prohibitedInferences":[],"confidence":0.5}],"warnings":["全月数据不足"]}
        """
        let output = try? HoloAgentResponseParser.parse(raw, remainingRetries: 0)
        expect(output != nil, "说明文本中包裹的 JSON 应可抽取解析")
        expect(output?.claims.first?.evidenceIDs == ["e1"], "claim evidenceIds 应归一到 evidenceIDs")
        expect(output?.claims.first?.metricAssertions.first?.evidenceIDs == ["e1"], "metric assertion evidenceIds 应归一到 evidenceIDs")
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
