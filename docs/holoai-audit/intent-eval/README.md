# 意图识别评测基线（intent_eval）

方案来源：`docs/plans/2026-08-15-intent-routing-long-term-architecture.md` §4 P0。

## 这是什么

意图识别（后端 LLM，purpose=intent）的回归评测集。任何改意图 prompt / 路由 / 上下文注入的工作，改前改后各跑一次，**总体准确率不得低于基线 -2pp**（无基线报告佐证的 prompt 改动不许发版）。

## 组成

- `corpus/seed-v1.json` — 种子语料（仓库构造，覆盖全部 21 个意图 + 歧义组 + 闲聊组，约 140 条；`acceptable` 支持可接受集合，`expectClarification` 标注应触发澄清的混合句）
- `run-eval.mjs` — runner（Node 18+，内置 fetch）。请求形状与 iOS 真实链路一致：system=最小用户上下文，意图 prompt 由后端注入，**结果包含 intentResponseStabilizer 规则旁路行为**（报告中标注 [rules旁路]）
- `reports/` — 历次报告（文件名含时间戳+语料版本+tag）；`last-failures.json` 为最近一次失败样本机器可读版

## 跑法

```bash
cd docs/holoai-audit/intent-eval

# 本地 dev / mock 后端（管道冒烟，结果无准确率意义）
node run-eval.mjs --tag smoke

# 真实基线（本地 dev 配好 HOLO_INTENT_PROVIDER，或指向测试环境）
node run-eval.mjs --tag baseline --base-url http://localhost:3000

# 调试：只跑前 10 条
node run-eval.mjs --limit 10
```

生产模型为 deepseek-v4-flash（temperature 0），约 140 条单轮成本可忽略；但 temperature 0 不保证逐字节稳定，对比基线时若准确率波动在 ±1pp 内视为持平。

## 语料维护规则

1. 新增意图必须同步补语料（P1 意图注册表落地后，护栏测试断言「注册表内每个意图在语料中至少有 1 条样本」）；
2. 歧义样本标可接受集合，不标单值——评测尺子不制造假精确；
3. 真实用户样本从 ChatMessage 历史导出（需把 `ChatMessageRepository.loadRecentDTOsAsync` 的 predicate 放开为仅 user，或新增专用查询），脱敏后存 `corpus/real-v1.json`，与种子语料合并统计；
4. 基线报告建立后，删除/修改任何已有样本必须在报告 change_note 里留记录。

## 已知边界

- 评测用固定最小上下文；真实链路上下文含纪念日清单/备忘单等动态块（P0 起 `AIContextSection` 注册表供给）。依赖上下文的样本（如 `a01 妈妈生日是哪天`）已标可接受集合吸收该差异；
- `modify_task_items` 样本以内嵌「（最近任务：…）」前缀模拟备忘单上下文。
