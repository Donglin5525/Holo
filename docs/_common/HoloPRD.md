# Holo - 产品需求文档（PRD）

> **版本**：v2.0.0
> **日期**：2026-03-21
> **产品名称**：Holo
> **文档状态**：活文档（随开发进度更新）

---

## 模块状态说明

| 模块 | 状态 | 文档位置 |
|------|------|---------|
| 记账（Finance） | ✅ 已实现 | `docs/finance/` |
| 习惯追踪（Habits） | ✅ 已实现 | `docs/habits/`（如有） |
| 待办（Todo） | 🚧 开发中 | `docs/todo/` |
| 日历（Calendar） | 📋 规划中 | 本文件 |
| 思考（Thoughts） | 📋 规划中 | 本文件 |
| 健康（Health） | 📋 规划中 | 本文件 |
| AI 能力 | ✅ 已实现(MVP) | 本文件 |

> **说明**：已实现模块的详细 PRD 和开发文档请查看对应模块目录下的文件。本文件保留作为产品愿景和长期规划的参考。

---

## 一、产品概述

### 1.1 产品愿景

做一款"个人数据资产 + AI 规划"一体化的个人 AI 助理，让用户把财务、任务、想法、习惯与身体状态统一沉淀，并由 AI 将数据转化为可执行的计划与长期人生策略。

### 1.2 一句话定位

一个把个人生活数据沉淀为资产，并由 AI 输出可执行规划与复盘的个人 AI 助理，让用户用更少的意志力持续变得更好。

### 1.3 目标用户

- **核心用户画像**：希望把生活"系统化管理"的大众用户，缺乏系统性方法论但有意愿改善生活
- **细分人群**：
  - 目标导向、计划型用户，需要清晰的执行路径
  - 希望量化自己并持续改进的用户（记账、健身、习惯培养、情绪管理）
  - 喜欢记录与反思、希望把内容沉淀为认知资产的用户

### 1.4 核心价值主张

- **All-in-one 只是入口，AI 规划闭环才是护城河**：不仅记录，还能把记录变成策略、计划与行动
- **跨域联动**：财务状态影响情绪与行为，Todo 与习惯影响健康，AI 能把这些关联看见并给出系统性建议
- **个人化长期陪伴**：随着数据积累，建议会更懂用户，形成"个人专属的生活操作系统"

### 1.5 产品成功标准

| 指标 | 定义 | 目标 |
|------|------|------|
| 留存 | 日活使用频次稳定 | 记账/打卡/代办至少一种高频入口日活 |
| 沉淀 | 用户每周形成可复盘的结构化数据 | 财务、习惯、身体、想法至少 2 类 |
| 转化为行动 | AI 生成的计划被采纳并执行 | 预算遵守率、训练完成率、习惯连续天数 |
| 复盘有效 | 周/月复盘输出明确的变化与下一步建议 | 用户能够感知收益 |

---

## 二、产品架构

### 2.1 交互架构：对话式交互（Chat-First）

Holo 采用对话式交互架构，核心理念参考钢铁侠 Jarvis：AI 作为用户的智能伙伴，通过自然语言理解用户意图，自动完成数据分类、存储和分析。

**核心交互流程**：
1. 用户通过自然语言输入信息（文字或语音）
2. AI 解析用户意图，提取结构化数据
3. 数据自动分类存储到对应模块
4. AI 即时反馈确认，并在合适时机提供洞察和建议

### 2.2 技术栈概览

| 层级 | 技术选型 | 说明 |
|------|---------|------|
| UI 框架 | SwiftUI（iOS 16+） | Apple 原生，声明式 UI |
| 架构模式 | MVVM + Clean Architecture | 清晰分层，易维护 |
| 本地数据库 | SQLite + SQLite.swift | 轻量、本地优先、隐私友好 |
| AI 服务 | OpenAI/Claude API + 协议抽象 | 多 Provider 支持，可切换 |
| 网络层 | URLSession + async/await | 原生异步网络 |
| 图表 | SwiftUI Charts（iOS 16+） | 原生图表库 |
| 语音识别 | SFSpeechRecognizer | Apple 系统级语音识别 |
| 包管理 | Swift Package Manager | Xcode 原生支持 |
| 代码规范 | SwiftLint | 自动代码检查 |
| 加密存储 | Keychain + SQLCipher（可选） | 敏感数据安全 |

### 2.3 系统架构图

```
┌──────────────────────────────────────────────────────┐
│                   Presentation Layer                  │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐ │
│  │  Chat View   │  │  Dashboard   │  │  Settings   │ │
│  └──────┬──────┘  └──────┬───────┘  └──────┬──────┘ │
│         │                │                  │         │
│  ┌──────┴────────────────┴──────────────────┴──────┐ │
│  │              ViewModels (MVVM)                   │ │
│  └──────────────────────┬──────────────────────────┘ │
├─────────────────────────┼────────────────────────────┤
│                   Domain Layer                        │
│  ┌──────────────────────┴──────────────────────────┐ │
│  │                  Use Cases                       │ │
│  │  ParseInput / GenerateInsight / ManageRecords    │ │
│  └──────────────────────┬──────────────────────────┘ │
│  ┌──────────────────────┴──────────────────────────┐ │
│  │               Entities & Interfaces              │ │
│  └──────────────────────┬──────────────────────────┘ │
├─────────────────────────┼────────────────────────────┤
│                    Data Layer                         │
│  ┌────────────┐  ┌─────┴──────┐  ┌────────────────┐ │
│  │  SQLite DB  │  │  AI Service │  │  Sync Service  │ │
│  │  (Local)    │  │  (Remote)   │  │  (预留)        │ │
│  └────────────┘  └────────────┘  └────────────────┘ │
└──────────────────────────────────────────────────────┘
```

