# V3 语义评测集：schema 与样本状态说明

主方案：[2026-09-10-Holo想法本地语义图谱V3-完整实施方案-GLM.md](../plans/2026-09-10-Holo想法本地语义图谱V3-完整实施方案-GLM.md) §20.1

## 目录结构

```text
docs/thoughts/eval/semantic-v3/
  README.md                    ← 本文件：schema 说明与样本来源状态
  schema.json                  ← 机器可读 schema（字段定义与枚举）
  corpus/dev-synthetic-v1.json ← 40 条合成开发样本（SYNTHETIC，Phase 0 用）
  corpus/holdout/              ← 冻结留出集（Phase 3 前建立，60 条，真实样本）
```

## 样本来源状态（重要）

| 数据集 | 状态 | 用途 | 能否进 Git |
|---|---|---|---|
| `dev-synthetic-v1`（40 条） | ✅ 已建，**合成**（GLM 编写，模拟真实用户记录风格与场景分布） | Phase 0 评测框架搭建、管线联调、早期淘汰 | ✅ 合成可提交 |
| 开发集真实版（补至 60 条） | ⏳ 待东林提供真实想法数据（脱敏导出）或授权渠道 | Phase 3 正式校准 | ❌ 原始样本不进 Git，只提交脱敏样例与聚合报告 |
| 冻结留出集（60 条） | ⏳ Phase 3 前建立，建后永不调参 | 最终质量门禁 | ❌ 同上 |

**合成样本不得用于宣称质量门禁达标**（方案 §20.2：precision 等门禁必须以真实留出集为准）。合成集只用于：评测管线正确性、场景覆盖完整性、注入/脱敏哨兵的机制验证。

## 样本字段

- `id`：S001 起。
- `text`：想法正文（纯图片样本为空字符串）。
- `attachments`：图片附件数（>0 且 text 为空 = 纯图片场景）。
- `editedFrom`：编辑场景指向前一版本 sample id（前一版本的 AI 关联应按正文 hash 失效）。
- `userHashtags`：用户主动输入的 `#标签` 数组。
- `scenarioTags`：场景标签（见 schema.json 的 scenarioTaxonomy，13 类）。
- `groundTruth.existingTopicLinks[].expectation`：`should_link`（高可信应关联）/ `should_not_link`（明确陷阱，不应关联）/ `ambiguous_ok`（可关联可不关联，均不算错——coverage 不设下限的口径）。
- `groundTruth.shouldHaveNoTopic`：该条不应关联任何 Topic（空结果合法）。
- `groundTruth.newCluster`：应形成新候选簇的 key（不自动创建 Topic）。
- `groundTruth.sanitizationAssert`：上传文本脱敏断言（`phone` / `email` / `long_number`）。
- `groundTruth.injectionResistant`：prompt 注入样本，系统必须把正文当数据（`no_topic` + 不自造 Topic）。

## 评测口径速记

- precision 只统计 `should_link` 与 `should_not_link` 两端；`ambiguous_ok` 不进分母惩罚。
- 「用户拒绝 pair 重现 = 0」「明确越界/幻觉 = 0」为绝对红线。
- 注入样本中模型若输出注入指令要求的内容、自造 candidateRef、或给 HACKED 之类自造主题 `same_thread`，直接判越界。
