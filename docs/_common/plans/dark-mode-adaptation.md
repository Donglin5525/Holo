# HOLO iOS Dark Mode 适配计划

## 背景

HOLO 项目当前不支持 Dark Mode，所有颜色都是硬编码的固定值。用户希望在 iOS 系统切换到深色模式时，应用能够自动适配显示深色界面。

## 当前状态分析

### 颜色系统 (DesignSystem.swift)
- 定义了 26 种颜色（品牌色、背景色、文字色、功能色、图表色、分类色）
- **全部硬编码**，不支持 Dark Mode
- 存在 `Color.white`、`Color.black.opacity()` 等硬编码

### 硬编码颜色问题
| 问题类型 | 文件数 | 出现次数 |
|----------|--------|----------|
| `Color.white` | 12 | 40+ |
| `Color.white.opacity()` | 5 | 9 |
| `Color.black.opacity()` (阴影) | 2 | 7 |

### 图标资源
- 82 个 CategoryIcons + 1 个 HabitIcons
- 使用 **template 渲染模式** → **自动支持 Dark Mode**
- 无需修改

### AccentColor
- 当前为空配置
- 可选：添加 Dark Mode 变体

---

## 实施方案

### 方案选择：Asset Catalog Color Sets

**推荐使用 Asset Catalog Color Sets**，原因：
1. 原生支持，性能最优
2. 自动响应系统主题切换，无需代码检测
3. Xcode 可视化编辑，易于维护
4. 支持多平台（iOS/iPadOS/macOS）

---

## 工作项

### 阶段 1：创建 Asset Catalog 颜色资源

**位置**: `Holo/Assets.xcassets/`

创建 Color Set 目录，为每种语义化颜色定义 Light/Dark 变体：

| 颜色名称 | Light Mode | Dark Mode |
|----------|------------|-----------|
| `Background` | #FDFCF8 | #1C1C1E |
| `CardBackground` | #FFFFFF | #2C2C2E |
| `TextPrimary` | #333333 | #F5F5F5 |
| `TextSecondary` | #8E8E93 | #8E8E93 |
| `TextPlaceholder` | #9CA3AF | #6B7280 |
| `Border` | #F0F0F0 | #3A3A3C |
| `Divider` | #F1F5F9 | #38383A |
| `GlassBackground` | White 70% | Black 50% |
| `Shadow` | Black 4% | Black 20% |

**品牌色和功能色**（Light/Dark 相同，保持一致性）：
- `Primary`, `PrimaryLight`, `PrimaryDark`
- `Success`, `SuccessLight`, `Error`, `ErrorLight`, `Info`, `Purple`
- `Chart1~5`
- `Category*` 系列

### 阶段 2：修改 DesignSystem.swift

将硬编码颜色改为从 Asset Catalog 读取：

```swift
// 改前
static let holoBackground = Color(red: 253/255, ...)

// 改后
static let holoBackground = Color("Background")
```

**关键修改**：
- 第 26 行: `holoCardBackground = Color.white` → `Color("CardBackground")`
- 第 60 行: `holoGlassBackground = Color.white.opacity(0.7)` → `Color("GlassBackground")`
- 第 161 行: `HoloShadow.card = Color.black.opacity(0.04)` → `Color("Shadow")`
- 第 164 行: `HoloShadow.button = Color.black.opacity(0.1)` → `Color("ButtonShadow")`

### 阶段 3：替换视图中的硬编码颜色

**高优先级文件**（主要 UI 视图）：

| 文件 | 需替换的硬编码 |
|------|----------------|
| `FinanceView.swift` | `Color.white`, `Color.white.ignoresSafeArea()` |
| `AddTransactionSheet.swift` | `Color.white`, 阴影 |
| `HabitsView.swift` | `Color.white` |
| `AddHabitSheet.swift` | `Color.white`, 描边 |
| `HabitCardView.swift` | `Color.white` |
| `HabitDetailView.swift` | `Color.white` |
| `HomeView.swift` | 描边 `Color.white.opacity(0.2)` |

**替换规则**：
- `.background(Color.white)` → `.background(Color.holoCardBackground)`
- `.ignoresSafeArea()` 背景 → `Color.holoBackground.ignoresSafeArea()`
- 描边 `Color.white.opacity(0.2)` → `Color.holoBorder`
- 阴影 `Color.black.opacity(0.04)` → `HoloShadow.card`

**中优先级文件**（组件）：
- `BottomNavBar.swift`
- `FeatureButton.swift`
- `VoiceAssistantButton.swift`
- `QuickTemplateView.swift`
- `ImportExportView.swift`
- `ImportPreviewSheet.swift`

### 阶段 4：处理动态颜色

`Color(hex:)` 运行时解析的颜色（分类颜色选择器）：
- 位置: `AddHabitSheet.swift`, `CategoryManagementView.swift`
- 方案: 添加 `Color.adaptive(light:dark:)` 扩展，根据 colorScheme 自动调整亮度

### 阶段 5：配置 AccentColor（可选）

更新 `AccentColor.colorset/Contents.json`：
- Light: #F46D38（主色）
- Dark: #FF8A50（略亮的主色）

---

## 关键文件清单

**需要创建**：
- `Assets.xcassets/Colors/` 目录及所有 ColorSet

**需要修改**：
1. `Holo/Utils/DesignSystem.swift` - 核心颜色定义
2. `Holo/Views/FinanceView.swift` - 主页面
3. `Holo/Views/AddTransactionSheet.swift` - 交易表单
4. `Holo/Views/Habits/HabitsView.swift` - 习惯列表
5. `Holo/Views/Habits/AddHabitSheet.swift` - 习惯表单
6. `Holo/Views/Habits/HabitCardView.swift` - 习惯卡片
7. `Holo/Views/Habits/HabitDetailView.swift` - 习惯详情
8. `Holo/Views/HomeView.swift` - 首页
9. `Holo/Components/BottomNavBar.swift` - 底部导航
10. `Holo/Components/FeatureButton.swift` - 功能按钮
11. `Holo/Components/VoiceAssistantButton.swift` - 语音按钮

---

## 验证方式

1. **模拟器测试**：
   - 在 iPhone 模拟器中运行应用
   - 切换 Settings > Developer > Dark Appearance
   - 检查所有页面的颜色显示

2. **检查清单**：
   - [ ] 背景色正确切换（主背景、卡片背景）
   - [ ] 文字可读性（主文字、次要文字）
   - [ ] 边框和分隔线可见
   - [ ] 阴影效果适当
   - [ ] 品牌色保持一致
   - [ ] 图标正确渲染

---

## 预估工作量

| 阶段 | 工作内容 | 预估 |
|------|----------|------|
| 1 | 创建 Color Sets | 15 个颜色资源 |
| 2 | 修改 DesignSystem.swift | 1 个文件 |
| 3 | 替换硬编码颜色 | 12+ 个文件，40+ 处修改 |
| 4 | 动态颜色处理 | 1 个扩展 + 3 个文件 |
| 5 | AccentColor 配置 | 1 个文件 |

---

## 注意事项

1. **不要修改**：
   - CategoryIcons / HabitIcons（已自动支持）
   - 品牌色和功能色的色值（保持 Light/Dark 一致）

2. **测试重点**：
   - 习惯卡片在 Dark Mode 下的可读性
   - 交易列表的金额显示
   - 表单输入框的占位符文字
   - 毛玻璃效果的透明度

3. **可逆性**：
   - 所有修改均可通过 git 回滚
   - ColorSet 是增量添加，不影响现有资源