---

## 三、功能需求详细说明

### 3.1 对话系统（Chat System）

对话系统是 Holo 的核心交互入口，所有数据的录入和查询都可以通过自然语言完成。

#### 3.1.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 文字输入 | 支持自然语言文字输入，AI 自动解析意图和数据 | P0 |
| 语音输入 | 支持语音转文字，调用 SFSpeechRecognizer | P1 |
| 快捷模板 | 提供场景化快捷入口（记账、新建任务、记录体重等） | P0 |
| 消息气泡 | 区分用户消息和 AI 回复，支持不同类型的消息样式 | P0 |
| 上下文对话 | 支持多轮对话，AI 可以追问不明确的信息 | P0 |
| 历史记录 | 对话历史可查看和搜索 | P1 |
| 离线暂存 | 无网络时暂存用户输入，联网后自动发送解析 | P1 |

#### 3.1.2 AI 意图识别

AI 需要从用户的自然语言中识别以下意图类型：

| 意图类型 | 示例输入 | 提取数据 |
|----------|---------|----------|
| 记账 | "午饭花了 35 块" | 金额: 35, 分类: 餐饮, 类型: 支出 |
| 新建任务 | "明天下午三点开会" | 任务: 开会, 时间: 明天 15:00 |
| 记录心情 | "今天心情不错，项目顺利推进" | 心情: 开心, 备注: 项目顺利推进 |
| 记录体重 | "今天体重 72.5kg" | 体重: 72.5, 单位: kg |
| 打卡 | "今天跑步打卡" | 习惯: 跑步, 状态: 已完成 |
| 查询 | "这个月花了多少钱" | 查询类型: 财务汇总, 范围: 本月 |
| 闲聊/建议 | "帮我规划一下明天的安排" | 请求类型: AI 规划 |

#### 3.1.3 AI 追问机制

当用户输入信息不完整时，AI 应主动追问：
- "午饭" → AI 确认分类："这笔消费属于餐饮类吗？"
- "花了钱" → AI 追问金额："具体花了多少呢？"
- "记一下" → AI 追问内容："你想记录什么内容呢？是记账、任务还是想法？"

---

### 3.2 待办任务（Todo）

#### 3.2.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 新增任务 | 通过对话或快捷入口创建任务 | P0 |
| 完成任务 | 标记任务为已完成 | P0 |
| 编辑任务 | 编辑任务标题、描述、截止时间 | P0 |
| 清单管理 | 支持多个清单，不同清单下任务独立隔离 | P0 |
| 标签管理 | 支持标签分类（工作、生活、副业等） | P1 |
| 时间管理 | 设置截止时间，未完成任务自动延续到第二天 | P0 |
| 未来规划 | 支持对未来事务进行规划和排期 | P1 |
| 重复提醒 | 支持重复性事项（生日、纪念日等） | P1 |
| 周期提醒 | 支持按日/周/月固定周期提醒 | P1 |
| 四象限整理 | 按紧急/重要维度对任务进行分类 | P2 |

#### 3.2.2 任务数据模型

```
Task {
  id: UUID                    // 唯一标识
  title: String               // 任务标题
  description: String?        // 任务描述
  listId: UUID                // 所属清单
  tags: [String]              // 标签列表
  priority: Priority          // 优先级（高/中/低）
  status: TaskStatus          // 状态（待办/进行中/已完成/已取消）
  dueDate: Date?              // 截止日期
  dueTime: Date?              // 截止时间
  isAllDay: Bool              // 是否全天任务
  repeatRule: RepeatRule?     // 重复规则
  createdAt: Date             // 创建时间
  completedAt: Date?          // 完成时间
  updatedAt: Date             // 更新时间
  rawInput: String?           // 用户原始输入（对话记录）
}

TaskList {
  id: UUID                    // 唯一标识
  name: String                // 清单名称
  icon: String?               // 图标
  color: String?              // 颜色
  sortOrder: Int              // 排序
  createdAt: Date             // 创建时间
}

RepeatRule {
  type: RepeatType            // daily / weekly / monthly / yearly
  interval: Int               // 间隔（每 N 天/周/月/年）
  endDate: Date?              // 结束日期（可选）
  daysOfWeek: [Int]?          // 每周几（仅 weekly 类型）
  dayOfMonth: Int?            // 每月几号（仅 monthly 类型）
}
```

---

### 3.3 记账（Finance）

#### 3.3.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 基础记账 | 记录每笔收入和支出 | P0 |
| 自定义科目 | 用户可创建自定义的收入和支出分类 | P0 |
| 消费详情 | 支持自定义消费名称、备注 | P0 |
| 分期账单 | 支持分期付款的账单记录 | P1 |
| 固定开支 | 支持重复性固定开支（如订阅会员费） | P1 |
| 数据导入 | 支持固定格式数据的导入 | P2 |
| 数据导出 | 支持固定格式数据的导出 | P2 |
| 可视化仪表盘 | 对财务收支情况进行图表分析 | P1 |
| 预算管理 | 设置月度/周度预算，追踪执行情况 | P1 |
| 余额分析 | 展示资产负债概览 | P2 |

#### 3.3.2 财务数据模型

