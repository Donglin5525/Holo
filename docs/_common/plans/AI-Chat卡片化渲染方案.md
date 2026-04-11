# AI Chat 卡片化渲染方案

## Context

当前 AI Chat 中，用户说"记一笔午饭 35 元"后，AI 返回的是纯文本 "已记录支出 ¥35（午饭）"，显示在普通聊天气泡中。这种呈现方式信息密度低、不够直观。需要将记账、任务创建、习惯打卡、心情记录、体重记录等操作结果渲染为结构化的卡片，提升信息可读性和交互体验。

---

## 设计理念

**共性框架 + 个性表达**：所有卡片共享统一的外壳（圆角、间距、阴影、交互），内容区域按领域自定义。

### 卡片视觉规范

```
┌─────────────────────────────────────┐
│  [图标]  标题          标签/徽章    │  ← 头部（icon + title + badge）
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  关键信息行 1                        │  ← 内容区（按卡片类型不同）
│  关键信息行 2                        │
│                                     │
│  🕐 时间信息              ›         │  ← 底部（时间 + 箭头指示可点击）
└─────────────────────────────────────┘
```

**统一属性**：
- 背景：`Color.holoCardBackground`
- 圆角：`HoloRadius.md` (12pt)
- 内边距：`HoloSpacing.md` (16pt)
- 阴影：`HoloShadow.card`, radius 4, y 2
- 边框：`Color.holoBorder`, lineWidth 1
- 最大宽度限制在聊天气泡内（左侧 AI 消息对齐）

**排版层级**（所有卡片统一）：
| 层级 | 元素 | 字体 | 颜色 |
|------|------|------|------|
| Header | 图标 + 标题 | `.holoBody` (16M) | `holoTextPrimary` |
| Key Value | 金额/数值 | `.holoHeading` (20S) | 支出红 `holoError` / 收入绿 `holoSuccess`，其他 `holoTextPrimary` |
| Secondary | 分类/描述/连续天数 | `.holoCaption` (14R) | `holoTextSecondary` |
| Footer | 时间 + 操作入口 | `.holoLabel` (12M) | `holoTextSecondary` |

**卡片 vs 气泡视觉关系**：卡片完全取代气泡，不使用 `BubbleShape`，使用自己的 `RoundedRectangle`。与文字气泡形成明确的视觉区分（操作结果 vs 对话文本）。AI 头像保留在左侧。

**交互状态**：
| 状态 | 表现 |
|------|------|
| Normal | 默认外观 |
| Pressed | scale(0.97) + opacity(0.8)，使用自定义 `CardButtonStyle`，0.15s easeInOut |
| 可点击提示 | 底部行显示时间 + `chevron.right` 箭头 + 按下反馈 |

**文字截断规则**：
| 元素 | 最大行数 | 说明 |
|------|---------|------|
| 标题/note | 1 行 | `.lineLimit(1)` |
| 内容/描述 | 2 行 | `.lineLimit(2)`，心情卡片专用 |
| 金额/数值 | 不限制 | 数字不会太长 |
| 分类路径 | 1 行 | `.lineLimit(1)` |

**空字段处理**：note 为 nil 时标题行显示分类名；streak 为 nil 时隐藏连续天数行；其他缺失字段隐藏对应行。

**Accessibility**：每个卡片添加 `.accessibilityLabel()`，格式如"记账卡片：午饭，支出35元"。卡片最小触控高度 44pt。

---

## 6 种卡片设计

### 1. 记账卡片 (Expense/Income)

```
┌─────────────────────────────────────┐
│  [分类SF Symbol]  午饭              │  ← 图标用分类的 SF Symbol
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  -¥35.00                            │  ← 金额（支出红色/收入绿色）
│  餐饮 · 午餐                        │  ← 分类路径
│  🕐 今天 12:30            查看 ›    │  ← 时间 + 操作入口
└─────────────────────────────────────┘
```

**图标**：使用该笔交易分类对应的 SF Symbol（如餐饮→`fork.knife`，交通→`car.fill`），从 `extractedData["primaryCategory"]` 匹配
**数据字段**：amount, note, primaryCategory, subCategory, type(expense/income), date

### 2. 任务卡片 (Task)

```
┌─────────────────────────────────────┐
│  checkmark.circle  完成项目报告      │  ← SF Symbol: checkmark.circle
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  🕐 今天                        ›   │
└─────────────────────────────────────┘
```

**数据字段**：title, dueDate, priority

### 3. 习惯打卡卡片 (Habit Check-in)

