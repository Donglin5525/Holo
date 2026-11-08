# 发版 CloudKit 部署清单（记忆中心批次）✅ 已完成（2026-10-25）

## 为什么要做
本批新增 Core Data 实体 `HoloMemoryControlEventMO`（用户控制事件表），已并入主模型随 iCloud 同步（CoreDataStack.swift:512 + cloudKitContainerOptions）。**不部署 = 正式用户首次打开新包后该表同步报错。**

## 顺序（不可颠倒）
1. **真机先跑一次最新构建**（东林 iPhone 装 Debug 包打开停留几秒）——把新表结构推进 **Development** 环境。没这步，后面部署的是旧结构=白部署。
2. **网页部署到 Production**（只能东林操作，账号是他的）：
   - 打开 icloud.developer.apple.com → 登录 → CloudKit → 容器 `iCloud.com.tangyuxuan.Holo`（Team 6WZ5TXGPQY）
   - 左上环境切到 **Development** → Database Structures → Record Types 确认 `CD_HoloMemoryControlEventMO` 存在（字段抽查：id/targetRecordID/kind/operationID/appliedAt）
   - 点 **Deploy Schema Changes…** → 勾全部 → 部署
   - 切到 **Production** 环境复查 `CD_HoloMemoryControlEventMO` 在列 = 完成
3. 部署即时生效，不用等发版。

## 顺带核对的老账（1.0.2 时代挂账，一直没实锤）
切 Production 后顺手确认这两个类型也在（缺就本次一并部署）：
- `CD_InductionRuleMO`（分类学习）
- `CD_RecycleBinBatchMO`（回收站）

## 验证命令（部署后东林可跳过；agent 侧无 CloudKit 凭证只能网页人工核）
CloudKit 无本机凭证（~/.holo-secrets/ 只有 ASC key），cktool 未存 token——部署只能网页做。


## 执行结果（2026-10-25 完成）

- ✅ Development 上报：真机跑新包未触发隐式上报（History 显示零新增）→ 加显式初始化工具 `CloudKitSchemaInitializer`（DEBUG 一次性，initializeCloudKitSchema）→ `CD_HoloMemoryControlEventMO` 出现。
- ✅ Deploy to Production：19 类型修改 + 6 新类型（含新表 38 索引）+ 安全角色 3 项，全量部署成功。
- ✅ Production 复查：`CD_HoloMemoryControlEventMO` 在列（64 类型）。InductionRule/RecycleBinBatch 老账一并清账。
- 工具留档：`Services/Sync/CloudKitSchemaInitializer.swift`（DEBUG-only，v2 键名）。**2026-10-27 修正**：不再随日常启动自动执行；仅开发者在 Xcode 启动环境显式设置 `HOLO_INITIALIZE_CLOUDKIT_SCHEMA=1` 时排入独立后台队列，成功才写完成标记，失败只在下一次显式请求时重试。普通记录同步仍由 CloudKit 镜像引擎处理；正式发版前仍需核对新类型并部署结构。
- 教训入档：真机 bundle id=com.tangyuxuan.holo-app（模拟器=com.holo.Holo，坑档已有）；initializeCloudKitSchema 是同步阻塞调用禁挂主线程；「先写标记后执行」会在被杀时残留假完成标记。
- 2026-10-27 真机补证：1.1.3 (35) 在 08:46 被 watchdog 结束，主线程停在 `initializeCloudKitSchema`。工程默认隔离为 MainActor，原 `Task.detached { await run() }` 仍会因 `run` 的隐式隔离跳回主线程；工具类型必须显式 `nonisolated`，同步 API 交独立 DispatchQueue，不能只凭「用了 detached」认定已离开主线程。

## ✅ 已闭环（2026-11-02 核实：两新表早已在生产库，待办前提有误）

~~本批新增两张同步实体（发现×知识联动，2026-10-31 随机漫步审计 S4 挂账）~~：
- `HoloMemoryKnowledgeRevisionMO` / `HoloMemoryKnowledgeOperationMO` → CloudKit 类型名 `CD_HoloMemoryKnowledgeRevisionMO` / `CD_HoloMemoryKnowledgeOperationMO`（2026-11-02 更正：原文误写 `HoloMemoryOperationMO`，真实类名见 CoreDataStack+HoloMemoryEntities.swift:209）

**2026-11-02 核实结论（CloudKit Console 网页实证）**：
- 两类型**已于 2026-10-28 20:30 由东林本人部署到 Production**（Schema History 实录：created CD_HoloMemoryKnowledgeRevisionMO type + 31 indexes / created CD_HoloMemoryKnowledgeOperationMO type + 38 indexes，与 CD_Thought 10 字段修改同批）——即 Knowledge v2.2 那次「64→66 类型」部署，多出的 2 个类型就是它们。
- Production 复核：68 类型与 Development 完全一致，两类型字段数 25/29 两端相同；Deploy Schema Changes 弹窗 Record Types (0) / Indexes (0) / Security Roles (0)。
- 10-31 审计 S4 把它们当作「未部署的新表」挂账，**未先查控制台**；该错误前提经 11-02 凌晨收尾台账（方案 A）传递至今，导致一轮不必要的真机上报（上报本身无害，为空差异）。
- 本次顺带：`CloudKitSchemaInitializer.doneKey` v2→v3（DEBUG-only，已随真机验证可越过旧标记）；真机 `[SchemaInit] ✅` 16:46:17。

**教训入档**：凡 CloudKit 部署类待办，**动工前先上控制台 Production → Record Types / Schema History 核对**，5 分钟读页面优先于任何构建装包动作；跨文档传递的待办必须在执行时重新验证前提。
