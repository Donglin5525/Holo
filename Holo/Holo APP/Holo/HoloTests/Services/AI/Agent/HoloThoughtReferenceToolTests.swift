//
//  HoloThoughtReferenceToolTests.swift
//  HoloTests
//

import Foundation

struct MockThoughtReferenceDataSource: HoloThoughtReferenceDataSource {
    let snapshot: HoloThoughtReferenceSnapshot
    func snapshot() async -> HoloThoughtReferenceSnapshot { snapshot }
}

@main
struct HoloThoughtReferenceToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test引用密度统计总数与被引用Top()
        try await test引用簇识别连通分量()
        try await test空引用返回empty()
        print("HoloThoughtReferenceToolTests passed")
    }

    private static func link(
        _ index: Int,
        sourceTitle: String,
        targetTitle: String,
        sourceId: UUID,
        targetId: UUID
    ) -> HoloThoughtLinkRecord {
        HoloThoughtLinkRecord(
            sourceId: sourceId,
            targetId: targetId,
            sourceFirstLine: sourceTitle,
            targetFirstLine: targetTitle,
            displayText: targetTitle,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(index) * 100)
        )
    }

    private static func request(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "thought_reference-\(query)", tool: "thought_reference", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func test引用密度统计总数与被引用Top() async throws {
        let hubA = UUID()
        let hubB = UUID()
        let c = UUID()
        let d = UUID()
        let snapshot = HoloThoughtReferenceSnapshot(links: [
            link(0, sourceTitle: "想法 C", targetTitle: "中心想法 A", sourceId: c, targetId: hubA),
            link(1, sourceTitle: "想法 D", targetTitle: "中心想法 A", sourceId: d, targetId: hubA),
            link(2, sourceTitle: "想法 D", targetTitle: "中心想法 B", sourceId: d, targetId: hubB)
        ])
        let result = try await HoloThoughtReferenceTool(
            dataSource: MockThoughtReferenceDataSource(snapshot: snapshot)
        ).execute(request("reference_density"))

        expect(result.status == .success, "reference_density 应成功")
        expect(result.sensitivity == .sensitive, "引用结构应标记 sensitive")
        let total = result.metrics.first { $0.metricKey == "thought.reference.total_count" }?.value
        expect(total == 3, "总引用数应为 3")
        // hubA 被引用 2 次，应排第一
        let topExcerpt = result.events.first?.excerpt ?? ""
        expect(topExcerpt.contains("中心想法 A") && topExcerpt.contains("被 2 条"), "应把被引用最多的 A 放第一，实际：\(topExcerpt)")
    }

    private static func test引用簇识别连通分量() async throws {
        // 簇 1：A - B - C 连通
        let a = UUID(), b = UUID(), c = UUID()
        // 簇 2：D - E 连通
        let d = UUID(), e = UUID()
        let snapshot = HoloThoughtReferenceSnapshot(links: [
            link(0, sourceTitle: "A", targetTitle: "B", sourceId: a, targetId: b),
            link(1, sourceTitle: "B", targetTitle: "C", sourceId: b, targetId: c),
            link(2, sourceTitle: "D", targetTitle: "E", sourceId: d, targetId: e)
        ])
        let result = try await HoloThoughtReferenceTool(
            dataSource: MockThoughtReferenceDataSource(snapshot: snapshot)
        ).execute(request("reference_clusters"))

        expect(result.status == .success, "reference_clusters 应成功")
        let clusterCount = result.metrics.first { $0.metricKey == "thought.reference.cluster_count" }?.value
        expect(clusterCount == 2, "应有 2 个连通分量")
        let maxSize = result.metrics.first { $0.metricKey == "thought.reference.cluster_size" }?.value
        expect(maxSize == 3, "最大簇应为 3 个想法")
    }

    private static func test空引用返回empty() async throws {
        let result = try await HoloThoughtReferenceTool(
            dataSource: MockThoughtReferenceDataSource(snapshot: HoloThoughtReferenceSnapshot(links: []))
        ).execute(request("reference_density"))

        expect(result.status == .empty, "空引用应返回 empty")
        expect(result.warnings.contains { $0.code == "NO_REFERENCE_DATA" }, "应返回 NO_REFERENCE_DATA")
    }
}
