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
- 工具留档：`Services/Sync/CloudKitSchemaInitializer.swift`（DEBUG-only，v2 键名，失败自动重试）——下次发版有新表时自动复用，无需手动网页核对上报。
- 教训入档：真机 bundle id=com.tangyuxuan.holo-app（模拟器=com.holo.Holo，坑档已有）；initializeCloudKitSchema 是同步阻塞调用禁挂主线程；「先写标记后执行」会在被杀时残留假完成标记。
