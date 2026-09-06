# iPad 精细化走查验证报告（2026-09-07 凌晨）

> 任务来源：东林反馈「iPad 版本优化还是有很大的问题」——①记忆长廊没平铺、字体没优化；②习惯模块样式异常且 iCloud 没同步习惯数据；③以此为基准全页面精细走查≥5轮，每轮有独立标准并回归前轮修复。
> 环境：iPad Pro 11-inch (M5) 模拟器（iOS 26.3），横屏 1194×834（expanded 档）/竖屏 834（medium 档），浅色+深色双模式，种子数据（rhythm 剧本）+ 真实新装空态双场景。
> 取证：/tmp/holo_ipad_audit/（v8-l-* 横屏全页面、v8-p-* 竖屏、v9-r* 旋转往返、v9-d-* 深色、v9b-* 新装空态）。

## 一、两个点名问题的根因与修复

### 1. 习惯数据 iCloud「没同步」——真根因是仓库不监听远程变更（已修）
- **现象**：iPad 首装后习惯页一直停在「快速开始」空态建议，而财务等其他模块数据正常出现。
- **根因**：CoreData 走 `NSPersistentCloudKitContainer` 单库同步，习惯实体定义本身合规（非可选字段都有默认值）。差别在消费层：FinanceRepository / UserPreferenceRepository / CategoryLearningStore / HomeIconConfigRepository 都监听了 `.NSPersistentStoreRemoteChange`（云端后台导入完成后重拉），**唯独 HabitRepository 只在本地写入时刷新**——首次加载（此时云端导入往往还没完成）之后 `activeHabits` 就再也不更新，本次会话内永远空态。
- **修复**：HabitRepository.setup() 注册同款远程变更监听，防抖 2 秒后重拉列表并广播既有 `habitDataDidChange`，视图层全部复用既有刷新管道（Models/HabitRepository.swift）。测试注入的独立 context 不挂共享 coordinator，不影响测试隔离。
- **⚠️ 需要东林真机确认的点**：此修复保证「云端数据一到就显示」。若装新包后 iPad 习惯仍为空，则说明 iPhone 端的习惯记录根本没导出到 iCloud（导出侧问题），届时需要查 iPhone 的 CloudKit 同步日志——模拟器无法复现 iCloud 链路，这一步只能真机验证。

### 2. 习惯模块「为什么长这个样子」——磁贴没撑满列宽（已修）
- **现象**：空态三块示例磁贴（散步/阅读/早睡）缩在超宽网格列的左缘，稀稀拉拉；有数据时真实磁贴同样不撑满。
- **修复**：HabitTileView 与空态示例磁贴统一 `.frame(maxWidth: .infinity)` 撑满磁贴列；列数自适应逻辑（每列≥240pt、最多4列）已有护栏不动。浅色/深色、横屏/竖屏、空态/有数据四组合均已截图验证。

### 3. 记忆长廊「没平铺、字体没优化」（已修）
- **根因（平铺）**：长廊全部内容被 `holoContentColumn` 统一限宽 720pt 居中，11 寸横屏内容区 978pt / 13 寸 1134pt，两侧各空出 128-207pt；而习惯磁贴墙、任务、财务、想法等模块在宽屏档都是通铺——反差感就是「没平铺」。
- **修复（平铺）**：expanded 档（≥1024pt）长廊内容列 720→920（`HoloAdaptiveLayout.galleryColumnMaxWidth`），竖屏 medium 档维持 720 保持手机一致的阅读栏。
- **根因（字体）**：章节头 title 15pt / 证据行 10pt / 筛选 10pt / 注脚 9pt / 空态 11pt 全是手机字号，iPad 阅读距离更远，视觉上「没优化」。
- **修复（字体）**：新增 `galleryTypeScale`（expanded 档 ×1.25），统一应用于日/周/月大时间数字、章节头、洞察「理解」章节头、时段标签、时间列、事件卡全部字号、日叙事、注脚与空态文案。iPhone 与竖屏 medium 档字号零变化。

## 二、五轮走查记录（每轮标准 + 发现 + 回归）

### R1｜布局与空间利用（标准：宽屏不出现「放大版 iPhone」，无大面积无功能空白）
- 已修：长廊 920 列宽（见上）；习惯磁贴撑满（见上）。
- 发现「2,026年」：月历章节头年份被数字分组符渲染成「2,026年」（String(localized:) 整数插值默认带千分位）。**已修**（`.number.grouping(.never)`），回归截图确认「2026年」。
- 记录待拍板（不动代码）：①轴档事件块是单列窄块，宽屏下右侧大面积空白；②想法列表卡片通铺拉满（约 766pt 行宽），长文本行偏长；③设置页 Apple 登录按钮拉满全宽。——三项均属 iPad v2 第二批既有规划（想法双栏/账本宽屏/设置双栏），见决策清单。
- 回归：R2-R5 每轮截图复核长廊/习惯布局未回退。

