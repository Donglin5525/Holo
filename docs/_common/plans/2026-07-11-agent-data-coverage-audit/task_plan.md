# Holo AI Agent 全数据覆盖排查与补齐计划

## 目标

验证健康数据（步数、睡眠、站立等）从采集到 Agent 最终回答的完整链路，并以“所有 Holo 产生的数据都可被 Agent 调用”为目标，盘点和补齐高价值缺口。

## 完成标准

- 明确步数、睡眠、站立三个代表性指标能否被 Agent 读取、是否带时间口径、是否能作为回答证据。
- 建立 Holo 数据域 × Agent 工具 × 支持操作 × 验证证据的覆盖矩阵。
- 对确认的阻断缺口先写失败测试，再做最小实现并跑回归。
- iOS 构建与所有受影响的 standalone/后端测试通过。
- 输出产品化报告，区分“已完整接入”“部分接入”“尚未接入”“受权限或设备数据限制”。
- 若改动 HoloBackend，完成 prompt 双端同步、版本提升，并提醒或执行后端发版与线上验证。

## 阶段

1. [已完成] 恢复既有方案与健康链路历史证据，核对当前代码是否漂移
2. [已完成] 逐层验证健康采集、Repository、Tool、Registry、Planner、Renderer 链路
3. [已完成] 全量枚举 Holo 数据模型、Repository、Agent 工具与可调用操作，形成覆盖矩阵
4. [已完成] 收敛产品设计与实施边界，写正式设计/实施计划
5. [已完成] RED：为确认缺口补失败测试并验证失败原因
6. [已完成] GREEN：补齐工具、数据源、注册与路由，逐项转绿
7. [已完成] 全量回归与 iOS 构建
8. [进行中] 完成报告、CHANGELOG、scoped commit/push 与后端线上验证

## 关键约束

- 保留工作区现有的时间查询、Memory Gallery、观点模块等无关改动，不覆盖、不混入本任务提交。
- 不把“存在 HealthKit 权限/Repository 方法”误判为“Agent 已可调用”；必须验证到工具调用与结果证据。
- 不把“工具已注册”误判为“模型一定会选对工具”；必须核对工具 schema、intent、Agent prompt 和真实执行。
- 工具侧快照保持 Codable/Sendable，不把 Core Data 管理对象跨并发边界泄漏出去。
- 用户已明确授权：方向无阻断时直接实施；本轮不启用 subagent。

## 错误记录

| 错误 | 尝试 | 处理 |
|---|---:|---|
| 创建目标时提示当前线程已有 active goal | 1 | 读取现有 goal，确认系统已用用户原始请求创建目标，继续沿用 |
| 按常见路径查找 `Holo.xcdatamodeld` 失败 | 1 | 项目使用代码化 Core Data 实体装配；改查 `CoreDataStack+*Entities.swift` 与各 Repository，不重复猜模型路径 |
| baseline `swiftc` 无法写 `~/.cache/clang/ModuleCache` | 1 | 不重复原命令；后续 standalone 编译显式把 Clang/Swift module cache 指到 `/tmp/holo-module-cache` |
| 首次插入多行 Prompt 的 patch 被列表行误解析 | 1 | 改为显式逐行 `+` 的 unified diff，避免模板拼接中的 `-` 被当成删除行 |
| 收尾代码审查发现 health result 仍沿用 normal 敏感级别 | 1 | 先新增失败断言，再把 descriptor 与所有结果统一为 sensitive，重跑工具测试和 iOS build 通过 |
