# Agent 自由表达式计算引擎 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 Agent 能处理用户「千奇百怪」的个性化计算需求（如「按金额分档算烟、换算根数、求日均」），不再为每类需求被动新增固定操作符。核心手段：把确定性计算引擎从「固定菜单」升级为「可自由组合的表达式树」，并引入「10条样本验证 + 显性告知」机制校准分档条件。

**Architecture:** 不引入自由代码执行、不开沙箱。在现有 `dynamic_query` 体系上新增一种派生操作 `expression`，以受限的递归表达式树（仅常量/指标引用/加减乘除）覆盖所有算术类需求。新增本地采样器取 10 条多样化样本供模型校准，通过 Chat 卡片显性告知用户查看了哪些数据。全量计算仍在本地精确执行，仅样本数据经 HOLO 后端网关送模型。

**Tech Stack:** Swift（CoreData / 现有 Agent Runtime），SwiftUI（样本告知卡片），XCTest 纯逻辑测试。

---

## 一、背景：为什么要做这件事

### 1.1 问题本质

用户会提出各种现有固定算法覆盖不到的计算需求，例如：

> 「账单里超过 200 的是一条烟，20-30 元的是一包，一包 20 根，算算我日均抽几根」

这类需求的共同结构是 **「分档 → 换算 → 派生」**：

1. **分档**：把数据按条件切成几堆（>200 一堆、20-30 一堆）
2. **换算**：每堆乘系数再合并（一堆×200 + 一堆×20 = 总根数）
3. **派生**：对结果再加工（÷天数 = 日均）

现有引擎的第①步（分档计数/求和）和第③步（perDay/ratio 等）都能做，**唯独第②步「乘系数再合并」是空白**。如果只补一个固定操作符，下次遇到新需求还得再补——永远穷举不完。

### 1.2 设计决策（已与东林确认）

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 通用性策略 | 可递归组合的表达式树 | 模型自由编排，不再穷举 |
| 安全边界 | 仅常量 + 指标引用 + `+ - × ÷` | 守住「禁止自由代码/SQL」红线 |
| 系数来源 | 每次问时口头说，不持久化用户规则 | 改动最小，MVP 先跑通 |
| 数据校准 | 取 10 条样本送模型验证分档条件 | 模型看不到真实数据就会盲猜分档阈值 |
| 用户知情 | 显性卡片告知查看了哪些数据 | 隐私透明，用户有知情权 |
| 是否支持四则运算 | 是（不止加权求和） | 覆盖占比、差值、合计等更多场景 |

### 1.3 类比

把现有引擎想象成一家「只有固定套餐的餐厅」——7 个套餐（7 种操作符），模型只能点套餐。本方案把它升级为「自选配料」：备好基础食材（筛数据、计数、求和）和调味料（加减乘除），让模型当厨师现场搭配。10 条样本验证就是「厨师上菜前先尝一口确认味道」，对了再正式做全量的。

---

## 二、核心设计

### 2.1 表达式树（Engine 升级的核心）

现有派生操作符是「扁平」的——一个操作符只做一件事（如 `perDay` 把一个指标除以天数）。表达式树是「立体的」——可以递归嵌套，表达力指数级增长。

**只有 5 种零件，不多不少：**

| 零件 | 类型 | 含义 | 举例 |
|------|------|------|------|
| 常量节点 | `.constant(Double)` | 固定数字 | `200`（一条多少根）、`30`（天数） |
| 指标引用节点 | `.metric(String)` | 引用本计划内已定义的聚合结果 | `"carton_count"`（>200元笔数） |
| 加法节点 | `.add(left, right)` | 两棵子树相加 | 根数A + 根数B |
| 乘法节点 | `.multiply(left, right)` | 两棵子树相乘 | `200 × carton_count` |
| 减法/除法 | `.subtract` / `.divide` | 两棵子树相减/相除 | 烟支出 ÷ 总支出 |

**「算烟」的表达式树形态：**

```
                        [÷]              ← 日均根数
                       /   \
                    [+]      30          ← 天数（常量）
                   /   \
                [×]     [×]
               /  \     /  \
             200  A   20   B
            (常量)(指标)(常量)(指标)

A = carton_count  (聚合：count, filter: amount > 200)
B = pack_count    (聚合：count, filter: amount ≥ 20 AND amount ≤ 30)
```

人话翻译：`(200 × A + 20 × B) ÷ 30`。底层 A、B 用现有引擎的分档计数算出，完全不改。

**同一套零件搭出的其他结构（通用性验证）：**

