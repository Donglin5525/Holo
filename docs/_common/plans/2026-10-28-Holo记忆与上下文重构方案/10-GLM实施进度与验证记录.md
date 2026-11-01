# GLM 实施进度与验证记录

日期：2026-10-29 起。实施口径：[08-最终实施方案与GLM交接](08-最终实施方案与GLM交接.md)（v3.3）。UI 契约：[减法版原型](原型/记忆重构-核心画面原型-减法版.html)（东林 10-29 拍板「可以，开工吧」；同目录完整版仅作对照）。

授权边界（08 §11 + 东林 10-29 指令）：允许改业务代码/Prompt/测试、用合成数据与已授权隔离副本；不操作日用真实库、不重置 CloudKit、不发 schema、不装设备、不部署生产后端。东林明确要求：做完派 QA agent 检查页面（对齐/换行/美观专项）。

## 状态总览

| 工单 | 状态 | 备注 |
|---|---|---|
| M00 基线 | ✅ | 见下 |
| M01 契约/身份/仓库 | ✅ | 构建绿；R02/R03/R06/R07/R09 修毕 |
| M02 来源路由/核验 | ✅ | 构建绿；R01/R05 修毕 |
| M03 控制链 | ✅ | 构建绿；R08/R09/R10 修毕 |
| M04 解析/失效 | ✅ | 构建绿；R04/R11 修毕 |
| M05 记忆中心页面 | ⏳ | ios-dev 按【减法原型】实施中 |
| M06 准入/提示词 | ✅ | 后端 defaultPrompts.json +3 规则；personalPromptVersion 2→3；R12 修毕；**需后端发版** |
| M07 存量迁移 | ✅(钩子) | 遗忘清除启动补跑已接 migrateKnowledgeIfNeeded；隔离彩排待 M10 |
| M08 消费统一 | ✅ | LifePattern 旁路收口到记忆开关 |
| M09 使用归因 | ✅(核心) | 词重合署名退役（R13）；notice 不再 3 秒消失；固定版本 manifest 待 M10 补 |
| M10 构建/测试 | ⏳ | 首轮已绿；等 M05 合入后全量构建+测试 |
| M11 验收 | 未开始 | |
| QA 页面走查 | 未开始 | 东林点名：对齐/换行/美观专项 |

## 逐单记录

### M01 契约/身份/仓库（2026-10-29，构建绿）
- `HoloKnowledgeContract.swift`：①semantic 加 `statementDigest`（用户独立陈述指纹参与 semanticDigest——**修比 09 更深的问题：旧实现纠正只改 displayText，指纹/修订 ID 不变，新修订被 upsert 幂等吞掉，纠正从未入库**）；②evidenceSnapshotID 绑定全部核验字段（来源键×修订配对、窗口、覆盖、反例状态、holdout、完整周期、统计摘要）；③OperationKind 容错化 `unknownPreserved(String)`（未知种类保留原值+保守限制，R06）；④Payload 未知 kind 不再降 `.none`，保留诊断。
- `HoloKnowledgeRepository+CoreData.swift`：①修跨分区错插（revision 只写自己分区，R09）；②同 ID 不同 canonical 内容→保留双份+标记冲突（R07）；③解码失败行收集受影响命题→`unreadablePropositionIDs`（R06）；④新增 `purgeKnowledgeProposition`（遗忘清除：正文置空壳+deletedAt+纠正原文清除，R08）；⑤新增 `pendingForgetPurgePropositionIDs`（补跑目标）。

### M03 控制链（构建绿）
- `HoloKnowledgeControlService.swift`：①correct 写入 statementDigest（纠正真正入库）；②幂等重试分支补镜像+控制代数（失败重试收敛，R09）；③saveControlState 失败→persistenceFailed 不假成功；④forget 成功后调用 purge（失败不回滚停用，启动补跑续清）；⑤镜像 correct→rejected（旧端 corrected=激活+抬置信度会让被纠正旧含义复活，R10）。

