# Holo 剧本文件规范（SCHEMA）

> 真源说明：字段以 App 代码为准——`Holo/Services/Diagnostics/HoloStorySchema.swift`（数据形状）与 `HoloStorySeeder.swift`（写入逻辑）。改任何一边都要同步改这份文档和另一边。
> 版本：2026-11-23 首版（第一批五个模块：记账 / 想法 / 待办 / 习惯 / 目标）。

## 0. 这是什么

给模拟器「喂」一份 JSON 剧本，App 启动时把剧本里的数据写进本地库，用于自媒体内容制作的截图和录屏。

- **只在 DEBUG 构建的模拟器上生效**，真机和正式包里这段代码根本不编译。
- 模拟器没有 iCloud 同步，数据天然隔离，不会碰任何真实数据。
- 金额一律写「整数分」，日期一律写「相对天数」，所以同一份剧本隔几个月再注入，画面上的「最近 7 天」「这个月」依然成立。

## 1. 三步上手

```bash
UDID=<模拟器 UDID>
APP="/tmp/holo_dd_wrap/Build/Products/Debug-iphonesimulator/Holo.app"   # holo_build.py build 的产物

xcrun simctl install "$UDID" "$APP"
DOC="$(xcrun simctl get_app_container "$UDID" com.holo.Holo data)/Documents"
mkdir -p "$DOC" && cp story.json "$DOC/story.json"
SIMCTL_CHILD_HOLO_STORY_FILE=story.json \
xcrun simctl launch "$UDID" com.holo.Holo -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
```

- 环境变量 `HOLO_STORY_FILE` 的值是 **Documents 目录下的文件名**（如 `story.json`），不能带路径。
- launch 命令末尾的语言参数建议带上（与宣传图通道同一套做法）：App 首次启动会按当前语言把预设分类和账户种进库（之后固化），带上它保证是简体；否则英文系统的模拟器会种成英文名，剧本里按中文名引用会找不到。
- 没设这个环境变量时启动，这个通道完全不工作，和现有截图开关（`HOLO_APP_STORE_SCREENSHOT_MODE`、`HOLO_ASO_V10`）互不影响。
- 想看注入日志：`xcrun simctl spawn "$UDID" log stream --predicate 'subsystem == "com.holo.app" AND category == "HoloStory"' --style compact`
  成功会打一行「剧本 xxx 注入完成：账户 n／分类 n／…」，失败会打「剧本注入失败」并带上是第几条的哪个字段出了问题。

## 2. 总则

### 2.1 日期

锚点是**启动当天的 0 点**（按模拟器的日历与时区）。同一台模拟器当天多次启动，换算结果一致。

| 写法 | 含义 | 例子 |
|---|---|---|
| `D-123` | 123 天前 | `D-30` |
| `D+5` | 5 天后 | `D+7` |
| `D0` | 今天 | `D0` |
| `D-3T12:30` | 3 天前的 12:30 | 时刻必须两位数字 `T08:05` |
| `2026-11-01` | 绝对日期 | 可带时刻 `2026-11-01T09:00` |

- **不带时刻 = 当天 12:00。** 想让「今天」的时间块出现在轴档上，请显式写时刻。
- 绝对日期必须是真实存在的日子（`2026-02-30` 会报错）。
- **未来时刻提醒**：如果一条数据的时间晚于「注入那一刻」，App 会把它当成还没发生——交易不进列表和统计。例如上午 10 点启动，`D0T19:00` 的晚餐就看不到。要稳稳显示，用 `D-1` 及更早，或时刻早于拍摄时间。

### 2.2 金额

一律整数「分」：`1280000` = ¥12,800.00。字段名都带 `Cents` 后缀。

### 2.3 用名字互相引用

剧本内部靠**名字**互相引用，不写任何 UUID：

| 引用方 | 字段 | 指向 |
|---|---|---|
| 交易 / 预算 / 目标 | `account` / `ledgerAccount` | `accounts[].name`，或库里已有的账户名 |
| 交易 | `category` | 二级分类名（预设分类直接写） |
| 交易 | `project` | `financeProjects[].name` |
| 退款 | `refundOf` | 被退那笔交易的 `id` |
| 习惯记录 / 目标 | `habit` / `sourceHabit` / `habits[]` | `habits[].name` |
| 目标 | `tasks[]` | `tasks[].title` |

引用规则：

