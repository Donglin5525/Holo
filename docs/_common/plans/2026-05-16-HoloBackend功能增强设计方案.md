# HoloBackend 功能增强设计方案

> 日期：2026-05-16
> 状态：第二轮审查完成（Claude 审查），待 GPT 终审

---

## 一、背景与目标

HoloBackend 当前是纯内存 MVP：限流、日志、Prompt 版本均重启即丢，管理后台无法从公网访问，ASR 调用无日志记录。本次增强目标是将后端从 MVP 升级为可运维的稳定服务。

### 审查结论

本方案不能只按”可运维增强”理解，还必须同步补齐生产安全边界。否则会出现”有后台、有日志、有持久化，但公网暴露、状态源分裂”的风险。

实施前必须确认以下门槛：

1. 管理后台公网访问必须与 HTTPS、VPN 或 SSH tunnel 三选一绑定，不能仅依赖 IP 白名单。
2. 在真实 App Attest 完成前，通过 **ECS 安全组限制来源 IP** 临时保护 API 端点，不引入客户端签名机制（避免 iOS 端跨平台改动）。正式鉴权等 App Attest 上线后一次性解决。
3. AI/ASR 日志默认只落元数据，用户正文摘要必须通过显式开关启用，并做截断和保留期控制。
4. SQLite 同步写入会阻塞 Node event loop；若宣称”不阻塞响应”，必须实现队列写入、背压和丢弃策略。
5. Prompt 版本状态源必须单一化，SQLite 作为唯一事实源，`managedPrompts.json` 只能用于一次性迁移或导出备份。

### 本期范围

| # | 功能 | 优先级 |
|---|------|--------|
| 1 | SQLite 持久化基础设施 | 基础 |
| 2 | 请求耗时日志（全局中间件） | 高 |
| 3 | ASR 调用摘要日志 | 高 |
| 4 | 管理日志持久化（内存 → SQLite） | 高 |
| 5 | AI 调用日志关联 Prompt 版本 | 中 |
| 6 | Prompt 版本历史 + Diff + 回滚 | 高 |
| 7 | 持久化限流存储（内存 → SQLite） | 中 |
| 8 | 管理后台部署到 ECS + SSH tunnel 访问 + IP 白名单 | 高 |
| 9 | 日志正文落库开关 + 截断上限 | 高 |

### 下期（依赖外部条件）

| 功能 | 依赖 |
|------|------|
| 域名 + HTTPS + Secure Cookie + CSRF + 登录限速 | 等域名购买 |
| 真实 App Attest 校验 | 等付费开发者账号 |

> 注意：如果本期没有 HTTPS，管理后台只能通过 SSH tunnel 或 ECS 安全组内网访问，不允许直接开放公网登录页。API 端点通过 ECS 安全组限制来源 IP 临时保护。

---

## 二、SQLite 持久化基础设施

### 技术选型

- **库**：`better-sqlite3`（原生绑定，同步 API，Alpine 兼容）
- **文件位置**：容器内 `/data/holo-backend.db`
- **Docker 挂载**：`-v ./data:/data` 持久化到宿主机

### 数据库连接管理

新建 `src/db/database.js`：

- 启动时打开连接，启用 WAL 模式（并发读写性能）
- 启动时执行 `PRAGMA integrity_check`，失败时拒绝启动并提示从备份恢复
- 启动时自动执行 migration，但 migration 必须具备事务、版本锁和失败中止机制
- 优雅关闭时 `db.close()`
- 单例模式，全局共享一个连接
- 配置 `busy_timeout`，避免短时间写锁冲突直接失败
- 写入路径区分“关键写入”和“可丢弃写入”：限流、Prompt 版本属于关键写入；请求耗时日志属于可丢弃写入

### 表结构设计

#### `ai_call_logs` — AI/ASR 调用日志

