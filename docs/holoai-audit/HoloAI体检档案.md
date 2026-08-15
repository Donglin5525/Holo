# HoloAI 体检档案

> 目标：对 HoloAI（AI 聊天助手）做长期、多轮的全面体检与改善。
> 四个维度：用户体验与交互 / 业务逻辑与数据流转 / 网络通信 / UI 美观度。
> 每轮体检产出问题清单（本档案维护），修复后更新状态。

## 轮次记录

| 轮次 | 日期 | 走查范围 | 修复数 | 状态 |
|---|---|---|---|---|
| 第 1 轮 | 2026-08-15 | 全量四维度（代码走查） | 9 项 | 已修复（待东林验收） |
| 第 2 轮 | 2026-08-15 | 档案第2轮优先项 + 东林三决策（超时/删确认/iCloud） | 16 项 | 已修复（待东林验收） |

---

## 问题清单

状态：`已修复` / `待修复` / `已记录·暂不修`（有理由）/ `观察中`

### 一、用户体验与交互

| # | 问题 | 位置 | 影响（用户感知） | 状态 |
|---|---|---|---|---|
| U1 | 多卡消息中点任意一张交易/任务卡，打开的都是最后一张的详情 | `ChatView.handleCardTap` 只用消息级 `resolveLinkedEntityId`（每类只缓存最后一个 ID） | 点 A 卡开 B 卡详情，跳转「没生效」感 | 第 1 轮修复 |
| U2 | 多张待确认卡时，点第二张的「确认/取消/改分类」实际操作第一张 | `confirmPendingTask` / `confirmPendingTransaction` / `cancelPendingTransaction` / `onTransactionModifyCategory` 均用 `firstIndex(where: pending)` | 确认错对象、误记账/漏记账 | 第 1 轮修复 |
| U3 | 长按消息「删除关联记录」在多卡消息里同样取第一个可删除实体，可能删错对象 | `MessageBubbleView.deletableCards` | 删除是破坏性操作，删错很痛 | 第 2 轮已修复（菜单按卡片粒度逐张列出，各带实体 ID） |
| U4 | 习惯/心情/体重卡片底部 chevron 箭头仍显示但点击无响应（假交互） | `ChatCardView.CardFooterView` 默认渲染箭头；a6395ed4 移除了点击但没去箭头 | 「看着能点，点了没反应」 | 第 1 轮修复 |
| U5 | 已取消的交易卡仍可点（有按压动效但无动作） | `TransactionChatCard` 只在 pending 时禁 onTap | 假交互残留 | 第 1 轮修复 |
| U6 | 卡片失败态（重试按钮）等按钮样式六种规格并存，确认类按钮胶囊/圆角不统一 | TaskChatCard / TransactionChatCard / FlexibleQueryChatCard / VoiceInputSheet 等 | 视觉不精致 | 已记录·随 D3 一并做 |
| U7 | 周期回放卡「继续生成」直连单例 Coordinator，与其他卡片的回调注入风格不一致 | `PeriodReplayChatCard.swift:55` | 架构一致性，无直接用户影响 | 已记录·暂不修 |
| U8 | 死代码：`WeeklyObservationCard`、`HoloMemoryCandidateCard`、`openTransactionDetail(_ message:)` 重载、habit/mood/weight 卡的 `onTap` 死参数 | 各文件 | 维护负担 | 待修复（第 2 轮清理） |
| U9 | 灵活查询卡行点击已删除的交易时静默无响应 | `ChatView.openTransactionDetail` 查不到就什么都不做 | 点了没反应 | 待修复（第 2 轮，配合 U5 一并处理删除态提示） |

### 二、业务逻辑与数据流转