| 用户问的 | 表达式树 |
|---------|---------|
| 烟钱占总支出比例 | `smoke_amount ÷ total_amount` |
| 这月比上月多抽几包 | `this_month_roots - last_month_roots` |
| 平均每包烟花多少 | `smoke_amount ÷ pack_count` |
| 打车换算短途趟数 | `(3 × big_rides + 1.5 × mid_rides) ÷ days` |
| 咖啡+奶茶日均杯数 | `(coffee + tea) ÷ days` |

**全部是同一套积木，不为任何一个专门写代码。**

### 2.2 安全护栏

表达式树虽灵活，但必须有边界，防止模型生成荒谬或危险的结构：

| 护栏 | 限制 | 实现位置 |
|------|------|---------|
| 操作符白名单 | 仅 `+ - × ÷`，无函数/循环/代码 | 枚举闭集 |
| 树深度 | ≤ 6 层嵌套 | `validate()` 递归计数 |
| 节点总数 | ≤ 20 个 | `validate()` 遍历计数 |
| 系数合法性 | 必须是有限实数（非 NaN/Infinity） | `validate()` 用 `isFinite` |
| 除零保护 | 分母为 0 时返回 nil + warning，不崩溃 | `derive()` 执行时检查 |
| 指标引用 | 必须指向同计划内已定义的聚合 id | `validate()` 校验 metricID 存在 |
| 聚合复用 | 沿用现有校验：aggregations ≤ 5，filters ≤ 10 | 不改 |

### 2.3 10 条样本验证

#### 为什么需要

模型不看到真实数据，就不知道分档阈值写得对不对。比如模型可能写出「金额 > 2000 算一条烟」，但它不知道你的账单里烟的实际金额分布。看了 10 条真实数据，它就能校准为「>200 算一条、20-30 算一包」。

#### 关键设计原则：样本在表达式生成之前给到模型

> **样本不是事后验证，而是事前校准。** 必须先让模型看到真实数据，它才能写对分档条件。

这意味着完整的计算是**两轮**的：
1. **轮 1（探查）**：模型先请求查「最近 30 天账单」，引擎返回聚合结果**并附带 10 条样本** → 模型据此校准分档条件，生成 expression plan
2. **轮 2（计算）**：引擎按 expression plan 全量精确执行

这一设计不改变 runLoop 主循环结构——HOLO 现有的 agent loop 本来就是多轮的。关键改动是：**让 dynamic_query 的返回结果附带 10 条样本**，而不是另搞一个独立的采样器。这样模型在任何一轮查询后都能看到样本，下一轮再生成 expression。

#### 样本从哪来

样本**复用引擎查询时的数据**，不二次查库。具体来说：引擎执行 dynamicPlan 时已经把全量数据加载成 `HoloQueryRow`，从中采样 10 条附在结果里返回即可。详见 4.5 节。

#### 采样策略（客户端执行）

- 从该次查询返回的 rows 中采样，最多 10 条
- 优先覆盖不同金额档位（大/中/小），让模型看到数据分布
- 若用户问题含关键词（如「烟」「咖啡」），优先取备注含该词的记录
- 不足 10 条时取全部，不凑数

#### 显性告知（Chat 卡片）

当一次查询附带样本时，向用户展示一个明确的卡片：

```
┌─────────────────────────────────────────────┐
│  📋 为了准确理解您的计算需求，                              │
│  我查看了您最近的 10 条账单样本：                          │
│                                                │
│  · 7月15日 餐饮 午饭 -¥28                        │
│  · 7月16日 购物 烟 -¥230                         │
│  · 7月18日 购物 烟 -¥25                          │
│  · 7月20日 购物 烟 -¥210                         │
│  · ...（共10条）                                  │
│                                                │
│  这些数据仅用于校准计算规则，                          │
│  实际全量计算在本地完成。                              │
└─────────────────────────────────────────────┘
```

---

## 三、全景数据流

```
用户提问：「算算我日均抽几根烟」
        │
        ▼
┌─ ① 轮1：模型请求查询（自行决定用哪种查询方式）────┐
│   模型基于用户问题 + 工具描述，决定：                 │
│   - 简单查询 → 走现有 dynamic_query（固定操作符）     │
│   - 复杂换算 → 先查数据看分布，下轮再出 expression  │
│   这是模型在 prompt 引导下的隐含决策，不是代码分支      │
└──────────────────────────────────────────────────┘
        │ 模型发出 toolRequest: dynamic_query
        ▼
┌─ ② 引擎执行查询 + 附带 10 条样本 ─────────────────┐
│   全量数据本地查询、聚合                                │
│   从返回 rows 中采样 10 条附在结果里                    │
│   展示告知卡片（用户看到查了哪些数据）                  │
└──────────────────────────────────────────────────┘
        │ 引擎结果（含样本）回灌给模型
        ▼
┌─ ③ 轮2：模型看到样本，生成表达式树 ───────────────┐
│   输入：聚合结果 + 10 条样本 + 用户规则               │
│   模型校准分档条件，输出 expression plan               │
│   规则不全 → 追问用户（走现有 clarification）          │
└──────────────────────────────────────────────────┘
        │ 模型发出 toolRequest: dynamic_query（含 expression）
        ▼
┌─ ④ 本地引擎执行：全量数据精确计算 ────────────────┐
│   数据不过模型，本地算完                              │
│   expression 递归求值 + perDay 等派生                │
└──────────────────────────────────────────────────┘
        │
        ▼
    ⑤ 展示结果（含计算公式、数据来源）
```

