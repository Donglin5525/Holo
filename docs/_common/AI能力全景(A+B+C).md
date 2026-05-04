# Holo AI 能力全景（Phase A+B+C 后）

> 生成日期：2026-05-05
> 基于 Phase A（基础洞察）、Phase B（结构化异常）、Phase C（个性化与质量闭环）完成后的完整 AI 能力清单

---

## 一、主动交互（用户触发）

### 1. AI 对话助手 — 自然语言操作

| Use Case | 说明 |
|----------|------|
| 记录收支 | "午饭花了35" → 自动识别类别、金额、创建交易 |
| 创建/完成任务 | "提醒我明天买牛奶" → 解析日期、创建待办 |
| 习惯打卡 | "打卡跑步" → 触发对应习惯的 check-in |
| 记录心情/体重 | "今天心情不错" → 记录 mood |
| 创建笔记 | "记一下：周五开会" → 创建 thought |
| 查询状态 | "我还有什么任务？" / "本周习惯完成怎么样？" |
| 多指令一次输入 | "午饭35，提醒我明天买牛奶" → 批量解析，顺序执行 |
| 低置信度澄清 | AI 不确定时主动追问，而非盲目执行 |
| 快捷按钮 | 8 个预设按钮（记支出、建任务、记心情等） |

### 2. AI 数据分析

| Use Case | 说明 |
|----------|------|
| 财务分析 | "这个月花了多少？" → 注入财务上下文，LLM 生成分析 |
| 习惯分析 | "最近跑步坚持得怎么样？" → 习惯完成率+趋势 |
| 任务分析 | "我最近拖延严重吗？" → 完成率+逾期统计 |
| 想法/情绪分析 | "我最近心情怎么样？" → mood 分布+标签+文本情感 |
| 跨域综合分析 | "总结一下我最近的生活状态" → 四域联动分析 |
| 对比分析 | "和上个月比怎么样？" → 自动计算对比期 |

### 3. AI 记忆洞察（回放）

| Use Case | 说明 |
|----------|------|
| 手动生成日/周/月报 | 点击触发 → 构建上下文 → AI 生成结构化洞察 |
| 查看洞察卡片 | habit/finance/task/thought/milestone/cross_domain/overview/anomaly 8 种卡片 |
| 查看异常卡片 | 红/橙/蓝 三级严重度可视化（消费飙升/预算超支/习惯断裂/任务过载） |
| 查看跨域关联 | "习惯完成率下降+外卖支出上升"这类跨模块发现 |
| 查看上期回顾 | 洞察中自动注入上期建议和异常，形成连续性 |
| 洞察评分反馈 | 对生成的洞察打分（Phase C 新增） |

### 4. AI 个性化配置

| Use Case | 说明 |
|----------|------|
| 选择 AI Provider | DeepSeek / 通义千问 / Moonshot / 智谱 / 自定义 |
| 编辑 Prompt 模板 | 8 个模板均可自定义覆写 |
| 在线测试 Prompt | 编辑后直接发送测试文本验证效果 |
| 编辑 HoloProfile | Markdown 格式的个人档案，注入到每次 AI 对话上下文 |

### 5. 智能分类学习

| Use Case | 说明 |
|----------|------|
| 纠正分类 → 自动学习 | AI 匹配失败 → 用户手动纠正 → 映射关系持久化 → 未来自动应用 |

**工程链路**：

```
用户输入 "家政200"
    │
    ▼
LLM 意图解析 → categoryCandidate: "家政"
    │
    ▼
IntentRouter.matchCategory()
    ├─ 精确匹配 ❌
    ├─ 同义词匹配 ❌
    ├─ 学习映射 ❌（首次）
    └─ 模糊匹配 ❌
    │
    ▼
兜底: ensurePendingCategory("待确认") + recordTransactionCandidate(id, "家政", .expense) → UserDefaults
    │
    ▼
用户看到: "⚠️ 无法识别分类「家政」，已暂归「待确认」，点击卡片可修改"
    │
    ▼
用户编辑 → 选择 "家政服务" → 保存
    │
    ▼
learnCategoryMappingIfNeeded()
    ├─ lookupTransactionCandidate(id) → ("家政", .expense)
    ├─ record("家政" → "家政服务") → UserDefaults
    └─ removeTransactionCandidate(id)
    │
    ▼
下次 "家政300" → 学习映射命中（策略 2.5, confidence 0.9）→ 直接分类 ✓
```

