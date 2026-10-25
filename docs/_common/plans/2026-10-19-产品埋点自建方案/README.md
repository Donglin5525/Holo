# 产品埋点自建方案（2026-10-19）

## 背景与决策

东林发起，三拍板（2026-10-19 对话）：

1. **方案 = 自建**，不引入神策 sa-sdk-ios。理由：该 SDK 只是采集端，必须配套收费的神策分析平台（按事件量年付、商务报价）；Holo 外部用户约 10 人，SQL 即可回答现有问题；Holo 是隐私敏感的全生活记录 App，第三方 SDK 带来隐私政策披露/App 备案 SDK 申报/信任成本。
2. **埋点字典由我方拟定**，本文档即 v1 字典。
3. **合规口径 = 从简 + 披露**：不单独弹征求同意弹窗，隐私政策增补「匿名使用数据」条款 + App Store 隐私标签申报（收集的是纯匿名使用数据，无个人身份、无内容正文）。

技术路线：完全复刻现有 `agent_telemetry_events` 成熟管线（客户端批量上报 → 服务端白名单校验 → INSERT OR IGNORE 幂等入库），只是事件域从「Agent 技术诊断」换成「产品使用行为」。

## 埋点字典 v1

### 公共信封（每条事件都带）

| 字段 | 来源 | 说明 |
|---|---|---|
| `id` | 客户端 UUID | 幂等去重键，失败重试不重复计数 |
| `name` | 字典枚举 | 事件名，后端白名单校验 |
| `timestampMs` | 客户端时钟 | 行为发生时刻 |
| `appVersion` | Bundle | 如 `1.1.3` |
| `buildChannel` | `#if DEBUG` | `debug` / `release`——东林日用机是开发构建，查询时用此字段过滤 |
| `device_id` | `X-Holo-Device-Id` 请求头 | 复用 Keychain/iCloud 设备身份（与付费权益同一身份体系） |

**隐私红线**：不收任何用户内容（金额、标题、备注、习惯名一律不进事件），只收「发生了什么动作」及其枚举参数。

### 事件清单（8 个）

| 事件名 | 触发时机 | 参数 | 回答的问题 |
|---|---|---|---|
| `app_first_launch` | 首次启动（UserDefaults once 标记） | 无 | 新增/激活 |
| `app_session_start` | 冷启动 / 回前台 | `trigger`: `cold`/`foreground` | 留存、DAU |
| `module_view` | 常驻模块打开（activeScreen 变非空） | `module`: `ai`/`finance`/`habits`/`tasks`/`memoryGallery`/`health`/`thoughts` | 哪些模块被用 |
| `bill_created` | 记账一笔落库成功 | `source`: `manual`/`ai`（AI=聊天/识图记账） | 记账量、AI 记账占比 |
| `habit_checkin` | 打卡成功（撤销不打）；数值型记一笔同 | `kind`: `check`/`numeric` | 习惯活跃度（本地操作，request_logs 看不到） |
| `task_created` | 任务创建成功 | `source`: `manual`/`thought` | 任务模块活跃度 |
| `paywall_viewed` | 付费墙曝光 | `context`: 触发场景（`membershipCenter`/`taskSplit`/…） | 付费墙漏斗上段 |
| `paywall_purchase_tapped` | 点击购买按钮 | `context` 同上 + `plan`: 商品 id | 付费转化意愿 |

**v1 刻意不收**：AI 功能用量（`ai_call_logs` 服务端已全覆盖且更准）、批量导入（低频）、小组件交互（后续版本）、洞察页深读（`module_view` 已覆盖入口）。

## 埋点字典 v2（2026-10-25，东林拍板「埋点有点少，新增一批随版本发出」）

新增 9 个事件，白名单 8 → 17。**先发后端白名单再发 iOS**（新事件名被旧白名单拒收时客户端 4xx 整批丢弃，不积压）。

