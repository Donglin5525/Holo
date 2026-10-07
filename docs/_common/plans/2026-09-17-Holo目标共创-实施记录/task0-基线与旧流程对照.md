# 目标共创 · Task 0 基线记录与旧流程对照

> 2026-09-17 记录。对应计划：[2026-09-17-Holo目标共创-完整开发计划.md](../2026-09-17-Holo目标共创-完整开发计划.md) 任务 0。
> 本文件是实施前的事实快照：工作区在途改动边界、旧流程的代码级行为（供新旧对照）、冻结场景集说明。

## 1. 工作区基线（git status 快照）

- 记录时刻：2026-09-17，分支 `1.0.6`，全库 198 条脏记录（大量并行会话在途改动 + 未跟踪文件）。
- **后端 `HoloBackend/` 工作区干净**（仅一个未跟踪脚本 `scripts/warm-p0-review-builder.mjs`）——后端改动将全部是本计划增量。
- 本计划要触碰、且**已有他人在途改动**的文件（实施时只做局部增量，禁止整文件覆盖/回退）：

| 文件 | 在途改动内容（摘要） | 本计划叠加内容 |
| --- | --- | --- |
| `Views/Goals/GoalListView.swift` | `holoWindowWidth` → `holoContentWidth` 环境键迁移（iPad 可用性改造） | 新建菜单加「一起想清楚」入口 |
| `Views/Chat/ChatViewModel.swift` | IntentRouter 增 `originalInput` 原话兜底参数（任务日期修复后续） | GoalWorkshop 会话挂载点 |
| `Models/AI/HoloAICapability.swift` | 记忆决策策略 v4 四开关（记忆低确认成本方案） | `goalWorkshopEnabled` 开关 |
| `Models/CoreDataStack.swift` | `sharedDataModel` 全进程单例（134020 模型歧义修复） | GoalWorkshop 两实体注册 |
| `ContentView.swift` | 在途（未逐一核对，改动约 56 行） | 无计划内改动（若需要仅局部增量） |
| `Localizable.xcstrings` | 并行多语言批次（约 9 万行 diff） | 追加目标共创词条 |
| `Holo.xcodeproj/project.pbxproj` | 在途 48 行 | 新文件四锚点挂载 |

- 本计划要触碰、且**当前干净**的文件：`GoalDraftReviewView.swift`、`GoalDetailView.swift`、`GoalEditForm.swift`、`GoalRepository.swift`、`TodoRepository.swift`、`HabitRepository.swift`、`ChatView.swift`、`HoloBackendAIProvider.swift`、`PromptManager.swift`、`HoloServerFeatureFlags.swift`、后端全部 purpose 文件。

## 2. 旧流程（GoalPlanningCoordinator）代码级行为记录

旧链路构成：`ChatViewModel.startGoalPlanning` → `GoalPlanningCoordinator` → `GoalPlanningPromptBuilder`（本地拼 prompt）→ `AIProvider.completeGoalPlanning`（**通用 chat purpose 流式调用**）→ `GoalDraftReviewView` → `GoalRepository.saveDraft`。

以下为代码事实（非模型实测；模型行为在任务 7 评测中实测）：

1. **固定轮次话术**：`GoalPlanningSession.defaultMaxTurns = 3`；`questionPrompt` 按第一/二/三轮写死「先肯定→追问动机投入→确认信息」，不感知内容缺口。
2. **固定行动数量**：`draftPrompt` 规定精简模式 2–4 任务 + 1–2 习惯、完整模式 4–8 任务 + 2–4 习惯——**不接收零习惯目标**，对 gw-020（只想喝水）、gw-032（旅行准备）、gw-035（搬家）这类场景会强行生成习惯。
3. **无路径选择**：草案一步到位，不存在「比较两条路线再选」的交互；route-fork 场景（gw-001/005/010/012）的取舍由模型单方面替用户决定。
4. **会话不持久**：`activeGoalPlanningSession` 只在 `ChatViewModel` 内存；杀 App / 崩溃即丢，无恢复。聊天记录仅作展示，不能重建会话状态。
5. **额度压缩策略**：入口按剩余额度把 `maxTurns` 压到 `max(1, min(3, remaining-1))`；额度终态直接释放会话回普通聊天。
6. **purpose 未隔离**：`completeGoalPlanning` 默认实现走 `chatStreaming`（通用 chat purpose + 全量 UserContext 注入）；无独立 prompt 版本、无 metadata_only 日志（聊天原文可进管理日志）。
7. **确认页字段缺失**：`GoalDraftReviewView` 不展示 `desiredOutcome`、`motivation`、`deadlineText`、`missingInfoWarnings`（计划 §1.2 事实，代码核对属实）；无成功证据、假设、里程碑、第一步概念。
8. **saveDraft 分步落库**：先 `createGoal`（save）→ 逐任务 `createTask`（每次 save）→ 逐习惯 `createHabit`（每次 save）→ 最后再 save。任一步失败留下半套数据；无幂等（双击确认/重试会创建整套重复行动）；无决策版本记录。
9. **旧流程无事实分级**：不区分用户陈述/授权记录/推断/未知；`missingInfoWarnings` 仅是字符串数组。

