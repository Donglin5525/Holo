import { createHash } from 'node:crypto';

/**
 * 版本化 migration 系统
 * - schema_version 表追踪已应用的 migration
 * - 每个 migration 有 id、SQL、checksum
 * - 事务包裹、备份前置、失败中止
 */

// Migration 定义：id 升序，每个包含 up SQL
const MIGRATIONS = [
  {
    id: 1,
    description: '创建 ai_call_logs 表',
    up: `
      CREATE TABLE IF NOT EXISTS ai_call_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        call_type TEXT NOT NULL DEFAULT 'chat',
        purpose TEXT,
        provider TEXT,
        model TEXT,
        is_stream INTEGER DEFAULT 0,
        prompt_type TEXT,
        prompt_version INTEGER,
        request_summary TEXT,
        response_summary TEXT,
        redaction_applied INTEGER DEFAULT 0,
        content_capture_enabled INTEGER DEFAULT 0,
        asr_file_type TEXT,
        asr_result_length INTEGER,
        error_message TEXT,
        duration_ms INTEGER,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_logs_created ON ai_call_logs(created_at);
      CREATE INDEX IF NOT EXISTS idx_logs_device ON ai_call_logs(device_id);
      CREATE INDEX IF NOT EXISTS idx_logs_call_type ON ai_call_logs(call_type);
    `,
  },
  {
    id: 2,
    description: '创建 prompt_versions 表',
    up: `
      CREATE TABLE IF NOT EXISTS prompt_versions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        prompt_type TEXT NOT NULL,
        version INTEGER NOT NULL,
        content TEXT NOT NULL,
        diff_from_prev TEXT,
        source TEXT NOT NULL DEFAULT 'managed',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(prompt_type, version)
      );
      CREATE INDEX IF NOT EXISTS idx_prompt_versions_type ON prompt_versions(prompt_type);
    `,
  },
  {
    id: 3,
    description: '创建 rate_limits 表',
    up: `
      CREATE TABLE IF NOT EXISTS rate_limits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT NOT NULL UNIQUE,
        count INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        expires_at TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_rate_limits_expires ON rate_limits(expires_at);
    `,
  },
  {
    id: 4,
    description: '创建 request_logs 表',
    up: `
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
      CREATE INDEX IF NOT EXISTS idx_request_logs_created ON request_logs(created_at);
    `,
  },
  {
    id: 5,
    description: 'prompt_versions 表新增 change_note 列',
    up: `
      ALTER TABLE prompt_versions ADD COLUMN change_note TEXT;
    `,
  },
  {
    id: 6,
    description: '创建 agent_step_idempotency 表（Agent step 级幂等，短期 TTL）',
    // response 列为 TTL 敏感数据：由应用层写入 AES-256-GCM 信封密文，不存完整 messages；
    // 由 expires_at + purgeExpired 控制保留期，不作为长期 Agent Job 表使用。
    up: `
      CREATE TABLE IF NOT EXISTS agent_step_idempotency (
        run_id TEXT NOT NULL,
        step_id TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        status TEXT NOT NULL,
        response TEXT,
        usage TEXT,
        error_code TEXT,
        error_status INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        PRIMARY KEY (run_id, step_id)
      );
      CREATE INDEX IF NOT EXISTS idx_agent_step_idempotency_expires
        ON agent_step_idempotency(expires_at);
    `,
  },
];

function computeChecksum(sql) {
  return createHash('sha256').update(sql.trim()).digest('hex').slice(0, 16);
}

/**
 * 执行所有未应用的 migration
 * @param {import('better-sqlite3').Database} db
 * @param {{ backupFn?: () => string }} options
 */
export function runMigrations(db, { backupFn } = {}) {
  // 确保 schema_version 表存在
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_version (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      migration_id INTEGER NOT NULL UNIQUE,
      description TEXT,
      checksum TEXT NOT NULL,
      applied_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  // 获取已应用的 migration
  const applied = new Map();
  const rows = db.prepare('SELECT migration_id, checksum FROM schema_version').all();
  for (const row of rows) {
    applied.set(row.migration_id, row.checksum);
  }

  // 检查是否需要备份（有任何新 migration 需要执行）
  const pending = MIGRATIONS.filter((m) => !applied.has(m.id));
  if (pending.length === 0) return;

  // 执行前备份
  if (backupFn) {
    const backupPath = backupFn();
    console.log(`[DB] Migration 前备份: ${backupPath}`);
  }

  // 逐个执行 pending migration
  for (const migration of pending) {
    const checksum = computeChecksum(migration.up);

    const appliedChecksum = applied.get(migration.id);
    if (appliedChecksum && appliedChecksum !== checksum) {
      throw new Error(
        `Migration #${migration.id} checksum 不匹配。已应用: ${appliedChecksum}, 当前: ${checksum}。可能被篡改，拒绝执行。`
      );
    }

    // 用事务包裹整个 migration
    const transaction = db.transaction(() => {
      db.exec(migration.up);
      db.prepare(
        'INSERT INTO schema_version (migration_id, description, checksum) VALUES (?, ?, ?)'
      ).run(migration.id, migration.description, checksum);
    });

    try {
      transaction();
      console.log(`[DB] Migration #${migration.id} 完成: ${migration.description}`);
    } catch (err) {
      throw new Error(
        `Migration #${migration.id} 失败，服务拒绝启动: ${err.message}`
      );
    }
  }

  console.log(`[DB] ${pending.length} 个 migration 全部完成`);
}