| 事件名 | 触发时机 | 参数 | 回答的问题 |
|---|---|---|---|
| `ai_conversation_started` | 一次分析会话内首条发出的 AI 消息（会话=每次前台激活；进程重启重记） | 无 | AI 渗透率（÷ `app_session_start`） |
| `ai_message_sent` | 每条真正发出的用户消息（本地拦截分支不计） | `kind`: `text`/`image`/`report_followup` | AI 使用强度 |
| `ai_deep_report_requested` | **显式**选择分析场景后发送（消耗深度洞察额度） | `scenario`: `crossDomain`/`finance`/`habit`/`health`/`task`/`thought`/`goal` | 旗舰功能请求量；注意：意图识别隐式触发的深度分析不在此事件，看服务端 `ai_call_logs` |
| `ai_deep_report_viewed` | 打开深度洞察报告详情页 | 无 | 生成 ≠ 查看，报告打开率 |
| `thought_created` | 想法首次落库（编辑器；AI 对话建笔记/记心情） | `source`: `editor`/`ai`；种子与导入不计 | 四大记录补齐 |
| `habit_created` | 新建习惯落库（手动添加 + 目标计划生成，经通知总线） | `type`: `checkIn`/`numeric` | 习惯模块创建转化 |
| `account_created` | 新建账户落库（唯一调用方=添加账户页） | `type`: `cash`/`digital`/`bank`/`card`/`creditCard`/`other` | 财务配置深度 |
| `receipt_booking_started` | 发起识图记账：快捷指令/分享/锁屏相机在 `book()`，聊天图片在 `prepareVisionExtraction` | `entry`: `chat`/`shortcutScreenshot`/`shortcutCamera`/`shareSheet`/`lockedCamera` | 识图记账漏斗上游（成功侧= `bill_created source=ai`） |
| `export_performed` | 导出文件生成成功（财务 CSV/JSON） | `format`: `csv`/`json` | 数据安全行为触达 |

**v2 砍掉的**：`ai_quick_action_tapped`（快捷指令 UI 已退役，`sendQuickAction` 是无调用方死代码）；购买成功（维持一期设计，由服务端订阅状态佐证）。

**v2 实施顺带根治的回归**（2026-10-25 冒烟实锤）：`sendMessage` 先清 `inputText` 再消费场景意图，而 4764ad2849（09-23）给 `inputText` 加了「清空即解除场景绑定」didSet——显式场景发送自 09-23 起全部退回常规意图识别。修法=场景意图在 `inputText = ""` 之前捕获。

## 技术设计

### 后端（HoloBackend）

- 新迁移 #22：`product_events` 表（id PK / device_id / name / timestamp_ms / params JSON 文本 / app_version / build_channel / received_at_ms）+ `(name, timestamp_ms)` 与 `(device_id, received_at_ms)` 索引。**180 天滚动保留**（产品数据比技术诊断数据有更长的回看价值），写入时顺手清理过期行。
- 新 `src/product/productEventStore.js`：`insertBatch(deviceId, events)` 事务写入 + 过期清理，照 `agentTelemetryStore.js` 范式。
- 新路由 `POST /v1/product/events`：`getDeviceId` 鉴权 → 限流（默认 10/分钟、500/天，env 可调）→ `normalizeProductEvent` 白名单校验（事件名 ∈ 8 个枚举、params ≤16 键值 ≤128 字符）→ 落库。返回 `{ok, accepted}`。
- **总开关**：`HOLO_PRODUCT_ANALYTICS_ENABLED=false`（env，默认开）时路由返回 `{ok:true, accepted:0, disabled:true}`——客户端收到 2xx 即清队列，**不发版即可全量关停收集**（与 `HOLO_MODERATION_ENABLED` 同款运维模式）。
- 客户端把 4xx 当「永久失败」丢弃批次（防止未来新版本新事件名被旧后端白名单拒收导致毒丸批次无限重试）；429/5xx/网络错误保留重试。

### iOS（Holo APP）

- 新 `Services/Analytics/HoloProductAnalytics.swift`：
  - `track(_:_:)` 静态入口，fire-and-forget，绝不影响调用方主流程；
  - 本地待上报队列 = Application Support 下 JSON 文件，上限 1000 条（超限丢最旧），启动加载、追加即落盘；
  - 上报时机与 Agent 遥测一致：冷启动、回前台、进后台，每批 ≤100 条最旧优先；
  - `TestHostEnvironment.isHostedByXCTest` 与截图播种模式下整体不启动（不产生假数据）。
- 接入点（全部选在**单一汇聚层**而非多个按钮）：
  - 会话：`HoloApp` 冷启动 `.task` + `scenePhase`；
  - 模块曝光：`HomeView.onChange(of: activeScreen)`（常驻栈是所有模块进出的唯一闸口，iPhone/iPad 通吃）；
  - 记账：`FinanceRepository.addTransaction`（所有记账入口——键盘/聊天/识图——的汇聚点，`aiSourceMessageId` 天然区分 AI 来源）；
  - 习惯打卡：`HabitRepository.toggleCheckIn`（仅成功打卡）+ `addNumericRecord`（incrementCount 复用之）；
  - 任务创建：`TodoRepository.createTask`（`sourceThought` 区分想法转任务）；
  - 付费墙：`HoloPlusPaywallView` onAppear + 购买按钮（context = `HoloPlusGateContext`）。