```sql
CREATE TABLE IF NOT EXISTS ai_call_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  call_type TEXT NOT NULL DEFAULT 'chat',  -- 'chat' | 'asr'
  purpose TEXT,                             -- 'chat' | 'intent' | 'insight' | 'asr_transcription'
  provider TEXT,
  model TEXT,
  is_stream INTEGER DEFAULT 0,
  prompt_type TEXT,                         -- 新增：使用的 Prompt 类型
  prompt_version INTEGER,                   -- 新增：使用的 Prompt 版本
  request_summary TEXT,                     -- 可选：脱敏 + 截断后的请求摘要
  response_summary TEXT,                    -- 可选：脱敏 + 截断后的响应摘要
  redaction_applied INTEGER DEFAULT 0,       -- 预留：是否已执行脱敏
  content_capture_enabled INTEGER DEFAULT 0, -- 是否启用正文摘要落库
  asr_file_type TEXT,                       -- ASR 专用：音频格式
  asr_result_length INTEGER,                -- ASR 专用：转写结果字符数
  error_message TEXT,
  duration_ms INTEGER,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_logs_created ON ai_call_logs(created_at);
CREATE INDEX idx_logs_device ON ai_call_logs(device_id);
CREATE INDEX idx_logs_call_type ON ai_call_logs(call_type);
```

#### `prompt_versions` — Prompt 版本历史

```sql
CREATE TABLE IF NOT EXISTS prompt_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  prompt_type TEXT NOT NULL,
  version INTEGER NOT NULL,
  content TEXT NOT NULL,
  diff_from_prev TEXT,            -- 与上一版本的 diff
  source TEXT NOT NULL DEFAULT 'managed',  -- 'managed' | 'reset'
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(prompt_type, version)
);

CREATE INDEX idx_prompt_versions_type ON prompt_versions(prompt_type);
```

#### `rate_limits` — 持久化限流计数

```sql
CREATE TABLE IF NOT EXISTS rate_limits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,       -- '{deviceId}:{purpose}:{minute|day}:{timestamp}'
  count INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL          -- 过期时间，用于清理
);

CREATE INDEX idx_rate_limits_expires ON rate_limits(expires_at);
```

#### `request_logs` — 全局请求耗时日志

```sql
CREATE TABLE IF NOT EXISTS request_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  status_code INTEGER,
  duration_ms INTEGER,
  device_id TEXT,
  user_agent TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_request_logs_created ON request_logs(created_at);
```

### Migration 管理

新建 `src/db/migrations.js`：

- 版本化 migration，用 `schema_version` 表追踪
- 启动时自动执行未应用的 migration，但执行前先备份当前数据库文件到 `/data/backups/`
- 每个 migration 是一个 SQL 字符串 + 可选的迁移函数，并整体包裹在事务中
- 使用 migration 锁避免多实例或重复启动时并发迁移
- 记录 migration id、checksum、applied_at，防止同版本内容被改写后静默跳过
- 任一 migration 失败时拒绝启动，避免半迁移状态继续对外服务

---

## 三、请求耗时日志

### 实现：Hono 中间件

新建 `src/middleware/requestLogger.js`：

```
请求进入 → 记录 startTime → await next() → 计算 duration → 投递到日志队列 → 批量写入 SQLite
```

- 排除 `/admin/*` 静态页面请求（避免日志噪音）
- 控制台结构化输出：`GET /v1/health 200 2ms`
- 使用内存队列异步批量写入 SQLite，不在请求响应链路中直接执行同步写
- 队列满时优先丢弃 `request_logs`，并输出降级事件；不得阻塞 AI/ASR 主链路
- 自动清理：启动时删除 7 天前的 request_logs

> `better-sqlite3` 是同步 API。如果直接在 middleware 中写库，会阻塞 Node event loop。因此“不阻塞响应”的前提是必须实现队列、批量 flush、错误隔离和队列长度上限。

### 控制台输出格式

```
[2026-05-16 12:00:00] POST /v1/ai/chat/completions 200 1420ms
[2026-05-16 12:00:01] POST /v1/asr/transcriptions 200 890ms
[2026-05-16 12:00:02] GET /v1/health 200 1ms
```

---

## 四、ASR 调用摘要日志

### 改造点

在 `src/app.js` 的 ASR 路由处理函数中，复用现有 `adminLogStore` 的 `startAiCall` / `finishAiCall` 模式：

