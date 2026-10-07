# Holo App 全面代码体检与 Code Review

- 审查日期：2026-10-04，Asia/Shanghai。
- 审查对象：Holo iOS App、Widget、数据与 AI 客户端链路；包含工作区尚未提交的实现。
- 交付性质：代码审查、风险验证、整改建议。本轮没有修改 App 业务代码，没有安装 App、提交、推送或部署。
- 主工作区：`/Users/tangyuxuan/Desktop/Claude/HOLO`。
- 推荐阅读顺序：第 1 节结论 → 第 3 节风险表 → 第 4 节具体问题 → 第 7 节整改顺序。

## 1. 产品结论

**存在可能导致闪退的明确代码路径，也存在会随数据量、反复进入页面、连续操作而放大的卡顿风险。优先修复异常数据处理、数据库恢复和重复工作，再推进性能优化。**

本轮列出 **16 项整改问题：10 项 P1、6 项 P2**，另有 3 项需要补充验证的观察项。这个数量不是线上事故数量：有些问题必须遇到异常数据、磁盘故障、特定时区或并发删除才会触发。

其中，三条进程终止机制已经在独立验证程序中复现：

1. 跨领域记忆包含重复锚点，直接执行生产候选构建器，触发 `Duplicate values for key`。
2. 语义库接受负数向量维度，直接执行生产读写实现，触发数组长度错误。
3. AI 重复任务参数超出存储范围，执行与生产一致的整数转换表达式，触发整数溢出。

前两项验证直接编译了对应生产源码；第三项验证的是转换表达式，不是完整 AI → 任务保存的端到端旅程。**这些结果证明代码在相应输入下会终止进程，不证明目前用户已经遇到了这些输入。**

卡顿方面，首页监听重复注册、导出在主线程整批处理、健康页旧请求覆盖新日期，以及编辑器输入时反复扫描全文，值得优先治理。数据量较小时可能不明显，长期使用、带图数据增长或反复切页后更容易暴露。

**黑屏本轮没有运行时复现。** 当前代码能够指出启动失败、启动等待和主线程繁忙的风险，但不能把“空库”“加载态”“画面停止响应”都称为黑屏。后续应结合真实设备的崩溃、卡死、系统终止记录分别判断。

建议先完成第 7 节的第一阶段，再安排第二阶段的高频体验优化。不要仅凭构建通过将这些问题标为已解决。

## 2. 审查基线、范围与证据规则

### 2.1 代码基线

| 项目 | 本轮事实 |
| --- | --- |
| Git 分支 | `1.1` |
| HEAD | `91265544ba7c0eacefd791f0e633cb59a896142e` |
| 工作区状态 | 存在大量未提交改动和新增文件，审查包含这些内容；不是只审查 HEAD |
| 第一份冻结快照 | 2026-10-04 09:44；App 1,114 个 Swift 文件、306,855 行 |
| 第二份冻结快照 | 2026-10-04 09:56；App 1,114 个 Swift 文件、307,222 行 |
| Widget | 8 个 Swift 文件、2,830 行 |
| 测试文件库存 | 首轮统计 309 个 Swift 单元/standalone 测试文件、28 个 UI 测试文件；不是本轮已执行数量 |
| 工程环境 | Xcode 26.3（17C529）；Swift 5.0 配置，默认 actor isolation 为 MainActor；最低 iOS 17.0 |
| XCTest 状态 | 当前工程实际存在 `HoloTests`、`HoloUITests` target 与 scheme 测试配置；历史“无 test target”说明已不适用于此快照 |
| 构建检查 | Release、generic iOS Simulator、关闭签名；没有运行模拟器 UI 或安装真机 |

审查期间，编辑器保存、设备会话认证和工程文件仍在更新。第一次构建发现的编辑器访问权限错误，已在第二份快照中看到对应修改。最终构建状态见第 6 节，不能把首轮错误直接说成当前仍未修复。

报告源码位置指向主工作区，行号以 **09:56 冻结快照**为基准；主工作区后续修改可能使行号或结论变化。对应文件 SHA-256 清单保存在 [代码快照清单](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/manifest.json>)，复核时优先比对文件和函数，而不是只比对行号。

### 2.2 覆盖范围

本轮采用全库风险模式扫描、关键调用链深读、Release 构建、已有独立测试、针对边界输入的独立验证。覆盖全库扫描不等于人工逐行检查全部 30 万行，也不等于所有用户流程已通过验收。

| 领域 | 重点检查内容 | 本轮结果与边界 |
| --- | --- | --- |
| 启动与生命周期 | HoloApp、CoreDataStack、首页初始化、恢复提示、后台服务注册 | 发现启动错误直接终止与恢复链路风险；未做故障设备冷启动 |
| 数据存储与同步 | Core Data 模型/迁移、主/后台上下文、SQLite、CloudKit 重复记录与对象生命周期 | 找到备份与异常向量边界缺口；未做双设备同步或真实旧库升级 |
| AI / HoloAI | 网络取消、意图参数、记忆校验、跨域融合、语义库、索引恢复 | 复现重复锚点与负维度终止；审查 iOS 网络代码，没有验证生产后端 |
| 任务 / Today / 目标 | 日期规则、重复任务、附件、搜索与完成相关读取 | 发现整数边界、计划时间断言、异步附件对象风险；没有改动完成/撤回语义 |
| 财务 | 查询、分类、票根、CSV/JSON/ZIP 导出、聚合统计 | 发现主线程整批导出与分类重复查询；财务区间查询已有关系预取，不能重复算旧问题 |
| 想法 / 编辑器 | 富文本更新、中文组字、保存与恢复、附件、语义整理 | 发现逐次全文扫描；新保存协议和恢复日志已在更新，完整故障验收仍待补 |
| 健康 / 习惯 | 日期切换、异步查询、统计计算与页面刷新 | 发现健康旧结果覆盖新日期；统计仍存在同步主线程工作 |
| Widget / 通知 | 快照刷新、数据通知扇出、监听注册、定时器 | 发现首页重复注册与 Widget 未合并刷新 |
| UI / 交互 / 图片 | 大型 SwiftUI 视图、聊天入口、图片后台处理、缓存与长文本路径 | 列出聊天结构和长内容性能验证项；没有用源码行数推定当前崩溃 |
| 工程质量 | 编译诊断、actor 隔离、独立测试、验收门槛 | 记录构建与测试真实结果；没有执行全量 XCTest |

不包含：全面的后端安全审计、服务端负载、App Store 审核审计、真实支付与生产部署、所有辅助功能/机型适配验收。这些不能从本次客户端代码 review 中推定通过。

### 2.3 优先级和证据等级

- **P1：** 相应功能发布前应修复并验收。涉及进程终止、数据保护失败、明显累积工作或关键备份能力失去可用性。
- **P2：** 纳入下一轮明确的性能/正确性整改，不建议无限延期。
- **观察项：** 尚不能形成确定缺陷，应先测量或补验证，不能直接据此重写代码。

证据等级：**A** 为本轮独立运行复现；**B** 为源码和调用链能够确认机制，但未复现整机用户表现；**C** 为仍需设备、时序或性能测量。问题中出现 B/C，不代表已经发生线上事故。

本轮没有足够证据宣布“所有设备必现、无法正常使用”的 P0 事故，也没有足够证据宣布“整体已稳定”。

## 3. 问题总表

