# Task Plan: Holo 用户头像全局一致性方案

## 目标

基于当前代码规划一套“用户只设置一次、全 App 一致显示”的头像能力，覆盖上传/编辑入口、Holo AI、Apple 登录预置资料、跨设备同步、隐私与数据生命周期，并输出可直接交付开发的实施计划。

## 范围约束

- 规划阶段已完成；本轮进入 iOS 实施、专项测试与本地/模拟器验证。
- 保护当前工作区内所有并行改动，只修改头像功能明确涉及的文件。
- 方案文件落在 `docs/_common/plans/`，遵循 Holo 项目规范。
- 不部署 HoloBackend；不执行 CloudKit Production schema 部署；不 commit/push，除非东林另行授权。

## Phases

### Phase 1：盘点当前链路

- [x] 核查头像、个人资料、Apple 登录和同步链路。
- **Status:** complete

### Phase 2：定义产品与数据规则

- [x] 定义范围、统一数据源、展示点和不替换范围。
- **Status:** complete

### Phase 3：形成实施计划

- [x] 补齐分阶段任务、数据契约、文件映射、验收与回退。
- **Status:** complete

### Phase 4：复核与交付

- [x] 复核方案与当前架构、权限、隐私、测试和发布流程的一致性。
- **Status:** complete

### Phase 5：补齐圆形头像裁剪体验

- [x] 将自动中心裁剪升级为用户可拖动、缩放的方形取景与圆形蒙版预览。
- [x] 补齐大图内存、方向、边缘留白、取消和多尺寸验收规则。
- **Status:** complete

### Phase 6：实施基线与接线设计

- [x] 复核重叠文件的当前差异，确认可增量编辑边界。
- [x] 冻结实体、仓库、裁剪器和全局展示组件的最终接口。
- **Status:** complete

### Phase 7：数据、图片与同步实现

- [x] 新增 UserAvatar Core Data 实体、仓库、冲突/删除状态和启动接线。
- [x] 新增图片降采样、裁剪状态、512 方图输出与专项测试。
- **Status:** complete

### Phase 8：编辑器与全局界面接入

- [x] 新增头像裁剪/个人资料编辑界面。
- [x] 接入设置账号卡、个人页和 Holo AI 用户消息。
- **Status:** complete

### Phase 9：隐私、本地化与数据生命周期

- [x] 更新相机权限说明与隐私政策；新增中文文案沿用应用基础语言，正式多语言发版前仍需补入本地化词条。
- [x] 验证退出登录保留、移除同步状态和账号删除覆盖。
- **Status:** complete

### Phase 10：构建、测试与交付复核

- [x] 运行专项测试和主 target 构建；完成无需系统照片授权的模拟器专项验证。
- [x] 记录未完成的相册/相机真机旅程、双设备同步和 CloudKit Production 门。
- **Status:** complete

## 已核实的关键决策

- Holo AI 当前用户头像是固定 `person.fill`；AI 自身头像是独立 `sparkles`。
- Apple 登录只提供首次授权姓名/邮箱和认证凭证，不提供头像；账号卡应消费 Holo 头像。
- 昵称已有 Core Data / CloudKit 字符串同步，AI 的 HoloProfile 不适合承载界面头像。
- 新增独立 `UserAvatarEntity` 存处理后小图和删除状态；不接 HoloBackend。
- 真实身份展示位替换头像，导航/功能/角色/品牌图标保持系统语义。
- 新实体需要 CloudKit Production schema 发版门，但生产部署不在本轮授权范围。

## Errors Encountered

| Error | Attempt | Resolution |
|---|---:|---|
| 项目根目录已有其他任务的 `task_plan.md` / `findings.md` / `progress.md` | 1 | 不覆盖，改用本功能独立规划目录 |
| 完成检查脚本不识别 `[complete]` 状态 | 1 | 改为标准 Markdown `[x]`，再运行完成检查 |
| 完成检查脚本按阶段标题与显式完成状态配对计数，单独 `[x]` 仍无法识别 | 2 | 按技能模板改为阶段标题 + 显式状态 |