**数据流向明确**：仅第②步的 10 条样本经 HOLO 后端网关（`api.holoapp.cn`）送模型，走现有 AI 请求同一通道。全量数据全程在本地。

**关键**：这是标准的多轮 agent loop，不改 runLoop 主循环结构。模型天生可以一轮查数据、下一轮出计划——现有机制完全支持。

---

## 四、详细技术设计

### 4.1 新增数据结构

**文件：`HoloDataTool.swift`（`HoloDynamicDerivation` 定义附近，约 L128-135）**

```swift
// 新增：表达式树节点
nonisolated indirect enum HoloExpressionNode: Equatable, Sendable {
    case constant(Double)
    case metric(String)                              // 引用 plan.aggregations 里的 id
    case add(HoloExpressionNode, HoloExpressionNode)
    case subtract(HoloExpressionNode, HoloExpressionNode)
    case multiply(HoloExpressionNode, HoloExpressionNode)
    case divide(HoloExpressionNode, HoloExpressionNode)
}
```

`indirect enum` 是 Swift 处理递归类型的关键字——它允许节点引用自身，从而形成树。

**⚠️ Codable 必须手写，不能自动合成。** Swift 编译器不会为带有关联值的递归 enum 自动合成 Codable 实现。需手写 `init(from:)` / `encode(to:)`，采用与项目现有 `HoloQueryValue`（`HoloDataTool.swift:74-97`）相同的 discriminator 模式：JSON 里带一个 `type` 字段标识节点种类。

对应的 JSON 格式（注意：与自动合成的格式不同）：

```json
{ "type": "constant", "value": 200 }
{ "type": "metric", "id": "carton_count" }
{ "type": "add", "left": { ... }, "right": { ... } }
{ "type": "divide", "left": { ... }, "right": { ... } }
```

```swift
// 扩展 HoloDynamicDerivationOperator：新增 expression
nonisolated enum HoloDynamicDerivationOperator: String, Codable, Sendable {
    case difference, ratio, percentageChange, rate, perDay, linearTrend, coverage
    case expression    // ← 新增
}

// 扩展 HoloDynamicDerivation：新增表达式树字段
nonisolated struct HoloDynamicDerivation: Codable, Equatable, Sendable {
    var id: String
    var operation: HoloDynamicDerivationOperator
    var metricID: String
    var denominatorMetricID: String? = nil
    var unit: String? = nil
    var expression: HoloExpressionNode? = nil     // ← 新增：operation == .expression 时使用
}
```

**设计说明：** `expression` 字段只在 `operation == .expression` 时有意义，其余派生操作忽略它。这样不破坏现有 `HoloDynamicDerivation` 的结构，旧代码零改动。

### 4.2 引擎执行逻辑

**文件：`HoloDataTool.swift`（`HoloDynamicQueryEngine.derive()` 函数内，约 L1311-1389）**

在现有 `derive()` 的 `switch spec.operation` 中新增 `.expression` 分支：

```swift
case .expression:
    // 收集到本轮所有已算出的 metric，建立 id → value 索引
    let resolved: [String: Double] = Dictionary(
        uniqueKeysWithValues: metrics.compactMap {
            guard let v = $0.value,
                  let id = extractAggregationID(from: $0.metricKey) else { return nil }
            return (id, v)
        }
    )
    // 递归求值表达式树
    if let node = spec.expression,
       let result = HoloExpressionEvaluator.evaluate(node, metrics: resolved) {
        value = result
        formula = HoloExpressionEvaluator.describe(node)   // 生成人类可读公式串
    } else {
        value = nil   // 引用缺失或除零 → 返回空
        formula = "expression(unresolved)"
    }
```

**独立的求值器（同文件新增）：**

```swift
nonisolated enum HoloExpressionEvaluator {
    /// 递归求值；返回 nil 表示引用缺失或除零。
    static func evaluate(_ node: HoloExpressionNode, metrics: [String: Double]) -> Double? {
        switch node {
        case .constant(let v): return v
        case .metric(let id):
            return metrics[id]
        case .add(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics) else { return nil }
            return lv + rv
        case .subtract(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics) else { return nil }
            return lv - rv
        case .multiply(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics) else { return nil }
            return lv * rv
        case .divide(let l, let r):
            guard let lv = evaluate(l, metrics: metrics),
                  let rv = evaluate(r, metrics: metrics), abs(rv) > 1e-9 else { return nil }
            return lv / rv
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
```