| ID | 优先级 | 问题 | 用户可能看到什么 | 证据 |
| --- | --- | --- | --- | --- |
| R01 | P1 | 数据库加载失败直接 `fatalError` | 启动即退出，无法进入修复流程 | B：明确终止分支 |
| R02 | P1 | 数据库恢复备份非完整事务，失败也继续重试 | 升级后数据空缺、备份难以救援、再次加载失败 | B：移动/重试/导出链路 |
| R03 | P1 | 向量维度与 BLOB 长度缺少统一校验 | 语义索引重建时闪退或读取错误内容 | A：生产源码负维度崩溃；短 BLOB 未拒绝 |
| R04 | P1 | 重复记忆锚点进入唯一键字典 | 后台记忆处理触发闪退 | A：生产构建器 SIGTRAP |
| R05 | P1 | AI 重复任务整数无上界，窄化转换会 trap | 创建某些重复任务时退出，可能留下半成品任务 | A：同转换表达式；B：完整调用链 |
| R06 | P1 | 时间规则用断言处理输入，全天固定为 24 小时 | 特定时区/非法时段保存时退出 | A：夏令时边界错误；B：终止分支 |
| R07 | P1 | 图片处理 await 后继续使用旧 Core Data 对象 | 并发删除/同步时附件失败、写回已删除内容，可能闪退 | B：对象跨挂起点；C：整机表现 |
| R08 | P1 | 首页监听和定时器可反复注册 | 越切页面越慢、重复刷新、耗电 | B：重复注册机制 |
| R09 | P1 | 导出在主线程整批读取和打包全部图片 | 导出卡住、无法取消、内存高，可能被系统终止 | B：执行位置与内存结构；C：实际阈值 |
| R10 | P2 | 健康页旧请求可覆盖新日期 | 日期与数值不一致、切天迟滞 | B：任务和状态发布机制 |
| R11 | P2 | 多条 async 查询仍在主线程同步工作 | 大数据下统计/日历/搜索卡顿 | B：执行位置；C：实际耗时 |
| R12 | P2 | Widget 刷新未合并密集数据通知 | 连续记录/同步时出现多轮查询、磁盘写入 | B：通知扇出机制 |
| R13 | P2 | 编辑器每次输入多次扫描全文 | 长笔记输入延迟、滚动与键盘不顺 | B：全文算法；C：长度阈值 |
| R14 | P1 | SQLite 打开失败后使用已关闭连接取错误码 | 存储异常时出现错误诊断或额外不稳定 | A：错误码失真；B：已关闭句柄使用 |
| R15 | P2 | 语义索引文件替换失败被当作成功 | 冷启动反复重建、索引健康状态不真实 | B：文件发布逻辑 |
| R16 | P2 | 恢复提示只在 onAppear 读取一次，分享依赖易清空状态 | 本次恢复没有提示，备份分享可能空白 | B：一次性读取；C：弹窗/分享时序 |

## 4. 详细 Review 与改进方案

### R01 · P1 · 数据库加载失败直接终止 App

**产品结论：** 一旦本地库因磁盘空间、文件访问、损坏或无法恢复的迁移问题打不开，用户可能连续启动即退出。保存的是个人长期记录，应该提供可恢复入口，不能把可处理的环境错误变成进程终止。

**建议决策：** 将存储启动统一为“加载中 / 就绪 / 失败 / 恢复中”的状态，失败时保留原库并进入明确的恢复页面。

**技术证据：** [CoreDataStack 存储完成回调](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:110>) 对任意最终加载错误执行 `fatalError`。[waitUntilReady](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:402>) 只表达成功，使用 `CheckedContinuation<Void, Never>`；没有把失败返回给等待页面的契约。此处不是普通 `throw`，外围 `do/catch` 无法接住。

**触发条件：** 存储首次打开或恢复重试失败。本轮未在用户真实数据库上注入这些故障。

**实施方案：**

1. 用一个共享存储启动状态管理成功、失败和恢复事件；等待方法返回可捕获错误或结果。
2. 所有等待方统一接收终态，不要只删 `fatalError` 后让 continuation 永久挂起，也不要错误时假装 ready。
3. 给用户“重试、导出诊断/现有备份、联系支持”等有限动作；破坏性重建必须有完整数据保护前提。
4. viewContext 的配置和后续使用遵守其队列约束，避免把后台回调直接当成主上下文执行环境。

**验收：** 正常首启/升级不退化；磁盘不足、不可访问、损坏库和无法迁移分别有终态；失败时仍保留可救援文件；所有等待任务能够结束，页面可操作。

**边界：** 不能通过“加载失败就创建空库”证明数据恢复成功；原始记录恢复与 App 能打开是两个验收目标。

### R02 · P1 · 冲突恢复没有保证备份整体完整

**产品结论：** 当前实现试图避免启动崩溃，但恢复时最重要的“旧数据可被完整救回”没有形成硬保证。CloudKit 不一定包含全部本地最新数据，不能用“以后会同步回来”替代备份完整性。

**建议决策：** 先形成可靠的迁移和恢复协议，再允许重建。备份不完整或无法确认安全时，应停止自动重建，进入 R01 的可恢复失败状态。

**技术证据：**

- [loadStoreAllowingRecovery](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:148>) 在模型冲突时调用备份；即使 `moved` 为 false 或只移动了一部分，仍再次 `loadPersistentStores`。
- [backupIncompatibleStoreFiles](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:185>) 分别移动 sqlite、WAL、SHM，单个失败只记日志，返回值仅表示主文件是否移动。
- [isModelMismatch](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:177>) 使用 `134100...134199` 范围分类，缺少对具体错误和迁移失败原因的细分。
- [恢复标记的备份列表](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:252>) 只匹配 `主文件名.conflict-backup-`，不会包含 `主文件名-wal.conflict-backup-`、`-shm`。因此“导出旧数据备份”的文件清单可能缺少 WAL 中尚未合并的内容。

当前 Widget 交互确实有独立容器读写同一个 App Group 库，见 [HoloWidgetDataStore](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/HoloWidgets/HoloWidgetIntents.swift:19>)。单进程逐个改名不是跨进程数据库恢复协议。本轮没有用真实 Widget 并发写入证明损坏已经发生。

**触发条件：** 模型不兼容进入恢复，且发生部分文件移动失败、目录权限/空间异常、未 checkpoint 的 WAL 或并发访问。

**实施方案：**

1. 对已支持升级路径建立旧版本模型/映射与迁移验证；只对明确可恢复的错误启动恢复，不把一整段错误码都等同于可重建。
2. 恢复前阻止 App 和扩展继续写入；使用 Core Data/SQLite 支持的、保留 WAL 一致性的关闭与备份方法，必要时通过独立 staging 目录完成迁移。
3. 返回包含备份路径、文件清单、各步骤结果的结构化结果。任何部分失败都不能继续按成功处理。
4. 每次恢复使用唯一标识，记录本次完整备份集；用户导出时打包完整恢复材料和元数据，而不是扫描目录猜测文件。
5. 分开报告“新库可打开”“本地恢复成功”“CloudKit 已完成回同步”，最后两项没有验证时必须诚实显示状态。

**验收：** 在旧库有待合并 WAL、第二个文件移动故障、扩展正在访问、未开启 iCloud、离线等情况下，原库仍可救援；备份包可在隔离环境恢复并核对记录数和关键内容。

**防止误修：** 本轮用程序化模型增加可选字段做独立迁移试验，轻量迁移成功。不能得出“没有 .xcdatamodel 文件就一定无法迁移”或“每次加字段都要重建空库”的结论。

### R03 · P1 · 语义向量读写缺少长度和维度契约

**产品结论：** 语义索引是可重建的派生数据，它的坏记录不应让用户无法使用整个 App。当前异常行可能造成进程终止、读出越界内容或不合理的大内存分配。

