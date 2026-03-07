# 分类体系升级 — 71 图标二级分类实施计划

> 最后更新：2026-03-07
> 状态：**实施完成，待审查**

---

## 一、背景与目标

原有分类系统为扁平结构：支出 10 个 + 收入 5 个 = 15 个一级分类，使用少量自定义图标。

升级目标：
1. 将 Figma 设计的 **71 个 SVG 图标** 全部集成到 APP 中
2. 建立 **二级分类层级**（一级大类 → 二级子分类），覆盖所有日常记账场景
3. 分类选择界面支持 **收入/支出 Tab 切换** + **下钻导航**
4. 新增 **最近常用分类** 快捷入口

---

## 二、图标来源与映射

### 2.1 源文件

- 路径：`icon/Finance icon/`
- 数量：71 个独立 SVG（`Container.svg`, `Container-1.svg` … `Container-70.svg`）
- 来源：Figma 手动导出

### 2.2 转换工具

使用 `icon/integrate_icons.py` 脚本自动处理：
- 从每个 Container SVG 中提取纯图标路径（移除背景矩形和文字标签）
- 生成 56×56 viewBox 的干净 SVG，fill 使用 `var(--fill-0, #HEX)` 适配 Xcode 模板渲染
- 输出到 `Assets.xcassets/CategoryIcons/` 的 imageset 目录结构

### 2.3 图标编号 → 名称映射表

按 Figma 设计稿的颜色分组和排列顺序：

#### 收入图标（16 个）

| 编号 | 图标名称 | 中文 | 分组色 |
|------|----------|------|--------|
| 0 | icon_interest | 利息 | #3B82F6 |
| 1 | icon_stock | 股票 | #3B82F6 |
| 2 | icon_rent_income | 房租收入 | #3B82F6 |
| 3 | icon_invest_other | 其他投资 | #3B82F6 |
| 4 | icon_salary | 工资 | #22C55E |
| 5 | icon_bonus | 奖金 | #22C55E |
| 6 | icon_parttime | 兼职 | #22C55E |
| 7 | icon_refund | 退款 | #22C55E |
| 30 | icon_red_packet | 红包 | #EF4444 |
| 31 | icon_gift | 礼物 | #EF4444 |
| 32 | icon_winning | 中奖 | #EF4444 |
| 33 | icon_transfer_in | 转入 | #EF4444 |
| 41 | icon_loan_in | 借入 | #A855F7 |
| 42 | icon_repay_in | 还款收入 | #A855F7 |
| 43 | icon_return | 退货 | #A855F7 |
| 44 | icon_other_inc | 其他收入 | #A855F7 |

#### 支出图标（55 个）

| 编号 | 图标名称 | 中文 | 分组色 |
|------|----------|------|--------|
| **餐饮** | | | **#13A4EC** |
| 64 | icon_breakfast | 早餐 | |
| 65 | icon_lunch | 午餐 | |
| 66 | icon_dinner | 晚餐 | |
| 67 | icon_late_snack | 夜宵 | |
| 68 | icon_snack | 零食 | |
| 69 | icon_coffee | 咖啡 | |
| 70 | icon_takeout | 外卖 | |
| **交通** | | | **#10B981** |
| 23 | icon_metro | 地铁 | |
| 24 | icon_taxi | 打车 | |
| 25 | icon_bike_share | 单车 | |
| 26 | icon_fuel | 加油 | |
| 27 | icon_parking | 停车 | |
| 28 | icon_travel | 旅行 | |
| 29 | icon_toll | 过路费 | |
| **购物** | | | **#F97316** |
| 56 | icon_clothes | 服饰 | |
| 57 | icon_digital | 数码 | |
| 58 | icon_groceries | 日用 | |
| 59 | icon_beauty | 美妆 | |
| 60 | icon_furniture | 家具 | |
| 61 | icon_book | 书籍 | |
| 62 | icon_sport | 运动 | |
| 63 | icon_present | 礼物 | |
| **娱乐** | | | **#EC4899** |
| 34 | icon_cinema | 电影 | |
| 35 | icon_gaming | 游戏 | |
| 36 | icon_video | 视频 | |
| 37 | icon_music | 音乐 | |
| 38 | icon_ktv | KTV | |
| 39 | icon_trip | 旅游 | |
| 40 | icon_fitness | 健身 | |
| **居住** | | | **#6366F1** |
| 50 | icon_rent | 房租 | |
| 51 | icon_water | 水费 | |
| 52 | icon_electricity | 电费 | |
| 53 | icon_gas | 燃气 | |
| 54 | icon_property | 物业 | |
| 55 | icon_internet | 网费 | |
| **医疗** | | | **#F43F5E** |
| 8 | icon_medical | 就医 | |
| 9 | icon_medicine | 药品 | |
| 10 | icon_checkup | 体检 | |
| 11 | icon_gym | 健身房 | |
| 12 | icon_supplement | 保健品 | |
| **学习** | | | **#06B6D4** |
| 45 | icon_course | 课程 | |
| 46 | icon_textbook | 教材 | |
| 47 | icon_exam | 考试 | |
| 48 | icon_stationery | 文具 | |
| 49 | icon_subscription | 订阅 | |
| **其他** | | | **#64748B** |
| 13 | icon_social | 社交 | |
| 14 | icon_pet | 宠物 | |
| 15 | icon_barber | 理发 | |
| 16 | icon_laundry | 洗衣 | |
| 17 | icon_repair | 维修 | |
| 18 | icon_insurance | 保险 | |
| 19 | icon_repayment | 还款 | |
| 20 | icon_transfer_out | 转账 | |
| 21 | icon_donation | 捐赠 | |
| 22 | icon_other_exp | 其他 | |

