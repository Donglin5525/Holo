# 小组件交互化方案 + 想法小组件「隐私模式」探查结论

日期：2026-09-09
状态：**已实施（东林三拍板后开工），未提交**。P0/P1/P2 代码全部落盘；小组件 target 编译全绿；P1 迁移已过双场景模拟器验证；App target 整体编译暂被一处**非本工作**的在途文件阻塞（详见文末「实施状态」）。
目标版本：1.0.3（1.0.2 提审中，不混入）
后端依赖：无（全部纯 iOS，不需要后端发版）

---

## 一、想法随机漫步小组件「隐私模式」探查结论

### 现象
「想法随机漫步」小组件永远处于隐私模式：不显示想法原文，只显示来源提示
（如「来自一次夜间记录」），大号尺寸底部固定一行「原文已收好 · 隐私不出 App」。

### 根因：这是一个「半成品开关」——开关本体存在，但没有装把手
- 代码里确实有一个隐私开关：`HoloWidgetPrivacySettings.showsThoughtExcerpt`
  （HoloWidgetSnapshotService.swift:487），它读取
  `UserDefaults` 的 `holoWidgetShowsThoughtExcerpt`。
- 这个键**全 App 没有任何地方写入**，也没有任何设置界面暴露它。
- `UserDefaults.bool` 对从未设置过的键返回 `false`，所以
  `showsOriginalExcerpt` 永远是 false → 小组件**永远**隐私模式。
- 结论：东林「找不到打开的地方」是正常的——这个入口从未被做出来。

### 修复方案（P0，小改，可先行）
1. 设置 → 隐私与安全（privacySecuritySection）新增一行开关：
   「桌面小组件显示想法原文」，默认**关**（维持现在的隐私默认值）。
2. 开关写入 `holoWidgetShowsThoughtExcerpt` 后：
   - 保留当前选中的那条想法，仅翻转 `showsOriginalExcerpt` 重写快照 JSON；
   - `WidgetCenter.reloadTimelines` 刷新想法随机漫步时间线，立即生效。
3. 小组件侧随开关切换文案：开关打开后，大号底部「原文已收好 · 隐私不出 App」
   改为不出现（当前是写死的，会和「显示原文」自相矛盾）。
4. 原文截断上限 72 字维持不变（`truncatedForWidget(maxLength: 72)`）。
5. 双语词表补齐（简中/繁中/英文）。

工作量：约半天（含 UI 测试与三语词表）。

---

## 二、小组件交互化（桌面直接点击操作）方案

### 现状
- 8 个小组件全部是「点击跳转」：Link → 深链进 App 对应页面。
- 全仓没有任何 AppIntent 使用，交互化是全新能力。
- 部署目标 iOS 17.0，交互小组件（Button/Toggle + AppIntent）全量可用，无版本包袱。

### 候选场景（按价值排序）
| 小组件 | 交互 | 位置 |
|---|---|---|
| 今日习惯 | 行内圆圈 → 打卡按钮（可再点取消） | 中号/大号的行尾 |
| 今日待办 | 行首圆圈 → 完成按钮 | 中号/大号的行首 |
| 其余 6 个 | 不加，维持跳转 | — |

小号尺寸空间太小，不塞按钮，整卡跳转维持现状。

### 关键前提（第一性原理）：数据在哪，操作就得在哪
- 小组件点击按钮后，执行动作的是**小组件自己的进程**，不是 App。
- 现状：数据库（CoreData）在 App 沙盒 Documents 目录，小组件进程**够不到**；
  App Group 共享区里只有展示用的 JSON 快照（只读副本）。
- 所以「点了就真的打卡」的前提是：**把数据库搬进 App Group 共享区**，
  让小组件能直接读写。

### 两条路线

**路线 A（根治）：数据库搬进 App Group**
- CoreDataStack.swift:72 的 store URL 从 Documents 改到 App Group 容器，
  用 CoreData 标准迁移（replacePersistentStore）完成一次性搬家。
- 小组件进程用普通 NSPersistentContainer 打开同一份库（不开 CloudKit 镜像，
  镜像仍由主 App 驱动；持久历史跟踪已开启，跨进程变更可被主 App 接力同步）。
- 风险与验证清单：
  1. 先做半天技术验证 spike：小组件进程加载完整数据模型并写入，确认内存与耗时达标；
  2. 三个迁移场景实测：老用户升级、卸载重装、iPad 双设备；
  3. CloudKit 同步回归（小组件写的打卡能同步上云）；
  4. 迁移前自动留底备份路径，失败可回退。
- 这是本方案**最大的决策点**：动的是所有数据的「家」。

**路线 B（降级）：不搬库**
- 小组件点行 → 跳进 App 对应页并高亮/滚动到该行（比现在多一步定位，但仍要进 App）。
- 零数据风险，但「不打开 App 就地完成」的产品价值就没了。

**否决项（说明为什么不走捷径）**
- 把打卡请求先记在共享 JSON、等下次开 App 再补写入数据库：
  打卡/连击语义会错天（例如 23:50 点了打卡、当天没再开 App，记录落到第二天），
  数据不可信，否决。