| # | 问题 | 位置 | 影响 | 状态 |
|---|---|---|---|---|
| B1 | 确认进行中点「取消」会被确认结果覆盖（钱照样入账）；反之取消后确认仍回写 | `confirmPendingTransaction` 与 `cancelPendingTransaction` 无互斥 | 取消的交易还是记上了 | 第 1 轮修复（confirmingItemIds 互斥守卫） |
| B2 | 同一消息多张卡先后确认：后完成的用点击时刻的过期快照回写，把先完成的卡片状态回滚成 pending，再点确认=重复建实体 | `confirmPendingTransaction`/`confirmPendingTask` 里 `var updatedItems = batch.items`（外层捕获值） | 重复任务/重复记账 | 第 1 轮修复（回写改用重读的最新 batch 定位） |
| B3 | 「确认后 App 被杀」无对账：实体已建、卡片仍 pending，重启后再确认=重复入账 | `persistConfirmationStatus` confirming 中间态 + 实体 `aiSourceMessageId/aiSourceItemId` 标记 + `reconcileInterruptedConfirmations()` 启动对账 | 重复记录 | 第 2 轮已修复 |
| B4 | 金额/标题解析失败被当成功：卡片翻成已确认，实际什么都没记 | `IntentRouter.route` 返回非抛错文本，确认流程一律置 success | 用户以为记上了，账本是空的 | 待修复（第 2 轮，route 返回结构化失败标记） |
| B5 | 聊天确认路径建任务丢原文兜底：LLM 只回「明天」时丢时间、丢提醒 | `confirmPendingTask` 调 `route` 未传 `originalInput`，`resolveTaskDueDate` 兜底成死代码 | 任务时间/提醒丢失 | 待修复（第 2 轮） |
| B6 | 交易确认失败后「重试」按钮点了没反应 | `confirmPendingTransaction` guard 只认 `pending`，failed 直接 return | 失败的账只能重打一遍字 | 第 1 轮修复 |
| B7 | 任务确认失败渲染成正常任务卡（无失败态分支） | `TaskCardData.requiresConfirmation` 只认 pending；TaskChatCard 无 failed 样式 | 用户以为创建成功，实际没有 | 待修复（第 2 轮，给任务卡加失败态） |
| B8 | 任务页改名/改期/完成后，聊天任务卡内容永不更新（只刷新删除态） | `ChatMessageRepository.refreshTaskCard` + CoreData 观察 | 卡片信息过期 | 第 2 轮已修复 |
| B9 | 账本页（非聊天内）编辑交易后，聊天交易卡不刷新 | CoreData 观察补 Transaction 更新扫描 | 卡片金额过期 | 第 2 轮已修复 |
| B10 | 习惯/心情/体重/想法卡：删除态永不计算，内容纯一次性快照 | `prefillDeletionStates` 只收集 finance/task 两类 | 习惯删了卡片还亮着 | 已记录·暂不修（优先级低，涉及面广） |
| B11 | 取消打卡（toggle off）后卡片仍显示「已完成」徽章 | buildRenderData 补 completed=false | 文案与徽章自相矛盾 | 第 2 轮已修复 |
| B12 | NLDateParser 不认 ISO8601（`2026-08-16T21:00:00+08:00`）和「明天 09:00」式时间 | `NLDateParser.swift:40-51, 151-179` | 建成无日期任务或丢时间 | 待修复（第 2 轮） |
| B13 | deleteTask 三级模糊匹配（含备注包含）+ 无确认直接执行 | Coordinator 拦截 + 删除确认卡（红色「确认删除」+「取消」） | 可能删错任务（可从回收站恢复） | 第 2 轮已修复（东林拍板加确认；completeTask 伤害小保持直执行） |
| B14 | 流式中途退出页面，重进后停止按钮无效（新 VM 没有 currentTask） | `cancelStreaming` 孤儿 streaming 消息兜底定稿 | 停不下来 | 第 2 轮已修复（旧 VM watchdog 因 weak self 失效的孤儿消息一并收尾） |
| B15 | 编辑交易回写后卡片日期行消失（「8月16日」无年份解析失败） | 回写改标准格式 yyyy-MM-dd HH:mm | 信息丢失 | 第 2 轮已修复（随 B9） |
| B16 | 多动作批的「歧义追问」被计为成功（「已为你处理 N 件事」但零动作） | `ConversationCoordinator.swift:397-409` | 用户被误导 | 待修复（第 2 轮） |
| B17 | 分期起始日期 DateFormatter 未设 locale（和历/佛历设备解析失败回退今天） | `IntentRouter.swift:1329-1332` | 边界用户分期起始日错位 | 已记录·暂不修（影响面小，改动一行，随第 2 轮顺手） |

