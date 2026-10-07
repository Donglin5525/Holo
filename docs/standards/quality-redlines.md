# 质量红线：不允许把「会闪退的包」递到东林手上

> **本文档是硬闸门，不是建议。** 由根目录 `AGENTS.md` 的「必读」指针与本索引（INDEX.md）共同引用；动代码前必读，交付前对照。
> 2026-09-17 由「点击 HoloAI 即闪退」事故设立（根因：ChatView 巨型视图树结构类型嵌套过深，SwiftUI 元数据实例化 + AttributeGraph 递归超出主线程栈，SIGSEGV 栈溢出，真机 4 份 .ips 同签名实锤）。
> 2026-09-23 第三次发作（语音按钮一点即崩，1.0.8 b29，工作区在途 +217 行内联代码把 ChatView 堆回 1993 行），随案增设 §6 ChatView 限重红线。

## 1. 交付前入口冒烟（硬闸门）
- 凡是要给东林真机装包验收的构建，**装包前必须先在模拟器完成五大入口走查**：今日/看板、HoloAI（进页 + 停留 3 秒覆盖异步初始化 + 发一条消息）、想法、任务、财务/设置。
- 走查由 ios-qa 子 agent 在无头模拟器执行，带回**文字结论**（是否崩溃、界面是否正常），不许只回截图路径。
- 任一入口崩溃 → 禁止交付，修复后重新过闸门。

## 2. 闪退诊断纪律：日志先行
- 任何闪退，第一步拿崩溃日志，**拿真实堆栈再动手**：
  - 真机：`~/Library/Python/3.11/bin/pymobiledevice3 crash pull --udid 00008150-000142E83A82401C <目录>`（东林 iPhone 17 Pro 的 USB UDID）
  - 模拟器：`~/Library/Logs/DiagnosticReports/` 最新 `Holo-*.ips`
- 拿 .ips 后先符号化定位（`xcrun atos` + 按 UUID 匹配的构建产物），再改代码；禁止凭印象改。
- 同一问题连续两轮没修好 → 停下跑 `self-check` skill（既有规则，此处重申）。
- **「修好了」的声明必须以「与复现环境同源的门禁」为准**：复现只在真机的问题，真机门禁（如 AICrashDeviceReproUITests）没跑绿之前，禁止向东林宣称修复完成（2026-09-17 事故：模拟器天然测不出、拿模拟器绿灯当判据，导致两轮假修复）。

## 3. 已知崩溃陷阱清单（改代码前对照，实锤新坑后追加）
1. **巨型 body 视图树**（2026-09-17 实锤）：单个 View 的 body/计算属性内联整棵复杂子树（消息列表/输入栏/长修饰符链），结构类型嵌套数十层 → 真机主线程栈溢出。规约：复杂子树拆独立 `struct`（struct 是类型边界，计算属性不是）；ChatView 的 `ChatContentColumn` / `ChatMessageListPane` 两道边界**禁止内联回计算属性**；新增长修饰符链大界面时同步评估拆分。
2. 非可选 `@NSManaged` UUID 跨线程 / 对象失效后访问 → Task 块内先做值快照（Thought.id / Attachment.id / reconcile 多案实锤）。
3. CoreData 对象删除后 UI 仍在 ForEach 渲染 → 删除路径保证 UI 读快照或重新 fetch。
4. 新增 Codable 持久化字段必须 `var` + 默认值或 Optional（`let` 带默认值不参与解码，恒 nil）。
5. 容错枚举必须显式手写 `init(from:)` / `encode(to:)`（编译器合成会盖掉协议扩展默认实现）。
6. 带 sheetDismissGuard 的视图禁止 push（今日看板闪退前科）。
7. 入口链路（ChatView 及其 .task 初始化路径）禁止 `.first!` / `try!` / `as!`；取应用目录用 `URL.applicationSupportDirectory`（非可选），不要 `urls(for:).first!`。
8. id 聚合字典禁用 `uniqueKeysWithValues`，必须 `uniquingKeysWith`（iCloud 副本天然重复 id）。
9. 大布局 / 环境键迁移类改动（双栏、侧栏、宽度语义切换）必须在 iPad 尺寸 + 竖横屏走查（防 watchdog 型假死被系统杀）。
10. **真机栈预算型崩溃**（2026-09-17 两轮 + 2026-09-23 三次发作、三轮修复实锤）：SwiftUI 巨树在真机 1MB 主线程栈溢出，但模拟器（Mac 进程 8MB 栈）**永远复现不了——模拟器绿灯对此类问题无证明力**。判据=真机：`HoloUITests/AICrashDeviceReproUITests` 是真机门禁，含入口用例与语音按钮二级交互用例；聊天/入口链路改动必须两个用例都真机跑绿才允许交付。历次拆出的结构体边界——`ChatContentColumn` / `ChatMessageListPane` / `ChatNavBar` / `ChatPageTabBar` / `ChatMemoryNoticeBar` / `ChatUnconfiguredView` / `ChatTaskEditSheet` / `ChatMatterStatusStack`——**一律禁止内联回 ChatView 计算属性**。崩溃帧形态：`closure/method in ChatView.xxx +数千字节`、`outlined init with copy of ChatView`、`___chkstk_darwin` 即此病。
    **三条三修实锤教训（2026-09-23，两轮假修复换来的，禁止再踩）**：
    a. **struct 边界不是免费的**：每经过一层 struct 边界，AttributeGraph 多下钻一层（约 12 帧 × 8KB ≈ 100KB 栈）。拆分只用于**叶子子件封顶单帧**；用嵌套容器 struct（ChatMainColumn→ChatPageTabContainer 方案）给链路「加层」会让原本能活的入口链直接爆栈。
    b. **方法帧同样叠加**：把巨型构造表达式挪进 ChatView 的方法（makeChatPane/makeMessagePaneActions 方案）不构成边界，崩溃帧原样落在方法上。
    c. **逃逸闭包捕获 View struct 的 self = outlined init with copy 整份复制该 struct**；应捕获浅值（先取 `$state` Binding 到局部变量再进闭包）。ChatView.internalLogAction 即此修法。