**建议决策：** 在向量写入和全部读取入口使用同一套校验；坏行隔离并重建该条索引，保留想法原文。

**技术证据：** [upsertItem](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/ThoughtSemanticStore.swift:162>) 接受独立的 `dimension` 和 `vector`，没有要求两者长度一致。[loadAllActiveVectors](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/ThoughtSemanticStore.swift:178>) 按数据库中的维度创建数组并索引 Float16 指针，没有检查 BLOB 字节数；[activeVector](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/ThoughtSemanticStore.swift:200>)、[loadVector](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/ThoughtSemanticStore.swift:229>) 有同类读取。`vector_key` 直接转 UInt64，也需保持正数/范围契约。相对地，`topicProfile` 已检查正维度与字节长度，可作为统一入口的参考，而不是只修一个读取方法。

[语义管线 bootstrap](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/ThoughtSemanticPipeline.swift:27>) 会打开并恢复索引；此路径不能仅凭历史“默认关闭”注释排除。

**本轮复现：**

- 生产 `upsertItem` 接受 `dimension = -1` 和 2 字节向量；生产 `loadAllActiveVectors` 随后 SIGTRAP：`Can't construct Array with count < 0`。
- 生产方法接受 `dimension = 1024` 和 2 字节 BLOB，随后返回 1024 维结果。它没有拒绝不完整输入；源码读取超出 BLOB 有效长度。
- 短 BLOB 用例没有获得 Address Sanitizer 报错，也没有在本轮复现段错误，不能写成“ASan 已证明闪退”。

证据：[负维度复现](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/semantic-negative.log>)、[短 BLOB 复现](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/semantic-short-blob.log>)、[独立验证源文件](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/SemanticEdgeProbe.swift>)。

**实施方案：**

1. 校验维度符合模型允许值、维度与向量元素数一致、BLOB 字节数严格匹配，且 key、模型版本及数值有效；先校验再转换/分配。
2. 所有 SQLite 向量读取统一走解码函数；不要让不同读取路径各自猜测合法长度。
3. 坏记录记录不含正文的错误摘要并隔离，按原文安排重建；避免坏行每次冷启动再次造成崩溃。
4. 事务失败时回滚，不用“跳过异常且标记任务成功”掩盖未生成索引。

**验收：** 负数、零、超大维度、短/长 BLOB、无效 key、非有限数、旧模型版本均能安全拒绝；有效向量 CRUD 和索引结果不变；坏索引不删除原文。

### R04 · P1 · 合法记忆记录中的重复锚点会让融合构建器崩溃

**产品结论：** 一个异常记忆记录可能在后台处理时拖垮整个 App。用户没有主动打开记忆页面也可能受影响。

**建议决策：** 统一记忆锚点的身份与去重规则，在输入、持久化和读取边界处理重复，并让融合构建器安全拒绝冲突。

**技术证据：** [候选构建器](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MemoryFusion/HoloCrossDomainCandidateBuilder.swift:40>) 对 `right.anchorRefs` 使用 `Dictionary(uniqueKeysWithValues:)`。[record.validate](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/HoloMemoryRecord.swift:258>) 只是用去重后的临时数组验证，不会修改原记录，也不会拒绝重复；稳定 ID 计算同样会折叠重复。于是“通过 validate”并不代表原始数组具备唯一键。

实际运行入口包括 [实时观察协调器](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MemoryObservation/HoloMemoryLiveObservationCoordinator.swift:234>) 的候选构建，另外还有候选判断和重新融合入口。这不是孤立的未使用辅助函数。

**本轮复现：** 两个领域记忆中加入相同 `stableKey` 的重复锚点，两条记录都通过生产 `validate()`，随后直接调用生产 builder，SIGTRAP：`Duplicate values for key: 'userTheme:恢复状态'`。见 [运行输出](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/fusion-duplicate.log>)、[验证源文件](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/FusionDuplicateProbe.swift>)。

**实施方案：**

1. 明确完全重复锚点的折叠规则；同一个 stableKey 内容相冲突时返回可捕获错误或隔离记录，不能随数组顺序随机保留一条。
2. 在写入时规范化，在历史读取时处理既有重复数据；builder 使用安全索引，不能依赖外部永远清洗正确。
3. 校验失败不推进成功游标、不产出看似成功的融合结果，允许数据修复后重试。

**验收：** 无重复、完全重复、冲突重复、历史 JSON 重复分别验证；完全重复不改变语义身份，冲突不会崩溃或悄悄生成结论。

### R05 · P1 · AI 重复任务参数可触发整数窄化崩溃

**产品结论：** AI 输出不是可信常量。一个看似可解析的数字，就可能让“创建任务”变成闪退，并留下已保存但未带重复规则的任务。

**建议决策：** 先统一验证整条任务提案，再一次性写入任务与重复规则。错误输入返回“重复规则不合法”，不改写用户原意。

**技术证据：** [创建任务与重复规则的顺序](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift:573>) 先创建任务，随后直接解析 `repeatInterval`、`repeatMonthDay` 并调用仓库；没有产品范围校验。[repeatInterval setter](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift:30>) 使用 `Int16(max(1, newValue))`，只处理下限；[createRepeatRule](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift:726>) 的 monthDay 同样直接转 Int16。

**本轮复现：** 执行生产同表达式，输入 40000，SIGTRAP：`Not enough bits to represent the passed value`。见 [复现结果](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/integer-overflow.log>)。这是转换级验证；没有实际调用在线 AI 创建任务。当前 RepeatPicker 未发现可任意输入该数字的文本框，因此不能把普通点击重复选项写成必现路径。

**实施方案：**

1. 定义重复间隔的合理产品上限，例如初步采用 1…365，再按当前业务契约确认；月日期限定 1…31，类型与 weekdays 组合也要合法。
2. 共享验证器供 AI、导入、编辑等入口使用，在任何对象创建、字段修改之前执行。
3. 合法性已确认后再做精确整数转换；失败抛业务错误，不能用截断或上限裁剪悄悄改变计划。
4. 将任务和规则放进一致提交协议，失败不留下半成品或脏 context 状态。

**验收：** 0、负数、上限、上限+1、40000、无效月日、空 weekdays、非法类型均不崩溃；失败无新增任务/规则/通知副作用。

### R06 · P1 · 计划时间输入用断言处理，日边界忽略夏令时

**产品结论：** 时间选择中的异常应允许用户修正。当前仓库把非法输入当程序断言；特定时区下，选择器本身还可能提供违反“同一天”规则的边界。

**建议决策：** 日期边界按日历计算，所有入口使用统一时间规则，并以可捕获错误拒绝非法范围。

**技术证据：** [createTask](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift:318>) 与 [updateTask](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift:423>) 使用 `preconditionFailure`，即使方法签名为 throws 也不能被普通 catch 接住。update 在检查前已修改其他字段，改为 throw 时也应同时调整验证顺序。

[endOfDayBound](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Tasks/PlannedTimeRangeSheet.swift:26>) 和 [开始时间上界](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Tasks/PlannedTimeRangeSheet.swift:120>) 以固定 24 小时计算一天。日历上的一天可能是 23 或 25 小时。

**本轮复现：** 美国洛杉矶 2026-03-08 夏令时开始日，当前计算的“当天 23:59”实际为次日 00:59；按日历增加一天再减一分钟才是当天 23:59。见 [边界结果](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/dst-day.log>)。整机选择器 → 保存的点击路径没有运行，因此本项是边界错误已证明、UI 触发待验证。普通上海时区不满足这个夏令时条件，选择器也已有 end≤start 修正，不能描述为普通点击必崩。

**实施方案：**