- 调用开始时记录：`call_type='asr'`、`purpose='asr_transcription'`、`asr_file_type`（从 Content-Type 提取）
- 调用完成时记录：`asr_result_length`（转写文本字符数）、`duration_ms`、`error_message`
- **禁止**记录音频二进制内容
- 默认不记录 ASR 转写全文，只记录字符数；如需记录摘要，必须走统一脱敏与正文落库开关

### 管理后台展示

在 `/admin/logs` 页面增加 ASR 调用卡片，展示：
- 音频格式
- 转写结果长度
- 耗时
- 错误信息（如有）

---

## 五、管理日志持久化

### 改造：adminLogStore → SQLite

改造 `src/admin/adminLogStore.js`：

- `startAiCall()` → 插入 `ai_call_logs` 记录，返回 ID
- `finishAiCall()` → 更新对应记录的响应、耗时、错误字段
- `getEntries()` → 从 SQLite 查询，支持分页和筛选
- `getEntry(id)` → 单条查询
- 保留内存缓存作为热数据层（最近 50 条），SQLite 作为持久层

### 正文记录策略

- 默认仅记录元数据：device_id、purpose、provider、model、duration、status、error_code、ASR 文件类型、转写结果长度
- `request_summary` / `response_summary` 默认关闭，由环境变量 `HOLO_LOG_CAPTURE_CONTENT=true` 显式启用
- 启用正文摘要后，截断到 2,000 字符上限，不做模式脱敏（正则匹配手机号/身份证等复杂度高且易误判）
- 对 `finance`、`health`、`memory` 等高敏内容，即使开启正文摘要也只记录长度和调用状态，不记录正文

### 自动清理

- 默认保留 30 天日志
- 启动时执行一次清理：`DELETE FROM ai_call_logs WHERE created_at < datetime('now', '-30 days')`
- 可通过环境变量 `HOLO_LOG_RETENTION_DAYS` 配置

---

## 六、AI 调用日志关联 Prompt 版本

### 改造点

在 `src/app.js` 的 chat 路由中，调用 `startAiCall()` 时额外传入：

- `prompt_type`：当前使用的 Prompt 类型（如 `system_prompt`、`intent_recognition`）
- `prompt_version`：从 `promptRegistry.getPrompt(type)` 获取的版本号

这需要 `promptRegistry.getPrompt()` 返回值中包含 version 字段（当前已有，只需传递到日志）。

> 注意：当前 chat 路由并不总是在后端组装 Prompt，部分请求可能由客户端传入 messages。实施时必须先明确每个 `purpose` 对应的 Prompt 类型来源；无法确定时 `prompt_type` 应为 `null`，不能伪造关联。

---

## 七、Prompt 版本历史 + Diff + 回滚

### 后端 API

| 端点 | 方法 | 说明 |
|------|------|------|
| `/admin/prompts/:type/history` | GET | 返回该 Prompt 的所有历史版本 |
| `/admin/prompts/:type/rollback` | POST | 回滚到指定版本，body: `{ version: N }` |

### 版本存储逻辑

改造 `src/prompts/promptRegistry.js`：

- `savePrompt(type, content)` 时：
  1. 读取当前 managed 版本内容
  2. 计算 diff（优先使用成熟 diff 库；MVP 可先只存完整内容）
  3. 写入新版本到 `prompt_versions` 表
  4. SQLite 成为运行时唯一事实源
- `getHistory(type)` → 查询 `prompt_versions` 表
- `rollback(type, version)` → 从表中读取目标版本内容，作为新版本写入
- 首次启动时可将现有 `managedPrompts.json` 一次性迁移到 SQLite，迁移成功后不再运行时双写
- `managedPrompts.json` 后续仅允许作为导入来源或人工导出备份，不参与线上读取决策

### Diff 算法

使用成熟 diff 库 `diff`（npm 包）生成行级 diff，不自研 LCS：

- 输入：旧文本、新文本
- 输出：带 `+`/`-` 前缀的行级 diff
- 存储为 `diff_from_prev` 字段

### 管理后台 UI

在 `/admin/prompts/:type` 页面新增：

1. **版本历史列表**：时间、版本号、来源、diff 摘要
2. **Diff 视图**：点击版本号查看与前一版本的 diff（绿/红高亮）
3. **回滚按钮**：确认弹窗后回滚到指定版本

---

