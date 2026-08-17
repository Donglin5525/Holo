# 记忆长廊 · 周历网格视图：泳道化 + 双指缩放 方案

- 日期：2026-08-16
- 状态：三部分均已实施（泳道化 / 缩放 P0 / 列表视图每日卡片化），编译通过，待东林真机验收；HTML 设计稿见 `docs/design-mockups/weekly-grid-swimlane-and-pinch-zoom.html`
- 涉及模块：记忆长廊 → 日历 → 周历 → 网格视图（纯 iOS 前端，**均不需要后端发版**）
- 两个需求相互独立、可分别实施和提交；HTML 里两种样式都支持缩放档位，演示的就是这种解耦。

---

## 需求一：视图边界与泳道样式

### 问题本质

网格视图目前唯一的结构信号是 0.5pt 的发丝分隔线，颜色 `#F1F5F9` 落在米白页面底 `#FDFCF8` 上，对比度约 **1.07 : 1**，肉眼几乎不可见。同时没有任何外框和背景层次，内容直接铺在页面上——所以「一眼看过去不知道这是干嘛的」。

### 产品方案：三层结构信号

不加新控件、不加点击负担，只靠三层视觉信号把「这是什么」讲清楚：

| 层 | 信号 | 回答的问题 |
|---|---|---|
| 外框 | 一张白底圆角卡片（1pt 描边 + 轻投影） | 「这是一个组件」 |
| 骨架 | 灰底表头栏 + 左侧时间轴导轨（连成 L 形） | 「这是一张日历」 |
| 泳道 | 三条竖向分道 + 今日橙色淡底贯穿全高 | 「三列是三天，中间是今天」 |

六处具体改动（HTML 设计稿「泳道方案」档对应）：

1. **外框卡片**：网格整体套进白底卡片，1pt 描边、12pt 圆角、轻微投影。
2. **表头栏**：日期行加灰底（#F4F7F9）+ 底部 1pt 分隔线，表头与内容分层——这是「日历感」的主要来源。
3. **时间轴导轨**：左侧 36pt 刻度列加灰底 + 右侧 1pt 描边，与表头左格（凌晨折叠按钮格）连成 L 形导轨。
4. **今日泳道**：中间列铺 4.5% 橙色淡底，从表头贯穿到卡片底部；表头今日格同步加淡底 + 2pt 橙色底条。原来靠橙色圆圈找今天，现在整条道就是今天。
5. **泳道分隔线**：日与日之间 0.5pt #F1F5F9 → 1pt #EDEEF1，三条道真正分开。
6. **凌晨摘要收进卡片**：原来浮在网格上方的独立小卡，改为卡片内部一条横带（表头下方），整个周历只剩一张卡。

**交互零变化**：横向翻页、冻结表头、凌晨折叠/展开、点击事件/溢出组、当前时间线、图例——全部保持原入口原行为（上线前按「旧操作→新入口」映射表走查一遍）。

**深色模式**：实现全部用语义色（holoCardBackground / holoBorder / holoNestedCardBackground…），暗色自动适配；HTML 只演示了亮色。

### 技术方案

改动集中在 `WeeklyGridView.swift` 一个文件的视图层，模型不动：

```
现状: VStack { calendarHeader; morningSummaryRow(独立浮卡); gridScroll }   ← 无背景无边框
改后: VStack(spacing: 0) { calendarHeader; morningBand; gridScroll }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
      legend 移到卡片外底部（不进卡片）
```

要点与坑：

- **表头**：`calendarHeader` 加 `holoNestedCardBackground` 背景，底部分隔线 0.5→1pt；今日 `dayHeader` 加 `holoPrimary.opacity(0.06)` 底 + 2pt 橙条。
- **导轨**：`timeAxis`、表头凌晨按钮格、凌晨带标签格统一加导轨背景 + 右侧 1pt 分隔，三段颜色相连即成 L 形。
- **泳道分隔线画在容器层，不画在列内**：列内的 trailing 分隔线会随横向翻页移动；改为在 `gridScroll` 上叠一层固定 overlay（GeometryReader 取 1/3、2/3 位置画 2 条 1pt 竖线，`allowsHitTesting(false)`）。可见窗口固定 3 列且列宽相同，固定线与列边界永远重合，同时避免最右列分隔线与外框描边叠成双线。
- **今日列底色**：`eventColumn` 的 ZStack 底层垫 `Color.holoPrimary.opacity(0.045)`（仅 today 列）。
- **凌晨行**：去掉独立圆角/描边，改为横带（上下 0.5pt 分隔即可）。
- **圆角裁切**：卡片 `clipShape` 后，表头/导轨的方角自动被裁成上圆角，无需单独处理。

工作量约 0.5 天；无模型改动、无后端。

---

## 需求二：双指捏合缩放时间格

### 产品方案

**用户价值**：密集时段（一小时内多条记录）目前最多直显 4 条 +「还有 N 条」入口，看全要多一步弹层；捏合缩放让「想看全」一步到位，与 Apple 日历 / Google 日历的心智一致。

**手势定义**：

- 双指捏合 → **全局**缩放整条时间轴（所有小时一起变高/变矮），锚点在手指中心；
- 范围 1.0×–2.6×，连续缩放不吸附档位（圆整到 0.05 步进），松手即停。下限即默认密度：再缩小事件块放不下，只会制造更多「还有 N 条」；
- 效果：小时行高 = 现有分档高度 × 倍率；**事件条高度（24pt）与字号不变**，行变高后容纳更多条目，「还有 N 条」自然消失/出现；
- 双击网格 → 重置 1.0×；
- 图例区右侧显示当前倍率胶囊（如「缩放 1.40×」），点按重置——既是状态反馈，也是不熟悉手势的用户和无障碍场景的替代入口；
- 倍率用 @AppStorage 持久化，重进页面保持。