- **accounts / categories / financeProjects / habits**：库里已经有同名（且未删）的，直接复用、不重建——所以预设的「微信」「午餐」不必再声明就能用。同名对象的类型必须和剧本写的一致，否则报错。
- **tasks 的 title 在剧本内必须唯一**（目标靠它找任务）。`transactions[].id`、`accounts[].name` 等在剧本内也不能重复声明。
- **一台模拟器只跑一个剧本。** 换剧本请卸载重装或换一台新模拟器，否则旧剧本的数据还留在库里。

### 2.4 幂等、失败与重试

- 按 `meta.storyId` 记「已注入」标记：同一剧本在这台模拟器上只注入一次，之后再带变量启动会直接跳过。
- 改了 storyId 再注入是**叠加**而不是替换（实测如此）：同名的账户 / 分类 / 项目 / 习惯会复用，交易、想法、任务、记录、目标是再写一套。
- **任何一条数据不合法 = 整份剧本都不写入**（先全部写进临时区，成功才一次落库），日志里会写明是哪个模块第几条的哪个字段。改好后下次启动自动重试，不用清任何东西。
- 这个通道不会让 App 崩溃：读不到文件、JSON 写错、引用找不到，都只是打日志然后跳过。

## 3. 顶层结构

```json
{
  "meta": { "storyId": "xiaoman-v1", "persona": "小满", "lockedClaims": { "daysRecorded": 365 } },
  "accounts": [], "categories": [], "budgets": [], "financeProjects": [],
  "transactions": [], "thoughts": [], "tasks": [],
  "habits": [], "habitRecords": [], "goals": [],
  "conversations": [], "insights": [], "memoryRecords": []
}
```

- 除 `meta` 外，所有顶层 key 都可省略（省略 = 空数组）。
- 出现文档里没写的字段会被忽略，不报错。

### meta

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `storyId` | string | 是 | 幂等键，非空即可。改剧本内容后想重新注入，换一个 storyId 或卸载重装 |
| `persona` | string | 否 | 剧本主角名，写入 App 的显示名（首页问候语「下午好，小满」）。**写入后新人引导页不再出现**；不填则引导照常 |
| `lockedClaims` | 任意 JSON | 否 | 内容侧的口径锁定表。App 只在日志里原样回显，**不做校验**；对账在生成器侧完成 |

## 4. 各模块字段

下表「必填」列中，✅ = 必填，— = 可选。

### 4.1 账户 `accounts`

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `name` | string | ✅ | | 账户名 |
| `type` | string | ✅ | | `cash` 现金 / `digital` 数字钱包 / `bank` 储蓄卡 / `card` 借记卡 / `creditCard` 信用卡 / `other` |
| `initialBalanceCents` | int | — | 0 | 期初余额（分）。可以是负数 |
| `icon` | string | — | 该类型的默认图标 | SF Symbol 名 |
| `color` | string | — | 该类型的默认颜色 | `#RRGGBB` |
| `notes` | string | — | | 备注 |
| `billingDay` | int | — | | 仅信用卡：账单日 1–31 |
| `dueDay` | int | — | | 仅信用卡：还款日 1–31 |
| `creditLimitCents` | int | — | | 仅信用卡：额度（分） |
| `dueReminderEnabled` | bool | — | false | 仅信用卡：还款提醒 |

**账户的创建时间不开放回填。** 原因：App 用「库里有没有创建时间早于首次初始化的账户」来判断是不是卸载重装回来的老用户，一旦成立会清理那些没被用到的预设账户。回填会让「微信 / 支付宝 / 储蓄卡 / 信用卡」被误清。账户列表也不显示创建时间，回填没有演示价值。

预设账户（新装模拟器自动就有，直接引用即可）：现金（**默认账户**）、微信、支付宝、储蓄卡、信用卡。

```json
{ "name": "旅行专款", "type": "bank", "initialBalanceCents": 3669800, "icon": "airplane", "color": "#0EA5E9", "notes": "年底存 5 万" }
```

### 4.2 分类 `categories`

只用来声明**预设里没有的**分类。预设分类（附录 A）直接在交易里写名字即可。

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `name` | string | ✅ | | 分类名 |
| `type` | string | ✅ | | `expense` 支出 / `income` 收入 |
| `parent` | string | — | | 一级分类名。**给了 = 建二级分类**；该一级不存在会连一级一起建。不给 = 自成一个一级分类 |
| `icon` | string | — | 一级 `questionmark.folder.fill`，二级 `circle.fill` | SF Symbol 名 |
| `color` | string | — | 二级跟随一级 | `#RRGGBB` |

