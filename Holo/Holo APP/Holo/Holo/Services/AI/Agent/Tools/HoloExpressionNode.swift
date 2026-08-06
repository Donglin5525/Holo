//
//  HoloExpressionNode.swift
//  Holo
//
//  Agent 自由表达式计算引擎的核心数据结构。
//  让 Agent 能处理「分档 → 换算 → 派生」类个性化计算（如算日均抽烟根数），
//  不再为每类需求新增固定操作符。
//
//  安全边界：仅常量 + 指标引用 + 加减乘除，禁止函数/循环/自由代码。
//  手写 Codable（discriminator 模式，与 HoloQueryValue 风格一致）。
//

import Foundation

// MARK: - 表达式树节点

/// 递归表达式树。只有 6 种节点，构成闭集，模型无法生成其他结构。
nonisolated indirect enum HoloExpressionNode: Equatable, Sendable {
    case constant(Double)
    case metric(String)                              // 引用 plan.aggregations 里的 id
    case add(HoloExpressionNode, HoloExpressionNode)
    case subtract(HoloExpressionNode, HoloExpressionNode)
    case multiply(HoloExpressionNode, HoloExpressionNode)
    case divide(HoloExpressionNode, HoloExpressionNode)

    /// 手写 Codable：JSON 里用 type 字段区分节点种类（discriminator 模式）。
    /// 与项目现有 HoloQueryValue 的 Codable 风格一致。
    private enum CodingKeys: String, CodingKey {
        case type, value, id, left, right
    }
    private enum NodeType: String, Codable {
        case constant, metric, add, subtract, multiply, divide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(NodeType.self, forKey: .type) {
        case .constant:
            self = .constant(try c.decode(Double.self, forKey: .value))
        case .metric:
            self = .metric(try c.decode(String.self, forKey: .id))
        case .add:
            self = .add(try c.decode(HoloExpressionNode.self, forKey: .left),
                        try c.decode(HoloExpressionNode.self, forKey: .right))
        case .subtract:
            self = .subtract(try c.decode(HoloExpressionNode.self, forKey: .left),
                             try c.decode(HoloExpressionNode.self, forKey: .right))
        case .multiply:
            self = .multiply(try c.decode(HoloExpressionNode.self, forKey: .left),
                             try c.decode(HoloExpressionNode.self, forKey: .right))
        case .divide:
            self = .divide(try c.decode(HoloExpressionNode.self, forKey: .left),
                           try c.decode(HoloExpressionNode.self, forKey: .right))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .constant(let v):
            try c.encode(NodeType.constant, forKey: .type)
            try c.encode(v, forKey: .value)
        case .metric(let id):
            try c.encode(NodeType.metric, forKey: .type)
            try c.encode(id, forKey: .id)
        case .add(let l, let r):
            try c.encode(NodeType.add, forKey: .type)
            try c.encode(l, forKey: .left); try c.encode(r, forKey: .right)
        case .subtract(let l, let r):
            try c.encode(NodeType.subtract, forKey: .type)
            try c.encode(l, forKey: .left); try c.encode(r, forKey: .right)
        case .multiply(let l, let r):
            try c.encode(NodeType.multiply, forKey: .type)
            try c.encode(l, forKey: .left); try c.encode(r, forKey: .right)
        case .divide(let l, let r):
            try c.encode(NodeType.divide, forKey: .type)
            try c.encode(l, forKey: .left); try c.encode(r, forKey: .right)
        }
    }
}

extension HoloExpressionNode: Codable {}

// MARK: - 求值器

/// 递归求值表达式树。返回 nil 表示引用缺失或除零（不崩溃，由上层标记 warning）。
nonisolated enum HoloExpressionEvaluator {

    /// 求值。metrics 是 id → value 的映射。
    static func evaluate(_ node: HoloExpressionNode, metrics: [String: Double]) -> Double? {
        switch node {
        case .constant(let v):
            return v.isFinite ? v : nil
        case .metric(let id):
            return metrics[id]
        case .add(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics) else { return nil }
            return (lv + rv).isFinite ? lv + rv : nil
        case .subtract(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics) else { return nil }
            return (lv - rv).isFinite ? lv - rv : nil
        case .multiply(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics) else { return nil }
            return (lv * rv).isFinite ? lv * rv : nil
        case .divide(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics), abs(rv) > 1e-9 else { return nil }
            let result = lv / rv
            return result.isFinite ? result : nil
        }
    }

    /// 生成人类可读的公式串，用于结果展示和调试。
    static func describe(_ node: HoloExpressionNode) -> String {
        switch node {
        case .constant(let v): return String(format: "%g", v)
        case .metric(let id): return id
        case .add(let l, let r): return "(\(describe(l)) + \(describe(r)))"
        case .subtract(let l, let r): return "(\(describe(l)) - \(describe(r)))"
        case .multiply(let l, let r): return "(\(describe(l)) × \(describe(r)))"
        case .divide(let l, let r): return "(\(describe(l)) ÷ \(describe(r)))"
        }
    }
}

// MARK: - 校验器

/// 分析表达式树的复杂度与引用合法性。
nonisolated enum HoloExpressionValidator {

    struct Stats {
        var depth: Int
        var nodeCount: Int
        var referencedMetricIDs: Set<String>
        var constants: [Double]
    }

    /// 遍历表达式树，收集深度、节点数、引用的 metric id、常量列表。
    static func analyze(_ node: HoloExpressionNode) -> Stats {
        var stats = Stats(depth: 0, nodeCount: 0, referencedMetricIDs: [], constants: [])
        walk(node, currentDepth: 1, stats: &stats)
        return stats
    }

    private static func walk(_ node: HoloExpressionNode, currentDepth: Int, stats: inout Stats) {
        stats.nodeCount += 1
        stats.depth = max(stats.depth, currentDepth)
        switch node {
        case .constant(let v):
            stats.constants.append(v)
        case .metric(let id):
            stats.referencedMetricIDs.insert(id)
        case .add(let l, let r), .subtract(let l, let r),
             .multiply(let l, let r), .divide(let l, let r):
            walk(l, currentDepth: currentDepth + 1, stats: &stats)
            walk(r, currentDepth: currentDepth + 1, stats: &stats)
        }
    }
}