### 旧流程在 10 个代表场景上的推演（代码级）

| 场景 | 旧流程行为 | 失败点 |
| --- | --- | --- |
| gw-001 会议英语 | 3 轮固定追问后直接出草案 | 路径取舍不存在，模型替用户选 |
| gw-003 多读书 | 追问后草案必含 1–2 个习惯 | 「按本数排任务」路线不可表达 |
| gw-014 减 20 斤 | 草案给任务+习惯 | 无医学边界声明；无成功证据字段 |
| gw-020 只想喝水 | 草案仍会生成任务（2–4 个起步） | 过度规划，违背用户明确范围 |
| gw-023 别让我每天记 | 追问不感知「拒绝每日记账」，草案习惯仍可能含每日记账 | 用户约束被忽略 |
| gw-032 云南旅行 | 生成习惯（如「每天查攻略」类凑数） | 一次性项目被日常化 |
| gw-038 想变好 | 3 轮追问泛泛而谈 | 无关键缺口概念，问不出决策级问题 |
| gw-041 用户纠正（不是没时间） | 纠正只作为下一轮 answer 文本拼接，无推断作废机制 | 旧假设残留 |
| gw-043 要求跳过追问 | 不支持；仍按轮次走 | 无法直达草案 |
| gw-044 已有目标重启 | 旧流程无已有目标入口，只能新建 | 重复建目标；无版本历史 |

## 3. 冻结场景集

- 位置：`Holo/Holo APP/Holo/HoloTests/Fixtures/GoalWorkshop/goal-workshop-scenarios-v1.json`（磁盘文件，测试经 `#filePath` 定位读取，Node 评测脚本直接读路径——单一真源）。
- 规模：**45 个合成场景**（≥40 达标），7 个领域（学习 9 / 职业 7 / 健康 9 / 财务 6 / 生活 6 / 项目 5 / 模糊 3），特殊类型全覆盖：路径分歧 4、零习惯 5、约束冲突 7、用户纠正 4、已有目标受阻 3、医学边界 3、一次性项目 2、要求跳过 1。
- 每条含：`input`、`keyGaps`（应问的关键缺口）、`routes`（合理路径 + fit + tradeoff）、`forbiddenInferences`（禁止推断）。无真实用户资料。
- 校验：JSON 解析通过、id 唯一、字段完备（脚本校验记录见实施过程）。

## 4. 测试基建事实（影响后续任务的实现方式）

- 新测试文件采用仓库既有「Standalone + XCTest 桥接」双形态：`#if HOLO_XCTEST_BRIDGE` 包 XCTest 壳，`#else` 走 `@main` 独立可执行（swiftc 探针），HoloTests target 的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 已含 `HOLO_XCTEST_BRIDGE`。
- 新 Swift 文件必须手动挂 `project.pbxproj` 四锚点（PBXBuildFile / PBXFileReference / PBXGroup / Sources phase），文件存在 ≠ 参与编译（历史实锤）。
- Core Data 测试复用 `CoreDataTestSupport.sharedTestContainer`；`CoreDataStack` 已有在途的 `sharedDataModel` 单例修复（134020），新实体注册必须走 `createDataModel()` 统一出口，禁止自建第二份模型。

## Task 0 验收自检