## 八、持久化限流存储

### 改造：inMemoryUsageStore → SQLite

新建 `src/usage/sqliteUsageStore.js`，实现与 `inMemoryUsageStore` 相同的接口：

- `checkLimit(deviceId, purpose, limits)` → 查询 + 更新 `rate_limits` 表
- 利用 SQLite 事务保证原子性：`INSERT ... ON CONFLICT(key) DO UPDATE SET count = count + 1`
- 过期清理：每次 check 时顺便删除过期记录

### 切换方式

通过 DI 注入，`createApp({ usageStore: new SqliteUsageStore(db) })`，路由代码零改动。

### 失败策略

- AI/ASR 等成本型接口：SQLite 限流写入失败时默认 fail-closed，返回 503 或进入极低额度保护模式
- 健康检查、后台静态页面等非成本接口：允许 fail-open
- 可选降级到内存限流，但必须有严格临时额度、持续时间上限和告警日志，不能无限期放开
- 日志记录降级事件，并在管理后台显示”限流存储异常”告警

### App Attest 前的临时 API 保护

真实 App Attest 上线前，通过 **ECS 安全组**限制 `/v1/ai/*` 和 `/v1/asr/*` 的来源 IP，仅允许开发者 IP 访问。这是零代码改动的方案，避免引入客户端签名机制导致的 iOS 端跨平台改动。正式鉴权等 App Attest 上线后一次性解决。

---

## 九、管理后台部署到 ECS + SSH tunnel + IP 白名单

### 访问策略

管理后台访问策略分两档：

| 模式 | 是否允许公网登录页 | 要求 |
|------|--------------------|------|
| 本期（无 HTTPS） | 否 | SSH tunnel 访问，不直接暴露 `/admin/login` 到公网 |
| 下期（有 HTTPS） | 是 | HTTPS + IP 白名单 + Secure Cookie + CSRF 防护 + 登录失败限速 |

本期无 HTTPS，部署脚本不得开放公网 `/admin/`，只允许通过 SSH tunnel 访问，例如本机转发到 ECS 的 `127.0.0.1:8787`。

### Nginx 配置改造

更新 `deploy/nginx-holo-backend.conf`：

```nginx
# API 端点 — ECS 安全组限制来源 IP（本期临时保护）
location /v1/ {
    proxy_pass http://127.0.0.1:8787;
    # ... 现有配置
}

# 管理后台 — 本期不通过 Nginx 暴露，仅通过 SSH tunnel 访问 127.0.0.1:8787
# 下期 HTTPS 启用后，再配置 location /admin/ 和 /v1/admin/ 并加 IP 白名单
```

下期（HTTPS 时）补充：

- Nginx 代理 `/admin/` 和 `/v1/admin/`，配置 IP 白名单
- HTTPS 证书与 HTTP → HTTPS 跳转
- `X-Forwarded-Proto` 透传，后端据此设置 Secure Cookie
- 登录失败限速，避免后台密码爆破
- CSRF token，保护状态变更路由

### Docker Compose 改造

```yaml
services:
  holo-backend:
    # ... 现有配置
    volumes:
      - ./data:/data          # SQLite 数据库持久化
      - ./logs:/app/logs      # 可选：日志文件备份
```

### 部署脚本更新

更新 `deploy/README-ECS.md`：
- 新增 SQLite 数据目录创建步骤
- 新增 SSH tunnel 访问管理后台的说明
- 新增 ECS 安全组配置说明（API 端点来源 IP 限制）
- 新增数据库备份/恢复指引
- 下期补充：HTTPS 配置、IP 白名单、CSRF、Secure Cookie 步骤

---

## 十、文件结构变更