1. `Calendar.date(byAdding: .day, value: 1, to: startOfDay)` 求次日日界；用同一日历完成上界、显示和保存校验。
2. 仓库在任何字段修改前验证成对、开始早于结束、允许跨日与否；非法输入抛统一错误。
3. 在编辑层显示可修正提示，不因已缓存日期、时区变化或导入输入终止进程。
4. 明确当前产品仍要求同一天；不要为避免断言直接放开跨日并影响 Today/日历含义。

**验收：** 上海、洛杉矶春季/秋季夏令时、午夜、23:59、开始等于结束、缺一个边界、编辑中切系统时区；拒绝后对象字段与通知均保持一致。

### R07 · P1 · 附件处理挂起后继续使用旧数据对象

**产品结论：** 图片处理已放到后台，这是正确方向。但处理期间父任务/想法可能被删除、清理或由同步改变；回来后直接写旧对象，仍可能失败或把附件写回不应存在的内容。

**建议决策：** 异步操作只保留稳定身份；处理完成后重新解析父记录并确认仍存在、未删除，再提交附件。

**技术证据：** [想法 addAttachment](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Data/Repositories/ThoughtRepository+Attachments.swift:20>) 在 await 图片处理后读取 `thought.id`、`sortedAttachments`、建立关系并保存。[任务 UIImage 添加入口](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository+Attachments.swift:20>)、[任务 Data 添加入口](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository+Attachments.swift:50>) 同样在挂起后使用 task；提前保存 `taskId` 仅用于日志，没有验证对象生命周期。

这是对象在挂起期间可能失效的问题，不等同于已经确认这几处在错误线程访问。它们留在 MainActor 也不能防止用户或同步在 await 期间删除记录。

**触发条件：** 大图处理中删除父记录、永久清理、远端删除合并、上下文重置。软删除可能表现为写入不该再显示的记录；硬删除/失效 fault 可能产生异常。本轮未做双设备或故障时序复现。

**实施方案：**

1. 开始时捕获已持久化 objectID/业务 UUID 和纯图片输入；后台图片处理不持有 managed object。
2. 返回后在所属 context 的执行队列重新 `existingObject` 或按 UUID 查询，确认未失效、未软删除。
3. 父记录不存在时返回明确结果，释放此次临时资源，不重建已删除对象。
4. 为正在处理的操作定义取消/删除规则；列表关页与“用户删除记录”不是同一语义，不要一律丢弃正常保存。

**验收：** 正常添加、处理期间软删除/永久删除/远端删除/取消，均不会闪退、复活记录或生成孤儿附件；成功图片与其父记录保持一致。

### R08 · P1 · 首页每次建立时可能累积监听和定时器

**产品结论：** 这种问题容易表现为“刚打开很流畅，使用一会儿越来越慢”。同一条数据变更会触发多轮相同计算，长期还会增加耗电。

**建议决策：** 首页提醒服务由唯一生命周期拥有者启动，`setup/start` 必须幂等；定时器与监听有明确停用契约。

**技术证据：** [HomeScheduleService.setup](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/HomeScheduleService.swift:67>) 每次注册 4 类数据通知、1 个回前台通知和 Timer，没有已启动检查。服务是 singleton；cancellables 持续保留。给 `refreshTimer` 赋新 Timer 不会自动注销旧的 RunLoop Timer。

[HomeView.task](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/HomeView.swift:321>) 调用 setup，而 [根页面切换](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/ContentView.swift:159>) 通过 switch 在 Home/Chat/Profile 间构建不同分支，首页可以重新建立，因此不是保证只执行一次的启动入口。

**实施方案：**

1. 单例 start 用状态保证重复调用无副作用；如果选择随页面停用，则 stop 成对取消监听并 invalidate Timer。
2. 由应用生命周期或明确的持有者启动；不要在多个页面分别“初始化同一个全局服务”。
3. 同一批变更合并 refresh，保持首页的本地确定性；本项不需要引入 LLM。
4. 排查同类全局服务时看是否具备幂等保护，不因为存在 setup 名字就统一重写。

**验收：** Home ↔ Chat/Profile 循环 20 次，仍只有一套监听和一个定时器；一次数据变化只引起预期的一轮刷新；切后台/前台没有累计增长。

### R09 · P1 · 带图导出在主线程处理全部记录和图片

**产品结论：** 导出是用户保护自己数据的重要能力。记录多、票根多时，这条路径可能让页面长时间无响应，内存也随全部图片增长；严重时可能被系统终止。

**建议决策：** 导出改为后台、分批、流式写入，提供进度和取消；先解决图片驻留与主线程打包，再优化格式细节。

**技术证据：** [DataExportService](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/DataExportService.swift:17>) 为 MainActor；async 方法内部并没有自动转到后台。[ReceiptExportPlan](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/DataExportService.swift:31>) 把全部图片 Data 留在数组；[构建导出计划](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/DataExportService.swift:45>) 逐笔读取票根；[生成 ZIP](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/DataExportService.swift:265>) 同步写文件和逐张加入 Archive。[fetchTransactions](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/DataExportService.swift:333>) 一次读取整个导出范围；CSV/JSON 构建完整字符串/数组再编码。

另有 [categoryNames](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/DataExportService.swift:356>) 每遇到二级分类就查询父分类，并重新取共享 viewContext，既增加重复查询，也破坏注入 context 的一致性。

**触发条件：** 大量交易、图片、长时间范围导出。示例：200 张 2 MB 的压缩图片，单是图片数组就对应约 400 MB 内容；这是容量示例，不是本轮测到的 Holo 内存值或 iOS 终止阈值。

**实施方案：**

1. 后台读取上下文按批次取稳定 DTO/附件标识，分类映射一次构建；不跨队列传 Transaction/Category。
2. 导出计划只存元数据和文件定位，逐张读取/写入后释放；CSV 按行写，JSON 采用分批/流式编码设计，避免全量内存复制。
3. ZIP 生成离开主线程，控制批次与取消检查；输出先写临时路径，全部完成后发布可分享文件。
4. 选定一次导出的数据快照/修订，确保正文文件与票根清单来自一致的数据集合。
5. 中途失败/取消只清理本次临时输出，保留原始数据。UI 在失败时给出可重试状态。

**验收：** 1k/10k 交易与 20/100/200 张真实尺寸票根分档验证；导出期间仍能交互并取消；核对数量、金额、分类、图片对应关系与 ZIP 完整性；峰值内存随批次受控，而非随全部图片线性驻留。

**防止误修：** 不能只把整个服务塞进 detached Task 并继续使用 viewContext；后台化必须同时守住数据对象队列和一致性。

### R10 · P2 · 健康日期切换缺少“当前请求”身份

**产品结论：** 用户快速切日期后，标题可能显示新日期，数值却来自旧日期；旧请求还会增加延迟和重复查询。这比纯动画问题更影响用户对健康数据的信任。

**建议决策：** 日期和指标作为请求身份，旧请求取消或丢弃；同一日期的日数据和周数据统一发布。

**技术证据：** [日期 onChange](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Health/HealthView.swift:111>) 每次创建未保存的 Task；[loadDateData](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Health/HealthView.swift:784>) 连续四次 await，每一步重新读取 selectedDate，直接写界面状态。[详情日期切换](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Health/HealthDetailView.swift:103>) 也启动无身份任务；[详情 loadDateData](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Health/HealthDetailView.swift:379>) 和 [loadWeeklyData](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Health/HealthDetailView.swift:538>) 没有发布前检查。

因此不仅可能“旧请求最后完成覆盖新请求”，也可能同一次执行混合旧日数据与新日期的周数据。

**实施方案：**