```json
{ "name": "健身卡", "parent": "娱乐", "type": "expense", "icon": "creditcard.fill", "color": "#EC4899" }
```

### 4.3 预算 `budgets`

预算是**按账户**统计的：只有记在这个账户上的支出才算进它的已花金额。

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `account` | string | ✅ | | 账户名 |
| `amountCents` | int | ✅ | | 预算额度（分），必须大于 0 |
| `period` | string | ✅ | | `week` / `month` / `year` |
| `startDate` | 日期 | — | 启动当天所在自然周期的起点 | 周期从这天起算。默认值 = 本周一 / 本月 1 日 / 今年 1 月 1 日 |
| `category` | string | — | | 分类预算。写一级 = 该一级及其下全部二级；写二级 = 只算这一个。不给 = 该账户的总预算 |

同一账户、同一周期、同一范围只能有一份预算，重复会报错。

```json
[
  { "account": "微信", "amountCents": 300000, "period": "month" },
  { "account": "微信", "amountCents": 60000, "period": "month", "category": "餐饮" }
]
```

### 4.4 财务项目 `financeProjects`

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `name` | string | ✅ | | 项目名 |
| `icon` | string | — | `📁` | emoji 或 SF Symbol 名 |
| `color` | string | — | `#64748B` | |
| `note` | string | — | | |
| `startDate` / `endDate` | 日期 | — | | 起止（软约束，只用于展示与到期完结） |
| `budgetAmountCents` | int | — | | 预算上限（分）；不给 = 纯记录，不算进度 |
| `status` | string | — | `active` | `active` 进行中 / `completed` 已完结 / `archived` 已归档 |
| `createdAt` | 日期 | — | 注入当刻 | 项目列表按它从新到旧排 |

提醒：`status` 写 `active` 但 `endDate` 已过（早于今天）的项目，App 打开项目页时会自动转成「已完结」，不必手动写 `completed`。

```json
{ "name": "日本旅行", "icon": "✈️", "color": "#F97316", "startDate": "D-210", "endDate": "D-205", "budgetAmountCents": 1200000, "status": "completed", "note": "大阪 + 京都 6 天" }
```

### 4.5 交易 `transactions`

一笔交易一条，分三种形态：**普通**、**分期**、**退款**。

| 字段 | 类型 | 普通交易 | 分期 | 退款 | 说明 |
|---|---|---|---|---|---|
| `id` | string | — | — | — | 剧本内引用名（给退款指路用），剧本内不能重复。不是落库的 ID |
| `type` | string | ✅ | ✅ | 不能写 | `expense` 支出 / `income` 收入 |
| `category` | string | ✅ | ✅ | 不能写 | 二级分类：`"午餐"` 或 `"餐饮/午餐"` |
| `account` | string | — | — | — | 账户名；不给 = 默认账户（退款：不给 = 退回原账户） |
| `amountCents` | int | ✅ | ✅ | ✅ | 普通 / 退款：本笔金额；分期：**总额** |
| `date` | 日期 | ✅ | 不读 | ✅ | 发生时间 |
| `note` | string | — | — | 不能写 | 备注。空字符串 = 没写备注 |
| `remark` | string | — | — | — | 附注 |
| `tags` | string[] | — | — | 不能写 | 标签 |
| `project` | string | — | — | 不能写 | 挂靠的财务项目名 |
| `installment` | object | — | ✅ | 不能写 | 分期定义，见下 |
| `refundOf` | string | — | — | ✅ | 被退那笔交易的 `id` |

**分类引用**：交易只能挂二级分类。预设分类里有 4 个名字在多个一级下重复——`洗衣`、`话费`、`礼物`、`其他`——引用它们必须写全「一级/二级」（如 `"居住/话费"`），只写名字会报错并列出候选。另外「其他」一级下预设里有两行同名的 `捐赠`，这个分类无法引用，请换别的名字。

**分期** `installment`：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `periods` | int | ✅ | 期数，≥ 2 |
| `startDate` | 日期 | ✅ | 第一期的发生时间；之后每期顺延一个月 |
| `feePerPeriodCents` | int | — | 每期手续费（分），默认 0 |

每期金额 = 总额 ÷ 期数（最后一期吸收除不尽的尾差）+ 每期手续费。全部期次一次建齐，**包括还没到期的未来期**（App 列表和统计只显示已发生的期次，与用户手动办分期的结果一致）。分期组不能被退。

