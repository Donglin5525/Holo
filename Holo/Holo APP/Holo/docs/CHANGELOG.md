# CHANGELOG

## 2026-06-05

### fix
- **记忆长廊 Dark Mode 空状态优化** — 修复 AI 回放空状态左侧圆形在深色模式下发黑发脏的问题，改为浅暗底、橙色描边与清晰图标；同步增强周期切换胶囊和洞察/明细未选中态的深色可读性

## 2026-05-31

### feat
- **HoloAI 记账确认与分类学习** — 记账由 AI 直接创建改为生成待确认草稿，用户可在卡片上确认/取消/修改分类；分类匹配优先使用用户历史纠正（CategoryLearnedMapping）；新增 Transaction.isAICreated/aiCandidate 字段支持 AI 来源标记与二次学习
- **HoloAI 卡片 UI 优化** — ChatCardView 统一组件重构，支持 header/footer/badge/deleted 通用模式；分析卡片精简布局；AnalysisDetailSheet 改为 bottom sheet 样式；习惯打卡/心情/体重/任务/目标卡片适配新组件

## 2026-05-19

### fix
- **站立数据改用 Apple Stand Hour 类别类型** — 之前用 `appleStandTime` 分钟数除以60，与 Apple Watch 站立环数据不一致；改用 `appleStandHour` 类别样本直接统计达标站立小时数，数据更准确