```
Transaction {
  id: UUID                    // 唯一标识
  type: TransactionType       // 收入 / 支出
  amount: Decimal             // 金额
  categoryId: UUID            // 分类 ID
  name: String?               // 消费名称
  note: String?               // 备注
  date: Date                  // 交易日期
  accountId: UUID?            // 账户 ID（预留）
  isInstallment: Bool         // 是否分期
  installmentInfo: Installment? // 分期信息
  isRecurring: Bool           // 是否固定开支
  recurringRule: RepeatRule?  // 重复规则
  tags: [String]              // 标签
  createdAt: Date             // 创建时间
  updatedAt: Date             // 更新时间
  rawInput: String?           // 用户原始输入
}

Category {
  id: UUID                    // 唯一标识
  name: String                // 分类名称
  icon: String                // 图标
  type: TransactionType       // 收入 / 支出
  parentId: UUID?             // 父分类（支持二级分类）
  isSystem: Bool              // 是否系统预设
  sortOrder: Int              // 排序
}

Installment {
  totalPeriods: Int           // 总期数
  currentPeriod: Int          // 当前期数
  totalAmount: Decimal        // 总金额
  perPeriodAmount: Decimal    // 每期金额
}

Budget {
  id: UUID                    // 唯一标识
  categoryId: UUID?           // 关联分类（可选，为空则为总预算）
  amount: Decimal             // 预算金额
  period: BudgetPeriod        // 周期（周/月/年）
  startDate: Date             // 开始日期
}
```

#### 3.3.3 预设分类

**支出分类**：餐饮、交通、购物、娱乐、居住、医疗、教育、通讯、服饰、运动、旅行、人情、宠物、其他

**收入分类**：工资、奖金、兼职、投资收益、红包、退款、其他

---

### 3.4 日历（Calendar）

#### 3.4.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 日历视图 | 支持日历/周历/月历三种视图切换 | P0 |
| 联动待办 | 待办中有截止时间的任务自动同步到日历 | P0 |
| 创建事项 | 支持在日历中直接创建待办事项 | P0 |
| 日历明细 | 日历视图展示每个日程的明细安排和备注 | P0 |
| 周历/月历 | 周历和月历显示更多信息，隐藏备注 | P1 |
| 时间块显示 | 按时间轴展示日程安排 | P1 |

#### 3.4.2 日历数据模型

```
CalendarEvent {
  id: UUID                    // 唯一标识
  title: String               // 事件标题
  description: String?        // 描述
  startDate: Date             // 开始时间
  endDate: Date?              // 结束时间
  isAllDay: Bool              // 是否全天
  linkedTaskId: UUID?         // 关联的任务 ID
  color: String?              // 颜色标记
  reminder: Reminder?         // 提醒设置
  createdAt: Date             // 创建时间
  updatedAt: Date             // 更新时间
}

Reminder {
  type: ReminderType          // 提前提醒类型
  offsetMinutes: Int          // 提前多少分钟
}
```

---

### 3.5 思考（Thoughts）

#### 3.5.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 文本记录 | 支持文本内容的保存 | P0 |
| 图片保存 | 支持图片内容的保存 | P1 |
| 富文本编辑 | 支持加粗、斜体、划线、有序/无序列表 | P1 |
| Markdown | 支持移动端 Markdown 语法 | P1 |
| 心情记录 | 提供心情模板（高兴/开心/沮丧/平静/愤怒等） | P0 |
| 标记分类 | 支持按不同内容类型进行标记 | P0 |
| 思维链 | 支持一条想法引用上一条想法，形成思维链 | P2 |

#### 3.5.2 思考数据模型

```
Thought {
  id: UUID                    // 唯一标识
  content: String             // 内容（Markdown 格式）
  type: ThoughtType           // 类型（想法/成就/收获/反思）
  mood: Mood?                 // 心情
  tags: [String]              // 标签
  images: [ImageAttachment]   // 图片附件
  parentThoughtId: UUID?      // 引用的上一条想法（思维链）
  createdAt: Date             // 创建时间
  updatedAt: Date             // 更新时间
  rawInput: String?           // 用户原始输入
}

Mood {
  type: MoodType              // 高兴/开心/平静/沮丧/愤怒/焦虑/疲惫/兴奋
  score: Int                  // 1-10 情绪评分
  note: String?               // 心情备注
}

ImageAttachment {
  id: UUID                    // 唯一标识
  localPath: String           // 本地存储路径
  thumbnailPath: String       // 缩略图路径
  width: Int                  // 宽度
  height: Int                 // 高度
  createdAt: Date             // 创建时间
}
```

#### 3.5.3 预设心情模板

| 心情 | 图标 | 评分范围 |
|------|------|---------|
| 兴奋 | 🤩 | 9-10 |
| 高兴 | 😄 | 8-9 |
| 开心 | 😊 | 7-8 |
| 平静 | 😌 | 5-6 |
| 疲惫 | 😩 | 3-4 |
| 沮丧 | 😔 | 2-3 |
| 焦虑 | 😰 | 2-3 |
| 愤怒 | 😤 | 1-2 |

---

### 3.6 健康（Health）

#### 3.6.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 体重记录 | 手动记录体重数据 | P0 |
| 步数目标 | 设置每日步数目标，检测是否达标 | P1 |
| 睡眠目标 | 设置每日睡眠目标，检测是否达标 | P1 |
| Apple Health 接入 | 接入苹果健康系统获取步数、睡眠、心率等数据 | P2（架构预留） |
| 健康趋势 | 可视化展示体重、步数、睡眠等趋势图 | P1 |

