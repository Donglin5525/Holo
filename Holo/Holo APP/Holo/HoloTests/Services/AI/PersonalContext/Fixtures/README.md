# PersonalContext 评测夹具格式（P0 冻结）

本目录存放通用个人情境能力的模型评测夹具。所有内容必须为**合成内容或已获准的脱敏内容**，禁止批量上传真实用户私密资料做测试。

## 目录结构与用途

```
Fixtures/
├── README.md          # 本文件：格式与冻结协议
├── schema.json        # 机器可读的夹具 JSON Schema
├── dev/               # 开发集：调 Prompt 时可反复读取答案
│   └── *.json
└── heldout/           # 留出集：冻结后不得在提示词调试中读取逐题答案
    ├── README.md      # 冻结记录（生成时间、组数、领域分布、生成方式）
    └── *.json         # 评测时按需加载，答案不进任何调试输出
```

## 夹具字段（七个必填区块）

| 字段 | 含义 | 约束 |
|---|---|---|
| `fixtureID` | 唯一标识 | `dev-*` / `heldout-*` 前缀区分集合 |
| `domainTags` | 覆盖领域标签 | 用于分域指标（工作/家庭/健康/学习/决策/财务/人际等，开放集合） |
| `sources` | 输入的原始来源快照 | `sourceID`、`sourceDomain`、`sourceKind`、`plainText`、可选 `eventTime`（事件发生时间）与 `recordedAt`（记录时间，两者刻意不同以测补记）、`revisionDigest` |
| `currentRequest` | 本轮用户请求 | `utterance`（原话）、可选 `goalSummary`、`referenceTime`（评测锚定时间，ISO8601） |
| `expectedSupportedRelations` | 应从 sources 理解出的关系/事实 | `statement`、`basisSourceIDs`（必须指向 sources）、`epistemicStatus`（declared/observed/inferred）、可选 `temporal`（事件时间约束） |
| `unknowns` | 系统应识别为未知的问题 | 不应有任何 source 支持其答案 |
| `expectedPlanEffects` | 对方案的影响断言 | `effectKind`（shouldInclude/shouldExclude/shouldAsk/shouldAdjust）+ `description` |
| `forbiddenClaims` | 禁止出现的断言 | 评测中输出即记失败（伪造来源/未经确认执行/把未知当事实） |
| `counterfactualVariants` | 反事实变体 | 修改/删除来源后，`expectedEffect` 描述建议应如何正确变化 |

## 留出集冻结协议

1. **生成时机**：必须在 Prompt 调试开始前生成并冻结，不少于 40 组，覆盖不同领域与组合。
2. **隔离规则**：提示词调试（含人工看样例调优）不得读取留出集逐题答案；跑最终评测后若据错误改 Prompt，该集合转为回归集，下次泛化评估必须换新留出集。
3. **评分口径**：分子/分母、Provider/模型/Prompt 版本一并报告；关键计划影响召回率 ≥85%（分域 ≥75%）、个性化断言有据率 ≥95%、无关补充率 ≤10%、反事实正确变化 ≥90%、固定红线零次（详见实施方案 15.2）。
4. **生成方式**：合成内容；由未参与 Prompt 调试的独立生成过程产出，生成记录写入 `heldout/README.md`。

## 消费方

- `dev/` 与 `heldout/` 由 P9 的评测 harness 加载（真实 Provider 调用）。
- 确定性测试（无需 LLM）不依赖本目录；夹具中的关系抽取期望也可供语义校验器的单测复用。