---

## 三、分类层级结构

### 3.1 支出（8 个一级 → 55 个二级）

| # | 一级分类 | 颜色 | 临时图标 | 二级子分类 |
|---|----------|------|----------|------------|
| 1 | 餐饮 | #13A4EC | icon_breakfast | 早餐、午餐、晚餐、夜宵、零食、咖啡、外卖 |
| 2 | 交通 | #10B981 | icon_metro | 地铁、打车、单车、加油、停车、旅行、过路费 |
| 3 | 购物 | #F97316 | icon_clothes | 服饰、数码、日用、美妆、家具、书籍、运动、礼物 |
| 4 | 娱乐 | #EC4899 | icon_cinema | 电影、游戏、视频、音乐、KTV、旅游、健身 |
| 5 | 居住 | #6366F1 | icon_rent | 房租、水费、电费、燃气、物业、网费 |
| 6 | 医疗 | #F43F5E | icon_medical | 就医、药品、体检、健身房、保健品 |
| 7 | 学习 | #06B6D4 | icon_course | 课程、教材、考试、文具、订阅 |
| 8 | 其他 | #64748B | icon_social | 社交、宠物、理发、洗衣、维修、保险、还款、转账、捐赠、其他 |

### 3.2 收入（4 个一级 → 16 个二级）

| # | 一级分类 | 颜色 | 临时图标 | 二级子分类 |
|---|----------|------|----------|------------|
| 1 | 投资理财 | #3B82F6 | icon_interest | 利息、股票、房租收入、其他投资 |
| 2 | 工资收入 | #22C55E | icon_salary | 工资、奖金、兼职、退款 |
| 3 | 人情来往 | #EF4444 | icon_red_packet | 红包、礼物、中奖、转入 |
| 4 | 其他收入 | #A855F7 | icon_loan_in | 借入、还款收入、退货、其他 |

### 3.3 层级规则

- **一级分类**：`parentId = nil`，图标暂用其第一个子分类的图标
- **二级子分类**：`parentId = 父分类.id`，继承父分类的颜色
- 用户记账时 **只能选择二级子分类**，一级分类仅作导航用途
- 统计报表可按一级分类汇总

---

## 四、实施步骤

### Step 1：图标导入（已完成）

**目标**：将 71 个 SVG 图标转换并添加到 Xcode Asset Catalog

**改动文件**：
- `Assets.xcassets/CategoryIcons/` — 新增 71 个 imageset 目录

**做法**：
- 运行 `icon/integrate_icons.py` 脚本
- 每个 imageset 包含：`Contents.json`（template-rendering-intent + preserves-vector-representation）+ 干净 SVG

**验证**：目录下现有 88 个 imageset（71 个新 + 17 个旧保留）

---

### Step 2：Core Data 模型升级（已完成）

**目标**：为 Category 实体添加 `parentId` 属性，启用轻量级迁移

**改动文件**：

