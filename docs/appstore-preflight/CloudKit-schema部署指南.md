# CloudKit Schema 部署到 Production（上架前必做）

> 交给 GPT 执行的自包含操作文档。更新于 2026-09-07，适用于 1.0.2 提审前。
> ⚠️⚠️ **2026-09-08 实查更正**：此前记载「8-25（build 21）部署过一次 Production」**与事实不符**——
> 当日在 CloudKit Console 实查，容器 `iCloud.com.tangyuxuan.Holo` 的 **Production 环境从未部署成功过**：
> Record Types 仅有系统自带的 `Users`，全部业务类型（CD_Account/CD_TodoTask 等 30+）均不存在。
> 这正是线上 1.0/1.0.1（App Store 版连 Production）用户 iCloud 同步静默失败、双设备不同步的根因。
> 另：Development 环境已有大部分类型（含 CD_TaskScheduleMirror / CD_CategoryMappingRecordEntity），
> 但缺 `CD_CategoryInductionRuleEntity` 与 `CD_RecycleBinBatch` 及 1.0.2 想法索引字段——
> 说明推 Development schema 的设备跑的不是最新代码；部署前须先用**最新 release/1.0.2 代码**真机跑一次补全。
> 部署完成后请删除本段更正说明。

## 背景（为什么做）

Holo iOS App 的全部本地数据（任务/想法/账务/目标/习惯等）通过 `NSPersistentCloudKitContainer` 同步到用户 iCloud 私有数据库，容器 ID：`iCloud.com.tangyuxuan.Holo`。

**2026-08-25（build 21 部署）之后新增的 schema 清单（本次必须覆盖）**：

| 实体 | 变更 | 功能 | 随版本 |
|---|---|---|---|
| `TaskScheduleMirror`（新增实体） | 整个实体 | 1.0.1 系统日历镜像同步 | 1.0.1 |
| `CategoryMappingRecordEntity`（新增实体） | 整个实体 | 分类学习映射迁入 iCloud | 1.0.1 |
| `CategoryInductionRuleEntity`（新增实体） | 整个实体 | 分类归纳规则 iCloud 同步 | 1.0.1 |
| `TodoTask` | `taskId` 补默认值（合规修复：不补会导致任务记录**静默保存失败**） | CloudKit 必填字段合规 | 1.0.1 |
| `Account` | `lastReconciledAt` / `lastReconciledBalance` / `importBalance` | 余额对账 | 1.0.1 |
| `Transaction` | `isReconciliationAdjustment` | 对账调整标记 | 1.0.1 |
| `Anniversary` | `isLunar` | 农历纪念日 | 1.0.1 |
| `ThoughtTagAssignment` 等 | `basisTextHash` / `evidenceQuote` / `indexState` / `indexVersion` 等 | 想法自动整理 V2 索引 | 1.0.2 |
| 工作区未提交的模型改动 | 提交后以 Console 实际 diff 为准 | 若随 1.0.2 发版需一并覆盖 | 1.0.2 |

历史清点（build 21 已部署，仅作对照）：`Account` 账单日/还款日/额度、`Goal.proactiveNudge`、`TodoTask.sourceTextSnippet`、约 30 个实体的 `deletedAt`/`deletedBatchId`、`RecycleBinBatch` 新实体。

本地 Core Data 是代码程序化建模型（没有 .xcdatamodeld 文件）；实际部署清单以 CloudKit Console 的 Development → Production diff 为唯一准绳，不要只核对上表。

**关键机制**：开发（Development）环境的 schema 由 App 运行时自动更新；但 App Store / TestFlight 构建连的是 **Production** schema，**只能手动在 CloudKit Console 部署**。不部署的后果：线上版本一同步就报错，用户 iCloud 数据同步失败——这是上架阻断项。

## 前提

- Apple Developer 账号（Team ID：`6WZ5TXGPQY`）能登录 CloudKit Console
- 一台登录了 iCloud 的 iPhone + Mac 上有最新代码（含上述字段的提交，2026-08-14 之后 main 分支）

## 步骤

1. **真机跑一次最新 Debug 构建**（Xcode 直接连真机运行），进到 App 主界面停留 10 秒以上。CloudKit 会自动把本地 schema 推到 Development 环境。
2. 打开 **CloudKit Console**（https://icloud.developer.apple.com/dashboard）→ 选择容器 `iCloud.com.tangyuxuan.Holo` → 左侧 **CloudKit Database**。
3. 环境切到 **Development** → **Schema** → **Records**：
   - 确认 `Account`、`Goal`、`TodoTask` 的既有新增字段已出现。
   - 确认 `RecycleBinBatch` Record Type 已出现。
   - 抽查财务、任务、习惯、想法、聊天/报告、记忆等 Record Type，确认新增 `deletedAt` 与 `deletedBatchId`；再以待部署变更清单检查其余实体，不能只抽查后就直接部署。
   - 如果字段没出现：回 Xcode 确认跑的是最新代码，重启 App 再等一会儿。
4. 点击 **Deploy Schema Changes to Production** → review 变更清单 → 确认部署。
   - **安全检查**：变更应全部是「新增字段/新增实体」。如果出现任何「删除字段」「修改类型」的红色警告（数据丢失风险），**停下来**，先弄清来源再继续，不要盲目部署。
5. 验证：用 TestFlight 构建登录同一 iCloud 账号，创建一条数据，确认能正常同步（重装 App 后数据还在）。

## 风险提示

- Production schema 部署**不可逆**（字段只能加、不能删）。本次全部为新增字段，属安全操作。
- 部署完成后不需要改任何代码，纯后台操作。