```
┌─────────────────────────────────────┐
│  flame.fill  跑步              ✅   │  ← SF Symbol: flame.fill + 打卡勾
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  连续打卡 7 天                       │  ← 连续天数（如有）
│  🕐 今天                查看 ›      │
└─────────────────────────────────────┘
```

**数据字段**：habitName, streak, completed

### 4. 心情记录卡片 (Mood)

```
┌─────────────────────────────────────┐
│  heart.fill  开心                   │  ← SF Symbol: heart.fill
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  今天天气不错，心情很好               │  ← 内容摘要（2行截断）
│  🕐 今天 14:30            查看 ›    │
└─────────────────────────────────────┘
```

**数据字段**：mood, content

### 5. 体重记录卡片 (Weight)

```
┌─────────────────────────────────────┐
│  scalemass.fill  体重记录            │  ← SF Symbol: scalemass.fill
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  65.5 kg                            │  ← 数值突出
│  🕐 今天                  查看 ›    │
└─────────────────────────────────────┘
```

**数据字段**：weight, unit

### 6. 通用确认卡片 (Fallback)

当有 intent 但无法渲染具体卡片时的兜底：

```
┌─────────────────────────────────────┐
│  sparkles  已完成操作                │  ← SF Symbol: sparkles
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│
│  已记录支出 ¥35（午饭）              │  ← 原始文本作为内容
└─────────────────────────────────────┘
```

**SF Symbol 图标总览**：

| 卡片类型 | SF Symbol | 来源 |
|---------|-----------|------|
| 记账 | 分类对应图标 | extractedData["primaryCategory"] 匹配 |
| 任务 | `checkmark.circle` | 固定 |
| 习惯打卡 | `flame.fill` | 固定 |
| 心情 | `heart.fill` | 固定 |
| 体重 | `scalemass.fill` | 固定 |
| 通用确认 | `sparkles` | 固定 |

> 所有新增 SF Symbol 名称实现前必须用 `NSImage(systemSymbolName:) != nil` 验证存在。

---

## 架构设计

### 数据层

**新增 `ChatCardData` 枚举** (在 `AIModels.swift` 中):

```swift
/// AI Chat 卡片数据
enum ChatCardData: Codable {
    case transaction(TransactionCardData)
    case task(TaskCardData)
    case habitCheckIn(HabitCheckInCardData)
    case mood(MoodCardData)
    case weight(WeightCardData)

    /// 从 intent + extractedData 构造卡片数据
    static func from(intent: AIIntent, data: [String: String]?) -> ChatCardData?
}

struct TransactionCardData: Codable {
    let amount: String
    let note: String?
    let primaryCategory: String?
    let subCategory: String?
    let type: String        // "expense" / "income"
    let date: String?
}

struct TaskCardData: Codable {
    let title: String
    let dueDate: String?
    let priority: String?
}

struct HabitCheckInCardData: Codable {
    let habitName: String
    let streak: Int?
    let completed: Bool
}

struct MoodCardData: Codable {
    let mood: String?
    let content: String
}

struct WeightCardData: Codable {
    let weight: String
    let unit: String
}
```

### 存储方式

**推荐方案：不新增字段**，直接在渲染时从 `intent` + `extractedDataJSON` 动态构造 `ChatCardData`。零数据迁移。

### 视图层

**新增 `ChatCardView`** (在 `Views/Chat/` 目录):

```swift
/// AI Chat 通用卡片容器
struct ChatCardView<Content: View>: View {
    let content: Content
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}
```

**新增各领域卡片视图**（在 `Views/Chat/Cards/` 目录）:
- `TransactionChatCard.swift` - 记账卡片
- `TaskChatCard.swift` - 任务卡片
- `HabitCheckInChatCard.swift` - 打卡卡片
- `MoodChatCard.swift` - 心情卡片
- `WeightChatCard.swift` - 体重卡片

### 消息渲染逻辑修改

修改 `MessageBubbleView.swift` 的 `bubbleContent`：

```
当前流程：
  AI 消息 → 纯文本气泡 + intent tag

新流程：
  AI 消息 → 判断是否有可渲染的卡片数据
    → 有卡片：卡片视图 + 底部简短确认文字（如"已帮你记好啦"）
    → 无卡片（chat/query）：保持原样文本气泡
```

---

## 交互设计

### 点击行为

| 卡片类型 | 点击后 |
|---------|--------|
| 记账 | 打开对应 transaction 的编辑 Sheet |
| 任务 | 跳转到任务详情 |
| 习惯打卡 | 跳转到习惯模块该习惯详情 |
| 心情 | 打开该观点详情 |
| 体重 | 跳转到体重习惯详情 |