**退款**：分类、备注、项目挂靠全部继承原交易，类型自动是收入；统计上冲减原分类的支出。被退的必须是**普通支出**（不能是分期，也不能是退款），多笔部分退款的累计不能超过原金额。

```json
[
  { "id": "salary", "type": "income", "category": "工资", "account": "储蓄卡", "amountCents": 1280000, "date": "D-13T10:05", "note": "11 月工资" },
  { "type": "expense", "category": "午餐", "account": "微信", "amountCents": 3200, "date": "D-3T12:15", "note": "老娘舅" },
  { "type": "expense", "category": "交通/地铁", "account": "支付宝", "amountCents": 400, "date": "D-1T08:20" },
  { "id": "usj", "type": "expense", "category": "门票", "account": "旅行专款", "amountCents": 69800, "date": "D-208T09:30", "note": "环球影城", "project": "日本旅行" },
  { "id": "keyboard", "type": "expense", "category": "数码", "account": "储蓄卡", "amountCents": 79900, "date": "D-150T21:10", "note": "键盘" },
  { "id": "gym", "type": "expense", "category": "健身卡", "account": "储蓄卡", "amountCents": 691200, "note": "健身卡两年卡", "installment": { "periods": 24, "startDate": "D-195" } },
  { "id": "keyboard-refund", "refundOf": "keyboard", "amountCents": 79900, "account": "支付宝", "date": "D-140T15:20", "remark": "七月退货" }
]
```

### 4.6 想法 `thoughts`

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `content` | string | ✅ | | 正文 |
| `createdAt` | 日期 | — | 注入当刻 | 想法列表按它排序，日历页按它归日 |
| `mood` | string | — | 无 | `happy` 开心 / `sad` 难过 / `angry` 愤怒 / `calm` 平静 / `thinking` 思考 / `inspired` 灵感 |
| `tags` | string[] | — | 无 | 标签；用 `/` 表示层级，如 `"工作/吐槽"` |
| `organizedStatus` | string | — | `organized` | 整理状态：`organized` 已整理 / `unprocessed` / `pending` / `processing` / `failed` / `disabled` / `skipped` / `excluded` |

`organizedStatus` 保持默认最稳：写成 `pending` / `unprocessed` 的想法会在启动后被送去 AI 整理（需要授权并联网，结果不可控）。

想法列表在全新库上会自动预置一条「欢迎笔记」；剧本里只要有至少一条想法，这条预置就不会出现。

```json
[
  { "content": "键盘还是退了吧 键程不喜欢", "createdAt": "D-141T10:12", "mood": "thinking", "tags": ["购物"] },
  { "content": "今晚早睡（并没有）", "createdAt": "D-5T23:40", "mood": "calm", "tags": ["生活"] },
  { "content": "会上那个方案不太行 算了不说", "createdAt": "D-1T15:30", "mood": "angry", "tags": ["工作/吐槽"] },
  { "content": "感觉自己最近有点空", "createdAt": "D-2T22:05", "mood": "sad" }
]
```

### 4.7 待办 `tasks`

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `title` | string | ✅ | | 剧本内必须唯一 |
| `note` | string | — | | 备注 |
| `status` | string | — | `todo` | `todo` 待办 / `inProgress` 进行中 / `completed` 已完成 |
| `completedAt` | 日期 | — | 注入当刻 | 仅 `completed` 可写；完成时刻 |
| `createdAt` | 日期 | — | 注入当刻 | 列表按它排序 |
| `dueDate` | 日期 | — | 无 | 截止时间 |
| `isAllDay` | bool | — | false | 全天任务（截止时间按当天 23:59:59 算） |
| `plannedStart` / `plannedEnd` | 日期 | — | 无 | 时间块（轴档上的条）。**必须成对**，同一天内，开始早于结束 |
| `priority` | string | — | `medium` | `urgent` / `high` / `medium` / `low`（旧的优先级列） |
| `importance` | string | — | `unknown` | 重要性：`p1` 重要 / `p2` 一般 / `p3` 不重要 / `unknown` 暂未判断 |
| `urgencyMode` | string | — | `auto` | 紧急性：`auto` 按截止日期自动折算 / 手动锁定 `p1` `p2` `p3` / `unknown` 暂未判断 |
| `archived` | bool | — | false | 已归档 |

