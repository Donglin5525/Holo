# Daily Sense 状态卡片重设计方案

> 日期：2026-06-05
> 范围：DailySenseStatusCard 视觉重设计 + 文案优化 + 规则引擎调优
> 前置方案：`docs/_common/plans/2026-05-23-Holo-Sense-Layer洞察闭环方案.md` Phase 4

## 背景与问题

当前 Daily Sense 卡片（Phase 4 实现）存在以下问题：

| 问题 | 现状 | 影响 |
|------|------|------|
| 消费文案难懂 | 「消费偏离均值 11.2x」——统计术语，用户不理解 | 看不懂 |
| 习惯文案生硬 | 「2 个习惯断连」——像技术术语 | 不自然 |
| 文案拼接拥挤 | 多个 reason 用 " · " 拼成一行 | 信息密度高但不直观 |
| 消费阈值过低 | 1.5x 触发，日均 ¥10 买杯咖啡就误报 | 通知疲劳 |
| 状态标题抽象 | 「状态稳定」「需要注意」「正在恢复」——像系统日志 | 没有温度 |
| 置信度圆点无用 | 一个 8px 小圆点表示 confidence | 用户不理解含义 |
| 健康信号未启用 | Feature Flag 关闭，代码空实现 | 缺少一个维度 |

## 设计决定

### 1. 卡片布局：时间线圆点式

**收起态**：状态图标 + 标题 + 彩色圆点行（每维度一个点）

```
┌─────────────────────────────────────────┐
│ ⚠️  节奏有点乱   🟠 🟠 🔴 🟢       ▾ │
└─────────────────────────────────────────┘
```

- 圆点颜色：绿=正常、橙=注意、红=异常
- 无数据的维度**不展示圆点**（3 个点而非固定 4 个）
- 右侧 ▾ 提示可展开

**展开态**：标题 + 竖线圆点时间线，每维度一行

```
┌─────────────────────────────────────────┐
│ ⚠️  节奏有点乱                      ▴ │
│                                         │
│  ●  待办          2 笔过了截止日        │
│  ●  习惯          2 个断了节奏          │
│  ●  消费          今天 ¥560 · 平时 ¥50 │
│  ●  睡眠          7.5h                  │
└─────────────────────────────────────────┘
```

- 竖线 + 圆点颜色与收起态圆点一一对应
- 圆点颜色规则与收起态一致

**颜色 token 映射**：

