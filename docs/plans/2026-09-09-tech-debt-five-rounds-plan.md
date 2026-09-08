# 技术体检 · 五轮代码优化计划

- 日期：2026-09-09
- 发起：东林（产品功能零变化，纯代码层优化）
- 工作量对标：资深 iOS 工程师一周
- 台账：`docs/tech-debt-5-rounds/ledger.md`
- 执行分支：1.0.3（每轮独立 commit，可单轮回滚）

## 一、体检结论（2026-09-09 摸底）

全工程 899 个源文件 / 238,128 行（不含测试）；HoloTests 230 文件约 950 个测试方法 + HoloUITests 72 个，QA 基线 897/897 绿。基础卫生好：print 仅 2 处且在 DEBUG 内、try!×1、as!×6、fatalError×6、TODO×1、无注释掉的代码块、无 SwiftLint。

### 卡顿实锤（主线程查询/解码/重渲染）
1. 习惯 streak 逐天 fetch ≤3650 次且在主线程（HabitRepository.swift:821/858；Stats.swift:80/451 每习惯叠加）
2. 长廊 HighlightDetector 日期×习惯双循环 fetch 主线程（HighlightDetector.swift:170/217；MemoryGalleryViewModel.swift:245-250；CalendarViewModel.swift:346）
3. TaskCardView 渲染内联 DateFormatter×4（:310/331/340/377）
4. ScheduleCommonViews 首页日程卡内联 formatter（:193/370/503/524）
5. DetailTabView 渲染路径逐日 Decimal reduce + 循环内 formatter（:55-63）
6. ThoughtGalleryView MainActor 逐张全尺寸解码（:70-80）；PolaroidMomentCard.swift:95、AttachmentGalleryView.swift:78 同款
7. DailyKanbanView 整页非 Lazy（:41-46 + KanbanTaskSection.swift:53）
8. FinanceRepository @MainActor+viewContext 全财务操作 + FinanceAnalysisState 每通知重算（FinanceAnalysisState.swift:186-200）
9. MilestoneDetector.swift:92、FinanceRepository.swift:800-815、ChatMessageRepository.swift:984 循环 fetch
10. ScheduleSyncEngine.swift:188-210 循环 save；AnniversaryShareCard.swift:99-104 computed 重复渲染
11. ChatViewModel 29 个 @Published / MemoryGalleryViewModel 24 个 @Published 全页失效面

### 死代码（已逐簇验证全工程 0 引用）
- 旧记账簇 1,971 行：Views/AddTransactionView.swift + Views/AddTransaction/ 五文件（注意：2026-09-09 在途改动曾往死文件加 146 行，仍死，R2 连同删除）
- 任务旧组件簇 1,407 行：ChecklistView/RepeatPicker/RepeatRuleView/AddFolderSheet/EditFolderSheet/PriorityPicker
- AI 记忆旧簇 901 行：HoloMemoryObserverService 等 5 文件
- MockAIProvider 547 行；散件约 1,197 行
- ThoughtShareCard.swift 文件是活的（ThoughtShareSheet 在用），仅内部旧类型约 360 行可删——排查误判已纠正，删除前逐文件重验是铁律
- 仅测试引用 6 处（连带删测试）；集合文件内死类型约 500-800 行

### 冗余与结构
- DateFormatter 内联创建 222 处 + 57 处分散 static，唯一共享封装只覆盖 1 个模板
- 金额格式化 3 套并存：统一入口 + 10 处 private formatAmount + 13 处手工 ¥ 拼接
- Logger subsystem 魔法串 ×158；HoloBackgroundContinuationManager 6 处裸 NSLog；ChatViewModel 内 4 次重复构造 Logger、10 处重复 updateMessage 参数组
- 6 个超 2,000 行文件、31 个超 1,000 行；Repository 两套位置（Models 根平铺 vs Data/Repositories）
- 无 SwiftLint/SwiftFormat、无警告基线

## 二、红线（全程有效）
- 产品功能零变化：不改交互/文案/视觉，不动 AI 提示词与业务规则，不动 CoreData 模型结构（不触发 CloudKit），后端零改动零发版
- 所有改动行为等价：等价替换、批量查询替代逐条查询、删除 0 引用代码、纯机械搬移
- 每轮验收门：编译零错误 + 全量单测绿 + 无头模拟器走查关键页（截图对比）+ 独立 commit
- 铁律：模拟器无窗口后台跑；新测试文件手动挂 pbxproj 防假绿；全量测试独占工作区

