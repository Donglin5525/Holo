# 场景依据

数量色阶：HoloHeatmap 用于待办统计完成节奏（12 周）和记忆活跃（13 周）；CalendarHeatmap / MonthCell 用于记忆月历，含 5 模块的底部色条，支持数量徽章形式。
习惯：HabitSingleReviewView 单习惯打卡日历；HabitReviewView 总体回顾；HabitTileView 今天习惯磁贴，使用用户习惯色和状态，不能视为单纯数量。
待办月历 TaskCalendarMonthGrid、财务 DayCellView 主要为数字、橙色选中及金额，不属于热力强度图，但纳入相邻页面对照。
参考源沿用前三轮已核实的 ColorBrewer / D3 连续色阶和感知明度方法。本轮新颜色为独立候选，不宣称官方配色。

修正：HabitTileView 不是当前今天页画法；已核对 HabitTodayView.heroCard（用户色淡渐变大卡）与 Components/HabitRowView（当月31天缝线），效果页采用后者。
设计边界：数量色与习惯状态、来源类别色分开。整体九场景同时展示，避免单独色卡造成误判。
