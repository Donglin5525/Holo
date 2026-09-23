# Task Plan: Holo Matter 战略收敛与首发重构

## 目标

交付一份可由东林直接实施的完整方案，把 Matter 从高负担功能模块重构为 Holo 对“持续事项”的幕后责任机制，并以“日本旅行”完成首个可发布纵向闭环。

## 产品红线

- 不向用户教授 Matter、Open Loop、Projection 等内部概念。
- 不将 Matter 做成另一个清单、文件夹或项目管理工具。
- 用户一次确认后，必须原子化建立事项、计划、清单、任务和关联。
- Today 同一行动不得重复展示。
- 首发只解决有截止时间、多步骤、需跨日推进的生活事项。

## 阶段

- [x] Phase 0：恢复旧方案、历史决策和当前工作区边界
- [x] Phase 1：复核当前产品路径、数据契约和代码落点
- [x] Phase 2：锁定产品宪法、首发边界和唯一用户旅程
- [x] Phase 3：拆解可实施的交互、数据、代码、测试、灰度和回退方案
- [x] Phase 4：完成主方案文档、自检和交付
- [x] Phase 5：将日本旅行主旅程固化为唯一可执行 Use Case，补齐状态、数据、异常、恢复与验收契约

## 决策记录

- Matter 保留为内部领域模型，不再作为需用户理解和管理的一级功能。
- 首发指标不是 Matter 创建数，而是 7 天内有效推进率。
- 首发优先做截止时间明确的生活事件，不承担长期目标管理。
- 退役单项加入、批量加入和独立 Matter 激活三段式交互，改为一次“开始推进”。
- 计划步骤复用 TodoList + TodoTask，不新建第五个 Matter 实体。
- 原子启动由 `HoloMatterRepository.launchPlan(request:)` 作为唯一写入入口。
- Today 从模块平铺改为注意力压缩，同一任务只出现一次。
- Use Case 不是场景故事，而是页面、用户动作、数据变化和可验收结果的唯一契约。
- 首发不执行 `dependencyEdges`；将 Draft 顺序以 `HoloMatterLink.planOrder` 持久化，避免冷启动后顺序和下一步漂移。
- UC-MATTER-001 是日本旅行首发的唯一产品、开发与验收契约，主方案中的抽象规则不得覆盖它。

## Errors Encountered

| Error | Attempt | Resolution |
|---|---:|---|
| 项目根目录已有其他任务的 `task_plan.md` / `findings.md` | 1 | 不覆盖，在本方案独立目录中建立规划文件 |
| 按预期路径读取 `HoloMatterRolloutPolicy.swift` 失败 | 1 | 使用 `rg` 重新定位，不猜测文件路径 |
| 最终检查的 awk 三元表达式在 macOS awk 上缺少括号而解析失败 | 1 | 改用带括号的表达式重跑；不影响文档内容 |