- [x] git 基线与重叠文件在途改动已记录（§1）
- [x] 45 个合成场景冻结（§3），覆盖 ≥6 领域与全部异常类型，无敏感原文
- [x] 旧流程 ≥10 场景对照记录（§2），未把纸面推演当模型实测
- [x] fixtures 可重复读取（JSON 单一真源 + 路径定位法）

---

## 5. Task 1–2 实施结果（2026-09-17 追记）

### Task 1（模型/状态机/校验器）✅
- 新增：`Models/GoalWorkshopModels.swift`（阶段/事实分级/路径/计划/请求响应契约/会话状态机）、`Services/AI/GoalWorkshop/GoalWorkshopValidator.swift`（§2.2 全部客户端校验规则）。
- 测试：`HoloTests/Services/AI/GoalWorkshop/` 两套件（Standone+XCTest 桥接双形态），swiftc 探针与真 XCTest 双通道全绿。
- 修复实录：①Codable 手写 init(from:) 后必须显式补 encode(to:)（记忆库已知坑）；②ICU 严格模式仍把 `/` 当 `-` 等价分隔符——日期严格校验改为「解析后回格式化比对」根治；③测试文件落点曾错位（游离 `Holo/HoloTests/` 副本已清理）。
- 门禁：`xcodebuild ... -only-testing:HoloTests/GoalWorkshopStateTests -only-testing:HoloTests/GoalWorkshopValidatorTests` → **Executed 2 tests, 0 failures**。

### Task 2（Core Data 会话/版本存储）✅
- 新增：`CoreDataStack+GoalWorkshopEntities.swift`（两实体程序化定义，ID 逻辑外键+CloudKit 默认值+软删除）、`GoalWorkshopSessionMO.swift`（payload 版本化信封+未知版本解码前隔离）、`GoalPlanRevisionMO.swift`（决策摘要）、`GoalWorkshopStore.swift`（单调 revision 守卫+同 id 副本去重+listResumable/discard）、`GoalPlanRevisionStore.swift`（幂等版本记录）；`CoreDataStack.swift` 追加两行实体注册（在途 sharedDataModel 单例之上叠加）。
- **关键工程发现：Holo 主 target 已是 Xcode 同步组（新文件自动入编译），但 HoloWidgets 显式共享 CoreDataStack.swift 等源文件——CoreDataStack 的新依赖必须同时挂 widgets target，否则「cannot find in scope」**。已按 Matter 模式挂载 5 文件（实体/模型/两 MO/校验器）。
- 测试：`HoloTests/Models/GoalWorkshopStoreTests.swift` 10 用例（重启恢复/终态排除/丢弃/并发旧写拒绝/期望版本校验/副本去重/未知版本隔离/版本幂等/摘要 roundtrip）。门禁：**Executed 10 tests, 0 failures**。
- 已知坑复现：iOS 26.3 模拟器 hosted XCTest 的系统级重复释放（malloc double-free）在「第二个 Store 实例」场景确定性复现——按 `CoreDataTestSupport.retain` 既定政策缓解（测试域问题，非产品代码缺陷）。
- **遗留（需真机/发版配合）**：①旧数据库副本轻量迁移实测（自动迁移选项已开，新增实体为最良性变更，仍需真装验证）；②CloudKit schema dry-run 与 Production 部署（模拟器无 CloudKit，须东林设备上报 schema 后增量部署——同既有发版流程）。

---

## 6. Task 3 实施结果（2026-09-17 追记）✅

- 后端七处：`config.js` goal_workshop 路由（temp 0.3 / 4096 tokens / low reasoning / 10分40日限流桶）、`app.js` 归 chat 额度池、`serverPromptPolicy.js` 映射+多语言白名单、`defaultPrompts.json` 提示词 v1（分阶段/一次一问/路径取舍/事实边界/零习惯/契约JSON/不声称保存）、`promptRegistry.js` 版本 1、`adminLogStore.js` 强制 metadata_only、`featureFlagStore.js` goalWorkshopV1 默认 false。
- mock provider 增加 goal_workshop 契约回声（operation→kind 映射+sessionID/revision 回显），供链路测试；模型质量归 Task 7 评测。
- 测试：新增 `tests/goal-workshop.test.js` 9 用例全绿（路由/额度头/限流桶/注入与版本/meta 端点/zh-Hant 指令/metadata_only 即使管理员开启正文捕获/开关关闸+开闸）；既有 `feature-flags.test.js` 的 deepEqual 期望按新开关更新。**全量 `npm test` 423/423 通过**。
- iOS：`PromptManager.swift` 两分支（DEBUG/Release）各加 `goalWorkshop` PromptType + DEBUG 后备模板 + 版本 1，语义与后端对齐（生产以后端注入为准）。
- **未部署生产**（按方案 §8：代码完成后停在生产发布前，等东林授权）。后端发版时需按 holo-backend-deploy skill 流程，发布后核对 /v1/prompts/meta 含 goal_workshop v1 + 一次真实契约请求。