```
src/
  db/
    database.js         # SQLite 连接管理（新建）
    migrations.js       # 版本化 migration（新建）
  middleware/
    requestLogger.js    # 请求耗时日志中间件（新建）
  usage/
    inMemoryUsageStore.js    # 保留，作为降级备份
    sqliteUsageStore.js      # 新建
  admin/
    adminLogStore.js         # 改造：内存 → SQLite
    adminLogsPage.js         # 改造：增加 ASR 日志展示
    adminPromptsPage.js      # 改造：增加版本历史 + Diff
    adminRoutes.js           # 改造：增加 history/rollback 路由
  prompts/
    promptRegistry.js        # 改造：版本历史存储
    defaultPrompts.json      # 不变
  app.js                     # 改造：注入 SQLite 依赖 + ASR 日志
  config.js                  # 改造：增加 SQLite 相关配置
deploy/
  docker-compose.yml         # 改造：增加 volume 挂载
  nginx-holo-backend.conf    # 改造：本期仅 /v1/ 代理
  README-ECS.md              # 改造：更新部署步骤
```

---

## 十一、实施顺序

```
Phase 1: SQLite 基础设施
  ├── database.js + migrations.js
  ├── integrity_check + busy_timeout + WAL
  ├── migration 事务、checksum、启动前备份
  └── 基础测试

Phase 2: 可观测性
  ├── 请求耗时日志队列中间件
  ├── ASR 调用摘要日志
  ├── 日志正文落库开关 + 截断上限
  └── 控制台结构化输出

Phase 3: 日志持久化 + Prompt 关联
  ├── adminLogStore 改造
  ├── 日志关联 Prompt 版本
  └── 管理后台日志页面增强

Phase 4: Prompt 版本管理
  ├── promptRegistry 版本历史存储（SQLite 单一事实源）
  ├── managedPrompts.json 一次性迁移
  ├── diff 库集成 + Diff 展示
  ├── 后端 API (history/rollback)
  └── 管理后台 UI (历史列表 + Diff 视图 + 回滚)

Phase 5: 持久化限流
  ├── sqliteUsageStore 实现
  ├── 成本接口 fail-closed / 极低额度保护
  └── DI 注入 + 失败策略

Phase 6: 部署
  ├── ECS 安全组配置（API 来源 IP 限制）
  ├── Docker Compose volume 挂载
  ├── SSH tunnel 管理后台访问配置
  ├── 部署到 ECS
  └── 冒烟测试
```

---

## 十二、风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| SQLite 并发写入瓶颈 | WAL 模式 + 单写连接；当前 QPS 极低，不构成问题 |
| better-sqlite3 Alpine 编译 | Dockerfile 需增加 `build-base` 和 `python3` 编译依赖，或使用预编译版本 |
| 同步 SQLite 写入阻塞 Node event loop | 请求耗时日志走队列批量写；关键写入只保留必要字段，并监控耗时 |
| 数据库文件损坏 | 启动时 PRAGMA integrity_check；启动前备份；失败拒绝启动并从备份恢复 |
| Migration 半失败 | 每个 migration 使用事务、checksum、版本锁；失败时拒绝启动 |
| AI/ASR 限流存储故障导致成本失控 | 成本接口 fail-closed 或极低额度保护，不无限期降级到内存 |
| 日志持久化泄露用户隐私 | 默认只记录元数据；正文摘要显式开关 + 截断上限 2,000 字符；高敏内容永不存正文 |
| Prompt SQLite 与 JSON 双写状态分裂 | SQLite 作为唯一事实源；JSON 只用于一次性迁移或导出备份 |
| 未接 App Attest 时 device_id 可伪造 | 通过 ECS 安全组限制 API 来源 IP；正式鉴权等 App Attest |
| 管理后台凭证泄露 | 本期不暴露到公网，仅 SSH tunnel 访问 |
| IP 变动导致无法访问管理后台 | 通过 SSH 连接 ECS 修改安全组；管理后台始终可通过 localhost 访问 |
| 迁移过程中服务中断 | 每个 Phase 独立可部署；迁移是渐进式的 |

---

## 十三、实施前检查清单

- [ ] 确认后台访问模式：本期 SSH tunnel，下期 HTTPS 公网。
- [ ] 确认 ECS 安全组已配置 API 来源 IP 限制。
- [ ] 确认日志正文默认关闭，截断上限 2,000 字符，保留期 30 天。
- [ ] 确认 SQLite migration 有备份、事务、checksum、失败中止。
- [ ] 确认 Prompt 以 SQLite 为唯一运行时事实源。
- [ ] 确认限流存储失败时成本接口不会 fail-open。
- [ ] 确认 Docker Compose volume 挂载路径正确。