| 文件 | 改动内容 |
|------|----------|
| `Models/CoreDataStack.swift` | `categoryAttributes` 新增 `parentId`（UUID, optional, indexed）；`persistentStoreDescriptions` 开启轻量级迁移 |
| `Models/Category.swift` | 新增 `@NSManaged public var parentId: UUID?`、`isTopLevel`、`isSubCategory` 计算属性 |

**`CoreDataStack.swift` 关键代码**：

```swift
// 父分类 ID
let parentId = NSAttributeDescription()
parentId.name = "parentId"
parentId.attributeType = .UUIDAttributeType
parentId.isOptional = true
parentId.isIndexed = true

// 轻量级迁移
description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
```

**`Category.swift` 关键代码**：

```swift
@NSManaged public var parentId: UUID?
var isTopLevel: Bool { parentId == nil }
var isSubCategory: Bool { parentId != nil }
```

**迁移策略**：轻量级迁移 — 仅新增可选字段，Core Data 自动推断映射模型

---

### Step 3：种子数据层级化（已完成）

**目标**：将扁平分类列表重构为层级结构

**改动文件**：
- `Models/Category+CoreDataProperties.swift` — 完全重写

**改动前（旧结构）**：

```swift
static let defaultExpenseCategories = [
    (name: "餐饮", icon: "icon_dining", color: "#FF6B6B"),
    // ... 共 10 个扁平分类
]
static let defaultIncomeCategories = [
    (name: "工资", icon: "icon_salary", color: "#74B9FF"),
    // ... 共 5 个扁平分类
]
```

**改动后（新结构）**：

```swift
typealias SubCategoryDef = (name: String, icon: String)
typealias CategoryGroupDef = (name: String, color: String, children: [SubCategoryDef])

static let expenseHierarchy: [CategoryGroupDef] = [
    (name: "餐饮", color: "#13A4EC", children: [
        (name: "早餐", icon: "icon_breakfast"),
        (name: "午餐", icon: "icon_lunch"),
        // ...
    ]),
    // ... 共 8 组
]

static let incomeHierarchy: [CategoryGroupDef] = [
    // ... 共 4 组
]
```

**初始化逻辑**：
1. `seedDefaultCategories()` 幂等检查（已有数据则跳过）
2. `seedHierarchy()` 遍历每个一级分类 → 创建 parent（icon 取首个子分类图标）→ 逐个创建 children（parentId 指向 parent.id）
3. `create()` 方法新增 `parentId` 参数

**注意**：旧用户升级后，现有扁平分类不会被自动删除或迁移。首次升级的用户因已有分类数据，`seedDefaultCategories()` 不会执行。如需清理旧数据并重新 seed，需要手动处理或在设置页面提供"重置分类"功能。

---

### Step 4：CategoryPicker UI 改造（已完成）

**目标**：支出/收入 Tab + 一级网格 + 下钻二级 + 返回按钮

**改动文件**：
- `Components/CategoryPicker.swift` — 完全重写
- `Views/AddTransactionView.swift` — `transactionType` 改为 `@Binding` 传递

**交互流程**：

```
┌─────────────────────────────────┐
│  [支出]  [收入]                  │  ← Tab 栏，默认选中"支出"
├─────────────────────────────────┤
│  最近使用（横向滚动）             │  ← 有历史记录时显示
│  ☕ 咖啡  🍜 午餐  🚇 地铁 ...   │
├─────────────────────────────────┤
│  选择分类                        │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  │餐饮│ │交通│ │购物│ │娱乐│  │  ← 一级分类 4 列网格
│  └────┘ └────┘ └────┘ └────┘  │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  │居住│ │医疗│ │学习│ │其他│  │
│  └────┘ └────┘ └────┘ └────┘  │
└─────────────────────────────────┘

        ↓ 点击"餐饮"

┌─────────────────────────────────┐
│  [支出]  [收入]                  │
├─────────────────────────────────┤
│  ← 餐饮                         │  ← 返回按钮 + 一级分类名
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  │早餐│ │午餐│ │晚餐│ │夜宵│  │  ← 二级子分类 4 列网格
│  └────┘ └────┘ └────┘ └────┘  │
│  ┌────┐ ┌────┐ ┌────┐          │
│  │零食│ │咖啡│ │外卖│          │
│  └────┘ └────┘ └────┘          │
└─────────────────────────────────┘
```

**核心状态管理**：

