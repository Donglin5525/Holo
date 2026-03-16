# 财务模块：分期记账 + 全局搜索

## Context

HOLO 财务模块目前支持单笔记账（收入/支出），但缺少两个常见功能：
1. **分期记账** — 信用卡分期、花呗分期等场景下，用户需要一次录入、自动拆分为多期交易
2. **全局搜索** — 交易记录越来越多后，无法快速按关键词找到历史交易

---

## 功能一：分期记账

### 1.1 数据模型变更

**文件：** `CoreDataStack.swift` — Transaction Entity 新增 3 个可选字段（支持轻量级迁移）

| 字段 | 类型 | 说明 |
|------|------|------|
| `installmentGroupId` | UUID? | 分期组 ID，同一笔分期的所有交易共享此 ID，非分期交易为 nil |
| `installmentIndex` | Int16 | 当前期数（从 1 开始），默认 0 表示非分期 |
| `installmentTotal` | Int16 | 总期数，默认 0 表示非分期 |

**文件：** `Transaction.swift` — 新增计算属性

```swift
/// 是否为分期交易
var isInstallment: Bool { installmentGroupId != nil }

/// 分期显示文字，如 "3/12期"
var installmentLabel: String? {
    guard isInstallment else { return nil }
    return "\(installmentIndex)/\(installmentTotal)期"
}
```

**文件：** `FinanceRepository.swift` — 新增分期创建方法

```swift
/// 一次性创建分期交易（N 笔）
func addInstallmentTransactions(
    totalAmount: Decimal,       // 本金总额
    feePerPeriod: Decimal,      // 每期手续费（0 = 无手续费）
    periods: Int,               // 总期数
    type: TransactionType,
    category: Category,
    account: Account,
    startDate: Date,            // 首期日期
    note: String?
) async throws -> [Transaction]
```

逻辑：
- 每期金额 = `totalAmount / periods + feePerPeriod`（末期吸收尾差）
- 生成 `installmentGroupId = UUID()`，共享给所有期
- 每期日期 = startDate + N 个月（`Calendar.dateByAdding(.month, value: i)`）
- 备注自动追加 `"[分期 1/12]"` 前缀

### 1.2 UI 变更 — AddTransactionSheet

**文件：** `AddTransactionSheet.swift`

在「备注输入」下方，新增「分期设置」区域（与备注平级）：

```
┌─────────────────────────────────┐
│ 📅 日期选择                      │
├─────────────────────────────────┤
│ 📝 备注输入                      │
├─────────────────────────────────┤
│ 🔄 分期付款                [开关] │  ← 新增 Toggle，与备注同级
│                                 │
│ （展开后显示）                    │
│  期数：  [3] [6] [12] [24] [自定义]│  ← 快捷选择 + 自定义输入
│  手续费：¥ [0.00] /每期          │  ← 可选，默认 0
│  首期日期：3月17日               │  ← 默认使用已选日期
│  ─────────────────              │
│  每期金额：¥1,050.00            │  ← 实时计算预览
│  总手续费：¥600.00              │
│  实际总支出：¥12,600.00          │
└─────────────────────────────────┘
```

**新增 State 变量：**
```swift
@State private var isInstallment: Bool = false
@State private var installmentPeriods: Int = 12
@State private var feePerPeriod: String = ""       // 每期手续费
@State private var showCustomPeriods: Bool = false  // 自定义期数输入
```

**保存逻辑调整：**
- `isInstallment == false` → 走现有 `addTransaction()` 逻辑
- `isInstallment == true` → 调用新的 `addInstallmentTransactions()`

### 1.3 UI 变更 — TransactionRowView

**文件：** `FinanceView.swift` 内的 `TransactionRowView`

分期交易行增加标记：

```
┌──────────────────────────────────────┐
│ 🍔  午餐                    ¥1,050  │
│     餐饮 · 15:30                     │
│     [分期 3/12]              ← 新增  │
└──────────────────────────────────────┘
```

在分类标签旁显示一个小胶囊 `"3/12期"`，颜色用 `holoPrimary.opacity(0.15)`。

### 1.4 分期交易的编辑/删除

- **编辑单期**：仅修改该期的备注（金额/日期不可改，保持分期一致性）
- **删除**：弹出选项 — "仅删除此期" / "删除全部分期"
  - 删除全部：通过 `installmentGroupId` 查找并批量删除

**FinanceRepository 新增：**
```swift
/// 查询同一分期组的所有交易
func getInstallmentGroup(groupId: UUID) async throws -> [Transaction]

/// 删除整个分期组
func deleteInstallmentGroup(groupId: UUID) async throws
```

---

## 功能二：全局搜索

### 2.1 数据层

**文件：** `FinanceRepository.swift` — 新增搜索方法

```swift
/// 搜索交易记录（按备注和分类名模糊匹配）
func searchTransactions(keyword: String, limit: Int = 50) async throws -> [Transaction]
```