---

## 7. Task 4–7 实施结果（2026-09-17 追记）

### Task 4（编排器）✅
- 新增 `GoalWorkshopCoordinator`（start/reply/skip/choose/generatePlan/requestOptions/correctFact/cancel；inFlight 同轮去重；受控重试不占 5 次预算）、`GoalWorkshopPromptBuilder`（版本化请求体 + 围栏剥离）；`HoloBackendAIProvider` 增 `goalWorkshop` purpose + `GoalWorkshopModelServicing` 窄接口。
- 语义修正实录：`beginModelRequest`/`recordModelFailure` 最终定为「前进 revision」——预算消耗与失败记录都是会话状态，不前进 revision 无法过 Store 单调守卫落库，且旧轮迟到响应天然变 stale（一石二鸟）。
- 门禁：`GoalWorkshopCoordinatorTests` **9/9 绿**（假模型注入：零追问直达/纠正/网络失败可恢复/额度两档/非法输出重试/重复提交/预算耗尽/取消/跳过双形态）。

### Task 5（入口 UI）✅
- 四卡独立 struct（Question/Options/Definition/Resume）+ `GoalWorkshopFlowView` 容器 + `GoalWorkshopServiceFactory`（DEBUG 启动参数 `GOAL_WORKSHOP_UI_MOCK` 切本地脚本回声，UI 测试零网络依赖）。
- 三入口接线：目标列表新建菜单「一起想清楚」（开闸才显）、ChatViewModel.startGoalPlanning 分支（开闸指向同一会话；ChatView 仅一行 sheet 薄挂载）、目标详情「一起想清楚怎么调整」（P0 只给建议，两处「尚未修改」标记）。
- 开关：`HoloAIFeatureFlags.goalWorkshopEnabled`（本地默认关 + 服务端 goalWorkshopV1 总闸 + DEBUG 强开参数）。
- 交互修正：工具栏改「关闭」纯退出（进度保留可恢复）——「取消即丢弃」违背「退出可恢复」契约。
- 门禁：`GoalWorkshopJourneyUITests` **3/3 绿**（全流程到确认页/退出再进恢复+放弃/关闸旧入口回退）。测试三轮修复实录（重进漏点菜单项/跨运行残留会话/按钮当文本找）——UI 测试状态污染要用「进流程先清残留」根治。
- **遗留**：繁中/英文 xcstrings 词条批次（Localizable.xcstrings 有 9 万行并行在途 diff，本轮不整文件重写；简中为源语言直接显示，与既有批次同批处理）。

### Task 6（确认页 + 原子保存）✅
- `GoalWorkshopCommitService.performCommit`：单事务（Goal+任务+习惯+决策版本+会话回执一次 save）；Goal 实体新增 `sourceSessionID`（可选，CloudKit 兼容）作逻辑 ID；幂等三层（会话 appliedGoalID / Goal.sourceSessionID / 决策版本号）；`GoalRepository` 增可注入 init + makeTask/makeHabit 无保存构造器；旧 `saveDraft` 复用同一事务（**根治部分写入**，手建+旧 AI 草案同步受益）。
- 确认页补字段：期望结果/动机/期限(DatePicker)/待补充信息/成功证据/关键假设（可删）/所选路径代价；保存失败具体报错不静默；双击防护。
- 失败注入钩子（DEBUG only）：任务第 N 项失败/习惯失败/save 失败。
- 门禁：`GoalWorkshopCommitTests` **12/12 绿**；全量 HoloTests **1174 测试仅 2 败**（HoloAgentSchedulerTests 健康锁屏——在档已知回归，与本功能无关，G2 会话已移交）。