### R2｜字体排印与视觉层级（标准：章节排印同族一致、无裁切无挤压、层级清晰）
- 已修：洞察 tab「理解」章节头补齐 1.25 倍排印（原漏掉，与日历章节头不一致）。
- 复核：放大后时间列（46→57.5pt）无裁切；章节头 minimumScaleFactor 兜底正常；事件卡正文/数值/徽章层级清晰。
- 回归：R3-R5 截图复核通过。

### R3｜交互与导航（标准：旋转往返状态不丢、sheet 呈现合理、导航可达）
- 旋转往返（竖→横→竖→横）：长廊日档的聚焦日期/档位/筛选全部保持，无重载闪断。
- 习惯详情在横屏以居中 form sheet 呈现，尺寸合理（v9-r4）。
- 已知缺口（模拟器通道限制，转真机验收）：键盘快捷键 ⌘1-9/⌘N 无外接键盘模拟通道；轴档长按拖选门交互未自动化。
- 发现（低置信，待真机复验）：页面切换动画进行中快速点按侧边栏，出现过一次点击落到下层内容上的穿透（自动化时序竞争，人工操作复现概率低）。
- 回归：R4/R5 复核通过。

### R4｜状态与数据（标准：空态/深色/失败态不破版，新装场景与东林真机一致）
- 真实新装空态（卸载重装、不播种）：习惯空态示例磁贴 2+1 撑满、居中体面；长廊空态欢迎条+空日卡正常；引导页→跳过→首页导览链路通畅。
- 深色模式（-darkModeSetting dark）：首页/长廊日视图/习惯/想法/任务横屏实拍全部正常，长廊纸底深色适配无对比度问题。
- 回归：R5 复核通过。

### R5｜全量回归（标准：前四轮修复项逐一复验 + 全量单测）
- V8 全套 16 项截图全部重跑通过；「2026年」/长廊 920/排印 1.25/磁贴撑满四项修复在最终构建中全部在场。
- 全量 HoloTests 结果见附注（运行中/结果见提交说明）；本批改动相关面 = HabitRepository / 长廊视图 / 自适应布局常量，无业务逻辑改动。

## 三、改动清单（12 文件，全部为本任务产物）
| 文件 | 改动 |
|---|---|
| Models/HabitRepository.swift | 远程变更监听+防抖重拉+广播 |
| Views/Habits/HabitTileView.swift | 磁贴撑满列宽 |
| Views/Habits/HabitsView.swift | 空态示例磁贴撑满列宽 |
| Utils/HoloAdaptiveLayout.swift | galleryColumnMaxWidth=920 + galleryTypeScale |
| Views/MemoryGallery/MemoryGalleryView.swift | 列宽分档 + 洞察章节头排印 |
| Views/MemoryGallery/Calendar/MemoryTimeChapterHeader.swift | 章节头排印 1.25 |
| Views/MemoryGallery/Calendar/CalendarRootView.swift | 周/月大时间排印 1.25 |
| Views/MemoryGallery/Calendar/Daily/DailyReplayView.swift | 日号/时段/时间列/叙事/注脚/空态排印 |
| Views/MemoryGallery/Calendar/Daily/DailyReplayEventCard.swift | 事件卡全字号排印 |
| Models/Calendar/MemoryTimeChapterPresentation.swift | 年份千分位修复 |
| HoloUITests/CalendarTimelineSmokeUITests.swift | V8/V9/V9b 审计用例（取证通道） |

## 四、待东林拍板（明早处理）
1. **习惯同步真机确认**：iPad 装本包登录 iCloud 后看习惯是否出现；仍为空则是 iPhone 导出侧问题，需另行排查（判据：修复只解决「到了不显示」，不解决「没导出」）。
2. **轴档宽屏布局**：事件块单列窄块 vs 随宽度展开/多泳道（建议列入 iPad v2 第二批）。
3. **想法列表宽屏行宽**：维持通铺 vs 限宽/双栏（v2 第二批已有「想法列表-详情双栏」规划，确认优先级）。
4. **设置页宽屏**：Apple 登录按钮拉满全宽观感（v2 第二批「设置宽屏双栏」确认优先级）。
5. **长廊 920 宽度观感**：若东林希望更大胆可试通铺+内部卡片限宽的方案（本轮取保守值）。