### M04 解析器/失效（构建绿）
- `HoloKnowledgeResolver.swift`：①`latestEvidence` 按目标修订过滤（v1/v2 交错不共用快照，R04）；②`hasUnreadableData` → 命题保守 inactive（R06/R07 消费端）。
- `HoloKnowledgeRepository+CoreData.swift` `persistedSourceStatus`：evidenceSnapshot 晚到只清 revised/unknown，不得解除 deleted/excluded/permissionRevoked（R11）。
- `HoloKnowledgeInvalidationService.swift`：保守事件（远端/Habit 定义变化）不再全库写 unknown，改走增量对账 reconcileSources（R05）。

### M02 来源路由/核验（构建绿）
- `HoloMemoryEvidenceRouter.swift`：sourceID 统一 `HoloLifeSourceKeys.entityID(of:)` 剥前缀（个人情境证据路由必 nil 的根治）；habit-checkin 指打卡记录不直达习惯定义。
- `HoloKnowledgeSourceVerifier.swift`：health 默认 provider `{ .verified }` → `{ .unknown }`（R01）。
- `HoloPersonalContextExtractor.swift`：basis kind 按域如实分类（conversation=explicitUserStatement，业务记录=entityRef，R01——「任务记录被说成你在对话里说过」的根治）。

### M06 准入/提示词（2026-10-29）
- 后端 `HoloBackend/src/prompts/defaultPrompts.json` `personal_context_extraction` +3 硬规则：单次事件不成条／无关并列项不并入／同主题聚合禁按天拆条。**需后端发版**（真源在后端，iOS 无副本）。
- `HoloMemoryDiagnosticsIdentity.swift`：personalPromptVersion 2→3。
- `HoloKnowledgeAdmission.swift` + `HoloKnowledgeResolution.swift`：完整周期门槛 `insufficientCompletePeriods`（跨度足够≠周期完整，R12）。
- `HoloKnowledgeIngestion.swift`：①独立事件数=去重血缘（样本数/天数不再冒充）；②跨域无反例如实 notSearched（不再标 searchedNoneFound）；③completePeriods=去重 ISO 自然周（真实可推导的工程定义）。

### M09 使用归因（核心）
- `ChatViewModel.swift`：删除词重合署名兜底（R13：两个实测反例会冒领）；memoryNotice 不再 3 秒自动消失（改由下轮发送清除——署名核对入口保留完整一轮）。
- `HoloMemoryAttributionReconciler.swift`：头注释标注退役，仅存隔离诊断。

### M08 消费统一
- `HoloLifePatternService.swift`：个人规律桶（压力/恢复/建议方式）收口到「记忆辅助回答」开关；lowValueTopics（用户负反馈）不受开关影响。

### M07 迁移钩子
- `HoloMemoryRuntime.migrateKnowledgeIfNeeded`：启动时补跑未完成的遗忘清除（幂等）。

## QA 页面走查与修复（2026-10-29，三轮）

**第一轮（ios-qa 全量走查）**：10 项验收 = 7 PASS / 1 FAIL / 2 N-A（值得确认为空态无法触达）。
布局专项全过：卡片两行式无胶囊无数字网格、对齐 20pt 一致、详情默认两段+「更多信息 ▾」、深色全可读、无崩溃。
FAIL 项：详情页「查看原话 ›」弹「该记录已被清除」toast 不跳转。

**根因诊断（查模拟器 App Group 库实证）**：
1. 存量数据 evidence kind 整体错标 `explicitUserStatement`（R01 存量面），路由按 (kind, domain) 组合分派 → `(.explicitUserStatement, .finance)` 落 default → 财务卡入口直接消失；
2. `isSourceAlive` 统一 `deletedAt == nil` 谓词，与任务 deletedFlag/想法 isArchived/习惯 isArchived 软删体系不符 → 活记录误判已清除；
3. QA 抽中的想法类依据实体在库中**物理不存在**（同步自真库、原文确已删）→ toast 如实但文案歧义。

