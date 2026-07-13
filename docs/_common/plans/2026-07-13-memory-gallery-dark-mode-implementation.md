# 记忆长廊 Dark Mode 适配实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** 修复记忆长廊日历切换器、月历色阶和活跃热力图在 Dark Mode 下使用固定浅色的问题，同时保持 Light Mode、布局和数据逻辑不变。

**Architecture:** 将两组热力色阶分别收口到可按 `ColorScheme` 解析的纯颜色模型，视图只传入当前外观并消费结果；切换器直接复用现有动态语义色。现有事件数量分级函数保持不变，避免视觉修复影响业务逻辑。

**Tech Stack:** Swift、SwiftUI、XCTest、Xcode build

---

### Task 1: 为月历色阶补齐深色模式契约

**Files:**
- Modify: `Holo/Holo APP/Holo/HoloTests/Services/Calendar/CalendarHeatmapTests.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/Calendar/CalendarHeatmap.swift`

**Step 1: 写失败测试**

新增测试，固定以下契约：

- Light Mode 仍返回现有 `#F6F8FB` 到 `#C8DDF8` 色阶。
- Dark Mode 返回 5 个互不相同、由暗到亮的深蓝灰色值。
- 相同等级在 Light/Dark Mode 下返回不同色值。

**Step 2: 验证测试先失败**

由于工程没有可运行的 XCTest target，先通过源码检查确认新增测试引用的 `hex(forLevel:colorScheme:)` 尚不存在；不得把 `Executed 0 tests` 作为通过。

**Step 3: 实现最小颜色模型**

为 `CalendarHeatmap` 增加接收 `ColorScheme` 的 `hex`、`color(forLevel:)` 和 `color(forCount:)` 重载，保留默认 Light Mode 参数以兼容现有调用和测试。事件数量到等级的映射不变。

**Step 4: 检查契约与编译接口**

运行源码检索，确认月历色阶不再只有固定浅色入口；最终由 Task 4 的工程编译验证 Swift 接口。

### Task 2: 接入月历与切换器的动态颜色

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Calendar/CalendarRootView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Calendar/Monthly/MonthCell.swift`

**Step 1: 接入当前外观**

在需要消费色阶的视图读取 `@Environment(\.colorScheme)`，月历格、徽章和图例均将当前外观传给 `CalendarHeatmap`。

**Step 2: 替换切换器固定背景**

将 `#F3F7FB` 和 `#F6F8FB` 改为现有 `Color.holoCardBackground`，保留边框、品牌橙选中态和尺寸。

**Step 3: 清理月历固定浅色调用**

非本月日期和空档统一走动态月历色阶，不再自行构造固定 hex `Color`。

### Task 3: 为记忆长廊活跃热力图补齐动态色阶

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryHeatmapView.swift`

**Step 1: 收口色阶模型**

在文件内建立独立的 `MemoryHeatmapPalette`，集中维护 Light/Dark 两组 5 级橙色阶；保持现有记录数量到等级的映射。

**Step 2: 视图消费动态色阶**

`MemoryHeatmapView` 将当前 `colorScheme` 传给 palette，格子、图例、边框和阴影继续沿用原有交互含义。

**Step 3: 扫描固定浅色残留**

运行：

```bash
rg -n 'Color\(hex: "#F[0-9A-F]{5}"\)' 'Holo/Holo APP/Holo/Holo/Views/MemoryGallery'
```

预期：本次三个目标区域不再存在作为容器或热力格背景的固定浅色；品牌前景白色和已有深色特调不纳入误报。

### Task 4: 验证与 scoped 收尾

**Files:**
- Verify only: 本计划涉及的 Swift 文件

**Step 1: 静态检查**

运行 `git diff --check`，预期无空白错误；逐文件检查 diff，确认不包含当前工作区的周历动态轴、洞察卡片等其他改动。

**Step 2: 工程编译**

使用项目现有 scheme 执行 iOS Simulator Debug build。预期输出 `BUILD SUCCEEDED`；如 scheme 或设备名变化，先用 `xcodebuild -list` 与可用 simulator 查询后再运行等价命令。

**Step 3: 结果验收**

确认：

- 两个切换器背景均为动态语义色。
- 月历 0 到 4 级在 Light/Dark Mode 下均有清晰层级。
- 活跃热力图 1 到 5 级在 Light/Dark Mode 下均有清晰层级。
- 没有修改布局、事件分级、点击行为和后端文件。

**Step 4: Scoped commit**

只暂存本计划实际修改文件和测试文件，提交信息使用：

```text
fix: 补齐记忆长廊深色模式适配
```