让任务属于某个目标：不在任务上写，而是在 `goals[].tasks` 里列出任务标题。

四象限由 `importance` × `urgencyMode` 实时决定，任一为 `unknown` 就进「待确认」区。想让任务落在「重要且紧急」，写 `"importance": "p1", "urgencyMode": "auto"` 并把 `dueDate` 设为已经过去或临近的时间。

```json
[
  { "title": "办签证", "dueDate": "D-215T00:00", "isAllDay": true, "status": "completed", "completedAt": "D-218T15:10", "createdAt": "D-225T09:30" },
  { "title": "取快递", "dueDate": "D-4T18:00", "status": "completed", "completedAt": "D-4T17:40", "createdAt": "D-5T09:00", "importance": "p3" },
  { "title": "整理用户访谈问题", "dueDate": "D-1T18:00", "importance": "p1", "urgencyMode": "auto", "createdAt": "D-6T10:00", "note": "周五前发给运营" },
  { "title": "完成作品集案例 01", "dueDate": "D+2T18:00", "priority": "high", "importance": "p1", "urgencyMode": "auto", "createdAt": "D-3T11:00", "plannedStart": "D0T16:00", "plannedEnd": "D0T17:30", "note": "先搭结构" }
]
```

### 4.8 习惯 `habits`

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `name` | string | ✅ | | 习惯名，剧本内唯一 |
| `type` | string | ✅ | | `checkIn` 打卡型 / `numeric` 数值型 |
| `icon` | string | — | `checkmark.circle` | SF Symbol 名 |
| `color` | string | — | `#5B8CFF` | |
| `frequency` | string | — | `daily` | `daily` / `weekly` / `monthly` |
| `targetCount` | int | — | 无 | **仅打卡型**：一个周期内目标次数 |
| `targetValue` | number | — | 无 | **仅数值型**：目标值（配合 `unit`） |
| `unit` | string | — | 无 | **仅数值型**：单位，如 `"公里"`、`"分钟"` |
| `aggregation` | string | — | `sum` | **仅数值型**：`sum` 计数类（按周期累加，如跑步公里）/ `latest` 测量类（取最新值，如体重） |
| `description` | string | — | 无 | 一句话描述（最多 16 字，超出截断） |
| `isBadHabit` | bool | — | false | 是否坏习惯 |
| `createdAt` | 日期 | — | 注入当刻 | **有历史记录的习惯必须回填到第一条记录之前**：统计只认「创建之后」的记录 |
| `archived` | bool | — | false | 已归档（「尝试后放弃」用这个，记录会保留） |
| `paused` | bool | — | false | 暂停中 |

打卡型不写 `targetValue` / `unit` / `aggregation`；数值型不写 `targetCount`。写串了会报错。

```json
[
  { "name": "跑步", "type": "numeric", "icon": "figure.run", "color": "#EA794C", "unit": "公里", "targetValue": 5, "createdAt": "D-330" },
  { "name": "阅读", "type": "numeric", "icon": "book.fill", "color": "#FF6B35", "unit": "分钟", "targetValue": 30, "createdAt": "D-330" },
  { "name": "早起", "type": "checkIn", "icon": "sun.max.fill", "color": "#F59E0B", "targetCount": 1, "frequency": "weekly", "createdAt": "D-270", "archived": true }
]
```

### 4.9 习惯记录 `habitRecords`

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `habit` | string | ✅ | 习惯名（须在 `habits` 里声明过） |
| `date` | 日期 | ✅ | 记录时间 |
| `value` | number | 数值型必填，打卡型不能写 | 数值型的记录值 |
| `completed` | bool | — | 仅打卡型：是否完成，默认 `true` |
| `note` | string | — | 备注 |

同一天可以有多条记录。

```json
[
  { "habit": "跑步", "date": "D-60T07:30", "value": 8.4 },
  { "habit": "跑步", "date": "D-36T07:30", "value": 21.1, "note": "杭州半马 2:41:33" },
  { "habit": "阅读", "date": "D-6T22:10", "value": 35 },
  { "habit": "早起", "date": "D-200T06:50" },
  { "habit": "早起", "date": "D-198T07:40", "completed": false }
]
```

### 4.10 目标 `goals`

