//
//  HoloThoughtReferenceTool.swift
//  Holo
//
//  想法引用结构工具：读取想法之间的 @ 引用关系，产出结构信号
//  （引用密度、被引用最多的想法、引用簇），帮 agent 理解用户的想法网络。
//
//  隐私边界：
//  - 只输出结构信号，原文一律用 firstLine 摘录或 displayText 快照
//  - 不展开想法正文，符合现有 thought 工具的脱敏边界
//

import Foundation

// MARK: - Value Types (tool-local)

/// 一条引用关系（有向：source → target）。
struct HoloThoughtLinkRecord: Codable, Equatable, Sendable {
    var sourceId: UUID
    var targetId: UUID
    var sourceFirstLine: String?
    var targetFirstLine: String?
    var displayText: String?
    var createdAt: Date?
}

struct HoloThoughtReferenceSnapshot: Codable, Equatable, Sendable {
    /// 所有有效引用（两端想法均未软删除/归档）。
    var links: [HoloThoughtLinkRecord]
    /// 被引用过的想法 id 集合（target 维度）。
    var referencedThoughtIds: Set<UUID> { Set(links.map { $0.targetId }) }
    /// 参与引用的任意一端的 id 集合。
    var involvedThoughtIds: Set<UUID> {
        Set(links.flatMap { [$0.sourceId, $0.targetId] })
    }
}

// MARK: - DataSource Protocol

protocol HoloThoughtReferenceDataSource: Sendable {
    func snapshot() async -> HoloThoughtReferenceSnapshot
}

// MARK: - Tool

struct HoloThoughtReferenceTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "thought_reference",
        description: "想法之间的引用关系结构（引用密度 / 被引用最多的想法 / 引用簇）",
        supportedQueries: ["reference_density", "reference_clusters"],
        supportedTimeRanges: ["recent", "30d", "90d"],
        outputMetrics: [
            "thought.reference.total_count",
            "thought.reference.top_cited_count",
            "thought.reference.cluster_count",
            "thought.reference.cluster_size"
        ],
        sensitivityPolicy: "sensitive"
    )

    private let dataSource: HoloThoughtReferenceDataSource

    init(dataSource: HoloThoughtReferenceDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的想法引用查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let snapshot = await dataSource.snapshot()
        guard !snapshot.links.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_REFERENCE_DATA", message: "没有可用的想法引用关系")
            ])
        }
        switch request.query {
        case "reference_density":
            return referenceDensity(request: request, snapshot: snapshot)
        case "reference_clusters":
            return referenceClusters(request: request, snapshot: snapshot)
        default:
            return empty(request: request, warnings: [
                HoloToolWarning(code: "UNSUPPORTED_QUERY", message: "不支持的想法引用查询：\(request.query)")
            ])
        }
    }
}

// MARK: - Query Implementations

private extension HoloThoughtReferenceTool {

    /// reference_density：总引用数 + 被引用最多的 Top5 想法（首行摘录）。
    func referenceDensity(request: HoloToolRequest, snapshot: HoloThoughtReferenceSnapshot) -> HoloDataToolResult {
        let links = snapshot.links
        let total = links.count

        // 被引用计数：target 维度
        let citedCounts = Dictionary(grouping: links, by: { $0.targetId })
            .mapValues { $0.count }
        let topCited = citedCounts.sorted { $0.value > $1.value }.prefix(5)

        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "thought.reference.total_count", value: Double(total), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "thought.reference.top_cited_count", value: Double(topCited.count), unit: "个", baselineValue: nil, comparison: nil)
        ]

        let events: [HoloEvidenceEvent] = topCited.enumerated().map { index, pair in
            let (thoughtId, count) = pair
            // 取一条指向该想法的 link 来拿显示文本
            let sample = links.first { $0.targetId == thoughtId }
            let label = sample?.targetFirstLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? sample?.targetFirstLine
                : sample?.displayText
            let title = Self.displayLabel(label)
            return HoloEvidenceEvent(
                id: "\(request.id)-density-\(index)-\(thoughtId.uuidString.prefix(8))",
                occurredAt: sample?.createdAt,
                metricKey: "thought.reference.top_cited_count",
                metricValue: Double(count),
                excerpt: "被引用最多的想法「\(title)」被 \(count) 条想法引用"
            )
        }
        return success(request: request, metrics: metrics, events: events)
    }

    /// reference_clusters：用并查集算连通分量，给出 Top 几个引用簇。
    func referenceClusters(request: HoloToolRequest, snapshot: HoloThoughtReferenceSnapshot) -> HoloDataToolResult {
        let links = snapshot.links
        var uf = HoloUnionFind<UUID>()
        for link in links {
            uf.union(link.sourceId, link.targetId)
        }
        let clusters = Dictionary(grouping: links.flatMap { [$0.sourceId, $0.targetId] }) { uf.find($0) ?? $0 }
            .values
            .map { Set($0) }
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
        guard !clusters.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_CLUSTER_DATA", message: "想法引用图没有形成任何连通分量")
            ])
        }

        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "thought.reference.cluster_count", value: Double(clusters.count), unit: "个", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "thought.reference.cluster_size", value: Double(clusters.first?.count ?? 0), unit: "个", baselineValue: nil, comparison: "最大簇")
        ]

        let events: [HoloEvidenceEvent] = clusters.prefix(6).enumerated().map { index, cluster in
            // 取簇内任一想法的首行作为代表
            let representative = links.first { cluster.contains($0.sourceId) || cluster.contains($0.targetId) }
            let label = representative?.sourceFirstLine ?? representative?.displayText
            let title = Self.displayLabel(label)
            return HoloEvidenceEvent(
                id: "\(request.id)-cluster-\(index)",
                occurredAt: representative?.createdAt,
                metricKey: "thought.reference.cluster_size",
                metricValue: Double(cluster.count),
                excerpt: "引用簇 \(index + 1)：围绕「\(title)」的 \(cluster.count) 个想法相互关联"
            )
        }
        return success(request: request, metrics: metrics, events: events)
    }

    // MARK: - Helpers

    func success(request: HoloToolRequest, metrics: [HoloMetric], events: [HoloEvidenceEvent]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil,
            sensitivity: .sensitive
        )
    }

    func empty(request: HoloToolRequest, warnings: [HoloToolWarning]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .empty,
            coverage: nil, metrics: [], events: [], warnings: warnings, error: nil,
            sensitivity: .sensitive
        )
    }

    /// 没有可用文本时给一个占位标签，避免 evidence 出现空标题。
    static func displayLabel(_ text: String?) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "（无标题想法）" : trimmed
    }
}

// MARK: - 并查集（用于引用簇连通分量计算）

private struct HoloUnionFind<Element: Hashable> {
    private var parent: [Element: Element] = [:]

    mutating func find(_ x: Element) -> Element? {
        if parent[x] == nil { parent[x] = x }
        var current = x
        while let p = parent[current], p != current {
            current = p
        }
        // 路径压缩
        var node = x
        while let p = parent[node], p != current {
            parent[node] = current
            node = p
        }
        return current
    }

    mutating func union(_ a: Element, _ b: Element) {
        guard let rootA = find(a), let rootB = find(b) else { return }
        if rootA != rootB { parent[rootB] = rootA }
    }
}
