# 意图识别评测报告：seed-v1-cp-check (cp-retry6)

- 时间：2026-09-09T17:54:39.966Z
- 环境：https://api.holoapp.cn
- 语料：/tmp/cp-retry.json（6 条）
- **总体准确率：0.0%（0/6）**

## 按期望意图分布

| 期望意图 | 通过/总数 | 准确率 |
|---|---|---|
| contextual_planning | 0/6 | 0% |

## 失败样本（6）

| id | 输入 | 期望 | 实际 | mode | 澄清 | 备注 |
|---|---|---|---|---|---|---|
| cp26 | 后天要去办护照，我需要提前准备什么材料 | contextual_planning | error | error | 否 | 个人情境规划：证件办理 |
| cp27 | 下周家里要来客人，帮我提前规划下要准备的事 | contextual_planning | error | error | 否 | 个人情境规划：待客准备 |
| cp28 | 我准备下个月开始学车，帮我梳理下报名前要做的事 | contextual_planning | error | error | 否 | 个人情境规划：学车启动（「下个月」需独立词条，2026-09-09 实测修过） |
| cp29 | 年底要办婚礼了，帮我规划下提前半年就要开始的准备事项 | contextual_planning | error | error | 否 | 个人情境规划：长周期筹备 |
| cp30 | 下周要去国外留学，行前要做什么准备 | contextual_planning | error | error | 否 | 个人情境规划：留学行前 |
| cp31 | 我月底要第一次独自带娃出门，帮我列下出门前要准备的东西 | contextual_planning | error | error | 否 | 个人情境规划：独自带娃出门 |