### 版本演进规约

新增事件 = **先发后端白名单，再发 iOS**（旧后端会拒收未知名，但客户端 4xx 丢批次策略保证不堵塞后续事件上报）。

## 前后端链路对齐（2026-10-19 二期：东林拍板「前后端要对得上、用户 ID 一致、完整用户链路」）

**用户标识一致性（核证结论）**：埋点上报与全部 HoloAI 请求走同一个 `HoloBackendDeviceIdentity.shared.deviceId`（Keychain/iCloud 持久的设备身份），同一个 `X-Holo-Device-Id` 头——`product_events` / `ai_call_logs` / `request_logs` 三表的 `device_id` 天然同源可 join。该身份跨设备经 iCloud 账号延续（换机找回同一 deviceId），实质为账号级用户 ID。

**会话关联键（本期新增）**：三张表原本没有显式会话键，靠时间戳猜对齐（且时间口径不一：两张服务端 UTC 文本、一张客户端毫秒）。现引入 **session_id 贯穿**：

- 客户端每次前台激活（cold/foreground session_start）生成会话 UUID；
- 埋点事件信封带 `sessionId`；所有后端请求经 `APIRequest.toURLRequest()` 统一附加 `x-holo-session-id` 头（网络层单一出口，一处生效全局）；
- 后端迁移 #23：三表各加 `session_id` 列 + 索引；`requestLogger` 中间件与 4 处 `startAiCall` 调用点记录该列；
- **语义红利**：后台任务唤醒的进程（锁屏续跑/BGTask）没有前台会话 → 不带头 → `session_id` 为空，恰好区分「用户前台操作发起」与「后台自动行为」。

**完整用户链路查询 SQL**（ECS sqlite3）：

```sql
-- 某设备最近一次会话的完整时间线：前端动作 + AI 调用 + 网络请求合并排序
WITH latest AS (
  SELECT session_id FROM product_events
  WHERE device_id = '<device_id>' AND session_id IS NOT NULL
  ORDER BY timestamp_ms DESC LIMIT 1
)
SELECT '前端动作' AS src, name AS what,
       datetime(timestamp_ms/1000, 'unixepoch', 'localtime') AS at
FROM product_events WHERE session_id IN (SELECT session_id FROM latest)
UNION ALL
SELECT 'AI调用', purpose || ' / ' || COALESCE(error_message, 'ok'),
       datetime(created_at, 'localtime')
FROM ai_call_logs WHERE session_id IN (SELECT session_id FROM latest)
UNION ALL
SELECT '网络请求', path || ' ' || status_code,
       datetime(created_at, 'localtime')
FROM request_logs WHERE session_id IN (SELECT session_id FROM latest)
ORDER BY at;

-- 会话粒度的 AI 使用漏斗：进对话模块 → 发起 AI → 记账成功
SELECT p2.name AS module_entry, COUNT(DISTINCT a.id) AS ai_calls, COUNT(DISTINCT p1.id) AS bills
FROM product_events p2
LEFT JOIN ai_call_logs a ON a.session_id = p2.session_id AND a.device_id = p2.device_id
LEFT JOIN product_events p1 ON p1.session_id = p2.session_id AND p1.name = 'bill_created'
WHERE p2.name = 'module_view' AND p2.params LIKE '%"ai"%' AND p2.build_channel = 'release'
GROUP BY p2.session_id;
```

**坑（冒烟实锤）**：埋点校验曾误用 32 字符截断处理 sessionId（UUID 是 36 位）→ 与 request_logs 存的完整值 join 失败。已修为 8-64 校验，测试改用真实 36 位 UUID 守住此回归。

## 合规

1. **隐私政策**（`HoloBackend/src/legal/privacy-{zh-Hans,zh-Hant,en}.html`）：增补「匿名使用数据」条款——收集设备标识与功能使用情况（进入哪些模块、使用哪些功能的次数），仅用于改进产品，不收集记账金额、习惯内容、想法正文等任何用户内容。需随本次后端发版生效。
2. **App Store 隐私标签**（东林手动，ASC 网页操作）：App Store Connect → App 隐私 → 新增「数据收集」项：
   - 数据类型：**使用数据 → 产品交互**（Product Interaction）；
   - 是否与用户身份关联：是（与设备 ID 关联）；
   - 用途：**分析（Analytics）**；
   - 不用于追踪（无广告/归因用途）。
   - 注意：Holo 因 AI 额度与付费权益本就上送 device_id，如已申报过「使用数据/标识符」类目，只需在用途里补勾「分析」。