**设计原则：** 除零时不崩溃、不吞错——返回 nil，由上层标记该 metric 为空，并在 warnings 里告知「表达式无法计算（分母为零）」。不堆 try/catch，让问题显性暴露。

**`extractAggregationID` 辅助函数**（同文件新增）：引擎产出的 metricKey 格式为 `dynamic.<source>.<aggregationID>.<group>`（见 `HoloDataTool.swift:1422` 的 `metricKey()` 函数）。提取 aggregation id 需按 `.` 分割、取倒数第二段：

```swift
private static func extractAggregationID(from metricKey: String) -> String? {
    let parts = metricKey.split(separator: ".").map(String.init)
    guard parts.count >= 2 else { return nil }
    return parts[parts.count - 2]    // 倒数第二段是 aggregation id
}
```

**⚠️ 派生操作执行顺序约束（重要）**：引擎按 `derivations` 数组顺序逐个执行（`HoloDataTool.swift:1204`）。后执行的派生若依赖先执行的派生结果（如 `perDay(total_roots)` 依赖 `expression(total_roots)`），被引用的必须排在前面。Prompt 必须明确引导模型：「derivations 按依赖顺序排列，被引用的排在前面」。

### 4.3 安全校验

**文件：`HoloDataTool.swift`（`HoloDynamicQueryValidator.validate()` 内，约 L595-618）**

在现有聚合校验循环之后，新增表达式树校验：

```swift
for derivation in plan.derivations where derivation.operation == .expression {
    guard let node = derivation.expression else {
        throw HoloDynamicQueryValidationError.unsupportedFieldOperation("expression 缺少表达式树")
    }
    // 深度 ≤ 6、节点 ≤ 20
    let stats = HoloExpressionValidator.analyze(node)
    guard stats.depth <= 6 else { throw HoloDynamicQueryValidationError.tooComplex }
    guard stats.nodeCount <= 20 else { throw HoloDynamicQueryValidationError.tooComplex }
    // 所有 metric 引用必须指向 plan 内已定义的聚合 id
    let definedIDs = Set(plan.aggregations.map(\.id))
    for referencedID in stats.referencedMetricIDs {
        guard definedIDs.contains(referencedID) else {
            throw HoloDynamicQueryValidationError.unknownField("表达式引用了未定义的指标：\(referencedID)")
        }
    }
    // 所有常量必须是有限数
    for c in stats.constants where !c.isFinite {
        throw HoloDynamicQueryValidationError.unsupportedFieldOperation("表达式包含非法常量")
    }
}
```

**独立的校验分析器（同文件新增）：**

```swift
nonisolated enum HoloExpressionValidator {
    struct Stats { var depth: Int; var nodeCount: Int; var referencedMetricIDs: Set<String>; var constants: [Double] }

    static func analyze(_ node: HoloExpressionNode) -> Stats {
        var stats = Stats(depth: 0, nodeCount: 0, referencedMetricIDs: [], constants: [])
        walk(node, currentDepth: 1, stats: &stats)
        return stats
    }

    private static func walk(_ node: HoloExpressionNode, currentDepth: Int, stats: inout Stats) {
        stats.nodeCount += 1
        stats.depth = max(stats.depth, currentDepth)
        switch node {
        case .constant(let v): stats.constants.append(v)
        case .metric(let id): stats.referencedMetricIDs.insert(id)
        case .add(let l, let r), .subtract(let l, let r),
             .multiply(let l, let r), .divide(let l, let r):
            walk(l, currentDepth: currentDepth + 1, stats: &stats)
            walk(r, currentDepth: currentDepth + 1, stats: &stats)
        }
    }
}
```

### 4.4 语义工厂登记

**文件：`HoloDataTool.swift`（`HoloMetricSemanticFactory` 内）**

两处映射新增 `.expression`：

```swift
// operation(forDerivation:) 新增 case，约 L667-677
case .expression: return .expression    // HoloMetricOperation 新增 .expression case

// valueRole(forDerivation:) 新增 case，约 L682-692
case .expression: return .current
```

**文件：`HoloAgentToolModels.swift`（`HoloMetricOperation` 枚举，约 L81-88）**

```swift
nonisolated enum HoloMetricOperation: String, Codable, CaseIterable, Sendable {
    case count, sum, average, minimum, maximum, distinctCount
    case difference, percentageChange, ratio, rate, perDay, linearTrend, coverage
    case correlation, conditionalAverage, groupComparison
    case expression    // ← 新增
}
```

### 4.5 查询结果附带样本（修正采样时机）