### 简短确认文字

卡片下方保留一行简短的纯文本确认：

```
┌──────────────────┐
│  记账卡片内容      │
└──────────────────┘
已帮你记好啦～          ← 简短文字（普通 Text，不在气泡里）
```

---

## 需要修改的文件

| 文件 | 操作 | 说明 |
|------|------|------|
| `Models/AI/AIModels.swift` | 修改 | 新增 `ChatCardData` 枚举和各卡片数据结构 |
| `Views/Chat/MessageBubbleView.swift` | 修改 | 增加卡片渲染分支，替换纯文本气泡 |
| `Views/Chat/Cards/ChatCardView.swift` | **新建** | 通用卡片容器（外壳） |
| `Views/Chat/Cards/TransactionChatCard.swift` | **新建** | 记账卡片视图 |
| `Views/Chat/Cards/TaskChatCard.swift` | **新建** | 任务卡片视图 |
| `Views/Chat/Cards/HabitCheckInChatCard.swift` | **新建** | 习惯打卡卡片视图 |
| `Views/Chat/Cards/MoodChatCard.swift` | **新建** | 心情卡片视图 |
| `Views/Chat/Cards/WeightChatCard.swift` | **新建** | 体重卡片视图 |
| `Views/Chat/ChatView.swift` | 修改 | 增加 `onCardTap` 处理，导航到对应模块 |
| `Services/AI/IntentRouter.swift` | 修改 | `RouteResult` 增加 taskId、habitId 等关联 ID |

---

## 实现步骤

### Phase 1: 数据层（2 个文件）
1. 在 `AIModels.swift` 新增 `ChatCardData` 枚举 + 5 个数据结构
2. 实现 `ChatCardData.from(intent:data:)` 工厂方法
3. 扩展 `IntentRouter.RouteResult` 增加 `taskId`、`habitId`、`thoughtId`

### Phase 2: 通用卡片外壳（1 个文件）
4. 新建 `Views/Chat/Cards/ChatCardView.swift`

### Phase 3: 各领域卡片视图（5 个文件）
5. 新建 `TransactionChatCard.swift`
6. 新建 `TaskChatCard.swift`
7. 新建 `HabitCheckInChatCard.swift`
8. 新建 `MoodChatCard.swift`
9. 新建 `WeightChatCard.swift`

### Phase 4: 集成到消息渲染（2 个文件）
10. 修改 `MessageBubbleView.swift` — 增加卡片渲染分支
11. 修改 `ChatView.swift` — 传入 `onCardTap` 回调

### Phase 5: 增强数据存储（1 个文件）
12. 修改 `IntentRouter.swift` — 各 handler 返回关联实体 ID

---

## 验证方式

1. 编译通过，无 warning
2. AI Chat 中发送"记一笔午饭 35 元" → 显示记账卡片
3. AI Chat 中发送"帮我创建一个任务：完成报告" → 显示任务卡片
4. AI Chat 中发送"帮我打卡跑步" → 显示打卡卡片
5. AI Chat 中发送"今天心情不错" → 显示心情卡片
6. AI Chat 中发送闲聊内容 → 保持原样文本气泡（无卡片）
7. 点击各卡片 → 正确跳转到对应模块/详情
8. 深色模式下卡片样式正确

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 9 issues, 1 critical gap |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | clean | score: 6/10 → 9/10, 4 decisions |

**UNRESOLVED:** 0 unresolved decisions

**VERDICT:** CEO + ENG + DESIGN CLEARED — ready to implement. Eng critical gap (实体已删除时导航崩溃) 需在实现时处理。

### 审查决策记录

| # | 问题 | 决策 |
|---|------|------|
| 1 | 导航方式 | onCardTap 回调，ChatView 内部直接处理 |
| 2 | ChatCardData 文件位置 | 独立为 Models/AI/ChatCardData.swift |
| 3 | IntentRouter 返回值 | 所有 handler 统一返回 RouteResult，携带实体 ID |
| 4 | 过渡动画 | 直接替换，无额外动画 |
| 5 | intent tag | 卡片渲染时隐藏 |
| 6 | 降级策略 | 三层：纯文本 → 具体卡片 → 通用确认卡片 |
| 7 | 确认文字 | 不要，卡片本身就是确认 |
| 8 | 测试 | 补充 ChatCardData.from() + IntentRouter 单元测试 |
| 9 | JSON 解析缓存 | 不缓存，LazyVStack 已有复用 |

### Critical Gap

卡片点击导航时，实体可能已被用户删除。`handleCardTap()` 必须检查实体是否存在，不存在则显示提示而非打开详情。