## 三、轮次安排（每轮 = 修上一轮回归 → 本轮主题 → 验收 → 台账+commit）

### 第 0 轮 · 基线准备（2026-09-09）
1. ✅ 在途 47 改动文件 + 35 新文件按主题分拣 6 笔提交（财务项目/个人情境萃取/AI表格/小组件隐私/文档评估/主词表）
2. 台账建立，体检发现全量入册
3. 编译警告增量基线存档

### 第 1 轮 · 卡顿专项
- streak 批量查询（≤3650 次/习惯 → 1 次取数内存计算）
- Highlight/Milestone 批量查询 + 挪后台
- 高频 formatter 缓存化（TaskCardView/ScheduleCommonViews/DetailTabView）
- 图片解码降采样+后台（ThoughtGalleryView/PolaroidMomentCard/AttachmentGalleryView）
- 看板 Lazy 化；FinanceAnalysisState 重算节流；长廊洞察页 Lazy
- 量化：上述路径查询次数/格式器新建次数降为常量级

### 第 2 轮 · 死代码清理
- 逐簇删除（删一簇→编译→测试→commit），删除前逐文件重验引用
- 目标净删约 6,500 行；仅测试引用 6 处连带删测试

### 第 3 轮 · 冗余收敛
- DateFormatter 统一工厂 + 222 处机械替换
- 金额格式化统一入口；Logger subsystem 常量化；NSLog→os.Logger
- ChatViewModel updateMessage helper；Toast 双实现只出评估报告

### 第 4 轮 · 结构治理（保守版，东林拍板）
- 机械拆分 MarkdownTextView（3,579 行）、ChatViewModel（3,220 行），零逻辑改动
- Repository 统一归位 Data/Repositories（纯移动）

### 第 5 轮 · 收尾加固
- 修回归；编译警告治理；SwiftLint 警告级引入 + 大文件冻结清单
- 全量回归（单测+UI 测试+模拟器全模块走查）
- 前后对比报告写入 CHANGELOG/TODO，交东林真机统一验收

## 四、在途改动分拣清单（第 0 轮执行记录 · 含并行会话协调结果）

> 2026-09-09 01:08 实况：另一并行会话提交并推送了 `1cc30301b feat(finance) 财务「项目」一期`（28 文件，含后端 prompts v3；其提交说明注明发版前置=CloudKit Production schema 部署+后端发版一次），随后转入「小组件交互+习惯待办」批次的在途开发（HoloWidgetIntents/HoloHabitWidget/HoloTodoWidget/TodoCompletionCore/HabitRepository 等，01:10 仍在写入）。本会话分拣据此调整为：

| 批次 | 主题 | 处置 |
|---|---|---|
| C1 | 财务项目功能 | ✅ 主体由并行会话 1cc30301b 提交；本会话补齐其遗漏的 4 残余文件（pbxproj 测试挂载/xcscheme 重排/CoreDataStack 装配/FlexibleQuery 测试对齐）= `f6c87141d` |
| C2 | 个人情境萃取+语义检索 | ✅ 本会话提交（昨日 15 时前的既有成果，并行会话未触碰） |
| C3 | AI 回复表格 | ✅ 本会话提交（同上） |
| C4 | 小组件想法隐私+财务小组件 | ⏸️ 归还并行会话——属其在途「widget-interactivity-and-thought-privacy」批次，勿抢 |
| C5 | 评估文档与语料 | ✅ 本会话提交 |
| C6 | 主词表 Localizable.xcstrings | ✅ 本会话提交（00:56 版本，含多主题文案） |
| C7 | 技术体检计划+台账 | ✅ 本会话提交 |
| 不提交 | 构建产物与走查产物 | build-contextplan-dd/×2、outputs/ 留工作区，建议后续进 .gitignore |

## 五、风险与回滚
- 每笔 commit 独立可 `git revert`；R1 性能改动以「测试全绿+截图对比+查询次数代码级验证」背书行为等价
- 全量测试须独占工作区，执行期间不开并行编译会话
- 已知坑在档：新测试文件手动挂 pbxproj；xcstrings 缺 key 只影响运行时回退不影响编译（中间提交可接受）