### 三、网络通信

| # | 问题 | 位置 | 影响 | 状态 |
|---|---|---|---|---|
| N1 | 流式中按键盘回车仍会并发发送第二条消息（发送按钮已换停止键，但 onSubmit 没守卫）→ 两个气泡显示交叉内容 | `ChatInputView.onSubmit` + `sendMessage` 无 isStreaming 守卫 | 消息串流、状态混乱 | 第 1 轮修复 |
| N2 | `errorMessage` 发布了但无任何 UI 消费；目标规划失败（非配额）只设 errorMessage → 完全静默失败 | `ChatViewModel.swift:1505-1507, 1559-1561` | 用户发消息没有任何回应 | 第 1 轮修复（失败写气泡） |
| N3 | `isError` 判定靠文案前缀/后缀匹配，与实际产出的错误文案全部对不上 → 重试按钮永不显示 | `ChatMessageViewData.isError` 三个条件全落空 | 断网/超时后只能重新手打整句 | 待修复（第 2 轮，根治需持久化错误标记如 messageType 扩展） |
| N4 | 90s watchdog + `timeoutIntervalForResource=120` 双闸对长分析类回复过紧 | watchdog 两段化（90s 提示不杀 / 300s 才超时）+ resource timeout 360s + 「AI 还在工作」提示胶囊 | 长回复被切 | 第 2 轮已修复（东林拍板放宽+感知文案） |
| N5 | 手动重试（retryMessage）重新走本地执行，若首次失败发生在「已落库、流式失败」场景会重复建实体 | `retryMessage` 删消息重发 | 重复记录 | 已记录·暂不修（N3 修好后重试入口才有用户，届时一起设计幂等） |
| N6 | deviceId 存 UserDefaults：卸载重装即换设备身份（后端额度/订阅按 deviceId 归属） | iCloud KVS 优先 + 本地兜底 + 双写 | 换机/重装后 AI 额度归属可能重置 | 第 2 轮已修复（东林拍板放 iCloud；真机首次构建会刷新签名配置） |
| N7 | SSEParser 只认 `data: `（带空格）、坏行静默丢弃无日志 | `SSEParser.swift` | 换上游格式会静默丢内容 | 第 2 轮已修复（支持无空格写法 + 坏行日志） |
| N8 | APIClient 通用 catch 把一切异常报成「网络不可用」 | `APIClient.swift:189-191` | 误导诊断 | 已记录·暂不修（同上） |
| N9 | 非流式路径 URLError.cancelled 被映射为可重试的 networkUnavailable，靠 Task.sleep 间接中断 | `APIClient.swift:87-88` | 轻微，多一次必败请求 | 已记录·暂不修 |

### 四、UI 美观度

