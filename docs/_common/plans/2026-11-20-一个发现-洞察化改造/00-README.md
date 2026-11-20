# 一个发现 · 洞察化改造（v4）文档包

> 日期：2026-11-20 ｜ 状态：方案已定，待实施 ｜ 前序：v3 `../2026-11-08-一个发现-全领域萃取与后端确认评审稿.md`

## 一句话目标

让「一个发现」从「把统计数字换个说法念一遍」，变成「一句用户没意识到、有证据、能接上用户自己生活的判断」。做法是**不再自己挖数据，改为站在「Holo 记住的你」记忆系统之上**。

## 文档清单（按阅读顺序）

| 文件 | 给谁看 | 内容 |
|---|---|---|
| `01-方案总纲.md` | 所有实施 agent 必读 | 问题根因、洞察及格线、目标架构、隐私决策、数据契约 |
| `02-后端实施.md` | 后端 agent | 新 purpose `discovery_insight_v2`、prompt、质量闸门、流式、发版 |
| `03-iOS实施.md` | iOS agent | 候选构建、证据填充、卡片 UI、反馈回流记忆、兜底 |
| `04-验证与验收.md` | 实施完成后的验证 agent | 基线打分、新旧对比、测试清单、上线开关 |

## 实施顺序与依赖

```
P0 基线诊断（04 §1）── 可与 P1 并行
P1 数据契约冻结（01 §5）── 后端/iOS 共同依赖，先由一个 agent 落成代码里的 schema
P2 后端（02）  ┐ 契约冻结后可并行
P3 iOS（03）   ┘
P4 验证（04）
```

## 已拍板的决策（实施 agent 不要再推翻）

1. **隐私级别对齐记忆系统**：允许把「画像条目 + 七域蒸馏特征包」的去标识化描述发给模型，与 `portraitSynthesis` 同一级别，复用同一套 `PortraitSafetyGate`。**数字仍不由模型生成**，由端侧证据槽位填充。
2. **旧链路 v3 保留作兜底**，由开关控制，不删除代码，验收通过后另开任务清理。
3. **宁缺毋滥**：当天无达标洞察就不出卡，沿用 v3「不硬选」。
4. **反馈闭环进记忆**：「准」写回画像为已确认，「不准」进画像拒绝黑名单。

## 通用红线（摘自 AGENTS.md / CLAUDE.md，实施时必须遵守）

- 预期 >20s 的 AI 调用必须端到端流式（`stream=true`），否则移动网络 ~30s 被 NAT 切断。
- Prompt 双端同步：后端 `defaultPrompts.json` 为生效端，iOS `PromptManager.swift` 放后备并升版本号。
- 后端发版走 `holo-backend-deploy` 技能，不手敲 docker build。
- Swift：禁 `!` 强解、禁 `print()`、日期用 `DateFormatter` + `zh_CN`、ScrollView 隐藏滚动条。
- Core Data 测试方法必须 `async throws`；测试改动用 `test_sim` 验证编译。
- 修改 >3 个文件先拆任务；出 bug 先写重现测试。
- 改 prompt 前先读 `docs/standards/PROMPT_GUIDELINES.md`。

## 待实施 agent 首先核实的事实（方案撰写时未完全追到）

- [ ] `DiscoveryCapsuleView` 的挂载点（推测在 Chat 快捷操作栏）。
- [ ] iOS `PromptManager.swift` 中确实没有 `discovery_topic_v1` 后备。
- [ ] 画像条目桥接进统一知识库的具体类型与 key 格式（`HoloPortraitSynthesisRuntime.swift`）。
- [ ] `PortraitStore` 是否已有拒绝黑名单的写入 API，可供反馈回流复用。