谓词逻辑：
```swift
NSPredicate(format: "note CONTAINS[cd] %@ OR category.name CONTAINS[cd] %@", keyword, keyword)
```
按日期降序排列，限制最多返回 50 条。

### 2.2 搜索入口 — FinanceLedgerView Header

**文件：** `FinanceView.swift` 内的 `FinanceLedgerView.headerView`

在现有 HStack 右侧按钮区（"今" 按钮和日历按钮之前）添加搜索按钮：

```
┌──────────────────────────────────────┐
│ ← 返回    今日账本    🔍  今  📅     │
│                       ↑ 新增          │
└──────────────────────────────────────┘
```

```swift
// 搜索按钮
Button { showSearch = true } label: {
    Image(systemName: "magnifyingglass")
        .font(.system(size: 18, weight: .medium))
        .foregroundColor(.holoTextSecondary)
        .frame(width: 40, height: 40)
        .background(Color.white)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
}
```

新增 `@State private var showSearch: Bool = false`，通过 `.fullScreenCover` 打开搜索页。

### 2.3 全屏搜索页

**新文件：** `Views/FinanceSearchView.swift`（约 200 行）

布局设计：

```
┌──────────────────────────────────────┐
│ ← 取消    [🔍 搜索交易记录...]       │  ← 搜索栏，自动聚焦
├──────────────────────────────────────┤
│                                      │
│ （输入前显示）                         │
│   🕐 最近搜索                        │  ← 可选：记录最近 5 条搜索词
│   iPhone 14 Pro                      │
│   星巴克                             │
│                                      │
│ （输入后实时显示）                     │
│   找到 3 条结果                       │
│ ┌──────────────────────────────────┐ │
│ │ TransactionRowView (复用)        │ │
│ │ TransactionRowView (复用)        │ │
│ │ TransactionRowView (复用)        │ │
│ └──────────────────────────────────┘ │
│                                      │
│ （无结果时）                          │
│   🔍 未找到相关交易                   │
│   试试其他关键词                      │
└──────────────────────────────────────┘
```

**关键实现：**
- 搜索框使用 `TextField` + `@FocusState` 自动聚焦
- 防抖：`onChange(of: searchText)` + `Task.sleep(0.3秒)` 避免频繁查询
- 结果列表复用 `TransactionRowView`
- 点击结果行 → 打开 `AddTransactionSheet`（编辑模式）
- 搜索词为空时显示「最近搜索」（用 `@AppStorage` 存最近 5 条）

---

## 实施顺序

### Phase 1：数据层（分期）
1. `CoreDataStack.swift` — Transaction Entity 添加 3 个可选字段
2. `Transaction.swift` — 添加 `@NSManaged` 属性 + 计算属性
3. `FinanceRepository.swift` — 添加 `addInstallmentTransactions()`、`getInstallmentGroup()`、`deleteInstallmentGroup()`
4. `TransactionUpdates` — 无需改动（分期字段不可编辑）

### Phase 2：分期 UI
5. `AddTransactionSheet.swift` — 添加分期设置区域 + 保存逻辑分支
6. `FinanceView.swift` TransactionRowView — 添加分期标签显示
7. `FinanceView.swift` 删除逻辑 — 分期交易的批量删除选项

### Phase 3：数据层（搜索）
8. `FinanceRepository.swift` — 添加 `searchTransactions()` 方法

### Phase 4：搜索 UI
9. 新建 `Views/FinanceSearchView.swift` — 全屏搜索页
10. `FinanceView.swift` FinanceLedgerView — header 添加搜索按钮 + fullScreenCover

---

## 涉及文件清单

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `Models/CoreDataStack.swift` | 修改 | +30 行（3 个字段定义） |
| `Models/Transaction.swift` | 修改 | +15 行（属性 + 计算属性） |
| `Models/FinanceRepository.swift` | 修改 | +80 行（3 个方法） |
| `Views/AddTransactionSheet.swift` | 修改 | +120 行（分期 UI 区域） |
| `Views/FinanceView.swift` | 修改 | +40 行（搜索按钮 + 分期标签 + 批量删除） |
| `Views/FinanceSearchView.swift` | **新建** | ~200 行 |

---

## 验证方案

1. **编译验证**：每个 Phase 完成后用 XcodeBuildMCP `build_sim` 确认编译通过
2. **分期功能验证**：
   - 在模拟器中创建一笔 12 期分期交易（¥12,000 + ¥50/期手续费）
   - 验证生成 12 笔交易记录，每笔 ¥1,050，日期间隔 1 个月
   - 验证交易行显示分期标签 "1/12期" ~ "12/12期"
   - 验证删除时弹出 "仅删除此期" / "删除全部分期" 选项
3. **搜索功能验证**：
   - 点击放大镜进入搜索页
   - 输入关键词验证实时搜索结果
   - 验证点击结果跳转编辑
   - 验证空结果展示
4. **回归验证**：普通单笔记账流程不受影响（`isInstallment == false` 走原逻辑）
