//
//  HoloMetricSemanticStandaloneTests.swift
//  HoloTests
//
//  Agent 统一结果语义契约 P1 — 类型化结果语义（Typed Result Semantic）独立测试，
//  不依赖会触发 CloudKit 的 App 测试宿主。
//
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/HoloAgentTimeRange.swift" \
//    "Holo/Models/AI/Agent/HoloEvidenceModels.swift" \
//    "Holo/Models/AI/Agent/HoloAgentToolModels.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
//    <本测试> -o /tmp/holo_metric_semantic_test && /tmp/holo_metric_semantic_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMetricSemanticStandaloneTests.main()
    }
}
#endif

struct HoloMetricSemanticStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try test动态查询引擎产出聚合与派生语义()
        test单位到业务量映射全覆盖()
        test分组字段到维度映射()
        test旧JSON解码兼容与语义往返()
        await test跨域工具产出相关性与分组语义()
        print("HoloMetricSemanticStandaloneTests passed")
    }

    // MARK: - a) 动态查询引擎语义

    /// finance.transactions：groupBy category + sum(amount) + difference 派生，带 baseline rows。
    private static func test动态查询引擎产出聚合与派生语义() throws {
        let currentRange = HoloAgentTimeRange(
            label: "本期",
            start: Date(timeIntervalSince1970: 10_000),
            end: Date(timeIntervalSince1970: 20_000)
        )
        let baselineRange = HoloAgentTimeRange(
            label: "上期",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 10_000)
        )
        let plan = HoloDynamicQueryPlan(
            source: "finance.transactions",
            timeRange: currentRange,
            baseline: baselineRange,
            groupBy: [HoloDynamicGrouping(type: .field, field: "category")],
            aggregations: [
                HoloDynamicAggregation(id: "spend", operation: .sum, field: "amount", unit: "元")
            ],
            derivations: [
                HoloDynamicDerivation(id: "delta", operation: .difference, metricID: "spend", unit: "元")
            ]
        )
        func row(_ id: String, _ at: TimeInterval, _ category: String, _ amount: Double) -> HoloQueryRow {
            HoloQueryRow(
                id: id,
                occurredAt: Date(timeIntervalSince1970: at),
                fields: ["amount": .number(amount), "category": .text(category)],
                excerpt: "\(category) \(amount) 元"
            )
        }
        let currentRows = [
            row("c1", 11_000, "餐饮", 620),
            row("c2", 12_000, "交通", 386),
            row("c3", 13_000, "购物", 100)
        ]
        let baselineRows = [
            row("b1", 5_000, "餐饮", 500),
            row("b2", 6_000, "交通", 500),
            row("b3", 7_000, "购物", 100)
        ]
        let catalog = HoloDataCatalog(datasets: [HoloCrossDomainTool.financeSchema])
        let output = try HoloDynamicQueryEngine.execute(
            plan: plan, catalog: catalog, currentRows: currentRows, baselineRows: baselineRows
        )

        func metric(_ suffix: String) -> HoloMetric {
            guard let metric = output.metrics.first(where: { $0.metricKey.hasSuffix(suffix) }) else {
                fatalError("缺少指标 \(suffix)，实际：\(output.metrics.map(\.metricKey))")
            }
            return metric
        }

        // 聚合指标语义：餐饮
        let diningSum = metric(".spend.餐饮")
        let diningSemantic = try unwrap(diningSum.semantic, "聚合指标缺少 semantic")
        expect(diningSemantic.domain == .finance, "domain 应为 finance")
        expect(diningSemantic.dataset == "finance.transactions", "dataset 应为 finance.transactions")
        expect(diningSemantic.measure == .amount, "measure 应为 amount")
        expect(diningSemantic.operation == .sum, "operation 应为 sum")
        expect(diningSemantic.valueRole == .current, "聚合指标 valueRole 应为 current")
        expect(diningSemantic.dimension == .category, "dimension 应为 category")
        expect(diningSemantic.groupLabel == "餐饮", "groupLabel 应为 餐饮")
        expect(diningSemantic.direction == nil, "聚合指标 direction 应为 nil")
        expect(diningSemantic.currentValue == 620, "currentValue 应为当前周期值 620")
        expect(diningSemantic.baselineValue == 500, "baselineValue 应为对比周期值 500")
        expect(diningSemantic.resultValue == diningSum.value, "resultValue 应等于 metric value")
        expect(diningSemantic.displayUnit == "元", "displayUnit 应保留原始单位")

        // 派生指标语义：difference → delta，方向按符号
        let diningDelta = metric(".delta.餐饮")
        let deltaSemantic = try unwrap(diningDelta.semantic, "派生指标缺少 semantic")
        expect(deltaSemantic.operation == .difference, "派生 operation 应为 difference")
        expect(deltaSemantic.valueRole == .delta, "difference 派生 valueRole 应为 delta")
        expect(deltaSemantic.direction == .increase, "620-500 应为 increase")
        expect(deltaSemantic.currentValue == 620, "派生 currentValue 应继承源 metric")
        expect(deltaSemantic.baselineValue == 500, "派生 baselineValue 应继承源 metric")
        expect(deltaSemantic.resultValue == 120, "resultValue 应为差值 120")
        expect(deltaSemantic.dimension == .category, "派生 dimension 应随分组")
        expect(deltaSemantic.groupLabel == "餐饮", "派生 groupLabel 应为 bucket key")
        expect(deltaSemantic.measure == .amount, "派生 unit 为 元，measure 应为 amount")

        // 下降与持平方向
        let transitDelta = try unwrap(metric(".delta.交通").semantic, "交通派生缺少 semantic")
        expect(transitDelta.direction == .decrease, "386-500 应为 decrease")
        let shoppingDelta = try unwrap(metric(".delta.购物").semantic, "购物派生缺少 semantic")
        expect(shoppingDelta.direction == .flat, "100-100 应为 flat")

        // engine 事件与 metric 挂同一份语义
        for event in output.events {
            let key = try unwrap(event.metricKey, "事件缺少 metricKey")
            let source = output.metrics.first { $0.metricKey == key }
            expect(event.semantic == source?.semantic, "事件语义应与 metric 语义一致：\(key)")
        }
    }

    // MARK: - b) unit → measure 映射

    private static func test单位到业务量映射全覆盖() {
        let cases: [(String?, HoloMetricMeasure)] = [
            ("元", .amount),
            ("个", .count), ("条", .count), ("项", .count),
            ("笔", .count), ("类", .count), ("次", .count),
            ("小时", .durationHours),
            ("分钟", .durationMinutes),
            ("步", .steps),
            ("天", .days),
            ("晚", .nights),
            ("%", .ratio), ("比例", .ratio),
            ("元/月", .rateMonthly),
            ("元/天", .rateDaily),
            ("相关系数", .correlation),
            (nil, .none), ("", .none), ("   ", .none), ("未知单位", .none)
        ]
        for (unit, expected) in cases {
            let actual = HoloMetricSemanticFactory.measure(forUnit: unit)
            expect(actual == expected, "unit \(unit ?? "nil") 应映射为 \(expected)，实际 \(actual)")
        }
    }

    // MARK: - c) 分组字段 → dimension 映射

    private static func test分组字段到维度映射() {
        let timeCases: [(HoloDynamicGroupBy, HoloMetricDimension)] = [
            (.day, .day), (.week, .week), (.month, .month), (.weekend, .weekend)
        ]
        for (type, expected) in timeCases {
            let actual = HoloMetricSemanticFactory.dimension(forGrouping: HoloDynamicGrouping(type: type))
            expect(actual == expected, "\(type) 分组应映射为 \(expected)")
        }
        let fieldCases: [(String, HoloMetricDimension)] = [
            ("category", .category),
            ("account", .account),
            ("transactionType", .transactionType),
            ("habit", .habit),
            ("polarity", .polarity),
            ("kind", .memoryKind),
            ("periodType", .periodType),
            ("status", .insightStatus),
            ("role", .conversationRole),
            ("intent", .conversationIntent)
        ]
        for (field, expected) in fieldCases {
            let actual = HoloMetricSemanticFactory.dimension(
                forGrouping: HoloDynamicGrouping(type: .field, field: field)
            )
            expect(actual == expected, "字段 \(field) 应映射为 \(expected)")
        }
        // 未知字段不猜
        let unknown = HoloMetricSemanticFactory.dimension(
            forGrouping: HoloDynamicGrouping(type: .field, field: "merchant")
        )
        expect(unknown == nil, "未知分组字段应返回 nil，实际 \(String(describing: unknown))")
        // 无分组 → nil
        expect(HoloMetricSemanticFactory.dimension(forGrouping: nil) == nil, "无分组 dimension 应为 nil")

        // groupLabel：all / unknown / 无分组 → nil；普通 bucket key 保留
        let grouping = HoloDynamicGrouping(type: .field, field: "category")
        expect(HoloMetricSemanticFactory.groupLabel(forBucketKey: "all", grouping: grouping) == nil,
               "all bucket 的 groupLabel 应为 nil")
        expect(HoloMetricSemanticFactory.groupLabel(forBucketKey: "unknown", grouping: grouping) == nil,
               "unknown bucket 的 groupLabel 应为 nil")
        expect(HoloMetricSemanticFactory.groupLabel(forBucketKey: "餐饮", grouping: nil) == nil,
               "无分组时 groupLabel 应为 nil")
        expect(HoloMetricSemanticFactory.groupLabel(forBucketKey: "餐饮", grouping: grouping) == "餐饮",
               "groupLabel 应为 bucket key")
    }

    // MARK: - d) 旧 JSON 兼容与往返

    private static func test旧JSON解码兼容与语义往返() {
        let decoder = JSONDecoder()

        // 旧 HoloMetric JSON（无 semantic）可解码且 semantic == nil
        let legacyMetricJSON = """
        {"metricKey":"dynamic.finance_transactions.spend.餐饮","value":620.0,"unit":"元","baselineValue":500.0,"comparison":"餐饮"}
        """
        let legacyMetric = try! decoder.decode(HoloMetric.self, from: Data(legacyMetricJSON.utf8))
        expect(legacyMetric.semantic == nil, "旧 HoloMetric JSON 的 semantic 应为 nil")
        expect(legacyMetric.value == 620, "旧 HoloMetric JSON 解码值应正确")

        // 旧 HoloEvidenceRecord JSON（无 semantic）可解码且 semantic == nil
        let legacyRecordJSON = """
        {
          "id":"ev-1","dedupeKey":"job-1:finance:ev-1","sourceModule":"finance","sourceKind":"dynamic_query",
          "metricKey":"dynamic.finance_transactions.spend.all","metricValue":620.0,"unit":"元",
          "excerpt":"动态计算","redactedExcerpt":"动态计算","sensitivity":"normal","confidence":0.9,
          "status":"active","generatedBy":"holo_agent_tool","generatedAt":1753300000.0,
          "referencedByJobIDs":["job-1"],"referencedByMemoryIDs":[]
        }
        """
        let legacyRecord = try! decoder.decode(HoloEvidenceRecord.self, from: Data(legacyRecordJSON.utf8))
        expect(legacyRecord.semantic == nil, "旧 HoloEvidenceRecord JSON 的 semantic 应为 nil")

        // 含 semantic 的 HoloMetric 往返编解码
        let semantic = HoloMetricSemantic(
            domain: .finance,
            dataset: "finance.transactions",
            measure: .amount,
            operation: .difference,
            valueRole: .delta,
            dimension: .category,
            groupLabel: "餐饮",
            direction: .increase,
            currentValue: 620,
            baselineValue: 500,
            resultValue: 120,
            displayUnit: "元"
        )
        let metric = HoloMetric(
            metricKey: "dynamic.finance_transactions.delta.餐饮",
            value: 120, unit: "元", baselineValue: nil, comparison: "餐饮",
            semantic: semantic
        )
        let encoder = JSONEncoder()
        let roundTripped = try! decoder.decode(HoloMetric.self, from: try! encoder.encode(metric))
        expect(roundTripped.semantic == semantic, "HoloMetric semantic 应完整往返")

        // 含 semantic 的 HoloEvidenceRecord 往返编解码
        let record = HoloEvidenceRecord(
            id: "ev-2", dedupeKey: "dk-2", sourceModule: .finance, sourceID: "ev-2",
            sourceKind: "dynamic_query", timeRange: nil, occurredAt: nil,
            metricKey: metric.metricKey, metricValue: 120, unit: "元", baselineValue: nil,
            comparison: "餐饮", semantic: semantic,
            excerpt: "动态计算", redactedExcerpt: "动态计算",
            sensitivity: .normal, confidence: 0.9, status: .active,
            generatedBy: "holo_agent_tool", generatedAt: Date(timeIntervalSince1970: 1_753_300_000),
            referencedByJobIDs: ["job-1"], referencedByMemoryIDs: [], deviceID: nil
        )
        let roundTrippedRecord = try! decoder.decode(HoloEvidenceRecord.self, from: try! encoder.encode(record))
        expect(roundTrippedRecord.semantic == semantic, "HoloEvidenceRecord semantic 应完整往返")
    }

    // MARK: - e) 跨域工具语义

    private static func test跨域工具产出相关性与分组语义() async {
        let range = HoloAgentTimeRange(
            label: "最近一周",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 4 * 86_400)
        )
        // 4 个对齐日，两侧均有方差，可计算相关系数
        let stub = CrossDomainStub(rows: [
            "health.steps": (0..<4).map { day in
                HoloQueryRow(
                    id: "h\(day)",
                    occurredAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 3_600),
                    fields: ["value": .number(Double(day + 1) * 2_000)],
                    excerpt: "步数"
                )
            },
            "finance.transactions": (0..<4).map { day in
                HoloQueryRow(
                    id: "f\(day)",
                    occurredAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 7_200),
                    fields: ["amount": .number(Double(day + 1) * 50)],
                    excerpt: "交易"
                )
            }
        ])
        let tool = HoloCrossDomainTool(dataSource: stub)

        // correlation：measure = correlation，operation = correlation
        let correlationPlan = HoloCrossDomainQueryPlan(
            leftSource: "health.steps", leftField: "value",
            rightSource: "finance.transactions", rightField: "amount",
            operation: .correlation, minimumAlignedDays: 3, timeRange: range
        )
        let correlationResult = try! await tool.execute(HoloToolRequest(
            id: "req-correlation", tool: "cross_domain", query: "aligned_analysis",
            timeRange: range, baseline: nil, requiredMetrics: [], parameters: [:],
            crossDomainPlan: correlationPlan
        ))
        expect(correlationResult.status == .success, "correlation 跨域计划应成功")
        let correlationMetric = correlationResult.metrics.first
        let correlationSemantic = correlationMetric?.semantic
        expect(correlationSemantic?.measure == .correlation, "correlation 计划 measure 应为 correlation")
        expect(correlationSemantic?.operation == .correlation, "correlation 计划 operation 应为 correlation")
        expect(correlationSemantic?.valueRole == .current, "跨域指标 valueRole 应为 current")
        expect(correlationSemantic?.domain == .finance, "跨域 domain 应取右侧（因变量）source")
        expect(correlationSemantic?.dataset == "health.steps+finance.transactions",
               "跨域 dataset 应为 left+right 组合，实际 \(correlationSemantic?.dataset ?? "nil")")
        expect(correlationSemantic?.dimension == nil, "跨域 dimension 应为 nil")
        expect(correlationSemantic?.groupLabel == nil, "跨域 groupLabel 应为 nil")
        expect(correlationSemantic?.currentValue == correlationMetric?.value, "跨域 currentValue 应等于 metric value")
        expect(correlationSemantic?.displayUnit == "相关系数", "跨域 displayUnit 应为相关系数")
        expect(correlationResult.events.first?.semantic == correlationSemantic, "跨域事件应挂同一份语义")

        // conditionalAverage / groupComparison：operation 可表达，空 unit → measure none、displayUnit nil
        for (operation, expected): (HoloCrossDomainOperation, HoloMetricOperation) in [
            (.conditionalAverage, .conditionalAverage),
            (.groupComparison, .groupComparison)
        ] {
            let plan = HoloCrossDomainQueryPlan(
                leftSource: "health.steps", leftField: "value",
                rightSource: "finance.transactions", rightField: "amount",
                operation: operation, minimumAlignedDays: 3, timeRange: range
            )
            let result = try! await tool.execute(HoloToolRequest(
                id: "req-\(operation.rawValue)", tool: "cross_domain", query: "aligned_analysis",
                timeRange: range, baseline: nil, requiredMetrics: [], parameters: [:],
                crossDomainPlan: plan
            ))
            let semantic = result.metrics.first?.semantic
            expect(result.status == .success, "\(operation.rawValue) 跨域计划应成功")
            expect(semantic?.operation == expected, "\(operation.rawValue) 的语义 operation 应为 \(expected)")
            expect(semantic?.measure == HoloMetricMeasure.none, "\(operation.rawValue) 空单位的 measure 应为 none")
            expect(semantic?.displayUnit == nil, "\(operation.rawValue) 空单位的 displayUnit 应为 nil")
            expect(semantic?.baselineValue == result.metrics.first?.baselineValue,
                   "\(operation.rawValue) 的 baselineValue 应等于 calculated.baseline")
        }
    }

    // MARK: - 工具

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { fatalError(message) }
        return value
    }

    private struct CrossDomainStub: HoloCrossDomainDataSource {
        let rows: [String: [HoloQueryRow]]
        func rows(source: String, timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow] {
            rows[source] ?? []
        }
    }
}
