# HoloBackend SQLite → MySQL 迁移方案

> 状态：待审查
> 日期：2026-05-16

## 1. 背景与目标

HoloBackend 当前使用 `better-sqlite3`（同步 SQLite 驱动）作为唯一数据库。随着数据量增长和多实例部署需求，需要引入 MySQL 支持。

**目标**：通过 `DB_TYPE` 环境变量实现双模式架构——本地开发/测试继续用 SQLite（零依赖），生产用 Docker Compose 自建 MySQL。

**核心挑战**：`better-sqlite3` 是同步 API，`mysql2` 是异步 API，需要通过统一的异步数据库抽象层解决。

---

## 2. 当前数据库现状

### 2.1 技术栈

| 项目 | 当前值 |
|------|--------|
| 驱动 | `better-sqlite3` ^12.10.0（同步） |
| ORM | 无，全部手写 SQL |
| 数据库文件 | `/data/holo-backend.db`（Docker volume 挂载） |
| 测试数据库 | `:memory:` 内存模式 |

### 2.2 表结构（5 张表）

| 表名 | 用途 | 关键列 |
|------|------|--------|
| `ai_call_logs` | AI/ASR 调用日志 | device_id, call_type, provider, model, duration_ms |
| `prompt_versions` | Prompt 版本管理 | prompt_type, version, content, source |
| `rate_limits` | 设备级限流计数 | **key**（注意：MySQL 保留字）, count, expires_at |
| `request_logs` | HTTP 请求日志 | method, path, status_code, duration_ms |
| `schema_version` | 迁移版本追踪 | migration_id, checksum |

### 2.3 SQLite 特有用法

| 特性 | 使用位置 |
|------|----------|
| WAL 模式 | database.js |
| `busy_timeout` pragma | database.js |
| `integrity_check` pragma | database.js |
| `wal_checkpoint(TRUNCATE)` | database.js（备份前） |
| `datetime('now')` | 6 张表的 DEFAULT + 清理查询 |
| `datetime('now', '-N days')` | adminLogStore、usageStore、requestLogger |
| `AUTOINCREMENT` | 所有表的 id 列 |
| `INSERT ... ON CONFLICT DO UPDATE` | rate_limits（UPSERT） |
| `db.transaction()` | migrations、usageStore、requestLogger |
| 文件级备份 | `copyFileSync` + WAL checkpoint |

### 2.4 涉及数据库的文件（8 个）

```
src/db/database.js          ← 连接、WAL、完整性检查、迁移入口
src/db/migrations.js         ← 5 个迁移 + 校验和验证
src/usage/sqliteUsageStore.js ← 限流 UPSERT
src/admin/adminLogStore.js   ← AI 调用日志 CRUD
src/prompts/promptRegistry.js ← Prompt 版本 CRUD（最复杂，23 处调用）
src/middleware/requestLogger.js ← HTTP 日志批量写入
src/app.js                   ← 组装层，db 分发给各 store
src/server.js                ← 入口，createDatabase() + graceful shutdown
```

---

## 3. 方案设计

### 3.1 架构：统一异步数据库抽象层

```
┌─────────────────────────────────────────────┐
│  app.js / server.js                          │
│  (只接触统一 driver 接口)                     │
├─────────────────────────────────────────────┤
│  usageStore / adminLogStore / promptRegistry │
│  (await driver.run/get/all/transaction)      │
├─────────────────────────────────────────────┤
│          统一异步 Driver 接口                 │
│  exec / run / get / all / transaction / close│
├──────────────────┬──────────────────────────┤
│  sqliteDriver    │    mysqlDriver            │
│  better-sqlite3  │    mysql2/promise pool    │
│  (同步包装异步)   │    (原生异步)              │
├──────────────────┴──────────────────────────┤
│  dialect helpers                              │
│  nowFn / dateSubFn / autoIncrement           │
└─────────────────────────────────────────────┘
```

### 3.2 统一 Driver 接口

