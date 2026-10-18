# Holo 成片色块场景效果页

2026-10-18。东林已确认雾蓝方案，已完成 iOS 落地，Debug 模拟器构建通过。HTML 保留本轮比较。

用户希望摆脱强行融合品牌橙的限制，并把相关实际色块场景画进 HTML 共同评审。

打开 [index.html](index.html)。默认雾蓝；松石青、灰紫、石墨灰与当前暖橙可切换。支持深浅模式、日常/三天/密集/空态、数量热力图灰度、一键新旧对照、日期点击联动、记忆月历兼容徽章预览。

## 覆盖清单

| 场景 | 代码依据 | 切换配色的影响 |
|---|---|---|
| 待办统计完成节奏 | TaskExperienceStatsView + HoloHeatmap | 数量色阶与图例 |
| 记忆洞察活跃热力图 | MemoryHeatmapView + MemoryGalleryView | 数量色阶与图例 |
| 记忆月历色块 | MonthlyCalendarView + MonthCell + CalendarHeatmap | 数量底色、日期前景、图例；来源细条保留 |
| 单习惯打卡日历 | HabitSingleReviewView / ReviewCalendarGrid | 保留习惯自选色、点/补录空圈/暂停线 |
| 今天习惯大卡与缝线 | HabitTodayView.heroCard + Components/HabitRowView | 保留习惯自选色与状态；没有套用旧 HabitTileView |
| 习惯回顾概览 | HabitReviewView.reviewRow | 保留习惯图标底色 |
| 记忆周历事件块 | WeeklyGridView.gridDisplayBlock | 保留来源色7.5%底、2px彩条 |
| 待办月历 | TaskCalendarMonthGrid | 保留计数文字与品牌橙选中圆底 |
| 记账月历 | DayCellView | 保留记录点和选中淡底 |

记忆月历的数字徽章属于已有组件的兼容样式，不代表当前默认入口已使用它。周历为手机三日窗口示意，时间位置为演示简化。月份固定2026年10月，截至18日。

范围按当前热力图议题理解为成片日历/记录色块及相邻上下文，没有扩展成全App每一个彩色按钮、分类选择器或所有图表的完整重设计。页面按代码结构复刻，图标与内容有简化，不是实际App截图，不能当作完整原生效果验收。

## 新配色原则

品牌橙仍承担操作和选中，独立数据色只表达数量。四套候选均用OKLCH固定色相、拉开明度；浅色从浅到深，深色反向逐档提亮。它们是本次设计，不是官方配色。

雾蓝优先比较：与橙色形成明确分工，少一点成功状态联想。松石青更温和，但需要防止把数量误认为达标。灰紫应检查与HoloAI的紫色角色是否混淆；石墨更中性但情绪温度低。

方法参考：[ColorBrewer](https://colorbrewer2.org/learnmore/schemes.html)、[D3连续色阶](https://d3js.org/d3-scale-chromatic/sequential)、[W3C OKLab/OKLCH](https://www.w3.org/TR/css-color-4/#ok-lab)，相关内容已在上一轮核对。设计判断仍需页面观感和原生验证。

## 验证边界

脚本语法检查通过。80组状态组合（5套色×2模式×4数据密度×2月历样式）渲染逻辑通过；核对九个场景、84/91格热力图、31天月历、稀疏三天及空态；四套新色相对亮度按序，候选底色的自适应黑白日期文字对比度≥4.5:1；配色切换、日期联动、徽章切换、新旧对照逻辑通过。

以上为轻量DOM替身测试，没有运行浏览器视觉验收。保留的业务自选色未宣称全量可访问性认证；原型阶段未修改iOS App；确认雾蓝后已完成接入与 Debug 模拟器构建，图表几何10,954项断言、品牌色隔离检查通过。未做真机视觉验收，未安装设备，无后端改动。