#### 3.6.2 健康数据模型

```
HealthRecord {
  id: UUID                    // 唯一标识
  type: HealthType            // 类型（体重/步数/睡眠/心率/血压等）
  value: Double               // 数值
  unit: String                // 单位（kg/步/小时/bpm 等）
  date: Date                  // 记录日期
  source: DataSource          // 数据来源（手动/Apple Health/其他）
  note: String?               // 备注
  createdAt: Date             // 创建时间
}

HealthGoal {
  id: UUID                    // 唯一标识
  type: HealthType            // 目标类型
  targetValue: Double         // 目标值
  unit: String                // 单位
  period: GoalPeriod          // 周期（每日/每周）
  isActive: Bool              // 是否启用
  createdAt: Date             // 创建时间
}

DataSource {
  type: SourceType            // manual / appleHealth / thirdParty
  name: String                // 来源名称
  identifier: String?         // 外部标识（预留）
}
```

---

### 3.7 打卡习惯（Habits）

#### 3.7.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 创建习惯 | 创建打卡项目，支持编辑和删除 | P0 |
| 打卡追踪 | 支持每日/每周/每月打卡 | P0 |
| 目标管理 | 设置打卡目标（如一周打卡 5 天） | P0 |
| 数值习惯 | 支持数字类习惯（如每日抽烟次数、体重等） | P1 |
| 环比数据 | 按统计维度提供环比数据 | P1 |
| 可视化报表 | 展示所有习惯和打卡的完成情况与进度 | P1 |
| 连续天数 | 记录并展示连续打卡天数 | P0 |

#### 3.7.2 习惯数据模型

```
Habit {
  id: UUID                    // 唯一标识
  name: String                // 习惯名称
  icon: String                // 图标
  color: String               // 颜色
  type: HabitType             // 类型（打卡型 / 数值型）
  frequency: HabitFrequency   // 频率（每日/每周/每月）
  targetCount: Int?           // 目标次数（如一周 5 次）
  targetValue: Double?        // 目标数值（仅数值型）
  unit: String?               // 单位（仅数值型）
  isArchived: Bool            // 是否归档
  sortOrder: Int              // 排序
  createdAt: Date             // 创建时间
  updatedAt: Date             // 更新时间
}

HabitRecord {
  id: UUID                    // 唯一标识
  habitId: UUID               // 关联习惯 ID
  date: Date                  // 打卡日期
  isCompleted: Bool           // 是否完成（打卡型）
  value: Double?              // 记录数值（数值型）
  note: String?               // 备注
  createdAt: Date             // 创建时间
}

HabitFrequency {
  type: FrequencyType         // daily / weekly / monthly
  targetDays: Int             // 目标天数（如每周 5 天）
}
```

---

### 3.8 AI 能力（AI System）

#### 3.8.1 功能描述

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 意图识别 | 解析用户自然语言，提取结构化数据 | P0 |
| 数据感知 | 拉通用户所有数据进行综合分析 | P0 |
| 情绪感知 | 基于用户的思考和想法了解情绪状态 | P1 |
| 每日总结 | 生成今日花销、完成事项、情绪与状态总结 | P1 |
| 每周复盘 | 生成财务趋势、习惯完成率、体重变化等复盘 | P1 |
| 计划生成 | 生成下周计划（预算建议 + 健身目标 + 关键 Todo） | P2 |
| 消费建议 | 了解用户预算，给出消费建议 | P2 |
| 进度提醒 | 了解习惯打卡进度，给出进度提醒 | P1 |
| 个人知识库 | 每次对话调取单个用户的知识库，给出个性化建议 | P2 |

#### 3.8.2 AI Provider 协议设计

```
protocol AIProvider {
    // 解析用户自然语言输入，提取结构化数据
    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult

    // 生成数据洞察和分析报告
    func generateInsight(type: InsightType, data: AnalysisData) async throws -> Insight

    // 多轮对话
    func chat(messages: [ChatMessage], userContext: UserContext) async throws -> ChatResponse
}

ParsedResult {
  intent: UserIntent              // 识别到的用户意图
  confidence: Double              // 置信度（0-1）
  extractedData: [String: Any]    // 提取的结构化数据
  needsClarification: Bool        // 是否需要追问
  clarificationQuestion: String?  // 追问问题
  responseText: String            // AI 回复文本
}

InsightType {
  case dailySummary               // 每日总结
  case weeklyReview               // 每周复盘
  case monthlyReport              // 月度报告
  case budgetAdvice               // 预算建议
  case habitProgress              // 习惯进度
  case healthTrend                // 健康趋势
  case weeklyPlan                 // 周计划生成
}

UserContext {
  recentTransactions: [Transaction]   // 近期交易
  activeTasks: [Task]                 // 活跃任务
  recentThoughts: [Thought]           // 近期想法
  habitProgress: [HabitSummary]       // 习惯进度
  healthData: [HealthRecord]          // 健康数据
  userPreferences: UserPreferences    // 用户偏好
}
```

#### 3.8.3 Prompt 管理策略

| Prompt 类型 | 用途 | 更新频率 |
|-------------|------|---------|
| 意图识别 Prompt | 解析用户输入，提取数据 | 高频优化 |
| 每日总结 Prompt | 生成当日数据总结 | 中频优化 |
| 每周复盘 Prompt | 生成周度分析报告 | 低频优化 |
| 情绪分析 Prompt | 分析用户情绪状态 | 中频优化 |
| 规划建议 Prompt | 生成行动计划和建议 | 低频优化 |
| 闲聊对话 Prompt | 日常对话和陪伴 | 低频优化 |