1. 用 `.task(id: 请求身份)` 或受控 task 管理加载；函数入参捕获 date/type，不在 await 后读取变化中的 selection。
2. 本地组装完整结果，发布前确认 generation/requestID 与当前一致，再一次性更新。
3. 在 HealthKit 服务层传播取消并停止不需要的 query；只取消 Swift Task 不一定停止 continuation 包装的底层请求。
4. 给当前请求维护 loading 状态，避免旧任务提前关掉新任务的加载提示；按日期缓存可复用结果。

**验收：** 连续切 5–10 个日期，人工让旧请求延迟完成，界面始终匹配最后选择；退出页面后无无效发布；权限拒绝/无数据/查询失败的含义保持准确。

### R11 · P2 · 多条 async 读取仍占用主线程

**产品结论：** 用户数据长期增长后，统计、搜索、日历会更容易卡顿。“函数写了 async”本身不能解决同步读取和聚合的时间成本。

**建议决策：** 逐步建立后台读取投影，只迁出可证明昂贵的读取和纯计算；不一次性重写所有仓库。

**技术证据：** [FinanceRepository](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift:17>) 为 MainActor，使用主 context；[区间交易读取](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/FinanceRepository+Aggregation.swift:79>) 和统计入口仍同步 fetch 并去重。[四模块日历聚合](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Calendar/CalendarEventProvider.swift:58>) 串行在共享上下文执行；[searchTasks](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift:876>) 没有结果分页/上限；[习惯统计 reload](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/HabitStatsState.swift:327>) 同步计算当月概览、展示数据、6 个月趋势。

当前财务区间读取已有 category/account 关系预取，不能再把它描述为“所有区间查询都有同一个已修复的 N+1”。日历当前串行访问同一 context 是线程安全选择，不能直接改成共享 context 的四路并发。

**实施方案：**

1. 为统计/搜索/日历建立独立读投影，私有 context 读取并返回 Sendable 值对象，编辑与提交继续遵守现有数据规则。
2. 能在数据库聚合的金额/计数优先聚合，页面只取需要的区间和字段；搜索分页并按关键词取消过时查询。
3. 同一修订的统计结果复用缓存；明确失效规则，避免财务口径/软删除/CloudKit 去重语义偏移。
4. 首屏先完成必要本地数据，低优先级全量通知排程、历史整理和统计按测量结果延后/分批。

**验收：** 在 1k/10k/100k 历史数据梯度中测量首次打开、切月、搜索、日历滚动；金额、去重、对账排除与完成状态必须与现行结果一致；确认主线程耗时下降。

### R12 · P2 · Widget 密集刷新没有合并

**产品结论：** 保存一条数据同时驱动页面与 Widget 是必要的，但短时间多条记录或同步更新不需要逐次重做所有快照。当前会放大后台写入和界面负担。

**建议决策：** 每种 Widget 建一个可合并的刷新请求，短窗口合并 dirty 状态，保留最终正确结果。

**技术证据：** [startObserving](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Widgets/HoloWidgetSnapshotService.swift:22>) 已有重复注册保护，这一点正确；但财务/想法通知逐次创建任务，习惯/任务通知直接计算。[refreshFinanceSnapshot](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Widgets/HoloWidgetSnapshotService.swift:122>) 每轮查询当月数据、预算、聚合、写文件和 reload timeline，没有同类请求合并。

这与 R08 不同：R08 是同一监听反复注册；本项是在单一监听下，正常密集通知引起重复昂贵工作。

**实施方案：**

1. 用 dirty kind 集合和单个 worker 合并刷新；初始合并窗口可从 200–500 ms 试验，最终由真机反馈确认。
2. 正在刷新时的新变更保留为下一代请求；过期快照不覆盖新的快照，避免简单 debounce 丢掉最后一次更新。
3. 后台读取投影、原子写快照；同一结果只 reload 一次。
4. Widget 内用户直接操作后需要立即反映的链路保留明确及时更新规则，不把所有动作都延迟。

**验收：** 一秒内连续 10 次数据变更或一批同步，刷新次数明显合并且最终金额/打卡/待办正确；App 与 Widget 展示口径一致。

### R13 · P2 · 长笔记每次输入都会多次扫描全文

**产品结论：** 短文本体验可能正常，但长笔记和多个任务/引用 Token 会增加每次按键成本，表现为输入延迟、光标不跟手。

**建议决策：** 优先做输入过程的增量更新与修订缓存，全文序列化移到必要的保存/空闲时刻；保留中文组字、撤销和 UTF-16 坐标规则。

**技术证据：** [textViewDidChange](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Thoughts/MarkdownTextView.swift:591>) 在每次有效文本变动时同步规范化任务元数据、同步 markdown、更新触发状态。[normalizeTaskMetadata](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Thoughts/MarkdownTextView.swift:1369>) 维护来源区间；[syncMarkdown](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Thoughts/MarkdownTextView.swift:941>) 序列化全文并更新辅助功能；[serializeNodes](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Thoughts/MarkdownTextView.swift:2828>) 遍历整个 attributedText。

组字 `markedTextRange` 守卫已经存在，不应误报“没有中文组字保护”。新编辑器自动保存已有防抖/减少中间通知，但并没有消除 UITextView delegate 中的逐次全文工作。

**实施方案：**

1. 记录编辑影响范围，只更新相邻段落/任务来源区间；按文本 revision 缓存结构化节点与 plainText。
2. 阅读/保存所需的完整快照按空闲、防抖或显式完成生成；输入时不重复完成数次相同遍历。
3. 确认辅助功能更新的最小必要范围，不能为了速度让 VoiceOver 选区映射错误。
4. UIKit 对象仍留在主线程；只有不可变快照的纯计算才进入后台。不要把 UITextView/textStorage 跨线程使用。

**验收：** 2k/10k/50k 字与多 Token 文本，测量输入延迟；中文拼音组字、光标、引用、任务勾选、撤销/重做、保存再打开无内容或坐标偏差。

### R14 · P1 · SQLite 打开失败后读取已关闭连接

**产品结论：** 文件路径、权限或空间异常时，应得到可解释的失败并安全降级。当前失败分支反而引入句柄生命周期错误，降低诊断可信度。

**建议决策：** 捕获 open 返回码，关闭前取必要错误信息；关闭后不再使用该连接。