> **核心修正**：不搞独立采样器。样本在 dynamic_query 执行时**从已加载的数据中采样**，附在结果里返回给模型。这保证「样本在表达式生成之前到达模型」。

**文件：`HoloAgentToolModels.swift`（`HoloDataToolResult` 扩展）**

在 `HoloDataToolResult` 上新增可选字段：

```swift
nonisolated struct HoloDataToolResult: Codable, Equatable, Sendable {
    var toolRequestID: String
    var tool: String
    var status: HoloToolResultStatus
    var coverage: HoloDataCoverage?
    var metrics: [HoloMetric]
    var events: [HoloEvidenceEvent]
    var warnings: [HoloToolWarning]
    var error: HoloToolError?
    var sensitivity: HoloEvidenceSensitivity? = nil
    /// 查询返回的数据样本（最多10条），供模型校准分档条件。
    /// 仅 dynamic_query 在数据量较大时附带；nil 表示无样本。
    var sampleRows: [HoloQueryRow]? = nil    // ← 新增
}
```

**文件：`HoloDataTool.swift`（`HoloDynamicToolDecorator.execute()` 内）**

引擎执行查询后，从 `currentRows` 中采样，附在结果上：

```swift
// 现有 execute() 末尾，return 前插入：
let sampleRows = HoloDynamicQuerySampler.sample(from: currentRows, limit: 10)
result.sampleRows = sampleRows.isEmpty ? nil : sampleRows
```

**采样器（同文件新增，纯函数）：**

```swift
/// 从查询返回的数据中采样最多 limit 条，优先覆盖不同值 + 关键词匹配。
nonisolated enum HoloDynamicQuerySampler {
    static func sample(from rows: [HoloQueryRow], keyword: String? = nil, limit: Int = 10) -> [HoloQueryRow] {
        guard rows.count > limit else { return rows }
        var selected: [HoloQueryRow] = []
        // 1. 关键词优先（若提供）
        if let keyword, !keyword.isEmpty {
            selected = rows.filter { row in
                row.fields.values.contains { $0.textValue?.localizedCaseInsensitiveContains(keyword) ?? false }
            }
        }
        // 2. 按首个数值字段排序补充，确保覆盖大/中/小档位
        if selected.count < limit {
            let remaining = rows.filter { !selected.contains($0) }
                .sorted { ($0.fields["amount"]?.numberValue ?? 0) > ($1.fields["amount"]?.numberValue ?? 0) }
            selected.append(contentsOf: remaining.prefix(limit - selected.count))
        }
        return Array(selected.prefix(limit))
    }
}
```

**设计说明：**
- 样本来自引擎已加载的 `currentRows`，不二次查库，零额外开销
- 样本是 `HoloQueryRow`（工具中性结构），只含金额/日期/分类/备注，不含 CoreData 对象
- 关键词由 Runtime 从用户问题提取后传入（见 4.6）

### 4.6 Runtime 采样注入与告知卡片

**文件：`HoloLocalAgentRuntime.swift`（`runLoop`）**

现有流程：模型输出 `toolRequests` → 执行器执行 → 结果回灌。

新增逻辑：执行器返回结果后，若 `result.sampleRows` 非空，**把样本序列化为文本注入下一轮 LLM 请求的 context**，同时产出一条告知卡片消息。

```swift
// runLoop 内，执行 toolRequests 后：
for request in output.toolRequests {
    let result = await executor.execute(request)
    // 若结果附带样本，注入下一轮 context
    if let samples = result.sampleRows, !samples.isEmpty {
        let sampleText = samples.map { HoloQueryRowFormatter.summary($0) }.joined(separator: "\n")
        checkpoint.appendToolContext("[数据样本·用于校准分档]\n\(sampleText)")
        // 产出告知卡片消息
        checkpoint.appendMessage(.samplePreview(rows: samples))
    }
    checkpoint.appendToolResult(result)
}
```

**告知卡片：** 复用现有 Chat 卡片体系（`Views/Chat/Cards/`），新增一个轻量视图展示采样列表。样式对齐现有分析卡片，不做独立设计语言。

**⚠️ 隐私说明**：这不是新增的数据出口。HOLO 现有的记账意图识别、灵活查询等功能本来就在发送同类账单数据给模型（走 `api.holoapp.cn` 后端网关）。10 条样本走的是**完全相同的通道**，同样的加密、鉴权、App Attest。

### 4.7 Prompt 模板修改

**文件：`PromptManager.swift`**

修改两个模板：`flexibleQueryPlanner`（约 L36）和 `agentLoop`（约 L44）。在现有工具描述部分，新增对 `expression` 派生操作的说明。

**新增的 prompt 片段（大意）：**