Prompt 模板存储在本地配置文件中，支持远程更新（预留），便于 A/B 测试和持续优化。

---

### 3.9 全局通用能力

#### 3.9.1 推送通知（Push Notification）

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 任务到期提醒 | 待办任务到期前推送提醒 | P0 |
| 重复事项提醒 | 重复性事项按规则推送 | P1 |
| 打卡提醒 | 每日习惯打卡提醒 | P1 |
| AI 洞察推送 | AI 生成的每日总结/周报推送 | P2 |
| 预算预警 | 接近或超出预算时推送提醒 | P2 |
| 自定义提醒时间 | 用户可设置各类提醒的时间 | P1 |

**技术实现**：
- 本地通知：使用 UNUserNotificationCenter 实现本地定时推送
- 远程推送（预留）：APNs（Apple Push Notification service）

#### 3.9.2 语音转文字

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 实时语音识别 | 用户说话时实时转为文字 | P1 |
| 中文支持 | 支持中文普通话识别 | P1 |
| 语音输入按钮 | 在输入框提供语音输入入口 | P1 |

**技术实现**：使用 Apple SFSpeechRecognizer，系统级集成，免费，支持中文。

#### 3.9.3 搜索能力

| 功能项 | 说明 | 优先级 |
|--------|------|--------|
| 全局搜索 | 跨模块搜索所有数据 | P1 |
| 模块内搜索 | 在特定模块内搜索 | P1 |
| 关键词高亮 | 搜索结果关键词高亮 | P2 |

---

## 四、数据库设计

### 4.1 数据库选型

- **主数据库**：SQLite（通过 SQLite.swift 操作）
- **存储位置**：App 沙盒内 Documents 目录
- **加密**：可选 SQLCipher 加密（敏感数据场景）

### 4.2 ER 关系图

```
┌──────────┐     ┌──────────┐     ┌──────────────┐
│   User   │────<│   Task   │>────│   TaskList   │
└──────────┘     └──────────┘     └──────────────┘
     │                │
     │           ┌────┴────┐
     │           │Calendar │
     │           │  Event  │
     │           └─────────┘
     │
     ├────<┌─────────────┐     ┌──────────┐
     │     │ Transaction │>────│ Category │
     │     └─────────────┘     └──────────┘
     │           │
     │      ┌────┴────┐
     │      │ Budget  │
     │      └─────────┘
     │
     ├────<┌──────────┐
     │     │ Thought  │──── (self-reference: parentThoughtId)
     │     └──────────┘
     │
     ├────<┌──────────────┐     ┌──────────────┐
     │     │ HealthRecord │     │  HealthGoal  │
     │     └──────────────┘     └──────────────┘
     │
     ├────<┌──────────┐     ┌──────────────┐
     │     │  Habit   │────<│ HabitRecord  │
     │     └──────────┘     └──────────────┘
     │
     └────<┌──────────────┐
           │ ChatMessage  │
           └──────────────┘
```

### 4.3 核心表结构

#### users 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| nickname | TEXT | 昵称 |
| avatar_path | TEXT | 头像本地路径 |
| ai_provider | TEXT | 当前使用的 AI 服务商 |
| ai_api_key | TEXT | API Key（加密存储于 Keychain） |
| preferences_json | TEXT | 用户偏好设置（JSON） |
| created_at | INTEGER | 创建时间戳 |
| updated_at | INTEGER | 更新时间戳 |

#### chat_messages 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| role | TEXT | 角色（user / assistant / system） |
| content | TEXT | 消息内容 |
| parsed_intent | TEXT | 解析出的意图类型 |
| parsed_data_json | TEXT | 解析出的结构化数据（JSON） |
| linked_record_id | TEXT | 关联的数据记录 ID |
| linked_record_type | TEXT | 关联的数据类型 |
| created_at | INTEGER | 创建时间戳 |

#### tasks 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| title | TEXT | 任务标题 |
| description | TEXT | 任务描述 |
| list_id | TEXT (UUID) | 所属清单 |
| tags_json | TEXT | 标签（JSON 数组） |
| priority | INTEGER | 优先级（0=低, 1=中, 2=高） |
| status | INTEGER | 状态（0=待办, 1=进行中, 2=已完成, 3=已取消） |
| due_date | INTEGER | 截止日期时间戳 |
| is_all_day | INTEGER | 是否全天（0/1） |
| repeat_rule_json | TEXT | 重复规则（JSON） |
| completed_at | INTEGER | 完成时间戳 |
| raw_input | TEXT | 用户原始输入 |
| created_at | INTEGER | 创建时间戳 |
| updated_at | INTEGER | 更新时间戳 |

#### transactions 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| type | INTEGER | 类型（0=支出, 1=收入） |
| amount | REAL | 金额 |
| category_id | TEXT (UUID) | 分类 ID |
| name | TEXT | 消费名称 |
| note | TEXT | 备注 |
| date | INTEGER | 交易日期时间戳 |
| is_installment | INTEGER | 是否分期（0/1） |
| installment_json | TEXT | 分期信息（JSON） |
| is_recurring | INTEGER | 是否固定开支（0/1） |
| recurring_rule_json | TEXT | 重复规则（JSON） |
| tags_json | TEXT | 标签（JSON 数组） |
| raw_input | TEXT | 用户原始输入 |
| created_at | INTEGER | 创建时间戳 |
| updated_at | INTEGER | 更新时间戳 |