| 信号等级 | 圆点颜色 | 状态标题颜色 | SwiftUI token |
|----------|----------|-------------|---------------|
| normal (🟢) | 绿 | `.holoSuccess` | `.holoSuccess` (#22C55E) |
| warning (🟠) | 橙 | `.orange` | `Color.orange`（系统橙色） |
| critical (🔴) | 红 | `.holoError` | `.holoError` (#EF4444) |

注意：`Color.orange` 与 `.holoPrimary` (#F46D38) 是不同颜色。`.holoPrimary` 仅用于品牌色（recovering 状态边框等），信号圆点的橙色统一使用 `Color.orange`。

### 2. 状态标题：节奏视角

| 状态 | 旧文案 | 新文案 |
|------|--------|--------|
| `.stable` | 状态稳定 | **节奏不错** |
| `.atRisk` | 需要注意 | **节奏有点乱** |
| `.recovering` | 正在恢复 | **节奏在找回** |

### 3. 信号文案规则

文案风格：有数据但不冷冰冰，超短短语，动词/状态主导。

#### 待办

| 条件 | 文案 | 圆点颜色 |
|------|------|----------|
| 逾期 ≥ 3 | `{N} 笔过了截止日` | 🟠 橙 |
| 逾期 1-2 | `{N} 笔快到截止日了` | 🟠 橙 |
| 无逾期 | `没有逾期` | 🟢 绿 |
| 无待办数据 | 不展示圆点和行 | — |

#### 习惯

| 条件 | 文案 | 圆点颜色 |
|------|------|----------|
| 断连 ≥ 2 | `{N} 个断了节奏` | 🟠 橙 |
| 恢复打卡 > 0 | `{N} 个恢复打卡` | 🟢 绿 |
| 全部完成 | `打卡都完成了` | 🟢 绿 |
| 无习惯数据 | 不展示圆点和行 | — |

#### 消费

| 条件 | 文案 | 圆点颜色 |
|------|------|----------|
| 偏离 > 3x 且今日 > ¥100 | `今天 ¥{today} · 平时 ¥{avg}` | 🔴 红 |
| 偏离 1.5x-3x | `比平时多花了 ¥{diff}` | 🟠 橙 |
| 正常范围 | `消费正常` | 🟢 绿 |
| 无消费记录 | 不展示圆点和行 | — |

消费金额取整显示（¥50 而非 ¥49.87）。

#### 健康（睡眠）

| 条件 | 文案 | 圆点颜色 |
|------|------|----------|
| 睡眠 < 5h | `只睡了 {N}h` | 🔴 红 |
| 睡眠 5-6h | `{N}h · 有点少` | 🟠 橙 |
| 睡眠 > 6h | `{N}h` | 🟢 绿 |
| 无健康授权 | 不展示圆点和行 | — |

#### 健康（步数）

| 条件 | 文案 | 圆点颜色 |
|------|------|----------|
| 步数 < 2000 | `步数偏少` | 🟠 橙 |
| 步数 ≥ 2000 | `走了 {N} 步` | 🟢 绿 |

健康睡眠和步数合并为「健康」一个维度展示，优先显示异常项。无异常时显示睡眠时长。

### 4. 收起态圆点逻辑

圆点数量 = 有数据的维度数（2-4 个），从左到右固定顺序：待办 → 习惯 → 消费 → 健康。

圆点颜色取该维度的信号等级：
- 无异常 → 🟢 绿
- 轻度异常 → 🟠 橙
- 重度异常 → 🔴 红

整体状态判断不变：`atRisk > recovering > stable`。但 confidence 字段不再显示为 UI 元素，改为内部调试用。

### 5. 交互行为

- 默认收起，点击切换展开/收起
- 展开/收起使用 `withAnimation(.easeInOut(duration: 0.25))`
- 每次进入记忆长廊页面，重新计算今日状态（复用现有 `DailySenseSnapshotStore` 缓存逻辑）

## 涉及文件

| 文件 | 改动类型 | 说明 |
|------|----------|------|
| `Views/MemoryGallery/Components/DailySenseStatusCard.swift` | **重写** | 新布局：收起态圆点行 + 展开态时间线 |
| `Services/AI/DailySenseStateBuilder.swift` | **修改** | 阈值调整 + 文案生成逻辑 + 健康信号启用 + 改为 async |
| `Models/DailySenseSnapshot.swift` | **修改** | reasons 从 `[String]` 改为结构化 `[DailySenseSignal]` |

### DailySenseSnapshot 模型变更

```swift
/// 单维度信号
struct DailySenseSignal: Codable, Equatable {
    let dimension: SenseDimension    // task / habit / expense / health
    let level: SignalLevel           // normal / warning / critical
    let text: String                 // 展示文案
}

enum SenseDimension: String, Codable {
    case task, habit, expense, health
}

enum SignalLevel: String, Codable {
    case normal    // 🟢 .holoSuccess
    case warning   // 🟠 .orange（系统橙色）
    case critical  // 🔴 .holoError
}

/// 每日状态快照（v2）
struct DailySenseSnapshot: Codable, Equatable {
    let schemaVersion: Int             // v2 = 2，用于检测旧版缓存
    let date: Date
    let state: DailySenseState
    let signals: [DailySenseSignal]   // 替代旧 reasons: [String]
    let generatedAt: Date

    /// JSON 向下兼容：旧版字段用 decodeIfPresent，缺失时回退默认值
    /// - 旧 `confidence: Double` → 忽略
    /// - 旧 `reasons: [String]` → 忽略
    /// - 新 `signals: [DailySenseSignal]` → 缺失时为空数组
    /// - 新 `schemaVersion: Int` → 缺失时为 1（旧版）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        date = try container.decode(Date.self, forKey: .date)
        state = try container.decode(DailySenseState.self, forKey: .state)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        signals = try container.decodeIfPresent([DailySenseSignal].self, forKey: .signals) ?? []
    }

    // 普通构造器
    init(date: Date, state: DailySenseState, signals: [DailySenseSignal], generatedAt: Date) {
        self.schemaVersion = 2
        self.date = date
        self.state = state
        self.signals = signals
        self.generatedAt = generatedAt
    }

    /// 是否为旧版格式（需要强制重建）
    var isLegacy: Bool { schemaVersion < 2 }
}
```

- `confidence` 字段移除（不再 UI 展示，内部规则调试用 Logger）
- `reasons: [String]` 替换为 `signals: [DailySenseSignal]`
- **新增 `schemaVersion` 字段**：`DailySenseSnapshotStore.todaySnapshot()` 返回缓存时，ViewModel 检查 `isLegacy`，若为旧版则忽略缓存、强制重新生成。这避免旧版快照被解码为 `signals=[]` 后出现"有标题但无圆点"的空壳卡片。

### DailySenseStateBuilder 改动

**阈值调整**：
- 消费异常阈值：`1.5x` → `3x` 且今日金额 > `¥100`
- 消费轻度提醒：`1.5x - 3x` 之间

**信号输出**：每个维度输出一个 `DailySenseSignal`，不再拼字符串到 reasons。

**健康信号**：启用 `InsightFeatureFlags.healthContextEnabled`，接入 `HealthRepository` 获取睡眠和步数数据。

**健康数据异步问题**：
1. `buildToday()` 改为 `static func buildToday() async -> DailySenseSnapshot?`
2. `MemoryGalleryViewModel.loadInsights()` 中的调用必须同步改为 `await DailySenseStateBuilder.buildToday()`
3. 健康数据读取策略：优先同步读取 `HealthRepository.shared.todaySteps` / `todaySleep` 缓存值（由后台刷新机制更新）。如果缓存值为 0，需要区分三种情况：
   - **无授权**：`HealthRepository` 的授权状态检查 → 不展示健康圆点
   - **有授权但未加载**：缓存属性为 `nil` 或 `0` 但授权存在 → 调用一次 `await HealthRepository.shared.refresh()` 后重读
   - **真实值**：正常展示。步数/睡眠不会出现真实 0 值，0 即意味着未加载

### DailySenseStatusCard 重写

- 新增 `@State private var isExpanded = false`
- 收起态：`HStack` = 图标 + 标题 + 圆点行 + ▾
- 展开态：在收起态下方追加竖线圆点列表
- 移除旧的 confidence 圆点

## 不变项

| 项目 | 说明 |
|------|------|
| 状态枚举 | `stable / atRisk / recovering` 不变 |
| 状态优先级 | `atRisk > recovering > stable` 不变 |
| 持久化 | JSON 文件 `DailySenseSnapshots.json`，保留 7 天 |
| 生成策略 | 纯规则引擎，不调用 AI |
| Feature Flag | `InsightFeatureFlags.dailySenseEnabled` 控制卡片显示/隐藏 |

## 验收标准

- [ ] 三种状态标题显示为新文案
- [ ] 收起态展示彩色圆点行，无数据维度不显示圆点
- [ ] 展开/收起动画流畅
- [ ] 消费异常只在 > 3x 且 > ¥100 时显示红色
- [ ] 消费文案显示实际金额对比而非倍数
- [ ] 健康维度展示睡眠时长，< 6h 标橙
- [ ] 旧版 JSON 快照正常解码（不崩溃），但触发强制重建，不显示空壳卡片
- [ ] `signals.isEmpty` 时**不展示** Daily Sense 卡片（不展示空壳）
- [ ] 健康无授权时健康圆点不出现；有授权但未加载时触发一次 refresh 后再读

---

## Codex 审查意见（2026-06-05）

结论：**Conditional Go**。产品方向成立，可以继续推进，但进入实现前建议先修正文档里的 3 个关键点，否则落地时容易出现编译问题、旧缓存吞掉新 UI、以及空状态语义不一致。

### 1. P1：健康接入的 async 方案与真实代码不一致

文档当前写法：
- `HealthRepository` 的数据获取方法全部是 `async` 且 `private`
- `buildToday()` 改为 async 后，健康数据仍直接同步读取 `todaySteps` / `todaySleep` 缓存
- `MemoryGalleryViewModel.refresh()` 已经是 async，因此调用处无需改动

真实代码约束：
- `HealthRepository` 是 `@MainActor` 单例，且已有公开 `refresh()` 和 `fetchDayData(for:)`
- 当前调用点仍是同步 `DailySenseStateBuilder.buildToday()`
- 如果把 `buildToday()` 改成 async，`MemoryGalleryViewModel.loadInsights()` 中的调用必须同步更新为 `await DailySenseStateBuilder.buildToday()`

建议修正文档：
- 明确 `buildToday()` 改为 `static func buildToday() async -> DailySenseSnapshot?`
- 明确 `MemoryGalleryViewModel.loadInsights()` 需要将调用改为 `await DailySenseStateBuilder.buildToday()`
- 健康数据优先使用 `await HealthRepository.shared.refresh()` 或 `await HealthRepository.shared.fetchDayData(for: Date())`
- 展示前用 `HealthMetricAvailability` 判断该指标是否可靠，避免把 `0` 同时误解成“无授权 / 无数据 / 真实 0”

### 2. P1：旧版 JSON 兼容会被今日缓存卡住

文档当前写法：
- 旧版 `reasons` / `confidence` 忽略
- 旧快照解码后 `signals = []`
- “下次生成时自动覆盖为新格式”

真实代码约束：
- `DailySenseSnapshotStore.todaySnapshot()` 只要命中今日缓存，`MemoryGalleryViewModel` 就直接使用缓存，不会重新生成
- 如果今日旧快照被解码成 `signals = []`，新 UI 可能出现“状态标题有风险，但没有圆点和展开行”的空壳状态

建议修正文档，二选一：
- 推荐方案：给 `DailySenseSnapshot` 增加 `schemaVersion`，发现旧 schema 或 `signals` 缺失时强制重建今日快照
- 兼容方案：把旧 `reasons` 迁移成临时 `DailySenseSignal`，至少保证当天旧缓存仍有可展示内容

不要只写“下次生成自动覆盖”，因为当前缓存策略不会保证当天自动重建。

### 3. P2：空数据验收标准互相矛盾

文档前文规则：
- 无数据维度不展示圆点和行
- 圆点数量 = 有数据的维度数

验收标准最后一条：
- “无数据时不展示卡片或展示「节奏不错」+ 全绿圆点”

这两个方向会导致实现者做出不同 UI。建议在文档里明确唯一策略：
- 推荐：`signals.isEmpty` 时不展示 Daily Sense 卡片
- 如果坚持展示“节奏不错 + 全绿圆点”，则必须定义默认维度集合和默认绿点数量，否则“全绿圆点”没有数据来源

### 建议的实施前修订清单

- [ ] 修正健康数据接入方案，改为 async builder + 显式 await 调用点
- [ ] 补充 `schemaVersion` 或旧 `reasons` 迁移策略
- [ ] 明确 `signals.isEmpty` 时的唯一 UI 行为
- [ ] 在验收标准里增加“旧版今日缓存不会显示空壳卡片”
- [ ] 在验收标准里增加“健康无授权 / 无数据 / 真实 0 分开处理”