```typescript
// 所有方法都是 async
interface DatabaseDriver {
  dialect: 'sqlite' | 'mysql'          // 只读属性

  exec(sql: string): Promise<void>     // DDL、SET 等
  run(sql: string, params?: any[]): Promise<{
    insertId: number
    affectedRows: number
  }>
  get(sql: string, params?: any[]): Promise<Row | null>
  all(sql: string, params?: any[]): Promise<Row[]>
  transaction<T>(fn: () => Promise<T>): Promise<T>
  close(): Promise<void>
  backup(): Promise<string>
}
```

### 3.3 SQL 方言差异处理

| SQLite | MySQL | helper 函数 |
|--------|-------|-------------|
| `INTEGER PRIMARY KEY AUTOINCREMENT` | `INT PRIMARY KEY AUTO_INCREMENT` | `autoIncrement(dialect)` |
| `datetime('now')` | `NOW()` | `nowFn(dialect)` |
| `datetime('now', '-30 days')` | `NOW() - INTERVAL 30 DAY` | `dateSubFn(dialect, 30)` |
| `ON CONFLICT(key) DO UPDATE SET` | `ON DUPLICATE KEY UPDATE` | 直接在 usageStore 中判断 |
| 列名 `key` | 列名 `key` 是保留字 | 迁移 #6 重命名为 `rate_key` |

---

## 4. 实施步骤

### Phase 0: 依赖与配置

**0.1 安装 mysql2**
```bash
npm install mysql2
```

**0.2 新增环境变量**（`src/config.js` + `.env.example`）
```
DB_TYPE=sqlite
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=holo
MYSQL_PASSWORD=
MYSQL_DATABASE=holo_backend
MYSQL_POOL_SIZE=5
```

### Phase 1: 数据库抽象层

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/db/driver/interface.js` | 新建 | JSDoc 接口定义 |
| `src/db/driver/sqliteDriver.js` | 新建 | 包装 better-sqlite3 为 async 接口 |
| `src/db/driver/mysqlDriver.js` | 新建 | mysql2/promise 连接池适配器 |
| `src/db/dialect/helpers.js` | 新建 | SQL 方言工具函数 |
| `src/db/database.js` | 重写 | async 工厂，按 config.type 选择驱动 |

### Phase 2: 迁移系统重写

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/db/migrations.js` | 重写 | 每个迁移的 `up` 改为 `(dialect) => sql` 函数，整体变 async |

新增迁移 #6：`rate_limits.key` → `rate_key`

### Phase 3: 消费者文件转 async（按依赖顺序）

**转换顺序**（每步后跑 `npm test` 验证）：

| 步骤 | 文件 | 关键改动 |
|------|------|----------|
| 3.1 | `src/usage/sqliteUsageStore.js` → `src/usage/usageStore.js` | 重命名，consume() 变 async，UPSERT 方言化 |
| 3.2 | `src/admin/adminLogStore.js` | 所有方法加 async，lastInsertRowid→insertId |
| 3.3 | `src/prompts/promptRegistry.js` | `_db`→`_driver`，10 个导出函数全部 async |
| 3.4 | `src/middleware/requestLogger.js` | flush() 变 async |
| 3.5 | `src/app.js` | createApp() 变 async，所有 store 调用加 await |
| 3.6 | `src/server.js` | 入口 async 化 |

### Phase 4: Docker 与部署

**4.1 docker-compose.yml 新增 MySQL 服务**
```yaml
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_DATABASE: holo_backend
      MYSQL_USER: holo
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      retries: 10

  holo-backend:
    depends_on:
      mysql:
        condition: service_healthy

volumes:
  mysql_data:
```

**4.2 Dockerfile**
- 保留 `build-base python3`（双模式需要 SQLite 编译）
- 生产可考虑单独的 MySQL-only Dockerfile 去掉这些依赖

**4.3 配置文件更新**
- `.env.example` 新增 `DB_TYPE` 和 `MYSQL_*` 变量
- `deploy/env.production.example` 同步更新

### Phase 5: 测试更新