**技术证据：** [open](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/ThoughtSemanticStore.swift:111>) 的失败分支先 `sqlite3_close_v2(handle)`，随后 `sqlite3_errcode(handle)`。成功关闭会释放连接资源；该句柄不能继续作为有效连接使用。依据：[SQLite close 文档](https://www.sqlite.org/c3ref/close.html)、[SQLite errcode 文档](https://www.sqlite.org/c3ref/errcode.html)。

**本轮复现：** 把语义库目录位置设置为已有文件，生产 open 返回的错误被包装为 `openFailed(code: 21)`，即 MISUSE。这个结果支持错误诊断失真；本轮没有在该用例复现崩溃，因此不能写成“路径异常必定闪退”。见 [输出](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/semantic-open.log>)。

**实施方案：** 分开保存 `sqlite3_open_v2` 的 rc 与 handle；在连接仍有效时读取详细信息，随后关闭并清空；对后续 PRAGMA/migrate 失败也统一资源清理和可重试状态，避免半初始化 db 被误判为已打开。

**验收：** 文件占目录、权限/空间故障、PRAGMA/迁移失败分别返回正确错误类别；没有关闭后使用；再次重试能够重新打开或持续明确失败。

### R15 · P2 · 索引 checkpoint 发布失败却更新成功状态

**产品结论：** 本地语义缓存没存好时，用户可能在下次打开时等待重建，但内部状态会说已完成保存，难以发现真正原因。这里主要影响速度和可信诊断，不等同于想法原文丢失。

**建议决策：** 初次创建和替换已有文件分别处理；只有最终文件成功发布后才更新 generation 与 checkpoint 时间。

**技术证据：** [checkpoint](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/USearchSemanticIndex.swift:75>) 保存临时索引后用 `try? replaceItemAt`，忽略替换错误并继续增加 generation/lastCheckpoint。目标文件尚不存在或发布失败时，仍会记成成功。

[loadFromDisk](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/SemanticV3/USearchSemanticIndex.swift:111>) 只加载索引，映射 `keyToID/idToKey` 是内存状态；因此即使修好文件发布，也应检查重启时映射恢复与 validate。不能承诺“只改这一行就完全消除冷启动重建”。

**实施方案：** 最终文件不存在时将完整临时文件移动到最终路径；存在时原子替换；失败抛可捕获错误，保留最后成功文件，不更新成功状态。按同一 generation 保存/恢复映射和必要元信息，或明确它只是加速重建的缓存。

**验收：** 首次 checkpoint、后续替换、发布失败、损坏文件、重启恢复；成功状态对应真实文件；映射与向量一致；原文和 SQLite 真身不受影响。

### R16 · P2 · 恢复事件提示和导出状态仍有时序缺口

**产品结论：** 发生数据恢复的同一次启动，用户应立即知道发生了什么并能保存备份。当前提示有机会遗漏到下一次进入，分享状态也需要验证。

**建议决策：** 恢复事件接入存储状态变化，分享材料先独立保存；确认提醒和备份导出结果分开管理。

**技术证据：** [恢复门 onAppear](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Components/StoreConflictRecoveryGate.swift:22>) 只读取一次 marker；存储加载和恢复是异步的，[marker 写入](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift:168>) 可能晚于 root 首次出现。当前未订阅此事件或就绪后的变化。

另外 [alert Binding](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Components/StoreConflictRecoveryGate.swift:27>) 在关闭时 acknowledge 并把 pendingEvent 设 nil，而 sheet 的内容仍依赖 pendingEvent。按钮触发自动关闭与 sheet 呈现的实际顺序待 UI 验证；存在分享数据被清空的疑点，不把它报告为已复现空白 sheet。

**实施方案：**

1. 用可观察存储状态/恢复事件，或者明确等待本次加载终态后检查事件；不要只依赖一次 onAppear。
2. 点击导出时先将备份 URL 集合复制到独立 share payload，再关闭说明弹窗并展示分享。
3. “已知晓说明”“导出完成/取消”“备份仍在设备”分别表达；不要在自动关闭弹窗时提前清空唯一的导出数据。
4. 导出材料完整性依照 R02，提示不能替代可靠备份。

**验收：** 让恢复 marker 在 onAppear 之后生成，本次启动仍出现说明；导出可打开完整文件集合；取消/失败后仍能重试，不出现空白页。

## 5. 需要补充验证的观察项

这些观察项不计入前述 16 个整改问题，不能直接宣称当前已发生相应闪退。

### W01 · 聊天视图结构与真机栈风险

冻结快照中，ChatView 1,887 行、TaskDetailView 2,392 行、MarkdownTextView 3,672 行、ThoughtEditorView 1,926 行。行数本身不是崩溃证据，不能因为文件长就判断必定栈溢出。

但 [项目质量红线](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/standards/quality-redlines.md:21>) 记录过聊天入口巨型 SwiftUI 视图树的真机崩溃，并明确保护既有叶子 struct 边界。[ChatView 1800 行警戒规则](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/standards/quality-redlines.md:44>) 在当前快照仍被超过，应停止继续把新界面内联到此文件。

**推荐：** 只拆独立叶子子件，保留状态单一来源，不增加中间容器层；保留已建立的浅值/Binding 捕获方式。用真机覆盖聊天入口、停留异步初始化、发消息、语音入口和二级弹窗。普通模拟器构建成功不能关闭本观察项。

**本轮边界：** 没有收集新的 .ips、运行真机门禁或证明当前快照仍存在历史同签名崩溃。文档中的历史事件来自本次读取的项目规范，不是本轮事故复现。

### W02 · actor 隔离与 Sendable 编译警告需要按真实职责处理

第二份快照 Release 构建输出 **332 条去重后的 warning**，其中 234 条含 actor、Sendable、isolation/isolated 等关键词。这个归类用于定位，不代表 332 个缺陷或 234 个已证实数据竞争；证据见 [最终编译诊断](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/build-diagnostics-final.txt>)。

**推荐：** 按职责分组治理：纯模型/值计算明确 nonisolated；界面状态留在 MainActor；Core Data 使用所属 context 的 perform；跨任务传不可变快照和稳定 ID。重点复核 AppIntent、系统回调和真正跨队列调用，不通过随意添加 `@unchecked Sendable`、`nonisolated(unsafe)` 来消音。

逐模块提高并发检查强度，检查每项告警对应的调用者和运行队列；没有必要为了“清零警告”一口气重写整个 App 或立即切换全库 Swift 6。

### W03 · 新编辑器保存/恢复与相册加载代码仍在更新

第二份快照已包含“完成前提交成功”“保存失败留在编辑器”“暂存图恢复”“恢复日志防抖”等实现，不能重复报告它们为未实现。审查收尾时，主工作区以下三个文件相对冻结快照仍有变化：

- `Views/Thoughts/ThoughtEditorView.swift`
- `Services/PhotoLibraryImageLoader.swift`
- `Services/Thoughts/ThoughtEditorRecoveryStore.swift`

**推荐：** 对这些后续改动另行核对最新 diff 并执行对应故障验收。重点覆盖完成按钮、交互关闭、图片失败重试、保存失败、进程结束后恢复、空白/清空内容、删除原记录、相册大图和内存警告。确认文本、富文本、引用与图片提交一致，恢复内容不被旧异步清理误删。

**本轮边界：** 构建结论只针对 09:56 快照，不能冒称这些更晚的改动也已编译和验收。R13 的 MarkdownTextView 输入扫描结论不依赖这三个后续改动。

## 6. 本轮实际验证记录

### 6.1 构建与已有测试

| 验证 | 结果 | 能说明什么 | 不能说明什么 |
| --- | --- | --- | --- |
| 第一份快照 Release generic Simulator build | 失败，两条诊断来自同一访问权限问题 | 编辑器提交扩展调用 private 方法，首轮快照不可构建 | 不能说收尾时仍未修复 |
| 第二份快照 Release generic Simulator build | **BUILD SUCCEEDED**；332 条去重 warning | 09:56 冻结源代码能够生成 unsigned Release Simulator App | 不是模拟器运行、真机稳定或全量测试通过 |
| ThoughtSemanticStore standalone | **通过**，生命周期、Float16 往返、版本、job、flat 检索、销毁与向量数学 | 已有正常语义库用例通过 | 这些用例未覆盖 R03 异常维度/BLOB，不能据此关闭边界问题 |
| ContextExtraction standalone | **60 条断言通过** | 当前结构校验相关用例通过 | 不是全部 PersonalContext 套件通过 |
| ExtractorOrchestrator standalone | **未通过**：正常路径预期创建 1 条，实际 0 条；执行在该断言处停止 | 现行策略与旧用例契约需要对齐 | 测试 helper 的 fatalError 不是 App 线上闪退；停止后的用例没有运行完 |
| 程序化 Core Data 可选字段迁移探针 | **成功** | 此特定可选字段轻量迁移可行 | 不证明 Holo 全部历史模型、App/Widget 多进程或真实 CloudKit 库升级通过 |
| 全量 XCTest / UI tests | **未执行** | 无全量通过结论 | 不能拿测试文件数量当执行数量 |

首轮访问权限问题定位在 `ThoughtRepository+EditorCommit.swift` 调用 `createAssignmentInternal`；第二份快照中的方法已从 private 改为可供同模块扩展调用，最终构建通过。本轮只是观察到其他在途工作修正了它，没有代为修改业务代码。

**编排器红测的进一步定位：** 测试 fixture 使用“父亲”且 scope 为 person，并预期持久化一条记忆；[v4 策略默认启用](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift:935>)，[第三方持久化权限](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift:829>) 会阻断 person/group，[无持久化授权的 discard](</Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift:986>) 经 attach 返回 nil。因此源码显示该旧 happy path 与新默认策略不一致。此处应先确认新产品契约并补充“用户自身正常创建 / 第三方不持久化”的独立用例，不应关闭策略或改生产行为来让旧断言变绿。该定位基于源码，没有宣称整套编排器已经重新调整并通过。

证据：[首轮编译诊断](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/build-diagnostics.txt>)、[最终构建结果](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/build-result-final.json>)、[语义库测试](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/semantic-tests.log>)、[个人情境测试](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/context-tests.log>)、[模型迁移探针](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/model-migration.log>)。

### 6.2 独立异常输入验证

| 用例 | 实际结果 | 证据范围 |
| --- | --- | --- |
| 融合记录重复锚点 | 通过 validate 后，生产 builder 触发 SIGTRAP（退出 -5） | 直接编译对应生产模型/构建器，使用合成记录 |
| 负数向量维度 | 生产 upsert 接受，生产读取触发 SIGTRAP（退出 -5） | 直接编译生产 store，在新建临时库中运行 |
| 1024 维 + 2 字节 BLOB | 未被拒绝，返回 1024 维数组（退出 0） | 证明缺少长度拒绝，不宣称本轮已出现 ASan 报错或段错误 |
| repeatInterval = 40000 | 同生产转换表达式触发 SIGTRAP（退出 -5） | 转换级探针，未执行完整 App/在线 AI 链路 |
| 洛杉矶夏令时日边界 | 当前计算得到次日 00:59，日历计算为当天 23:59 | 日期计算探针，未操作真实 DatePicker |
| 语义目录被已有文件占据 | openFailed(code: 21)（退出 0） | 实际 store 的失败路径；未复现此分支闪退 |

探针只使用临时目录和合成数据，没有读写用户的真实 App 数据库。结果清单见 [探针执行结果](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/results.json>)。

### 6.3 未完成的验证

- 真实 iPhone/iPad 上的启动、聊天入口与语音门禁、卡死/黑屏/系统终止记录。
- Instruments 主线程、帧时间、输入延迟、内存峰值和泄漏观察。
- 真实 HealthKit 权限与数据、快速日期切换的请求时序。
- 双设备 CloudKit 合并、离线重启、远端删除与图片上传竞争。
- 真实旧版本库升级、低存储、WAL 未合并、App 与 Widget 同时操作。
- 全量 XCTest、所有 UI 测试与后端生产验证。

这些是建议后续补齐的证据，不是本轮已完成的验收。

## 7. 推荐整改顺序与可执行交付划分

不建议把 16 项堆成一次大重构。优先修“失败不应拖垮 App”的边界，再降低重复和整批工作。

### 第一阶段：异常输入与数据保护

| 建议交付单元 | 涉及问题 | 推荐工作量 | 完成定义 |
| --- | --- | --- | --- |
| 语义库读写与资源生命周期 | R03、R14 | 小到中 | 向量统一契约、坏行隔离、正确 open 错误码与清理；正常与异常探针均安全 |
| 记忆锚点身份与安全索引 | R04 | 小到中 | 输入规范化 + 历史读取处理 + builder 安全行为，重复/冲突不会终止 |
| 任务输入统一验证 | R05、R06 | 中 | 提案先验证再写入，窄化转换安全，日历边界正确，失败无半成品 |
| 存储失败与恢复协议 | R01、R02、R16 | 中到大 | 显式启动终态、完整备份、可恢复页面、同次启动提示、可验证导出 |
| 附件父记录生命周期 | R07 | 中 | await 后重新解析且拒绝已删除父记录，取消/并发删除无孤儿或复活 |

工作量是相对判断，不是未经实施的工期承诺。存储恢复涉及长期数据与多进程，必须用旧库与故障注入验收，不能只通过编译交付。

**阶段退出条件：** 相关新异常用例通过；受影响已有测试通过；Release 构建通过；对存储与附件执行明确的设备数据验收。Context 编排器红测同步对齐新策略并跑完，不能留一个名义上的“正常路径”红测充当安全网。

### 第二阶段：高频体验与备份可用性

| 建议交付单元 | 涉及问题 | 推荐工作量 | 完成定义 |
| --- | --- | --- | --- |
| 首页服务唯一启动 | R08 | 小 | 20 次切页不增加监听/Timer，一次通知只有预期刷新 |
| 导出后台流式处理 | R09 | 中到大 | 大数据可操作/取消，内存随批次受控，文件完整且口径一致 |
| 健康页按请求身份发布 | R10 | 中 | 旧结果不覆盖新日期，底层查询可取消或安全丢弃 |
| Widget 合并刷新 | R12 | 中 | 密集通知合并，最后状态正确，直接交互仍及时 |

先完成 R08 这类小而明确的累积问题，再给导出和健康时序建立真实数据基线。

### 第三阶段：长期数据规模与维护成本

| 建议交付单元 | 涉及问题 | 推荐工作量 | 完成定义 |
| --- | --- | --- | --- |
| 后台读取投影与结果缓存 | R11 | 中到大，逐模块 | 财务/日历/习惯/搜索各自有量化耗时和口径回归，不共享 context 并发 |
| 编辑器输入增量计算 | R13 | 中到大 | 长文本延迟下降，组字、坐标、撤销、结构化保存不退化 |
| 索引持久化与映射恢复 | R15 | 中 | 首次/替换发布真实成功，失败不伪装 checkpoint，重启索引一致 |
| 聊天结构与并发告警治理 | W01、W02 | 按真实调用链逐项 | 叶子边界保护、真机入口与语音通过，告警按职责减少 |

### 实施约束与回退原则

1. 保留现有统一业务规则：财务发生口径/对账排除/去重，任务完成与撤回，习惯打卡和 CloudKit 软删除，不为性能建立另一套规则。
2. 首页品牌光球、轨道和默认动效先保留；没有性能测量证据时不要把删除品牌资产作为“优化方案”。优先消除额外查询、重复监听和主线程大工作。
3. 写入策略改变需可核对历史数据，不以清空数据、静默截断 AI 参数或跳过失败当作修复。
4. 每个交付单元单独验证、便于回退；回退应保留原始数据和最后成功产物，不回退到异常输入直接终止的状态。
5. 缓存升级使用版本与原子发布。缓存可重建，正文/附件是原始资产，两者的删除和恢复规则必须不同。
6. 本报告没有提出后端改动。如后续实施调整 AI 参数/Prompt 契约，需要同步核对双端实现及生产版本，客户端构建不能替代后端发版验收。

## 8. 建议验收矩阵

下表是待执行计划，不是完成记录。尽量选择支持范围内性能较弱的真实设备，同时补一台当前主力设备与 iPad；不必先做所有组合，按改动范围选择。

| 场景 | 测试动作 | 要求观察的结果 | 对应问题 |
| --- | --- | --- | --- |
| 全新安装、正常旧库升级 | 冷启动 2 次，进入主要模块 | 首屏可见/可操作、记录正确，等待任务有终态 | R01、R02 |
| 存储故障 | 临时测试库注入无权限、空间不足、模型不兼容、部分备份失败 | 不退出、不无限加载，完整原库可恢复，说明准确 | R01、R02、R14、R16 |
| Widget 与 App 交互 | Widget 打卡/勾选，同时主 App 打开或进入恢复 | 同一记录规则一致，不跨进程搬走仍在写的库 | R02、R12 |
| 后台记忆异常输入 | 重复锚点、冲突来源、坏维度/BLOB | 不退出，不生成伪成功结果，历史原文不受损 | R03、R04 |
| AI 创建重复任务 | 极端 interval/月日/类型与组合 | 明确拒绝，任务/规则/通知无半提交 | R05 |
| 日期与时区 | 夏令时春秋、午夜、时区变化、非法范围 | 合法时段保持同日规则；失败可修正且未修改对象 | R06 |
| 图片竞争 | 加大图处理中删除、远端删除、退出与取消 | 不复活记录、不留孤儿、不闪退 | R07、W03 |
| 长会话切页 | Home ↔ Chat/Profile 20 次，然后新增记录 | 监听/Timer/刷新数量不累计，响应不逐渐变慢 | R08 |
| 历史数据增长 | 财务 1k/10k/100k、想法 1k/10k、长期习惯/任务 | 搜索、切月、日历按批次/投影运行，口径相同 | R11 |
| 带图备份 | 20/100/200 张真实尺寸票根，切到后台再回来，取消 | 文件完整、可取消、峰值内存受控、原数据完整 | R09 |
| 健康快速切天 | 连续切 5–10 天，注入旧请求延迟 | 页面只发布当前日期数据，不混合日/周结果 | R10 |
| 密集变更 | 连续 10 次记录或一批同步 | Widget 合并刷新，最后状态及时且准确 | R12 |
| 长文本编辑 | 2k/10k/50k 字、多 Token、中文输入、撤销、保存重开 | 输入延迟受控，光标/引用/任务/内容一致 | R13、W03 |
| 索引恢复 | 首存、替换、故障、冷启动、损坏缓存 | checkpoint 真实，映射恢复，坏缓存不损原文 | R15 |
| 聊天真机门禁 | 进入停留、发消息、语音、二级弹窗、重复切换 | 无历史同签名栈溢出，完成入口和语音门禁 | W01 |
| iPad / 辅助功能 | 旋转、分屏、动态字体、VoiceOver、Reduce Motion | 界面可用，长内容和编辑选区正确 | UI 回归 |

### 性能结果如何判定

为每个热点记录数据规模、设备、系统、构建模式、冷热缓存和操作次数，再比较改前/改后 P50/P95 耗时与峰值内存。不要用主力高性能手机上的主观“感觉顺”替代数据增长验收。

作为工程目标，可参考 Apple：离散交互的主线程同步工作尽量低于 100 ms，连续交互/动画优先把相关主线程工作控制在约 5 ms 内。它们是优化预算参考，不是本轮已测到的 Holo 耗时，也不是所有流程一刀切的业务 SLA。[Apple 响应性文档](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)

建议记录：冷启动首个可操作画面耗时、切模块/切月/搜索/按键 P95、通知后的实际刷新次数、导出峰值内存与取消耗时、健康过期结果丢弃数量。诊断只记耗时、计数、错误类别和修订身份，不采集个人正文/健康内容。

### 数据与并发结果如何判定

读取后台化不等于把已有 managed object 放到后台：每个 context 按自己的队列执行，跨队列传 objectID 或值对象。Apple 明确要求 managed object 遵守上下文队列约束。[Apple Core Data 后台使用文档](https://developer.apple.com/documentation/coredata/using-core-data-in-the-background)

验收同时核对“没有崩溃”“结果正确”“原数据完整”，不能只验证其中一项。

## 9. 已有保护与本轮排除的误报

完整 review 也要记录哪些做法已经正确，避免把正在生效的保护拆掉。

| 已核对内容 | 当前证据 | Review 判断 |
| --- | --- | --- |
| 财务区间查询关系预取 | Aggregation 已预取 category/account | 不把这条路径继续报为旧的关系 N+1；导出的父分类查询另见 R09 |
| Widget startObserving 幂等 | observers 非空即返回 | 不与首页重复注册问题混淆 |
| 图片处理后台化 | 附件入口 await 后台图片处理 | 解码/压缩迁出正确；需补的是父记录生命周期 |
| 编辑器组字保护 | markedTextRange 守卫、组字状态上报 | 不报“没有 IME 保护”；增量优化必须保留它 |
| 新编辑器完成协议 | 保存结果、失败留页、暂存图、恢复日志等已出现 | 不把历史未实现问题当作当前事实；后续改动另验收 |
| 个人情境来源索引 | 当前使用安全来源索引，重复来源用例先于正常路径红测执行 | 不重复报告历史 sourceID 字典崩溃已仍在原位置；R04 是另一个锚点字典 |
| 分类删除 / 部分记忆 ID 字典 | 上游当前有重复副本过滤/ID 去重 | 不能仅搜索到 uniqueKeysWithValues 就认定全部危险 |
| 网络取消 | APIClient 取消映射与 SSE onTermination 已接入；云端分析轮询检查取消与超时 | 没有沿用历史“取消永远无效”的结论；断网/后台恢复仍需设备验收 |
| 程序化模型可选字段迁移 | 本轮独立探针成功 | 不把模型形式本身判为必定丢库 |
| coder 的 fatalError、固定正则 try! | 多为不支持的初始化路径或常量模式 | 不将所有 force/fatal 文本匹配自动计为用户可触发崩溃 |
| 大型视图源码行数 | 风险提示而非运行堆栈 | 不因行数宣称当前栈溢出，也不删除品牌动效求“精简” |

## 10. 证据索引与复核方法

持久化证据位于本报告同目录的 `evidence/`；只保留文本诊断、合成探针和代码哈希，没有把二进制、DerivedData、用户数据库或大段构建产物加入项目。

- [09:56 源码/工程 SHA-256 清单](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/manifest.json>)：用于判断结论是否对应当前文件。
- [最终构建结果](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/build-result-final.json>) 与 [最终构建诊断](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/build-diagnostics-final.txt>)：对应 Release Simulator 构建。
- [首轮审查元数据](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/summary-initial.json>) 与 [首轮编译诊断](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/build-diagnostics.txt>)：保留在途错误已修正的时间背景。
- [语义库现有测试](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/semantic-tests.log>) 与 [PersonalContext 现有测试](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/context-tests.log>)：包括未通过项。
- [语义异常输入探针](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/SemanticEdgeProbe.swift>)、[重复锚点探针](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/FusionDuplicateProbe.swift>)、[整数/日期边界探针](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/ScalarEdgeProbe.swift>)、[轻量迁移探针](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/CoreDataModelProbe.swift>)。
- [探针退出结果](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/results.json>) 与对应日志：分别对应异常终止、正常返回和日期计算结果。
- [证据使用与复现说明](</Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/README.md>)：复核边界与命令。

源码冻结与完整构建日志临时目录为 `/tmp/holo-code-review-20261004`。临时目录可能被系统清理；报告结论、哈希、诊断摘要与探针已另存到项目，不依赖临时二进制持续存在。

**后续修复关闭一项问题时，必须附：对应文件/修订、修复后的异常与正常验证、设备验证范围、尚未验证边界。** 不用一句 BUILD SUCCEEDED 或“有测试文件”替代这些事实。