目标走的是**用户在表单里手动新建目标**的同一条保存链路，所以数据形状和真人建出来的目标一致（目标本体 + 计划首版 + 习惯绑定）。

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `title` | string | ✅ | | 目标标题 |
| `domain` | string | — | `other` | `learning` 学习 / `health` 健康 / `career` 职业 / `finance` 财务 / `life` 生活 / `project` 项目 / `other` 其他 |
| `iconEmoji` | string | — | 领域默认 emoji | 列表大图标 |
| `summary` | string | — | | 一句话概括 |
| `desiredOutcome` | string | — | | 想要的结果（成功标准） |
| `motivation` | string | — | | 动机 |
| `deadline` | 日期 | — | 无 | 期限。到期判定按「是否早于现在」，所以期限写今天 `D0` 会在当天就显示已到期 |
| `createdAt` | 日期 | — | 注入当刻 | 立目标的日期。详情页「坚持了 N 天」按它算 |
| `status` | string | — | `active` | `active` 进行中 / `paused` 已暂停 / `completed` 已完成 |
| `completedAt` | 日期 | — | 注入当刻 | 仅 `completed` 可写；完成时刻 |
| `allowAIContext` | bool | — | false | 是否允许 AI 把这个目标用作对话背景 |
| `goalKind` | string | — | `process` | `process` 过程型 / `cumulative` 累积型（从 0 攒到目标）/ `target` 达标型（当前水平到达某个值） |
| `metricSource` | string | 量化目标必填 | `manual` | 数字从哪来：`manual` 手动记录 / `habit` 数值习惯 / `ledger` 账本 |
| `metricUnit` | string | — | 无 | 单位，如 `"公里"`、`"本"`、`"元"` |
| `targetValue` | number | 量化目标必填 | | 目标值 |
| `baselineValue` | number | — | 无 | **仅达标型**：起点水平（如当时体重 75） |
| `startDate` | 日期 | — | `createdAt` | **仅累积型**：从哪天起算。没给 `createdAt` 时默认注入当刻 |
| `comparison` | string | — | 不写 | 比较方向：`reach` 达到（≥）/ `stayBelow` 不超过 / `trendDown` 向下 / `trendUp` 向上。**只有显式写了才会进计划**，并影响进度算法（见 5.2） |
| `sourceHabit` | string | habit 源必填 | | 数据来源习惯名，必须是数值型习惯 |
| `ledgerScope` | string | — | `whole_ledger_delta` | ledger 源的口径：`whole_ledger_delta` 全账本净结余增加 / `account_balance` 单账户余额 / `account_delta` 单账户净结余增加 |
| `ledgerAccount` | string | 单账户口径必填 | | 上面两种单账户口径要指定的账户名 |
| `habits` | string[] | — | 无 | 挂到目标下的习惯名（行动绑定）。只建绑定、不改习惯自己的归属，删目标不会连带删习惯 |
| `tasks` | string[] | — | 无 | 挂到目标下的任务标题。一个任务只能属于一个目标 |
| `metricLogs` | object[] | — | 无 | 手动记录的进度，**只有 `manual` 源可写**。每项 `{ "date": 日期(必填), "value": number(必填), "note": string }` |

约束：

- 过程型目标（不给 `goalKind`）不能带任何量化字段和 `metricLogs`。
- 量化目标必须给 `targetValue`；`baselineValue` 只属于达标型；`startDate` 只属于累积型。
- `manual` 源不能带 `sourceHabit` / `ledgerScope` / `ledgerAccount`；`habit` 源必须给数值型 `sourceHabit`；单账户口径必须给 `ledgerAccount`。
- 模拟器读不到「苹果健康」，所以不支持 `healthKit` 数据源。

```json
[
  {
    "title": "跑完一场半马", "domain": "health", "iconEmoji": "🏃",
    "desiredOutcome": "完赛一场半程马拉松", "createdAt": "D-330", "deadline": "D+30",
    "status": "completed", "completedAt": "D-36T11:15",
    "goalKind": "target", "metricSource": "habit", "sourceHabit": "跑步", "metricUnit": "公里", "targetValue": 21.1, "baselineValue": 3
  },
  {
    "title": "年底存下 5 万", "domain": "finance", "iconEmoji": "💰",
    "desiredOutcome": "旅行专款账户余额到 5 万", "createdAt": "D-330", "deadline": "2026-12-31",
    "goalKind": "cumulative", "metricSource": "ledger", "ledgerScope": "account_balance", "ledgerAccount": "旅行专款", "metricUnit": "元", "targetValue": 50000
  },
  {
    "title": "读完 24 本书", "domain": "learning", "iconEmoji": "📚",
    "desiredOutcome": "今年读完 24 本书", "createdAt": "D-330",
    "goalKind": "cumulative", "metricSource": "manual", "metricUnit": "本", "targetValue": 24,
    "habits": ["阅读"], "tasks": ["买转换插头"],
    "metricLogs": [ { "date": "D-320", "value": 1, "note": "《置身事内》" }, { "date": "D-290", "value": 1 } ]
  }
]
```