**存储设计**（UserDefaults）：

| Key | 类型 | 说明 |
|-----|------|------|
| `categoryLearnedMappings` | `[String: String]` | `"{type}\|{normalized}" → "{primary}\|{sub}"` |
| `transactionCategoryCandidates` | `[String: String]` | `{transactionUUID} → "{type}\|{candidate}"`（临时暂存） |

---

## 二、被动交互（系统触发）

### 6. 后台自动生成

| Use Case | 说明 |
|----------|------|
| BGAppRefreshTask 自动生成洞察 | 日/周/月报在后台自动触发 |
| 前台补偿 | 后台任务错过时，回到前台自动补生成 |

### 7. 定时通知

| Use Case | 说明 |
|----------|------|
| 周报提醒 | 可配置星期+时间，推送本地通知 |
| 月报提醒 | 可配置日期+时间，推送本地通知 |

### 8. 自动异常检测

| 异常类型 | 触发条件 |
|----------|----------|
| 消费飙升 | 日均支出 ≥ 上期 2 倍且 > ¥100 |
| 预算超支 | 分类预算 progress ≥ 100% |
| 预算预警 | 分类预算 progress ≥ 80% |
| 习惯断裂 | 日打卡习惯（非坏习惯）连续 ≥3 天未完成 |
| 任务过载 | 活跃任务 ≥10 且逾期 ≥3 |

### 9. 自动跨域关联

| 关联类型 | 条件 |
|----------|------|
| 习惯↔财务 | 习惯完成率下降 + 外卖支出上升 |
| 任务↔财务 | 逾期任务增加 + 支出上升 |
| 情绪↔习惯 | 负面情绪比例 >40% + 习惯完成率下降 |
| 任务↔习惯 | 两者完成率同频波动 |
| 情绪↔消费 | 负面情绪 + 支出突增 |
| 工作日/周末模式 | 日均消费比 >1.5 倍 |

### 10. 自动去重与缓存

| 机制 | 说明 |
|------|------|
| Snapshot Hash 缓存 | 数据没变 → 跳过重新生成 |
| Jaccard 去重 | 新洞察与近期 3 条相似度 >0.85 → 自动跳过 |
| 上期回顾注入 | 自动拉取上期洞察的建议和异常，注入本期上下文 |

---

## 三、当前能力边界

### 能做的

- 自然语言 → 结构化操作（15 种意图）
- 周期性数据 → 结构化洞察卡片（8 种类型）
- 跨模块发现 + 异常预警
- 个性化 profile 注入
- 智能分类学习

### 还不能做的

- **Siri / Shortcuts / 小组件集成**：无 AppIntents
- **推送级别主动触达**：只有本地通知，没有远程推送触发 AI 分析
- **多轮对话上下文记忆**：每次对话独立，无长期对话记忆
- **主动建议推送**：如"检测到你本周外卖支出偏高，要不要调整预算？"（需要主动触达能力）
- **实时异常告警**：异常只在生成洞察时计算，不会即时通知

### 下一步方向

如果要让 AI 更有"存在感"，核心方向是 **主动推送 + 实时感知**。

---

## 四、涉及文件索引

| 模块 | 关键文件 | 数量 |
|------|----------|------|
| Services/AI/ | AIProvider, IntentRouter, ConversationCoordinator, PromptManager, MemoryInsightService, CrossModuleCorrelator, CategoryLearnedMapping, AnalysisContextBuilder 等 | 27 |
| Models/AI/ | AIModels, AIConfiguration, ChatCardData, AnalysisContext, AnalysisDomain 等 | 7 |
| Views/Chat/ | ChatView, ChatViewModel, QuickActionBar, ChatCards 等 | 11 |
| Views/MemoryGallery/ | MemoryGalleryView, MemoryInsightCardView, MemoryInsightHeroCard 等 | 17 |
| Views/Settings/ | AISettingsView, PromptEditorView, HoloProfileEditorView 等 | 6 |
| **总计** | | **73 文件** |