- 现有 44 个测试：`createTestApp()` 变 async，内部仍用 `:memory:` SQLite
- 可选新增 `tests/mysql-integration.test.js`

### Phase 6: 数据迁移脚本

新建 `scripts/migrate-sqlite-to-mysql.js`：
1. 读取现有 SQLite 全部数据
2. 批量写入 MySQL（100 行/批）
3. 验证行数一致
4. 保留 SQLite 原文件

**切换步骤**：
1. 部署新代码，`DB_TYPE=sqlite` → 验证无回归
2. 启动 MySQL 容器
3. 运行迁移脚本
4. 切换 `DB_TYPE=mysql`，重启服务
5. 管理面板验证数据完整性

### Phase 7: 备份策略

| 环境 | 方式 |
|------|------|
| SQLite（本地） | 不变，WAL checkpoint + 文件拷贝 |
| MySQL（生产） | ECS cron: `docker exec holo-mysql mysqldump ... \| gzip > backup.sql.gz` |

---

## 5. 文件变更汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `package.json` | 修改 | 添加 `mysql2` |
| `src/config.js` | 修改 | 新增 `db` 配置段 |
| `src/db/driver/interface.js` | **新建** | 统一异步接口定义 |
| `src/db/driver/sqliteDriver.js` | **新建** | SQLite 异步适配器 |
| `src/db/driver/mysqlDriver.js` | **新建** | MySQL 异步适配器 |
| `src/db/dialect/helpers.js` | **新建** | SQL 方言工具函数 |
| `src/db/database.js` | **重写** | 异步工厂 + 驱动选择 |
| `src/db/migrations.js` | **重写** | 异步 + 方言感知 |
| `src/usage/usageStore.js` | **新建** | 替代 sqliteUsageStore.js |
| `src/usage/sqliteUsageStore.js` | **删除** | 被 usageStore.js 替代 |
| `src/admin/adminLogStore.js` | 重写 | 全部 async |
| `src/prompts/promptRegistry.js` | 重写 | 全部 async（最复杂） |
| `src/middleware/requestLogger.js` | 重写 | async flush |
| `src/app.js` | 重写 | async createApp |
| `src/server.js` | 重写 | async 初始化 |
| `deploy/docker-compose.yml` | 修改 | 新增 MySQL 服务 |
| `Dockerfile` | 修改 | 可选去掉 build-base |
| `.env.example` | 修改 | 新增 DB 变量 |
| `deploy/env.production.example` | 修改 | 新增 MySQL 变量 |
| `scripts/migrate-sqlite-to-mysql.js` | **新建** | 数据迁移脚本 |
| `tests/*.test.js`（4 文件） | 修改 | async createTestApp |

**统计**：6 个新建 + 1 个删除 + 14 个修改/重写 = 21 个文件

---

## 6. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| async 转换引入时序 bug | 高 | 44 个测试逐步验证，每转换一个文件跑全量测试 |
| MySQL 连接断开 | 中 | mysql2 连接池自动重连，driver 层增加错误日志和重试 |
| `rate_limits.key` 是 MySQL 保留字 | 高 | 迁移 #6 重命名为 `rate_key`，在 MySQL 查询前完成 |
| 事务行为差异 | 低 | SQLite 独占锁 vs MySQL 行锁，现有事务都是简单顺序操作 |
| 数据迁移丢失 | 高 | 脚本验证行数，保留 SQLite 原文件不删除 |
| 部署期间服务中断 | 中 | 先 DB_TYPE=sqlite 验证，再切 MySQL，保留回退能力 |

---

## 7. 验证清单

- [ ] `npm test` — 44 个测试全部通过（SQLite 模式）
- [ ] `DB_TYPE=mysql` 启动服务 → `/v1/health` 返回 OK
- [ ] 管理面板 `/admin/logs` 查看调用日志
- [ ] 管理面板 `/admin/prompts` 查看/编辑 prompt
- [ ] 迁移脚本行数对比一致
- [ ] 并发 10 个 chat 请求 → rate_limit UPSERT 正确
- [ ] Docker Compose `docker compose up` 两个服务都健康
