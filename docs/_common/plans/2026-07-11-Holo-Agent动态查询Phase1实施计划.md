# Holo Agent 动态查询 Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** 建立安全、确定性的动态查询 DSL，并让 Agent 能对财务与健康原始记录现场组合指标，而不再受固定 query/metricKey 限制。

**Architecture:** 在现有 `HoloToolRequest` 中加入可选动态计划；财务与健康工具分别提供规范化行数据，统一执行器负责字段校验、过滤、分组、聚合、基线比较、派生指标与证据生成。旧 query 保留为快捷模板和降级路径。

**Tech Stack:** Swift, Foundation, HealthKit/Core Data adapters, standalone Swift tests, Holo Agent Loop, Hono prompt registry.

---

### Task 1: 动态查询协议与目录

- 在 Agent 工具模型中定义字段目录、查询行、过滤器、分组、聚合、派生和计划结构。
- 为 finance.transactions 与 health 四类日数据注册字段目录。
- 增加计划校验：单数据源、注册字段、安全算子、31 天上限、最多 5 个聚合和 200 条证据。
- 先写 standalone 测试验证非法字段、范围和复杂度会被拒绝。

### Task 2: 确定性计算引擎

- 实现过滤、日/周/月/周末分组、count/sum/average/min/max/distinctCount。
- 实现 difference/ratio/percentageChange/rate、基线比较、线性趋势和覆盖率。
- 每个结果生成稳定 metric ID、公式、来源 ID、时间范围和对应 EvidenceEvent。
- 测试睡眠均值、低睡眠占比、周末步数、基线差值和错误单位。

### Task 3: 财务与健康适配器

- HealthDataSource 直接将 HealthKit 日记录规范化为动态行。
- FinanceDataSource 从交易仓库读取原始交易并规范化金额、类型、分类、账户、文本和日期。
- `HoloHealthTool` / `HoloFinanceTool` 优先执行 dynamicPlan；失败返回可修正 INVALID_DYNAMIC_PLAN，不静默伪造结果。
- 固定 query 保持兼容。

### Task 4: Agent Loop 与 Prompt

- `HoloToolRequest` 增加可选 `dynamicPlan`，旧持久化 JSON 保持兼容。
- 工具目录 Prompt 输出可查询字段与 DSL 安全边界。
- agent_loop Prompt 升级，要求长尾财务/健康问题优先生成动态计划，失败最多修正一次。
- iOS 后备 Prompt 与后端默认 Prompt 同步升版。

### Task 5: 证据校验、灰度与验收

- ClaimVerifier 继续按实际 EvidenceRecord 校验动态 metric ID 和数值，不依赖预注册 metricKey。
- 增加动态查询 feature flag；关闭时仅走旧 query。
- 运行动态引擎、健康、财务、Parser、Runtime standalone 回归和完整 iOS build。
- 更新 CHANGELOG；仅提交本任务文件，保留 Memory Gallery 工作区改动。