## 5. 目标进度怎么算（写剧本前必读）

进度不是存在目标上的数字，而是 App 每次展示时按「类型 × 数据来源」实时算出来的。剧本要显示某个进度，就得让对应的数据源算出那个数。

### 5.1 当前值口径

| `goalKind` | `metricSource` | 当前值 = |
|---|---|---|
| 累积型 `cumulative` | `manual` | `startDate` 之后全部手动记录的 `value` 之和（默认从 `createdAt` 起算，可以跨全年） |
| 累积型 | `habit` | **只看最近 14 天**：该习惯这 14 天内记录值之和。例外：显式写了 `comparison`，则改为 `startDate` 之后全部记录之和 |
| 累积型 | `ledger` + `whole_ledger_delta` | 全账本从 `startDate` 到现在的净结余变化 |
| 累积型 | `ledger` + `account_delta` | 指定账户：当前余额 − `startDate` 当时的余额 |
| 累积型 | `ledger` + `account_balance` | 指定账户的当前余额 = 期初余额 + 已发生的流水 |
| 达标型 `target` | `manual` | **最新一条**手动记录的 `value` |
| 达标型 | `habit` | 该习惯**最新一条**记录的 `value` |

### 5.2 进度百分比

- `reach`（不写 `comparison` 时的默认）：当前值 ÷ 目标值，封顶 100%。
- `trendDown` / `trendUp`：(基线 − 当前值) ÷ (基线 − 目标值)，必须有 `baselineValue`。
- `stayBelow`：不算进度百分比，只判是否超过。

### 5.3 对着口径写剧本

| 想要的画面 | 怎么写 |
|---|---|
| 存款目标 72%（¥36,000 / ¥50,000） | 累积型 + `ledger` + `account_balance`，把账户期初余额和流水凑到 ¥36,000 |
| 读书 19 / 24 本 | 累积型 + `manual`，`metricLogs` 写 19 条 `value: 1`。**不要**用阅读分钟习惯当数据源——它累加的是分钟 |
| 半马完赛（最近一次跑 21.1 公里） | 达标型 + `habit`，`sourceHabit` 指向跑步习惯，并让 21.1 那条是最新一条跑步记录 |
| 减重 75 → 70 kg | 达标型 + `comparison: "trendDown"`，`baselineValue: 75`，`targetValue: 70` |

- 账户余额只算**已发生**的流水（时间早于现在）。想让某笔支出计入余额，它的 `date` 必须早于注入那一刻。
- 达标型取「最新一条」：比赛日之后如果还有更短的跑步记录，当前值就变成那次距离。

## 6. 预留模块（第二批，本轮不写数据）

顶层 `conversations`（对话）、`insights`（洞察）、`memoryRecords`（记忆记录）三个 key 现在就会被接受，但要给空数组 `[]`。里面放了内容也不会报错，只在日志里提示「属于第二批模块，本次未写入」。

## 附录 A：预设分类（简体中文环境）

新装模拟器首次启动时按系统语言种入预设分类和账户。**模拟器语言请用简体中文**，否则预设名字是英文或繁体，剧本里按简体名字引用会找不到。也可以在 `categories` 里把要用的分类自己声明一遍来规避。

支出一级 9 个，收入一级 4 个。括号内是该一级下的二级分类（交易能挂的是二级）。

**支出**