```
当用户的计算需求包含「把数据按条件分档、每档换算成不同单位再合并」时
（如「金额超过X的是一箱、Y到Z之间的是一盒，一盒N个」），使用 expression 派生操作：

1. 先为每一档写一个带过滤条件的聚合（count 或 sum），每档一个 id
2. 用 expression 把各档指标乘上用户给的换算系数并相加
   - expression 是一棵树：constant / metric / add / subtract / multiply / divide
   - 例：(200 × carton_count + 20 × pack_count) ÷ 30
3. 如需日均/占比，把 expression 的结果再套 perDay 或作为除法分子

⚠️ 规则约束：
- 如果用户没说全换算系数（如只说「一包20根」但没说一条多少根），不要猜测，必须追问。
- derivations 按依赖顺序排列：被引用的派生结果必须排在引用它的派生前面。
  （例：先放 expression(total_roots)，再放 perDay(total_roots)）
- 优先用 2-3 层的浅表达式，避免过度嵌套（深度上限 6）。

⚠️ 你会收到最多 10 条数据样本，用于校准分档阈值。
请对照样本验证你的分档条件是否合理（如金额区间是否匹配真实数据分布）。
```

⚠️ 你会收到最多 10 条数据样本，用于校准分档阈值。
请对照样本验证你的分档条件是否合理（如金额区间是否匹配真实数据分布）。
```

---

## 五、改动清单（文件级）

| # | 文件 | 改动类型 | 量 | 说明 |
|---|------|---------|----|------|
| ① | `Services/AI/Agent/Tools/HoloDataTool.swift` | 修改 | ~150 行 | 核心：表达式树 enum（手写 Codable）+ 求值器 + 校验器 + 采样器 + derive 分支 + validate 分支 + 语义映射 |
| ② | `Models/AI/Agent/HoloAgentToolModels.swift` | 修改 | ~5 行 | `HoloMetricOperation` 加 `.expression`；`HoloDataToolResult` 加 `sampleRows` 字段 |
| ③ | `Services/AI/PromptManager.swift` | 修改 | ~30 行文本 | flexibleQueryPlanner + agentLoop 模板加 expression 说明 + 执行顺序约束 |
| ④ | `Services/AI/Agent/HoloAgentResponseParser.swift` | 修改 | ~15 行 | 解析 expression 字段（手写解码 discriminator 模式） |
| ⑤ | `Services/AI/Agent/HoloLocalAgentRuntime.swift` | 修改 | ~25 行 | runLoop 采样注入 + 告知卡片产出 |
| ⑥ | `Views/Chat/Cards/`（现有卡片体系内新增） | 新建 | ~60 行 | 样本告知卡片 UI，对齐现有卡片风格 |
| ⑦ | `HoloBackend/src/prompts/promptRegistry.js` | 修改 | 同步③ | 后端 prompt 托管同步（需发版） |

**不动的部分：** 后端网关透传逻辑、CoreData 存储层、网络层基础架构、现有 7 种派生操作符的实现。

---

## 六、Task 分解（实施步骤）

### Task 1: 表达式树数据结构 + 求值器 + 校验器（纯逻辑，可独立测试）

**Files:**
- Modify: `HoloDataTool.swift`（新增 `HoloExpressionNode` enum、`HoloExpressionEvaluator`、`HoloExpressionValidator`）

**Steps:**
1. 新增 `HoloExpressionNode` indirect enum（6 种节点：constant/metric/add/subtract/multiply/divide），**手写 Codable**（discriminator 模式，参考 `HoloQueryValue`）
2. 新增 `HoloExpressionEvaluator`（递归求值 + 公式描述）
3. 新增 `HoloExpressionValidator`（深度/节点数/引用/常量校验）
4. 这三个类型是纯函数，不依赖 CoreData / 网络，可独立单元测试

**验证:** 纯逻辑测试覆盖嵌套求值、除零返回 nil、深度超限抛错、Codable 往返。

### Task 2: 引擎集成 expression 派生操作

**Files:**
- Modify: `HoloDataTool.swift`（`HoloDynamicDerivationOperator` 加 case、`HoloDynamicDerivation` 加字段、`derive()` 加分支、`validate()` 加校验、`extractAggregationID`、语义工厂登记）
- Modify: `HoloAgentToolModels.swift`（`HoloMetricOperation` 加 `.expression`）

**Steps:**
1. `HoloDynamicDerivationOperator` 枚举加 `.expression`
2. `HoloDynamicDerivation` 结构体加 `expression: HoloExpressionNode?` 字段
3. 新增 `extractAggregationID(from:)` 辅助函数（按 `.` 分割取倒数第二段）
4. `derive()` 函数 switch 加 `.expression` 分支，调用 `HoloExpressionEvaluator`
5. `validate()` 加表达式树校验（调用 Task 1 的 `HoloExpressionValidator`）
6. `HoloMetricSemanticFactory` 的 operation/valueRole 映射加 `.expression` case
7. `HoloMetricOperation` 枚举加 `.expression`

**验证:** 构造含 expression 的 `HoloDynamicQueryPlan`，引擎执行后输出正确的 metric。测试「算烟」场景：(200×count(>200) + 20×count(20-30)) ÷ 30。

### Task 3: 查询结果附带样本 + 采样器

**Files:**
- Modify: `HoloAgentToolModels.swift`（`HoloDataToolResult` 加 `sampleRows` 字段）
- Modify: `HoloDataTool.swift`（新增 `HoloDynamicQuerySampler`，`HoloDynamicToolDecorator.execute()` 末尾采样并附结果）

**Steps:**
1. `HoloDataToolResult` 新增 `sampleRows: [HoloQueryRow]?` 字段（可选，兼容旧 JSON）
2. 新增 `HoloDynamicQuerySampler.sample(from:keyword:limit:)` 纯函数（关键词优先 + 金额分散）
3. `HoloDynamicToolDecorator.execute()` 在返回结果前，从 `currentRows` 采样并附到 `result.sampleRows`

**验证:** 给定 50 条模拟数据 + 关键词「烟」，断言采样结果 ≤10 条且包含关键词匹配项。

### Task 4: Prompt 模板更新

**Files:**
- Modify: `PromptManager.swift`（flexibleQueryPlanner + agentLoop 模板）
- Modify: `HoloBackend/src/prompts/promptRegistry.js`（后端同步）

**Steps:**
1. 在 flexibleQueryPlanner 模板中加入 expression 操作的说明和使用示例
2. 在 agentLoop 模板中加入「规则不全必须追问」「对照样本校准分档」的指令
3. 后端 promptRegistry.js 同步更新（需发版）
4. 客户端 prompt 版本号递增

**验证:** Prompt 模板版本号递增；本地 default 与后端托管版本一致。

### Task 5: Response Parser 扩展

**Files:**
- Modify: `HoloAgentResponseParser.swift`

**Steps:**
1. 解析 `dynamicPlan.derivations[].expression` 字段为 `HoloExpressionNode` 树
2. 解析失败时降级为 nil（该 derivation 被跳过），不崩溃
3. 兼容模型输出中 expression 字段缺失的旧格式

**验证:** 用模拟 JSON 测试解析器，覆盖嵌套表达式、字段缺失、格式错误。

### Task 6: Runtime 采样注入与告知卡片

**Files:**
- Modify: `HoloLocalAgentRuntime.swift`（runLoop 注入采样逻辑）
- Create: `Views/Chat/Cards/`（现有卡片体系内新增样本告知视图）

**Steps:**
1. runLoop 执行 toolRequest 后，检查 `result.sampleRows` 是否非空
2. 若有样本，序列化为文本注入下一轮 LLM 请求的 context（供模型校准分档）
3. 同时产出一条告知卡片消息推入 Chat 流
4. 实现样本告知 SwiftUI 视图，对齐现有卡片风格

**验证:** 模拟带 sampleRows 的查询结果，确认样本被注入 context、告知卡片被产出。

### Task 7: 端到端集成测试

**Steps:**
1. 用「算烟」场景做完整链路测试：用户提问 → 采样 → 模型生成 expression → 本地执行 → 结果展示
2. 验证告知卡片正确展示 10 条样本
3. 验证规则不全时触发澄清追问
4. 验证除零/引用缺失时返回 warning 而非崩溃

---

## 七、测试策略

### 7.1 纯逻辑测试（Task 1-3，不依赖 UI/网络）

| 测试项 | 覆盖点 |
|--------|--------|
| `HoloExpressionEvaluator` | 嵌套求值 `(200×3 + 20×5) ÷ 30 = 23.33` |
| 除零保护 | `divide(metric, constant(0))` 返回 nil |
| 引用缺失 | `metric("undefined_id")` 返回 nil |
| `HoloExpressionValidator` 深度 | 7 层嵌套被拒绝 |
| `HoloExpressionValidator` 节点数 | 21 个节点被拒绝 |
| `HoloExpressionValidator` 引用 | 引用未定义 aggregation id 被拒绝 |
| 引擎端到端 | 构造「算烟」plan，执行后输出正确 metric |

### 7.2 集成测试（Task 5-6）

| 测试项 | 覆盖点 |
|--------|--------|
| Parser 解析 | 模型 JSON 含 expression 字段，正确解析为树 |
| Parser 降级 | expression 字段格式错误时不崩溃 |
| Runtime 注入 | expression 请求触发采样 + 卡片产出 |

### 7.3 手动验收（Task 7）

- 真机/模拟器上问「算烟」问题，确认完整链路跑通
- 确认告知卡片正确展示
- 确认规则不全时模型追问

---

## 八、能力边界

### 能覆盖（预计 95% 的个性化计算需求）

- 一切「筛选 → 分档 → 乘系数 → 合并 → 求均/求比」的算术问题
- 算烟、算咖啡、算打车档次、算消费占比、算环比差值、算平均单价……

### 覆盖不了（约 5%，不在本方案范围）

| 需求类型 | 举例 | 为什么覆盖不了 | 归属 |
|---------|------|--------------|------|
| 时间窗口连续性 | 「连续7天每天打车超50元的时段」 | 需要滑窗判断，不是纯算术 | 后端深度分析 |
| 趋势预测 | 「预测下个月烟钱」 | 需要时间序列模型 | 后端 insight 服务 |
| 聚类/分类 | 「消费按习惯聚类」 | 需要机器学习 | 后端 memory 服务 |

这三类已有归属（HOLO 现有的后端深度分析能力），不在本方案范围内。

---

## 九、发版与隐私说明

### 9.1 发版

| 部分 | 是否需后端发版 | 说明 |
|------|--------------|------|
| 引擎逻辑（Task 1-3, 5-6） | **不需要** | 纯客户端，跟 app 版本走 |
| Prompt 模板（Task 4） | **需要** | 生产以后端托管为准；客户端改默认模板，但后端 `promptRegistry.js` 要同步更新才能稳定生效 |

**需后端发版的仅为 prompt 模板同步。** 改动内容是把 expression 操作说明加入 flexibleQueryPlanner 和 agentLoop 两个模板的后端版本。

### 9.2 隐私流向

- 10 条样本数据经 HOLO 后端网关（`api.holoapp.cn`）发给模型
- 走现有所有 AI 请求**同一通道**，同样的加密、鉴权、App Attest
- 不直连第三方模型 API
- 全量数据计算在本地完成，不过模型
- 用户通过告知卡片明确知道哪些数据被查看

---

## 十、风险与缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| 模型生成的表达式树格式不规范 | 中 | 解析失败 | Parser 降级为 nil + 走澄清追问；Prompt 给清晰示例 |
| 模型分档阈值写错 | 中 | 结果不准 | 10 条样本校准 + 模型自检 |
| 除零导致结果为空 | 低 | 用户看不到结果 | 返回 warning 提示「数据不足以计算」 |
| 树过深导致复杂度爆炸 | 低 | 性能 | 硬限制深度 ≤6、节点 ≤20 |
| 用户觉得告知卡片打扰 | 低 | 体验 | 卡片轻量设计，可折叠 |

---

## 附录 A：算烟场景的完整查询计划 JSON（示例）

以下是模型应输出的 `dynamicPlan`，引擎据此精确执行：

```json
{
  "source": "finance.transactions",
  "timeRange": { "label": "最近30天", "start": "...", "end": "..." },
  "filters": [
    { "field": "type", "operation": "equal", "value": { "type": "text", "text": "expense" } }
  ],
  "aggregations": [
    {
      "id": "carton_count",
      "operation": "count",
      "filters": [{ "field": "amount", "operation": "greaterThan", "value": { "type": "number", "number": 200 } }]
    },
    {
      "id": "pack_count",
      "operation": "count",
      "filters": [
        { "field": "amount", "operation": "greaterThanOrEqual", "value": { "type": "number", "number": 20 } },
        { "field": "amount", "operation": "lessThanOrEqual", "value": { "type": "number", "number": 30 } }
      ]
    }
  ],
  "derivations": [
    {
      "id": "total_roots",
      "operation": "expression",
      "metricID": "total_roots",
      "expression": {
        "type": "add",
        "left": {
          "type": "multiply",
          "left": { "type": "constant", "value": 200 },
          "right": { "type": "metric", "id": "carton_count" }
        },
        "right": {
          "type": "multiply",
          "left": { "type": "constant", "value": 20 },
          "right": { "type": "metric", "id": "pack_count" }
        }
      }
    },
    {
      "id": "daily_average",
      "operation": "perDay",
      "metricID": "total_roots",
      "unit": "根"
    }
  ]
}
```

> **注意 JSON 格式**：表达式树节点用 discriminator 模式（`type` 字段标识节点种类），与项目现有 `HoloQueryValue` 的 Codable 风格一致。`constant` 节点用 `value`，`metric` 节点用 `id`，`add/subtract/multiply/divide` 节点用 `left`/`right`。

引擎执行顺序：先算 `carton_count`、`pack_count`（分档计数）→ 再算 `total_roots`（表达式求值）→ 最后算 `daily_average`（perDay）。每一步都是确定性精确计算。**derivations 必须按依赖顺序排列**（被引用的排在前面）。
