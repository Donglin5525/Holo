//
//  VerifyExpressionEngine.swift
//  表达式引擎验证脚本（standalone，不依赖 Xcode test target）
//
//  用法：swift VerifyExpressionEngine.swift
//  验证表达式树的求值器、校验器、采样器核心逻辑。
//

import Foundation

// MARK: - 复制核心逻辑（与 HoloDataTool.swift 中的实现保持一致）

indirect enum ExpressionNode: Equatable {
    case constant(Double)
    case metric(String)
    case add(ExpressionNode, ExpressionNode)
    case subtract(ExpressionNode, ExpressionNode)
    case multiply(ExpressionNode, ExpressionNode)
    case divide(ExpressionNode, ExpressionNode)
}

enum ExpressionEvaluator {
    static func evaluate(_ node: ExpressionNode, metrics: [String: Double]) -> Double? {
        switch node {
        case .constant(let v): return v.isFinite ? v : nil
        case .metric(let id): return metrics[id]
        case .add(let l, let r):
            guard let lv = evaluate(l, metrics: metrics), let rv = evaluate(r, metrics: metrics) else { return nil }
            return lv + rv
        case .subtract(let l, let r):
            guard let lv = evaluate(l, metrics: metrics), let rv = evaluate(r, metrics: metrics) else { return nil }
            return lv - rv
        case .multiply(let l, let r):
            guard let lv = evaluate(l, metrics: metrics), let rv = evaluate(r, metrics: metrics) else { return nil }
            return lv * rv
        case .divide(let l, let r):
            guard let lv = evaluate(l, metrics: metrics), let rv = evaluate(r, metrics: metrics), abs(rv) > 1e-9 else { return nil }
            return lv / rv
        }
    }
}

struct ExpressionStats {
    var depth: Int
    var nodeCount: Int
    var referencedMetricIDs: Set<String>
}

enum ExpressionValidator {
    static func analyze(_ node: ExpressionNode) -> ExpressionStats {
        var stats = ExpressionStats(depth: 0, nodeCount: 0, referencedMetricIDs: [])
        walk(node, currentDepth: 1, stats: &stats)
        return stats
    }

    private static func walk(_ node: ExpressionNode, currentDepth: Int, stats: inout ExpressionStats) {
        stats.nodeCount += 1
        stats.depth = max(stats.depth, currentDepth)
        switch node {
        case .constant: break
        case .metric(let id): stats.referencedMetricIDs.insert(id)
        case .add(let l, let r), .subtract(let l, let r),
             .multiply(let l, let r), .divide(let l, let r):
            walk(l, currentDepth: currentDepth + 1, stats: &stats)
            walk(r, currentDepth: currentDepth + 1, stats: &stats)
        }
    }
}

// MARK: - 测试数据结构（模拟查询行）

struct SimRow {
    var id: String
    var amount: Double
    var text: String
}

// MARK: - 测试

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name): 期望 \(expected)，实际 \(actual)")
    }
}

func assertNil(_ name: String, _ value: Double?) {
    if value == nil {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name): 期望 nil，实际 \(value!)")
    }
}

func assertNotNil(_ name: String, _ value: Double?) {
    if value != nil {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name): 期望非 nil，实际 nil")
    }
}

// === 求值器测试 ===

print("\n=== 求值器测试 ===")

// 常量
assertEqual("常量求值", ExpressionEvaluator.evaluate(.constant(42), metrics: [:])!, 42.0)

// 指标引用
assertEqual("指标引用", ExpressionEvaluator.evaluate(.metric("cartons"), metrics: ["cartons": 3])!, 3.0)

// 指标缺失
assertNil("指标缺失返回nil", ExpressionEvaluator.evaluate(.metric("missing"), metrics: [:]))

// 嵌套算术：(200×3 + 20×5) ÷ 30 = 700÷30 ≈ 23.333
let smokingNode: ExpressionNode = .divide(
    .add(
        .multiply(.constant(200), .metric("cartons")),
        .multiply(.constant(20), .metric("packs"))
    ),
    .constant(30)
)
let smokingResult = ExpressionEvaluator.evaluate(smokingNode, metrics: ["cartons": 3.0, "packs": 5.0])!
assertEqual("算烟嵌套算术", round(smokingResult * 1000) / 1000, 23.333)

// 除零保护
assertNil("除零返回nil", ExpressionEvaluator.evaluate(.divide(.constant(100), .constant(0)), metrics: [:]))

// 减法
assertEqual("减法", ExpressionEvaluator.evaluate(.subtract(.metric("a"), .metric("b")), metrics: ["a": 500, "b": 300])!, 200.0)