#### categories 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| name | TEXT | 分类名称 |
| icon | TEXT | 图标 |
| type | INTEGER | 类型（0=支出, 1=收入） |
| parent_id | TEXT (UUID) | 父分类 ID |
| is_system | INTEGER | 是否系统预设（0/1） |
| sort_order | INTEGER | 排序 |

#### thoughts 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| content | TEXT | 内容（Markdown） |
| type | TEXT | 类型（idea/achievement/reflection） |
| mood_type | TEXT | 心情类型 |
| mood_score | INTEGER | 心情评分（1-10） |
| mood_note | TEXT | 心情备注 |
| tags_json | TEXT | 标签（JSON 数组） |
| images_json | TEXT | 图片附件信息（JSON） |
| parent_thought_id | TEXT (UUID) | 引用的上一条想法 |
| raw_input | TEXT | 用户原始输入 |
| created_at | INTEGER | 创建时间戳 |
| updated_at | INTEGER | 更新时间戳 |

#### health_records 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| type | TEXT | 类型（weight/steps/sleep/heartRate） |
| value | REAL | 数值 |
| unit | TEXT | 单位 |
| date | INTEGER | 记录日期时间戳 |
| source_type | TEXT | 来源类型（manual/appleHealth） |
| source_name | TEXT | 来源名称 |
| note | TEXT | 备注 |
| created_at | INTEGER | 创建时间戳 |

#### habits 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| name | TEXT | 习惯名称 |
| icon | TEXT | 图标 |
| color | TEXT | 颜色 |
| type | INTEGER | 类型（0=打卡型, 1=数值型） |
| frequency_type | TEXT | 频率类型（daily/weekly/monthly） |
| target_count | INTEGER | 目标次数 |
| target_value | REAL | 目标数值（数值型） |
| unit | TEXT | 单位（数值型） |
| is_archived | INTEGER | 是否归档（0/1） |
| sort_order | INTEGER | 排序 |
| created_at | INTEGER | 创建时间戳 |
| updated_at | INTEGER | 更新时间戳 |

#### habit_records 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT (UUID) | 主键 |
| habit_id | TEXT (UUID) | 关联习惯 ID |
| date | INTEGER | 打卡日期时间戳 |
| is_completed | INTEGER | 是否完成（0/1） |
| value | REAL | 记录数值（数值型） |
| note | TEXT | 备注 |
| created_at | INTEGER | 创建时间戳 |

### 4.4 数据库索引设计

```sql
-- tasks 表索引
CREATE INDEX idx_tasks_list_id ON tasks(list_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_due_date ON tasks(due_date);
CREATE INDEX idx_tasks_created_at ON tasks(created_at);

-- transactions 表索引
CREATE INDEX idx_transactions_date ON transactions(date);
CREATE INDEX idx_transactions_category ON transactions(category_id);
CREATE INDEX idx_transactions_type ON transactions(type);

-- thoughts 表索引
CREATE INDEX idx_thoughts_type ON thoughts(type);
CREATE INDEX idx_thoughts_created_at ON thoughts(created_at);
CREATE INDEX idx_thoughts_mood_type ON thoughts(mood_type);

-- health_records 表索引
CREATE INDEX idx_health_records_type ON health_records(type);
CREATE INDEX idx_health_records_date ON health_records(date);

-- habit_records 表索引
CREATE INDEX idx_habit_records_habit_id ON habit_records(habit_id);
CREATE INDEX idx_habit_records_date ON habit_records(date);

-- chat_messages 表索引
CREATE INDEX idx_chat_messages_created_at ON chat_messages(created_at);
CREATE INDEX idx_chat_messages_intent ON chat_messages(parsed_intent);
```

### 4.5 数据库迁移策略

- 使用版本号管理数据库 Schema 变更
- 每次 Schema 变更创建对应的 Migration 文件
- App 启动时自动检测并执行未完成的迁移
- 迁移过程中保证数据不丢失

---

## 五、用户体系与账户管理

### 5.1 MVP 阶段

MVP 阶段采用**单机模式**，不需要用户注册和登录：
- 数据全部存储在本地
- 用户打开 APP 直接使用
- 提供基础的用户资料设置（昵称、头像）

### 5.2 后续扩展（预留）

| 功能 | 说明 | 阶段 |
|------|------|------|
| 账户注册/登录 | Apple ID 登录 / 手机号登录 | Phase 2 |
| 数据云端同步 | iCloud / 自建后端同步 | Phase 2 |
| 多设备支持 | 数据跨设备同步 | Phase 3 |
| 数据导出 | 支持导出为 JSON/CSV | Phase 2 |

---

## 六、数据安全与隐私策略

### 6.1 数据存储安全

| 安全措施 | 说明 | 优先级 |
|----------|------|--------|
| 本地存储优先 | 所有用户数据优先存储在设备本地 | P0 |
| Keychain 加密 | API Key 等敏感信息存储在 Keychain | P0 |
| SQLCipher 加密 | 数据库文件加密（可选） | P2 |
| 生物识别锁 | 支持 Face ID / Touch ID 解锁 APP | P1 |

### 6.2 AI 调用隐私

| 安全措施 | 说明 | 优先级 |
|----------|------|--------|
| 最小数据原则 | 发送给 AI 的数据仅包含当次对话必要的上下文 | P0 |
| 数据脱敏 | 敏感信息（如具体金额）在发送前进行脱敏处理（可选） | P2 |
| 本地预处理 | 使用 Apple NLP 框架进行基础分类，减少云端调用 | P2 |