### Task 7（评测与门槛）部分完成
- `scripts/eval-goal-workshop.mjs`：45 冻结场景三轮契约（understand→propose_options→build_plan）自动校验 + 结构红线（代答事实/声称保存）+ 汇总报告（outputs/ 已 gitignore）。**本地 mock 后端链路验证 3/3 PASS**（仅链路，不代表质量）。
- 已跑门槛：后端 423/423；iOS 全量 1174（2 已知无关败）；UI 旅程 3/3；既有验收走查（多屏导航 42s）通过；共创各卡片视觉检查通过（菜单/问题卡/路径卡/确认页——无裁切/重叠/乱码）。
- **未跑（需环境/授权）**：① 真实模型 40 场景质量评测（等后端发版 + 真实 Provider）；② 真机门禁 AICrashDeviceReproUITests（需东林设备）；③ CloudKit schema 上报与 Production 部署；④ 真机人工验收；⑤ 五大入口的「发一条消息」项——本机无 UI 点按通道（idb 不可用），以全量单测+验收走查+截图目检替代，发版前真机补。

### 工程事实归档（本轮新增坑/模式）
1. **Holo 主 target 已是 Xcode 同步组**：`Holo/` 下新 Swift 文件自动入编译，无需挂 pbxproj；但 **HoloWidgets 显式共享 CoreDataStack.swift 等源文件——CoreDataStack 的新依赖（实体扩展/MO/模型/校验器）必须同步挂 widgets target**，否则报「cannot find in scope」。
2. HoloTests/HoloUITests 仍是经典 target：新测试文件四锚点手动挂载（本轮挂 4 个文件全部先漏挂后补——「Executed 0 tests」就是信号）。
3. iOS 26.3 模拟器 hosted XCTest 系统级 malloc 双重释放在「创建第二个 Store/Repository 实例」场景确定性复现——`CoreDataTestSupport.retain` 既定缓解（本轮三处命中；非产品代码缺陷）。
4. 同步组文件清单有滞后：同目录先后创建的文件可能只有先者入编译，touch pbxproj/删中间产物均无效时需排查 target 归属（本轮实为 widgets 显式列表问题，非同步组缓存）。

---

## 8. 后端发版记录（2026-09-17 21:23，东林授权）

- **部署提交**：`e13e05a1c`（feat: goal_workshop purpose 首版，10 文件 +300/-3）→ 脚本自动追加了 `4fd4b104`（chore: 卷入并行会话的未跟踪 `HoloBackend/scripts/warm-p0-review-builder.mjs`——scripts/ 目录不参与服务运行，内容无损保留；**已向东林报备，不 revert**（revert 会删对方磁盘文件，风险更大）。
- **流程**：holo-backend-deploy skill 脚本（npm test 423/423 → 推 origin/1.0.6 → ECS 对齐 → DOCKER_BUILDKIT=0 docker build → 容器重建）。启动后首拍健康检查 Empty reply（启动时延），5 秒后公网健康恢复 `{"ok":true}`。
- **发版后验证（§8 全项）**：
  1. `/v1/release/status` → commit=4fd4b104（含 e13e05a1c）✓；
  2. 容器内 promptRegistry → `goal_workshop version 1 source default` ✓（meta 端点生产有门控，用容器内验证）；
  3. 容器内 grep → serverPromptPolicy/config/adminLogStore 均含 goal_workshop（部署成功≠上线，以容器内实证为准）✓；
  4. **真实契约请求**（生产真模型）：HTTP 200 / 2.9s / kind=question / sessionID+revision 回显正确 / 载荷互斥 / 问题命中决策级分支（「紧张 vs 组织不成语言」）✓；
  5. **生产日志隐私红线**：ai_call_logs 的 goal_workshop 行不含用户原话（metadata_only 生产生效）✓。
- **当前状态**：purpose 已上线且可用；`goalWorkshopV1` 开关默认关——线上客户端零感知。**开闸即灰度**（admin 后台可开，或等 iOS 提审后统一开）。
- **下一步待办**：45 场景真实模型评测（注意：单设备跑满 135 次请求会触限流/额度，需 Plus 设备或分批）；iOS 提交与真机门禁；CloudKit schema 上报。