| 状态 | 类型 | 说明 |
|------|------|------|
| `selectedCategory` | `@Binding<Category?>` | 用户最终选中的二级子分类 |
| `transactionType` | `@Binding<TransactionType>` | 收入/支出，Tab 切换时联动 AddTransactionView |
| `drillDownParent` | `@State<Category?>` | 当前下钻的一级分类，nil 表示在一级视图 |
| `categories` | `@State<[Category]>` | 从 Core Data 加载的全量分类 |
| `recentCategories` | `@State<[Category]>` | 最近常用二级子分类 |

**动画**：下钻使用 `.asymmetric` 过渡（进入从右滑入，退出向左滑出），时长 0.25s

---

### Step 5：最近常用分类（已完成）

**目标**：统计最近使用频率最高的二级分类，在分类选择顶部快捷展示

**改动文件**：
- `Models/FinanceRepository.swift` — 新增 `getRecentCategories()` 方法
- `Components/CategoryPicker.swift` — 新增 `recentSection` 横向滚动区域

**统计规则**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| type | - | 按交易类型分别统计 |
| days | 30 | 统计最近 30 天的交易 |
| limit | 8 | 最多返回 8 个 |

**逻辑**：查询时间窗口内的交易 → 按 Category objectID 计数 → 只保留 `isSubCategory` → 降序取 Top N

**展示条件**：仅在一级分类视图（未下钻）且有历史记录时显示

---

### Step 6：关联修改（已完成）

**目标**：确保所有引用分类/图标的页面兼容新的层级结构和自定义图标

#### 6.1 AddTransactionView.swift

**改动**：`CategoryPicker` 的 `transactionType` 参数从值传递改为 `$transactionType` Binding

```swift
// 改动前
CategoryPicker(selectedCategory: $selectedCategory, transactionType: transactionType)
// 改动后
CategoryPicker(selectedCategory: $selectedCategory, transactionType: $transactionType)
```

#### 6.2 QuickTemplateView.swift

**改动**：模板匹配逻辑从索引改为名称

```swift
// 改动前 — 索引匹配，层级化后索引会失效
(amount: 15, categoryIndex: 0, type: .expense)

// 改动后 — 名称匹配，直接查找二级子分类
(amount: 15, categoryName: "早餐", type: .expense)
```

查找函数 `findCategory(named:type:)` 优先匹配二级子分类，找不到回退到一级。

#### 6.3 FinanceView.swift — TransactionRow

**改动**：图标渲染兼容 `icon_` 前缀

```swift
// 改动前 — 只支持 SF Symbols
Image(systemName: transaction.category.icon)

// 改动后 — 自定义图标 + SF Symbols 兜底
if transaction.category.icon.hasPrefix("icon_") {
    Image(transaction.category.icon).renderingMode(.template)...
} else {
    Image(systemName: transaction.category.icon)...
}
```

---

## 五、改动文件清单

| 文件路径 | 改动类型 | 改动概要 |
|----------|----------|----------|
| `Assets.xcassets/CategoryIcons/` | 新增 | 71 个 imageset |
| `Models/CoreDataStack.swift` | 修改 | +parentId 属性 +轻量级迁移 |
| `Models/Category.swift` | 修改 | +parentId +isTopLevel +isSubCategory |
| `Models/Category+CoreDataProperties.swift` | 重写 | 层级种子数据 + seedHierarchy + create 支持 parentId |
| `Models/FinanceRepository.swift` | 修改 | +getRecentCategories() |
| `Components/CategoryPicker.swift` | 重写 | Tab + 下钻 + 返回 + 最近常用 |
| `Components/QuickTemplateView.swift` | 重写 | 名称匹配替代索引匹配 |
| `Views/AddTransactionView.swift` | 修改 | transactionType 改为 Binding |
| `Views/FinanceView.swift` | 修改 | TransactionRow 图标兼容 |

---

## 六、已知限制与后续优化

### 6.1 旧数据兼容

- `seedDefaultCategories()` 有幂等保护：已有分类数据则跳过
- **问题**：已安装用户的 15 个旧扁平分类不会自动迁移为层级结构
- **建议**：后续在设置页提供"重置分类"或"数据迁移"功能

### 6.2 一级分类图标

- 当前一级分类暂用第一个子分类的图标
- 后续可为每个一级分类设计独立的汇总图标

### 6.3 分类管理

- 当前不支持用户自定义分类（增删改排序）
- 后续可增加分类管理页面

### 6.4 统计报表

- 报表按一级分类汇总需要额外查询逻辑
- 当前仅按二级子分类统计