### 6.3 隐私合规

| 合规项 | 说明 | 优先级 |
|--------|------|--------|
| 隐私政策 | 提供清晰的隐私政策说明 | P0 |
| 数据使用声明 | App Store 隐私标签声明 | P0 |
| 数据导出 | 用户可导出所有个人数据 | P1 |
| 数据删除 | 用户可一键删除所有数据 | P0 |
| 数据类型声明 | 声明收集的数据类型：财务、健康、用户内容 | P0 |

---

## 七、离线与同步策略

### 7.1 离线能力

| 功能 | 离线支持 | 说明 |
|------|---------|------|
| 数据浏览 | 完全支持 | 所有数据本地存储 |
| 手动记录 | 完全支持 | 通过快捷模板直接写入本地 |
| 对话输入 | 部分支持 | 暂存用户输入，联网后发送 AI 解析 |
| AI 分析 | 不支持 | 需要网络调用大模型 API |
| 图表展示 | 完全支持 | 基于本地数据渲染 |

### 7.2 离线队列设计

```
OfflineQueue {
  id: UUID                    // 唯一标识
  type: QueueType             // 队列类型（aiParse / aiInsight）
  payload: String             // 请求数据（JSON）
  status: QueueStatus         // 状态（pending / processing / completed / failed）
  retryCount: Int             // 重试次数
  maxRetries: Int             // 最大重试次数
  createdAt: Date             // 创建时间
  processedAt: Date?          // 处理时间
}
```

### 7.3 云端同步（预留）

架构层面预留 SyncService 协议接口：
- 支持增量同步
- 支持冲突解决策略（本地优先 / 远端优先 / 手动合并）
- 支持同步状态追踪

---

## 八、推送与通知系统

### 8.1 通知类型

| 通知类型 | 触发条件 | 实现方式 | 优先级 |
|----------|---------|---------|--------|
| 任务到期 | 任务截止时间前 N 分钟 | 本地通知 | P0 |
| 重复事项 | 按重复规则触发 | 本地通知 | P1 |
| 打卡提醒 | 每日固定时间 | 本地通知 | P1 |
| 每日总结 | 每天晚上固定时间 | 本地通知 | P2 |
| 预算预警 | 消费接近/超出预算 | 本地通知 | P2 |
| 周报推送 | 每周固定时间 | 本地通知 | P2 |

### 8.2 通知设置

用户可自定义：
- 各类通知的开关
- 打卡提醒时间
- 每日总结推送时间
- 勿扰时段

---

## 九、性能与质量要求

### 9.1 性能指标

| 指标 | 目标 |
|------|------|
| 冷启动时间 | 小于 2 秒 |
| 页面切换 | 小于 300ms |
| 数据库查询 | 单次查询小于 100ms |
| AI 响应时间 | 首字符输出小于 3 秒 |
| 内存占用 | 常驻内存小于 100MB |
| 包体积 | 小于 50MB |
| 帧率 | 滚动和动画保持 60fps |

### 9.2 质量要求

| 要求 | 说明 |
|------|------|
| 崩溃率 | 小于 0.1% |
| 数据完整性 | 数据写入必须保证原子性 |
| 错误处理 | 所有网络请求和数据库操作需要错误处理 |
| 日志系统 | 关键操作记录日志，便于排查问题 |
| 单元测试 | 核心业务逻辑测试覆盖率大于 80% |

---

## 十、数据导入导出设计

### 10.1 导出功能

| 导出格式 | 支持的数据 | 优先级 |
|----------|-----------|--------|
| CSV | 财务数据、习惯打卡数据 | P2 |
| JSON | 全量数据备份 | P2 |

### 10.2 导入功能

| 导入格式 | 支持的数据 | 优先级 |
|----------|-----------|--------|
| CSV | 财务数据（固定模板） | P2 |
| JSON | 全量数据恢复 | P2 |

### 10.3 导入导出模板

提供标准化的 CSV 模板供用户下载，包含字段说明和示例数据。

---

## 十一、外部数据源接入预留设计

### 11.1 数据源接口协议

```
protocol ExternalDataSource {
    var sourceType: SourceType { get }
    var sourceName: String { get }
    var isConnected: Bool { get }

    func connect() async throws
    func disconnect() async throws
    func fetchData(from: Date, to: Date) async throws -> [ExternalRecord]
    func syncLatest() async throws -> [ExternalRecord]
}

ExternalRecord {
  sourceType: SourceType          // 数据来源类型
  recordType: String              // 记录类型
  data: [String: Any]             // 原始数据
  timestamp: Date                 // 数据时间
}
```

### 11.2 计划接入的数据源

| 数据源 | 数据类型 | 接入阶段 |
|--------|---------|---------|
| Apple HealthKit | 步数、睡眠、心率、体重 | Phase 2 |
| Apple Calendar | 日程事件 | Phase 2 |
| Apple Reminders | 待办事项 | Phase 3 |
| 微信/支付宝账单 | 财务数据（通过 CSV 导入） | Phase 2 |
| 运动类 APP | 运动数据 | Phase 3 |

---

## 十二、MVP 范围定义与优先级

### 12.1 MVP 功能范围

**MVP 核心目标**：跑通"记录 → AI 总结 → 给出计划 → 跟进执行"一条主线。

