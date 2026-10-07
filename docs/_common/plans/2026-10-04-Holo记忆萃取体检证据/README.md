# 记忆萃取体检证据

对应报告：[Holo 记忆萃取全面体检与可用性改造方案](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo记忆萃取全面体检与可用性改造方案.md>)。

本目录仅包含本次审查生成的诊断材料，不含真实用户数据库、模型密钥或真实记录原文。业务代码未修改，生产仅做健康与发布身份读取。

## 已运行

| 文件 | 内容 |
|---|---|
| `baseline-decision.log` | 4 个既有套件通过，共 208 个断言 |
| `baseline-personal-context.log` | 12 个既有套件，11 通过、1 失败；失败后该套件剩余断言未执行 |
| `audit-probe.log` | A01–A12 对当前缺口的复现输出，包含编译诊断 |
| `MemoryAuditProbe.swift` | 合成来源、真实纯逻辑实现的调用；A11 移植查询顺序到独立 Core Data 内存库 |
| `run_probe.py` | 依赖清单与独立编译运行器；产物位于临时目录，不进入 App 或真实数据库 |
| `source-manifest.json` | HEAD、审查时点、54 个相关业务文件 SHA-256；当前工作区含既有未提交改动 |
| `source-index.json` | 相关源码入口及行号，避免把历史方案当现状 |
| `production-readonly.json` | 公网健康、发布身份与测试 Prompt 端点的原始只读结果 |
| `backend-release-diff.txt` | 线上部署 commit 至本地 HEAD 的后端文件差异 |
| `prompt-default-comparison.json` | 部署 commit 对应 Git 默认模板和当前默认模板比较；不是生效 managed Prompt 核验 |
| `acceptance-corpus.jsonl` | 24 个人工预期的合成验收种子，未运行真实模型 |

## 诊断编号

| 编号 | 复现的缺口 | 证据范围 |
|---|---|---|
| A01 | 实际数字 100，错误摘要 999999 仍被接纳且 active | 真实领域 Validator 与 ActivationPolicy |
| A02 | 输入限制 1 项，模型漏回后记录限制变成 0 | 真实领域 Validator |
| A03 | 90 天证据变为调度当天记录窗 | 真实包与记录构造 |
| A04 | 两条独立偏好合并为一条 | 真实信号、身份与 Validator |
| A05 | 窗结束后裁决 discard，召回规则仍允许 | 真实 DecisionPolicy 与 RecallPolicy |
| A06 | Prompt 未输出已有业务状态、归属、领域、血缘 | 真实 Prompt Builder；未测试模型是否因此误推断 |
| A07 | quote/revision 缺失仍通过 | 真实个人情境 Validator |
| A08 | 单条长来源 2 个包，实际萃取仅 1 次 | 真实 Extractor + 空候选模型替身 + 内存写入替身 |
| A09 | qualified 判定落库为 factEligible | 真实 Reconciler / 新记录与决策构造 |
| A10 | 纠正仅更新摘要，旧 payload 未变；规划排除 | 真实反馈与访问规则，内存存储替身 |
| A11 | 151 行分页 `[50,50,0,50]`，只触达 100 行 | Core Data 内存库缩小复现；没有启动生产适配器 |
| A12 | 回复仅通用词“预算”重合，也被署名为使用记忆 | 真实 AttributionReconciler |

`REPRODUCED` 表示缺口复现，不表示修复完成。程序打印缺口状态，本身不是发布测试；不能只以退出码 0 或输出条数验收。修复后必须把这些场景改写为正确行为的回归断言。

## 复跑

先比较 `source-manifest.json` 的文件指纹，确认当前源码是否已经变化。此目录记录的是文件指纹与运行证据，未复制业务源码，不能恢复历史脏工作区。

```sh
python3 '/Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo记忆萃取体检证据/run_probe.py'
```

该命令使用 macOS Swift 与 Core Data，只处理程序内合成输入，不请求模型。`HOLO_MEMORY_STANDALONE` 隔离 App 依赖；探针在独立进程中暂设当前 v4 规则并恢复原值，不读写 Holo 用户数据库。

既有套件：

```sh
bash '/Users/tangyuxuan/Desktop/Claude/HOLO/scripts/run-memory-decision-standalone.sh'
bash '/Users/tangyuxuan/Desktop/Claude/HOLO/scripts/run-personal-context-standalone.sh'
```

第二条当前有已记录失败，不能标记为全部通过。实际模型、完整 iOS 构建、普通 Release、真机、跨设备和生效 Prompt 的验收仍未完成。

## 关键搜索事实

2026-10-04 对当前 Swift 业务源码搜索 `invalidateMemories(`，仅找到服务定义和 `HoloMemoryForgettingStandaloneTests.swift` 的测试调用。该事实说明未发现这条主动失效入口在业务修改/删除流程中接通；不等于所有读取策略都完全没有过滤，也不证明真实用户已经发生泄漏。

旧 `LongTermCandidateObserver` 的代码仍存在，当前启动使用 `ReplayDigestObserver`。未找到旧 observer 的启动调用，因此本报告不把“AI 洞察先生成、再唯一驱动长期记忆”作为当前主链路。

## 验收种子的用法

`acceptance-corpus.jsonl` 每行一个场景：category、合成来源/控制动作、question/consumer、expected 的命题与禁止推断及具体作用。所有标签是目标行为，不是当前输出；`status=proposed_not_executed`。

真实模型基准前先审查标签，补齐 source contract、时间/时区、Prompt 与模型身份。不同合适措辞应被接受；主体、条件、数值、证据和用途不得变。负例允许合法空产出。纠正/遗忘场景需同时运行消费者，不可只比较摘要字符串。