// 无限常量
assertNil("Infinity常量返回nil", ExpressionEvaluator.evaluate(.constant(.infinity), metrics: [:]))

// === 校验器测试 ===

print("\n=== 校验器测试 ===")

// 深度和节点数：((a+b)+c) → 深度3，节点5
let nestedNode: ExpressionNode = .add(.add(.metric("a"), .metric("b")), .metric("c"))
let stats = ExpressionValidator.analyze(nestedNode)
assertEqual("深度3", stats.depth, 3)
assertEqual("节点5", stats.nodeCount, 5)
assertEqual("引用3个指标", stats.referencedMetricIDs, Set(["a", "b", "c"]))

// 算烟的树深度
let smokingStats = ExpressionValidator.analyze(smokingNode)
print("   算烟表达式深度=\(smokingStats.depth)，节点数=\(smokingStats.nodeCount)")
assertEqual("算烟深度≤6", smokingStats.depth <= 6, true)
assertEqual("算烟节点≤20", smokingStats.nodeCount <= 20, true)

// 7层深嵌套应被拒绝（深度>6）
var deepNode: ExpressionNode = .constant(1)
for _ in 0..<7 { deepNode = .add(deepNode, .constant(1)) }
let deepStats = ExpressionValidator.analyze(deepNode)
assertEqual("7层嵌套深度>6", deepStats.depth > 6, true)

// === 算烟场景端到端模拟 ===

print("\n=== 算烟场景端到端 ===")

// 测试数据：3条>200（一条），5条20-30（一包），2条其它
let rows: [SimRow] = [
    SimRow(id: "t1", amount: 230, text: "烟"),
    SimRow(id: "t2", amount: 250, text: "烟"),
    SimRow(id: "t3", amount: 210, text: "烟"),
    SimRow(id: "t4", amount: 25, text: "烟"),
    SimRow(id: "t5", amount: 28, text: "烟"),
    SimRow(id: "t6", amount: 22, text: "烟"),
    SimRow(id: "t7", amount: 30, text: "烟"),
    SimRow(id: "t8", amount: 20, text: "烟"),
    SimRow(id: "t9", amount: 15, text: "水"),
    SimRow(id: "t10", amount: 50, text: "饭"),
]

// 分档计数（模拟引擎的 count + filter）
let cartonCount = Double(rows.filter { $0.amount > 200 }.count)
let packCount = Double(rows.filter { $0.amount >= 20 && $0.amount <= 30 }.count)

assertEqual("一条烟计数=3", cartonCount, 3.0)
assertEqual("一包烟计数=5", packCount, 5.0)

// 表达式求值：200×3 + 20×5 = 700（不含除法的总根数表达式）
let totalRootsNode: ExpressionNode = .add(
    .multiply(.constant(200), .metric("cartons")),
    .multiply(.constant(20), .metric("packs"))
)
let totalRoots = ExpressionEvaluator.evaluate(totalRootsNode, metrics: [
    "cartons": cartonCount, "packs": packCount
])!
assertEqual("总根数=700", totalRoots, 700.0)

// perDay：700÷30 ≈ 23.333
let dailyAvg = totalRoots / 30.0
assertEqual("日均根数≈23.33", round(dailyAvg * 100) / 100, 23.33)

// === 通用性验证：其他场景 ===

print("\n=== 通用性验证 ===")

// 占比：烟支出 ÷ 总支出
let smokeAmount = rows.filter { $0.text == "烟" }.reduce(0) { $0 + $1.amount }
let totalAmount = rows.reduce(0) { $0 + $1.amount }
let ratioNode: ExpressionNode = .divide(.constant(smokeAmount), .constant(totalAmount))
let ratio = ExpressionEvaluator.evaluate(ratioNode, metrics: [:])!
print("   烟支出=\(smokeAmount)，总支出=\(totalAmount)，占比=\(round(ratio * 1000) / 10)%")
assertNotNil("占比计算成功", ratio)

// 差值：本月 - 上月
let diffNode: ExpressionNode = .subtract(.metric("this_month"), .metric("last_month"))
let diff = ExpressionEvaluator.evaluate(diffNode, metrics: ["this_month": 1200, "last_month": 800])!
assertEqual("环比差值=400", diff, 400.0)

// === 结果汇总 ===

print("\n=== 结果汇总 ===")
print("通过：\(passed)，失败：\(failed)")
if failed > 0 {
    print("❌ 有失败用例")
    exit(1)
} else {
    print("🎉 全部通过")
}