3. **国内口径**：数据仅进自有 ECS 服务器（无第三方 SDK），App 备案不涉及第三方 SDK 清单变更；隐私政策披露已覆盖个保法「明示告知」义务，v1 不加单独同意弹窗（拍板 3）。

## 运维与查询

常用 SQL（ECS 上 sqlite3）：

```sql
-- 近 7 天活跃设备数（按天）
SELECT date(received_at_ms/1000, 'unixepoch', 'localtime') AS day, COUNT(DISTINCT device_id)
FROM product_events WHERE build_channel='release'
GROUP BY day ORDER BY day DESC LIMIT 7;

-- 功能使用排行（近 30 天）
SELECT name, COUNT(*) cnt, COUNT(DISTINCT device_id) devices
FROM product_events WHERE build_channel='release'
GROUP BY name ORDER BY cnt DESC;

-- 付费墙漏斗（近 30 天）
SELECT name, COUNT(DISTINCT device_id) FROM product_events
WHERE name IN ('paywall_viewed','paywall_purchase_tapped') AND build_channel='release'
GROUP BY name;
```

## 验收清单

- [x] 后端：`node --test tests/product-event-upload.test.js` 全绿（落库/幂等/400/限流/开关 6 项）；二期 `tests/session-linkage.test.js` 3 项（AI 日志会话键/缺头空值/三表 join）；全量 559/559 无回归
- [x] iOS：构建通过 + HoloProductAnalyticsTests 6/6 绿（队列落盘/上限/移除/清空/事件名契约/会话生命周期）
- [x] 模拟器全链路冒烟（2026-10-19 两轮实证）：一期 `app_first_launch` + cold session 落库；二期同一 36 位会话 ID 真实贯穿 `product_events` 与 `request_logs`，跨表 join 命中 2 行；迁移 #22/#23 在全新库执行成功
- [x] 隐私政策三语条款已更新（1.3 自动收集信息改写 + 使用目的表补「匿名使用数据」行）
- [ ] 东林手动：ASC 隐私标签申报（见「合规」节步骤）
- [ ] 后端发版部署（新增表+路由+政策文件；**未部署前生产后端对新路由 404，客户端按 4xx 丢弃批次不影响使用，部署后自动恢复收集**）
- [ ] 东林真机验收（装含埋点的 Debug 包日常使用一两天后，ECS 上按「运维与查询」SQL 核对事件齐全性）

## 实施记录（2026-10-19）

- 后端：迁移 #22（`src/db/migrations.js`）、`src/product/productEventStore.js`、路由 `POST /v1/product/events` 与 `normalizeProductEvent`（`src/app.js`）、限流与 `productAnalytics.enabled` 开关（`src/config.js`，env `HOLO_PRODUCT_ANALYTICS_ENABLED`，默认开）、测试 `tests/product-event-upload.test.js`
- iOS：`Holo/Services/Analytics/HoloProductAnalytics.swift`（事件枚举/本地队列 actor/上报器）+ 六处接入（HoloApp 会话与上报触发、HomeView 模块曝光、FinanceRepository 记账、TodoRepository 建任务、HoloPlusPaywallView 付费墙、HabitRepository 经通知总线）
- 测试挂载：`HoloTests/Services/Analytics/HoloProductAnalyticsTests.swift`（pbxproj 四锚点手动挂载）
- **坑（已根治）**：`HabitRepository.swift` 被主 App 与 HoloWidgets 两 target 共享编译，直接引用 App 侧埋点类型导致小组件 target 编译失败；修法=仓库层发 `holoHabitCheckinDidRecord` 通知（Foundation 零依赖），主 App 侧埋点服务监听记录——数据域不依赖上报服务的解耦正解
- **二期（前后端链路对齐）**：iOS `HoloAnalyticsSession`（锁保护的会话 ID 持有者）+ `APIRequest.toURLRequest()` 统一附加 `x-holo-session-id`；后端迁移 #23 三表加列、`requestLogger.readSessionId`、`app.js getSessionId` + 4 处 `startAiCall` 传入、`normalizeProductEvent` 解析；测试 `tests/session-linkage.test.js`
