# HoloBackend 功能增强设计方案

> 日期：2026-05-16
> 状态：设计完成，待实施

---

## 一、背景与目标

HoloBackend 当前是纯内存 MVP：限流、日志、Prompt 版本均重启即丢，管理后台无法从公网访问，ASR 调用无日志记录。本次增强目标是将后端从 MVP 升级为可运维的稳定服务。

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
| 8 | 管理后台部署到 ECS + IP 白名单 | 高 |

### 下期（依赖外部条件）

| 功能 | 依赖 |
|------|------|
| 域名 + HTTPS | 等域名购买 |
| 真实 App Attest 校验 | 等付费开发者账号 |

---

## 二、SQLite 持久化基础设施

### 技术选型

- **库**：`better-sqlite3`（原生绑定，同步 API，Alpine 兼容）
- **文件位置**：容器内 `/data/holo-backend.db`
- **Docker 挂载**：`-v ./data:/data` 持久化到宿主机

### 数据库连接管理

新建 `src/db/database.js`：

- 启动时打开连接，启用 WAL 模式（并发读写性能）
- 启动时自动执行 migration
- 优雅关闭时 `db.close()`
- 单例模式，全局共享一个连接

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
  request_summary TEXT,                     -- 截断后的请求摘要
  response_summary TEXT,                    -- 截断后的响应摘要
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
- 启动时自动执行未应用的 migration
- 每个 migration 是一个 SQL 字符串 + 可选的迁移函数

---

## 三、请求耗时日志

### 实现：Hono 中间件

新建 `src/middleware/requestLogger.js`：

```
请求进入 → 记录 startTime → await next() → 计算 duration → 写入 SQLite
```

- 排除 `/admin/*` 静态页面请求（避免日志噪音）
- 控制台结构化输出：`GET /v1/health 200 2ms`
- 异步写入 SQLite（不阻塞响应）
- 自动清理：启动时删除 7 天前的 request_logs

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
  2. 计算 diff（行级 LCS 算法）
  3. 写入新版本到 `prompt_versions` 表
  4. 更新 `managedPrompts.json`（保持向后兼容）
- `getHistory(type)` → 查询 `prompt_versions` 表
- `rollback(type, version)` → 从表中读取目标版本内容，作为新版本写入

### Diff 算法

自实现轻量 LCS diff，无需外部依赖：

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

### 降级策略

- SQLite 写入失败时降级到内存限流（不因存储故障阻塞正常请求）
- 日志记录降级事件

---

## 九、管理后台部署到 ECS + IP 白名单

### Nginx 配置改造

更新 `deploy/nginx-holo-backend.conf`：

```nginx
# API 端点 — 所有来源
location /v1/ {
    proxy_pass http://127.0.0.1:8787;
    # ... 现有配置
}

# 管理后台 — IP 白名单
location /admin/ {
    allow 你的IP地址;
    deny all;
    proxy_pass http://127.0.0.1:8787;
}

# 管理后台 API
location /v1/admin/ {
    allow 你的IP地址;
    deny all;
    proxy_pass http://127.0.0.1:8787;
}
```

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
- 新增 IP 白名单配置说明
- 新增数据库备份/恢复指引

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
  nginx-holo-backend.conf    # 改造：增加 /admin/ 代理 + IP 白名单
  README-ECS.md              # 改造：更新部署步骤
```

---

## 十一、实施顺序

```
Phase 1: SQLite 基础设施
  ├── database.js + migrations.js
  └── 基础测试

Phase 2: 可观测性
  ├── 请求耗时日志中间件
  ├── ASR 调用摘要日志
  └── 控制台结构化输出

Phase 3: 日志持久化 + Prompt 关联
  ├── adminLogStore 改造
  ├── 日志关联 Prompt 版本
  └── 管理后台日志页面增强

Phase 4: Prompt 版本管理
  ├── promptRegistry 版本历史存储
  ├── Diff 算法
  ├── 后端 API (history/rollback)
  └── 管理后台 UI (历史列表 + Diff 视图 + 回滚)

Phase 5: 持久化限流
  ├── sqliteUsageStore 实现
  └── DI 注入 + 降级策略

Phase 6: 部署
  ├── Nginx /admin/ 代理 + IP 白名单
  ├── Docker Compose volume 挂载
  ├── 部署到 ECS
  └── 冒烟测试
```

---

## 十二、风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| SQLite 并发写入瓶颈 | WAL 模式 + 单写连接；当前 QPS 极低，不构成问题 |
| better-sqlite3 Alpine 编译 | Dockerfile 已用 Node Alpine；better-sqlite3 需 `build-base` 和 `python3` 编译依赖，或使用预编译版本 |
| 数据库文件损坏 | 启动时 PRAGMA integrity_check；定期备份建议 |
| IP 变动导致无法访问管理后台 | Nginx 配置支持多个 allow 指令；可通过 SSH 修改配置 |
| 迁移过程中服务中断 | 每个 Phase 独立可部署；迁移是渐进式的 |