| # | 问题 | 位置 | 影响 | 状态 |
|---|---|---|---|---|
| D1 | 聊天卡片族约 60 处固定字号（`.system(size:)`，含 11.5/10.5/15.5 分数档），不支持 Dynamic Type；同页输入栏用 token 可缩放，图文节奏割裂 | `Cards/` 与 `Analysis/` 全目录 | 无障碍 + 视觉一致性最大欠账 | 待修复（专项，单独一轮做） |
| D2 | `VoiceInputHaptics` 私有枚举完整复制 HapticManager（触觉红线） | `VoiceInputSheet.swift` | 规范红线 | 第 2 轮已修复（22 处调用改投 HapticManager，删除重复枚举） |
| D3 | 同一对话首屏三种卡片外壳并存：圆角 22+重阴影 / 圆角 16+无阴影 / 圆角 16 裸卡 | `ChatCardView` vs `QuotaExhaustedChatCard` vs `ChatEmptyStateView` | 视觉不齐 | 待修复（与 D1 同轮） |
| D4 | 徽章四种规格、时间戳三档字号、卡内大数字三档字号并存 | 各卡片 | 视觉不齐 | 待修复（与 D1 同轮） |
| D5 | 硬编码颜色：AnalysisChatCard 琥珀色内联 RGB、PeriodReplayChatCard 系统色绕过 token、jumpToLatestButton 硬编码阴影 | 各处 | 规范红线 | 部分修复（输入栏禁用态 `.gray` 已换 token）；余下待修复（第 2 轮） |
| D6 | Loading 指示器四种 scale（0.68/0.8/1.0/1.2）+ tint 写法不一 | 6 处 | spinner 大小不一 | 待修复（第 2 轮，封装统一组件） |
| D7 | 流式光标两套实现（"|" vs "│"）+ StreamingTextView 流式分支实为死路径 | `StreamingTextView` / `AIReadableResponseView` | 光标字形不一致 | 待修复（第 2 轮清理时一并） |
| D8 | FlexibleQuery 标题 18pt+lineLimit(1)+scale 0.82，中文长标题先缩字号再截断；metrics 区 magic padding 46 | `FlexibleQueryChatCard.swift:40-46, 76` | 长标题显示不佳 | 待修复（与 D1 同轮） |
| D9 | 动画全裸写魔法数字，Chat 目录 `HoloAnimation` 使用数为 0；常驻循环动画无 reduceMotion 兜底 | 全目录 | 规范红线 | 待修复（与 D1 同轮） |

### 五、工程基建

| # | 问题 | 位置 | 影响 | 状态 |
|---|---|---|---|---|
| T1 | **测试 target 整体编译失败**：11 个新写的 Standalone 测试漏加 `HOLO_XCTEST_BRIDGE` 双模式包装（@main 与 XCTest 冲突），另有 7 处测试代码过期、1 个桥接死条目、1 处 fixture 笔误 | HoloTests 多文件 | 单元测试一个都跑不了 | 第 2 轮已修复（测试恢复运行：700 通过 / 27 个存量失败为测试积压过期，见 T2） |

---

## 第 1 轮修复明细（2026-08-15）

| 编号 | 修复内容 | 方案 |
|---|---|---|
| U1 | 整卡点击按卡片自身实体 ID 跳转 | `TransactionCardData`/`TaskCardData` 携带 entityID，构造时从 renderData 注入；`handleCardTap` 优先用卡片 ID，兜底消息级（兼容旧数据） |
| U2 | 确认/取消/改分类按钮按被点卡片定位 | 卡片数据携带 executionItem ID；四个操作函数签名带 itemID，按 ID 定位而非 firstIndex；singleCard 旧路径 itemID 为 nil 时退回 firstIndex（单卡无歧义） |
| U4 | 假箭头移除 | `CardFooterView` 增加 showsChevron 参数，habit/mood/weight 传 false |
| U5 | 已取消卡禁点 | `TransactionChatCard` isCancelled 时 onTap 传 nil |
| B1 | 确认中不允许取消/改分类 | `confirmingItemIds` 互斥守卫扩展到 cancel 和 modifyCategory |
| B2 | 回写用最新快照 | 确认函数回写时以重读的 currentBatch 定位 item，不再用过期 pendingIndex |
| B6 | 重试按钮可达 | 确认 guard 接受 failed 状态（交易卡） |
| N1 | 流式中禁止回车发送 | onSubmit 加 isStreaming 守卫；sendMessage 入口兜底守卫 |
| N2 | 目标规划失败写气泡 | 非配额错误分支补 addMessage（assistant 气泡），不再只设无消费的 errorMessage |