| 模块 | MVP 包含功能 | 不包含（后续迭代） |
|------|-------------|-------------------|
| 对话系统 | 文字输入、意图识别、快捷模板、上下文对话 | 语音输入、历史搜索 |
| 待办 | 新增/完成/编辑任务、清单管理、时间管理 | 四象限、标签管理、重复提醒 |
| 记账 | 基础记账、预设分类、消费详情 | 分期、固定开支、导入导出、预算 |
| 日历 | 日历视图、联动待办、创建事项 | 周历/月历切换 |
| 思考 | 文本记录、心情记录、标记分类 | 富文本、图片、思维链 |
| 健康 | 体重手动记录 | Apple Health 接入、步数/睡眠目标 |
| 打卡 | 创建习惯、每日打卡、连续天数 | 数值习惯、环比数据、可视化报表 |
| AI | 意图识别、数据感知、每日总结 | 每周复盘、计划生成、个人知识库 |
| 通知 | 任务到期提醒 | 打卡提醒、AI 推送、预算预警 |
| 设置 | 用户资料、AI 配置 | 数据导出、生物识别锁 |

### 12.2 功能优先级矩阵

| 优先级 | 定义 | 功能列表 |
|--------|------|---------|
| P0 | 必须有，MVP 核心 | 对话输入、意图识别、基础记账、任务管理、心情记录、体重记录、打卡、日历联动、任务提醒 |
| P1 | 重要，MVP 后首批迭代 | 语音输入、标签管理、预算管理、可视化仪表盘、每周复盘、打卡提醒、搜索、生物识别 |
| P2 | 锦上添花，中期迭代 | 数据导入导出、Apple Health 接入、计划生成、个人知识库、思维链、四象限、数据库加密 |

---

## 十三、非功能性需求

### 13.1 兼容性

| 要求 | 说明 |
|------|------|
| 最低系统版本 | iOS 16.0 |
| 设备支持 | iPhone（iPad 预留） |
| 屏幕适配 | 支持所有 iPhone 屏幕尺寸 |
| 深色模式 | 支持 Light / Dark Mode |
| 动态字体 | 支持系统动态字体大小 |
| 多语言 | MVP 阶段仅支持简体中文，预留国际化框架 |

### 13.2 可访问性

| 要求 | 说明 |
|------|------|
| VoiceOver | 支持 VoiceOver 无障碍访问 |
| 动态字体 | 支持 Dynamic Type |
| 高对比度 | 支持高对比度模式 |

### 13.3 可维护性

| 要求 | 说明 |
|------|------|
| 代码规范 | 使用 SwiftLint 强制代码规范 |
| 文档 | 使用 DocC 生成 API 文档 |
| 日志 | 统一日志框架，支持分级输出 |
| 错误追踪 | 预留 Crash 上报能力（如 Firebase Crashlytics） |

---

## 十四、后续迭代路线图

### Phase 1 - MVP 核心（4-6 周）

- 项目脚手架搭建
- 数据库设计与实现
- 对话系统 UI + AI 意图识别
- 基础记账功能
- 基础任务管理
- 心情和体重记录
- 习惯打卡
- 日历联动
- 本地通知

### Phase 2 - 功能完善（4-6 周）

- 语音输入
- 可视化仪表盘（SwiftUI Charts）
- 预算管理
- 每周复盘 AI 报告
- Apple HealthKit 接入
- 数据导入导出
- 生物识别锁
- 账户系统 + 云端同步

### Phase 3 - 深度 AI（4 周）

- AI 计划生成
- 个人知识库
- 跨域联动分析
- 情绪趋势分析
- Prompt 优化与 A/B 测试

### Phase 4 - 生态扩展（持续）

- iPad 适配
- macOS 版本
- Apple Watch 快捷记录
- Widget 小组件
- Siri Shortcuts 集成
- 更多外部数据源接入
- 商业化（免费增值模式）

---

## 附录

### A. 术语表

| 术语 | 定义 |
|------|------|
| Holo | 产品名称，寓意全息化的个人生活管理 |
| 数据资产 | 用户沉淀的所有结构化个人数据 |
| AI Provider | AI 服务提供商（如 OpenAI、Anthropic） |
| 意图识别 | AI 从自然语言中识别用户目的的过程 |
| 洞察 | AI 基于数据分析生成的总结和建议 |
| 思维链 | 想法之间的引用关系，形成思考脉络 |

### B. 参考竞品

| 竞品 | 特点 | Holo 差异化 |
|------|------|------------|
| 随手记 | 专业记账 | Holo 是全域数据 + AI 规划 |
| 滴答清单 | 专业任务管理 | Holo 跨域联动，AI 驱动 |
| Notion | 全能工作空间 | Holo 更聚焦个人生活，对话式交互 |
| Daylio | 心情日记 | Holo 将情绪与其他数据关联分析 |
| Apple Health | 健康数据 | Holo 将健康与财务、任务等联动 |

### C. 风险与应对

| 风险 | 影响 | 应对策略 |
|------|------|---------|
| AI 意图识别准确率不足 | 用户体验差，数据错误 | 提供快捷模板作为兜底，AI 追问机制，用户可手动修正 |
| AI API 成本过高 | 运营成本压力 | 本地预处理减少调用次数，缓存常见分析结果 |
| 用户输入习惯培养困难 | 留存率低 | 快捷模板降低门槛，推送提醒培养习惯 |
| 数据隐私顾虑 | 用户不愿使用 | 本地存储优先，透明的隐私政策，最小数据原则 |
| 功能范围膨胀 | 开发周期延长 | 严格遵循 MVP 范围，YAGNI 原则 |