## 4. 装包唯一性与干净组装
- 给设备装包前记录构建产物路径与时间戳；排查东林手机上的问题时**先核对包身份**（.ips 里的构建号 + 构建产物 UUID 匹配），防多会话 / 旧目录装错包（有前科）。
- **给东林的验收包必须从干净检出组装**（git worktree 干净检出 HEAD + 只放本次改动文件，方法论见 memory `parallel-workspace-verify-worktree`）；禁止把主工作区多会话叠加态直接打包上机——2026-09-23 事故的直接诱因即未提交在途 +217 行随包上机，任何会话都没有完整验证过叠加态。

## 5. 与「少写防御性代码」的边界
闸门设在**交付流程与陷阱清单**，不在代码里到处 `try?` / 判空。只有确有边界的收口（如 `URL.applicationSupportDirectory` 替代 `.first!`、`if let` 拆包）才动代码；禁止为想象中的异常堆兜底。

## 6. ChatView 限重红线（2026-09-23 增，随语音按钮闪退第三次发作设立）
- **警戒线 1800 行**（`wc -l Holo/Views/Chat/ChatView.swift`，当前 1839，已在限上）：超过即禁止再往里加任何代码，先把存量拆出去。
- **新增界面块一律建独立 struct 文件**（放 `Views/Chat/` 目录，工程为文件系统同步型、自动进 target），通过参数/闭包注入依赖，`@State` 单一数据源留在 ChatView；禁止以「只加两行」「临时先放这」为由内联回 ChatView。**但只拆「叶子子件」——禁止新增中间容器层去包裹既有结构**（陷阱 10 三修教训 a：每层边界吃约 100KB 真机栈预算）。
- 判定原则回第一性：struct 是叶子上的帧边界（栈帧到此封顶），计算属性/方法都不是；但层数本身也是预算敌人——**「叶子拆出去、层级不增加」**是唯一安全方向。
- ChatView 有改动（哪怕一行）的包，交付前必须真机门禁两用例（入口 + 语音按钮）跑绿——见陷阱 10。
- 行数检查可自动化：提交前 `wc -l` 一句即测，超线由 Agent 自查打回，不依赖人记。

## 7. 数据沙箱隔离红线（2026-09-25 增，随饼图混层事故设立）

**原则：回收站（软删态）里的东西不能影响线上的内容——看不见的数据必须对活数据视图零影响，如同沙箱隔离。**

- 软删/回收站/同步副本/悬空引用这类「暂时不可见但未销毁」的数据态，**不得泄漏进任何活数据视图**（统计、列表、徽章、提醒、额度）。2026-09-25 实锤案例：回收站部分恢复不联动父级 →「活二级+死一级」孤儿 → 统计聚合让二级冒充一级混入饼图。
- **三侧同时盘查**，动软删、回收站、同步副本机制时缺一不可：
  1. **删除侧**：删父级容器（分组/清单/账户）时，子级与挂靠数据的去向必须显式处置（迁移或同批软删），禁止留半删状态；
  2. **恢复侧**：恢复任何子对象时，其同模块父链必须联动恢复（`RecycleBinRestoreEngine.restoreLinkedParents` 的 switch 分支表就是联动清单，**新增可软删实体必须同步加分支**）；
  3. **读路径**：所有「按 id 找关联对象」的查询（聚合、归组、去重、徽章计算），必须假设关联对象可能临时不在（在回收站/同步未达/悬空），并明确选一种语义：归入未分类桶、跳过并留日志，或触发自愈——**禁止静默让子级冒充父级**。
- 存量脏数据靠自愈修复链（`FinanceRepository.runRepairPass`）拉回正常态，不在读路径各自打补丁；读路径只负责「不留痕不放过」（日志暴露）。
- 新增「可软删实体」或「按 UUID 挂父引用的实体」时，自检三问：删父时子去哪了？恢复子时父跟不跟？读路径找不到父时账算谁的？三问答不下来不许合入。

---

*最后更新：2026-09-25（饼图混层事故随案增设 §7 数据沙箱隔离红线；历史：0923 §6 ChatView 限重 + 装包干净组装；新增实锤陷阱时在此追加并保持 AGENTS.md 底线四条不动）*