**为什么全局缩放、而不是只放大手指下的那一格**：单格缩放会让时间轴锯齿化（各小时高低不一）、缩了哪格不可见、也难复位；而全局缩放保住现有不变量「同一小时跨三天同高」（列对齐规则不破坏）。HTML 的 1.5× 档演示：今晚 20 点 6 条记录在 1.0× 时显示 4 条 +「还有 2 条」，1.5× 起全部直接可见。

**边界与共存**：溢出交互保留（缩到最小时仍可点「还有 N 条」进组详情，缩放是补充不是替代）；凌晨折叠状态下缩放只作用于可见的 7–23 点；列表视图、月历不受影响。

### 技术方案

**状态**：`@AppStorage("holo.memoryGallery.weeklyGrid.hourScale") private var hourScale: Double = 1.0`

**手势**（iOS 17 `MagnifyGesture`，项目已用 `scrollTargetBehavior` 等 17+ API，无兼容问题）：

```swift
gridScroll
  .simultaneousGesture(
    MagnifyGesture()
      .onChanged { hourScale = clamp(startScale * $0.magnification, 1.0, 2.6) }
      .onEnded { _ in startScale = hourScale }   // 写回持久化
  )
  .gesture(TapGesture(count: 2).onEnded { resetScale() })
```

风险与兜底：SwiftUI `ScrollView` 有吞双指手势的可能。先用 `simultaneousGesture`（双指与单指滚动物理上不冲突，通常可行）；若真机被吞，兜底方案是 `UIViewRepresentable` 包 `UIPinchGestureRecognizer`——聊天页 `ChatScrollIndicator` 已有「ScrollView 内放 bridge 找 UIScrollView」的先例可复用。

**模型改动（核心，两处）**：

1. `WeeklyGridAxisProfile.make(…, scale: CGFloat = 1.0)`：`height = 分档高度 × scale`，圆整到 0.5pt 防亚像素闪烁；`totalHeight` 联动。`top/yPosition/height` 接口不变 → 时间轴、列 frame、nowLine 全部自动跟随，无需改调用方。
2. `WeeklyGridEventLayout` 去硬编码（`maximumVisibleEvents = 4`、溢出行 `top + 111`）→ 从 profile 每小时实际高度派生：
   - 容量 `capacity(h) = max(1, floor((h − 27) / 27) + 1)`；
   - **已验证**：该公式在 scale = 1 时与现网分档完全一致（42→1 条、57→2、84→3、111→4、131→4 + 溢出行 top+111）→ 不缩放时视觉零回归；
   - 溢出行 `top = hourTop + pad + visibleCount × 27`，height 17 不变。

**锚定（P1，可选）**：缩放时保持手指下的时间点不动（Apple 日历行为）。SwiftUI 控制不了 contentOffset，需复用上述 UIScrollView 桥接按增量 `setContentOffset`。P0 先不做（顶部锚定 + 自然滚动），真机验收漂移感明显再上。

**性能**：profile 是 17 小时 × 7 天的纯值计算，缩放期间每帧重算无压力；建议把 `computeProfile` 结果缓存，仅 eventsByDay / scale / collapseMorning 变化时重算。LazyHStack 可见列约 5 列，重布局无风险。

**验收标准**：

1. 1.0× 下与现网视觉完全一致（回归基线）；
2. 双指张开 → 行高变大、「还有 N 条」消失；捏合 → 恢复；双击 → 重置 1.0×；
3. 单指纵滚 / 横向翻页 / 事件点击不受影响；
4. nowLine 在任意倍率下位置与真实时间对应；
5. 倍率持久化，重进页面保持；
6. 凌晨折叠/展开状态下缩放正常。

工作量：P0 半天～1 天；P1 锚定 +0.5 天（视真机体验决定是否做）。

---

## 需求三（追加）：列表视图每日卡片化

原列表为「每天一行、chip 横向铺开」：阅读动线是横向的、截断无提示、空白天占一整行。改造为：

- **每天一张卡片**（与网格泳道卡同一设计语言）：卡片头 = 日期 + 「N 条」+ 模块色点摘要；今日卡左缘 3pt 橙条 + 「今天」小标签。
- **chip 自动换行（FlowLayout）**：复用 `Components/TagSelector.swift` 里现成的 `FlowLayout`，chip 样式与点击交互不变，一天内容全部可见、无横滑。
- **空白天弱化**：一条细行（日期 + 无记录），不再占整行卡片。

改动仅 `WeeklyListView.swift`，数据结构不变，约半天。

---

## 实施顺序建议

1. **需求一（泳道化）**：纯视觉、低风险、独立可验收 → 先做先提交；
2. **需求二 P0（手势 + 布局联动）**：模型小改但已验证兼容性；
3. **需求二 P1（锚定 + 倍率胶囊）**：真机体验驱动。

两需求均为纯 iOS 前端改动，不涉及后端发版。

## 关联文件

- 视图：`Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Calendar/Weekly/WeeklyGridView.swift`
- 时间轴模型：`Holo/Holo APP/Holo/Holo/Models/Calendar/WeeklyGridAxisProfile.swift`
- 事件布局模型：`Holo/Holo APP/Holo/Holo/Models/Calendar/WeeklyGridEventLayout.swift`
- 设计稿：`docs/design-mockups/weekly-grid-swimlane-and-pinch-zoom.html`