**修复**：①路由改按**来源域**分派（kind 仅排除聚合），存量/新数据都可路由，conversation/health/profile 仍走出处弹层不虚构跳转；②存活谓词按实体分派（TodoTask=deletedFlag+archived / Thought=deletedAt+isArchived / Habit=isArchived / Transaction+Goal=deletedAt）；③toast 文案改「这条依据的原文已被删除」。

**第二轮复验**：财务卡入口出现且可点（FIXED）、文案已换（FIXED）；活体跳转未闭环（抽中卡的原文均已删，活交易对应的记忆卡未抽到）——路由返回值与存活谓词已由逻辑保证，跳转本身是 10-25 已验证的既有链路。对话类来源无弹层入口（设计为出处弹层，UI 未覆盖到）记遗留。

## 本轮最终遗留清单

1. **需后端发版**：`personal_context_extraction` +3 防碎片规则（M06）——需东林授权走 `holo-backend-deploy`
2. M09 固定版本 `memoryUsageManifestV1`（新回答持久化绑定当时语义修订/证据快照）——下一批
3. 对话类来源的出处弹层入口（conversation 域 liveText 已支持，详情页 sourceRow 未接线）
4. xcstrings 新增 47 key 的 en/zh-Hant 翻译
5. 活体跳转闭环验证（需一条原文仍存在的记忆卡）+ 真机走查（东林 30 秒验收清单：个人页→Holo 记忆→卡片两行/详情两段/值得确认/哪里不对 sheet）
6. 「值得确认」空态下「对，记住/不对」交互未实测（本机无成熟候选——符合「宁空勿凑」的预期行为）
7. 全量 HoloTests 7 处失败均属并行会话在途改动，未越界修复

## M10 验证记录（2026-10-29）

- **合并态全量构建**：`xcodebuild -scheme Holo -destination id=2F63C1D8` → BUILD SUCCEEDED（主会话+ios-dev 全部改动合并后复验）。
- **探针脚本**：与重构后契约不兼容（声明提取机制耦合旧 enum 结构），已标注过时；验证转真实 XCTest（符合 09「修改后应新增实际集成回归」）。
- **知识测试 052/053**：全绿。过程中按新语义适配的测试点（均为行为升级的正确连锁，非放松）：
  - S08/S44/成熟正例补 `completePeriods` 字段（新门槛语义：成熟数据必须含完整周期维度）
  - M06 未知载荷断言 `.none` → `.unknownPreserved(kind:) + isUsageRestricting`（R06 升级）
  - R11 断言翻转：晚到旧快照**不**清除 deleted（旧断言固化缺陷行为）；补「可清除 revised」正例
  - 遗忘后命题返回最小无正文阻断（不是「不存在」）；restore 对已清除正文的遗忘命题走因果校验（conflict/notAllowed 而非 notFound）
- **全量 HoloTests**：7 处失败，逐一甄别**全部归属并行会话在途改动**（ReportReplayReaderView 登记表不一致、习惯撤销×2、任务时间下限、新人笔记、DailySense、调度顺延）——均不在本轮改动文件集，不越界修复。本轮相关测试（知识 052/053、归因、发现联动）全绿。
- **装包启动存活**：simctl install+launch com.holo.Holo（2F63C1D8）→ 进程存活 pid 98839。

## M00 基线（2026-10-29）

- 分支 1.1.4，工作区 143 个脏文件（多会话并行在途）。本工作只限 Knowledge/MemoryCenter/MemoryRepository/Chat 归因/Prompt 相关文件。
- 探针脚本复跑：`证据/run_review_probes.py` 输出与 09 §3 基线一致（future field preserved: false；text-only correction keeps digest/revision: true；changed coverage keeps evidence ID: true；old evidence later issuedAt → verified；remote empty conservative → false；overlap attribution 两反例仍冒领）。**修复后应重跑对比：text-only correction keeps digest/revision 应翻 false、old evidence later issuedAt 应不再 verified、overlap attribution 反例不再冒领。**
- 知识层底子：`Services/AI/Knowledge/` 9 文件 + 2 契约模型约 3800 行（v2.2 未提交）；按 09 的 R01–R16 修缺陷+补接缝，不推倒重写。