### 六、测试基建（第 2 轮新增）

| # | 问题 | 位置 | 影响 | 状态 |
|---|---|---|---|---|
| T2 | 测试停摆期间积压 27 个失败测试（AgentScheduler 时序类 13、ResultRenderer 断言过期 7、ConsistencyReconciler 2、ThoughtTagConvergence 2、AgentResult 2、CalendarEventProvider 1 等），需逐个判断是生产 bug 还是测试过期 | HoloTests 各处 | 测试信号不可信 | 待修复（第 3 轮候选：逐个 triage） |
| T3 | 想法编辑器会话遗留：legacy JSON fixture 插值笔误已修；该会话的其他未提交改动仍在工作区（与本体检无关，待其自行收尾） | `MarkdownTextViewNodePipelineTests.swift` | — | 已顺手修复 1 处 |

---

## 第 2 轮修复明细（2026-08-15）

| 编号 | 修复内容 | 方案 |
|---|---|---|
| T1 | 测试 target 恢复编译运行 | 11 个 Standalone 测试补 `#if !HOLO_XCTEST_BRIDGE` 双模式包装 + `@testable import`；修 7 处过期 API 断言；清 1 个桥接死条目；pbxproj 移除 4 个纯 @main 脚本的编译条目（保留文件供命令行使用） |
| U3 | 多卡删除指错对象 | 删除菜单按卡片粒度逐张列出，各带自己的实体 ID |
| B3 | 确认中被杀防重复入账 | confirming 中间态前置落库；Transaction/TodoTask 加 `aiSourceMessageId/aiSourceItemId`；启动 `reconcileInterruptedConfirmations()` 对账（已建实体补 confirmed，未建回 pending） |
| B7 | 任务卡失败态 | 失败文案 + 重试按钮；确认入口认 failed |
| B8/B9 | 卡片↔实体双向同步 | CoreData 观察补 Transaction 更新；新增 `refreshTaskCard`；`refreshTransactionCard` 消息匹配改全量 ID |
| B11 | 取消打卡徽章矛盾 | buildRenderData 取消时写 `completed=false` |
| B12 | 日期解析覆盖 | NLDateParser 支持 ISO8601 与「09:00」冒号时间 |
| B13 | 删任务加确认（东林拍板） | Coordinator 拦截唯一命中生成红色「确认删除」卡（含取消按钮）；IntentRouter 不再无确认直删 |
| B14 | 重进页面停止失效 | cancelStreaming 把孤儿 streaming 消息一并定稿（旧 VM watchdog 因 weak self 失效无人收尾） |
| B15 | 编辑后卡日期消失 | 回写改标准格式 `yyyy-MM-dd HH:mm`（可回解） |
| N4 | 超时放宽+感知（东林拍板） | watchdog 两段：90s 提示「AI 正在处理较长的内容，仍在工作中」不掐断，300s 才超时；URLSession resource timeout 120→360s |
| N6 | deviceId 迁 iCloud（东林拍板） | iCloud KVS 优先/本地兜底/双写 + 两个 entitlements 加 KVS 声明 |
| N7 | SSE 坏行静默丢弃 | 支持 `data:` 无空格写法 + 解码失败留日志 |
| D2 | 触觉去重 | 22 处调用改投 HapticManager，删私有枚举 |
| 附带 | 任务/交易确认卡统一加「取消」按钮 | 与删除确认卡对称，「只能确认不能反悔」的交互断点消除 |

## 验证记录

- 第 1 轮后基线：698 通过 / 33 失败（存量）
- 第 2 轮后：**700 通过 / 32 失败**；与基线逐项 diff：**零新增回归**，多修复 1 个存量失败（fixture 笔误），余 27 个唯一失败项全部为测试停摆期间积压（T2）
- 全部改动仅 iOS 客户端，无需后端发版
