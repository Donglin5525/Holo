# CloudKit Schema 部署到 Production（上架前必做）

> 交给 GPT 执行的自包含操作文档。更新于 2026-08-25，适用于 1.0（21）。

## 背景（为什么做）

Holo iOS App 的全部本地数据（任务/想法/账务/目标/习惯等）通过 `NSPersistentCloudKitContainer` 同步到用户 iCloud 私有数据库，容器 ID：`iCloud.com.tangyuxuan.Holo`。

近期代码新增了以下 schema（本地 Core Data 是代码程序化建模型，没有 .xcdatamodeld 文件）：

| 实体 | 新增字段 | 功能 |
|---|---|---|
| `Account` | 账单日 / 还款日 / 额度 | 信用卡账单管理 |
| `Goal` | `proactiveNudge` | 目标主动提醒开关 |
| `TodoTask` | `sourceTextSnippet` | 想法选中转任务的来源快照 |
| 约 30 个可清理业务实体 | `deletedAt` / `deletedBatchId` | 统一软删除、清空批次与 30 天恢复 |
| `RecycleBinBatch`（新增实体） | 批次 ID、时间、模块、数量等 | 跨设备展示与恢复回收站事件 |

`deletedAt/deletedBatchId` 覆盖财务、任务、习惯、想法、目标、纪念日、聊天/报告、记忆洞察、长期记忆和周计划等实体。实际部署清单以 CloudKit Console 的 Development → Production diff 为唯一准绳，不要只核对上表中的旧 3 个实体。

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