- 餐饮：早餐 / 午餐 / 晚餐 / 夜宵 / 零食 / 咖啡 / 外卖 / 饮品 / 水果 / 酒水 / 超市 / 火锅 / 烧烤 / 甜品 / 啤酒 / 茶饮
- 交通：地铁 / 打车 / 公交 / 单车 / 加油 / 充电 / 停车 / 洗车 / 车辆保养 / 火车 / 机票 / 旅行 / 过路费 / 违章罚款 / 船票 / 渡轮 / 电动车 / 租车
- 购物：服饰 / 数码 / 日用 / 美妆 / 家具 / 书籍 / 运动 / 礼物 / 鞋包 / 珠宝 / 玩具 / 宠物用品 / 植物花卉 / 买菜
- 娱乐：电影 / 游戏 / 视频 / 音乐 / KTV / 旅游 / 住宿 / 门票 / 健身 / 体育赛事 / 演唱会 / 展览 / SPA美容 / 密室/剧本 / 户外运动
- 居住：房租 / 房贷 / 水费 / 电费 / 燃气 / 物业 / 网费 / 家电 / 装修 / 家政保洁 / 搬家 / 话费 / 安防 / 洗衣 / 家具租赁
- 医疗：就医 / 药品 / 体检 / 健身房 / 保健品 / 牙齿保健 / 医疗用品 / 住院 / 眼镜 / 心理咨询 / 康复理疗 / 疫苗
- 学习：课程 / 教材 / 考试 / 文具 / 订阅 / AI工具 / 软件服务 / 云存储 / 语言学习 / 乐器学习 / 艺术培训 / 体育培训 / 证书考证
- 人情：红包礼金 / 请客 / 送礼 / 探望 / 育儿 / 赡养 / 其他
- 其他：社交 / 宠物 / 理发 / 洗衣 / 话费 / 烟酒 / 维修 / 保险 / 手续费 / 税费 / 罚款 / 还款 / 转账 / 快递 / 捐赠 / 其他 / 其他支出 / 快递费 / 慈善

**收入**

- 投资理财：利息 / 股票 / 基金 / 房租收入 / 其他投资 / 理财 / 投资收益 / 理财收益 / 数字货币 / 分红
- 工资收入：工资 / 奖金 / 兼职 / 项目款 / 咨询费 / 报销 / 退款 / 稿费版税 / 佣金
- 人情来往：红包 / 礼物 / 中奖 / 转入 / 众筹 / 赞助
- 其他收入：借入 / 还款收入 / 退货 / 公积金 / 出闲置 / 稿费 / 补贴 / 个税退税 / 保险理赔 / 押金退还 / 奖励 / 婚礼 / 其他收入 / 其他

预设里有个名字自带斜杠的二级分类「密室/剧本」：引用时把整串写全即可（`"密室/剧本"`），App 会先按完整名字对一遍，再按「一级/二级」拆。

## 附录 B：枚举取值速查

| 用在哪 | 字段 | 可选值 |
|---|---|---|
| 账户 | `type` | `cash` `digital` `bank` `card` `creditCard` `other` |
| 分类 / 交易 | `type` | `expense` `income` |
| 预算 | `period` | `week` `month` `year` |
| 财务项目 | `status` | `active` `completed` `archived` |
| 想法 | `mood` | `happy` `sad` `angry` `calm` `thinking` `inspired` |
| 想法 | `organizedStatus` | `organized` `unprocessed` `pending` `processing` `failed` `disabled` `skipped` `excluded` |
| 待办 | `status` | `todo` `inProgress` `completed` |
| 待办 | `priority` | `urgent` `high` `medium` `low` |
| 待办 | `importance` | `p1` `p2` `p3` `unknown` |
| 待办 | `urgencyMode` | `auto` `p1` `p2` `p3` `unknown` |
| 习惯 | `type` | `checkIn` `numeric` |
| 习惯 | `frequency` | `daily` `weekly` `monthly` |
| 习惯 | `aggregation` | `sum` `latest` |
| 目标 | `domain` | `learning` `health` `career` `finance` `life` `project` `other` |
| 目标 | `status` | `active` `paused` `completed` |
| 目标 | `goalKind` | `process` `cumulative` `target` |
| 目标 | `metricSource` | `manual` `habit` `ledger` |
| 目标 | `comparison` | `reach` `stayBelow` `trendDown` `trendUp` |
| 目标 | `ledgerScope` | `whole_ledger_delta` `account_balance` `account_delta` |

## 附录 C：这个通道不管的事

以下是「展示状态」，不属于数据注入，需要时另行处理或由主会话决定：

- **新人引导与首访导览**：只有填了 `persona` 才会跳过新人引导；首页三步导览、记忆长廊欢迎条不受这个通道影响。
- **AI 数据处理授权**：不授权。涉及 AI 对话的界面需要另行处理（对话内容属于第二批）。
- **Plus 会员权益展示**：不处理。
- **本地通知**（预算超支、账单到期、目标风险等）：注入发生在启动链的提醒排程之后，这些提醒不会因为剧本数据而重新排；全新模拟器也没有通知权限。
