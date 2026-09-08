# 意图识别评测报告：seed-v1-cp-check (cp-check-10)

- 时间：2026-09-08T11:46:04.761Z
- 环境：https://api.holoapp.cn
- 语料：/Users/tangyuxuan/Desktop/Claude/HOLO/docs/holoai-audit/intent-eval/corpus/seed-v1-contextplan-check.json（10 条）
- **总体准确率：90.0%（9/10）**

## 按期望意图分布

| 期望意图 | 通过/总数 | 准确率 |
|---|---|---|
| contextual_planning | 9/10 | 90% |

## 失败样本（1）

| id | 输入 | 期望 | 实际 | mode | 澄清 | 备注 |
|---|---|---|---|---|---|---|
| cp09 | 最近有哪些固定支出快到扣费日了，帮我理一下怎么安排 | contextual_planning | query_analysis | query | 否 | 个人情境规划：订阅缴费 |