### 分期
- **P0**：想法小组件隐私开关（与交互化无依赖，可独立先行）。
- **P1**：数据搬家（路线 A）+ 半天 spike 验证。
- **P2**：交互落地——
  - HabitToggleIntent / TodoToggleIntent（AppIntent，识别行 ID，快照结构里 id 已具备）；
  - 复用语义：习惯 toggleCheckIn、任务 completeTask / completeRepeatingTask
    （重复任务点完成要按重复语义生成下一次，逻辑抽成 App 与小组件共享的文件，防两套规则漂移）；
  - 执行成功后重写对应模块快照 + 刷新时间线；系统自带按下确认动画，无自定义空间；
  - Plus 闸门沿用（未订阅仍是锁定态，不出现按钮）；
  - 锁屏小组件（accessory）本期不涉及——目前没配置过锁屏尺寸。

### 工作量估算
- P0：约 0.5 天
- P1：1–2 天（含 spike 与三场景迁移验证）
- P2：2–3 天（含共享逻辑抽取、UI 测试）
- 合计：约 4–6 天，全部纯 iOS

### 验收方式
- 模拟器：点击打卡 → 行内圆圈变实心、圆环进度/连击数即时更新、进 App 核对记录一致；
- 真机（东林）：桌面无网状态下打卡 → 稍后联网进 App 确认同步上云；
- iPad 双设备回归同步。

---

## 三、拍板点（东林 2026-09-09 已拍板）

1. **P0 隐私开关**：✅ 先行修复 —— 已实施
2. **路线 A 数据搬家**：✅ 做 —— 已实施并验证
3. **交互范围**：习惯+待办 —— 已实施
4. **开关默认值**：❌ 改为**默认显示原文**（用户显式关闭才隐藏）—— 已按此实施

---

## 四、实施状态（2026-09-09 收工时点，未提交）

### 已完成
- **P0**：设置→隐私与安全 新增「桌面小组件显示想法原文」开关（默认开，`object==nil` 判定首启默认）；
  切换即重写想法快照+刷新时间线；小组件大号底部「隐私不出 App」文案随开关显隐；示例快照同步更新。
- **P1**：`CoreDataStack` 新增共享库选址与一次性迁移（`sharedStoreURL`/`resolveStoreURLForMigration`/
  `migrateStore`）。共享区有库→直接用；旧址有库→独立协调器整体搬迁（旧文件原地保留作回退底稿）；
  搬迁失败留在旧址绝不落空库。**模拟器验证通过**：老版装数据(182分类)→新版升级迁移→数据完整、
  新库生效、二次启动走已迁移路径、App 无崩溃。
- **P2 架构（与原方案的差异，更收敛）**：
  - 待办侧外引级联过深（通知服务→深链→订阅栈），放弃整仓共享，改为**抽核心**：
    `Models/TodoCompletionCore.swift`（完成语义纯数据库部分 + 今日读口径，自 TodoRepository 原样搬移），
    TodoRepository 四个写方法与三个读方法改为薄壳委托（副作用顺序不变）。
  - 习惯侧级联浅（两个 84 行小文件），HabitRepository 整文件共享；新增
    `init(context:observesRemoteChanges:)` 防止扩展进程误触主 App 容器。
  - `SoftDeletable.swift` 拆出 `SoftDeletableCore.swift`（协议+默认实现+习惯/待办链 6 实体扩展），
    其余 ~25 个实体的软删扩展留在原文件（仅 App）；SpendingProject/MemoryInsight 两个扩展挪回各自类文件。
  - `Services/Widgets/HoloWidgetHabitTodoSnapshot.swift`：习惯/待办快照刷新自 HoloWidgetSnapshotService
    搬移（App 与小组件进程共用单一事实源），服务改薄壳委托。
  - `HoloWidgets/HoloWidgetIntents.swift`：HoloWidgetDataStore（扩展进程普通容器，不开 CloudKit 镜像）
    + HoloHabitToggleIntent / HoloTodoToggleIntent；习惯/待办组件行内圆圈改 Button（行其余区域仍是跳转 Link）。
  - pbxproj：HoloWidgets target 显式挂载 ~70 个共享文件（沿用 A100 四锚点范式，新 ID 段 A1C0/A1D0）。
- **编译**：HoloWidgets target 全绿。App target 我方文件全部编译通过。

### 待办（被外部因素阻塞）
- **App target 阻塞**：`Services/AI/Vision/HoloVisionExtractionService.swift` 有 6 个编译错误
  （rawData/rawImageData 不一致、可选链误用、缺 await、缺 import CoreData）。该文件非本工作触碰
  （mtime 00:55-01:56 与 IntentRouter 同窗），系并行在途改动的中间态，按「不混改他人文件」纪律未处理。
  该文件修复后即可全量编译，随后补：模拟器桌面小组件点击实测 + P0 设置项走查 + 新增文案三语词表回填。
- 真机验收项照旧（东林）。

### 给后续会话的 pbxproj 手术坑（本次实证）
- 含 `+` 的文件名在 PBXFileReference 的 name/path 必须加引号，漏引 = 整个工程 "damaged" 解析失败
- 批量挂载用自增 ID 段时务必核算区间不与先前批次重叠（本批曾 A1D0...031 撞号致文件幽灵缺席）
- 多 target 的 Sources phase 并存，按行号定位插入点前先确认 phase 归属
