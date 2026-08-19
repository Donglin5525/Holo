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
  {
    id: 7,
    description: 'Agent step 幂等记录新增 generation CAS 版本',
    up: `
      ALTER TABLE agent_step_idempotency
      ADD COLUMN generation INTEGER NOT NULL DEFAULT 1;
    `,
  },
  {
    id: 8,
    description: '创建 App Attest challenge 与实例 key 状态表',
    up: `
      CREATE TABLE IF NOT EXISTS app_attest_challenges (
        id TEXT PRIMARY KEY,
        challenge_hash TEXT NOT NULL,
        key_id TEXT,
        expires_at INTEGER NOT NULL,
        consumed_at INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_app_attest_challenges_expires
        ON app_attest_challenges(expires_at);

      CREATE TABLE IF NOT EXISTS app_attest_keys (
        key_id TEXT PRIMARY KEY,
        public_key_pem TEXT NOT NULL,
        receipt TEXT,
        sign_count INTEGER NOT NULL DEFAULT 0,
        environment TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_app_attest_keys_last_seen
        ON app_attest_keys(last_seen_at);
    `,
  },
  {
    id: 9,
    description: '创建订阅权益与真机验收覆盖表',
    up: `
      CREATE TABLE IF NOT EXISTS subscription_entitlements (
        device_id TEXT PRIMARY KEY,
        tier TEXT NOT NULL,
        product_id TEXT,
        original_transaction_id TEXT,
        latest_transaction_id TEXT,
        environment TEXT,
        expires_at TEXT,
        revoked_at TEXT,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_subscription_entitlements_expires
        ON subscription_entitlements(expires_at);

      CREATE TABLE IF NOT EXISTS subscription_acceptance_overrides (
        device_id TEXT PRIMARY KEY,
        tier TEXT NOT NULL CHECK (tier IN ('free', 'plus')),
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
    `,
  },
  {
    id: 10,
    description: '创建按成功动作计数的会员额度账本',
    up: `
      CREATE TABLE IF NOT EXISTS quota_action_ledger (
        subject_id TEXT NOT NULL,
        quota_type TEXT NOT NULL,
        period_key TEXT NOT NULL,
        action_id TEXT NOT NULL,
        tier TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('reserved', 'committed')),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY (subject_id, quota_type, period_key, action_id)
      );
      CREATE INDEX IF NOT EXISTS idx_quota_action_ledger_period
        ON quota_action_ledger(subject_id, quota_type, period_key, status);
      CREATE INDEX IF NOT EXISTS idx_quota_action_ledger_stale
        ON quota_action_ledger(status, updated_at_ms);
    `,
  },
  {
    id: 11,
    description: '创建 AI 内容举报表（App Store Guideline 1.2）',
    up: `
      CREATE TABLE IF NOT EXISTS content_reports (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        reason TEXT NOT NULL,
        detail TEXT,
        content_snapshot TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_content_reports_created
        ON content_reports(created_at);
      CREATE INDEX IF NOT EXISTS idx_content_reports_status
        ON content_reports(status);
      CREATE INDEX IF NOT EXISTS idx_content_reports_device
        ON content_reports(device_id);
    `,
  },
  {
    id: 12,
    description: '创建服务端可控功能开关表（P2 路由急停，经 subscription/status 下发）',
    up: `
      CREATE TABLE IF NOT EXISTS feature_flags (
        flag TEXT NOT NULL UNIQUE,
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    `,
  },
  {
    id: 13,
    description: '权益覆盖表新增有效期列（运营手动开通 Plus 的到期回收，NULL=永久）',
    up: `
      ALTER TABLE subscription_acceptance_overrides ADD COLUMN expires_at TEXT;
    `,
  },
  {
    id: 14,
    description: '创建用户反馈表（设置页「反馈给开发者」通道，图片存文件系统）',
    up: `
      CREATE TABLE IF NOT EXISTS user_feedback (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        category TEXT NOT NULL CHECK (category IN ('suggestion', 'issue', 'other')),
        content TEXT NOT NULL,
        contact_type TEXT CHECK (contact_type IN ('wechat', 'qq', 'email', 'phone') OR contact_type IS NULL),
        contact_value TEXT,
        images TEXT,
        app_version TEXT,
        os_version TEXT,
        status TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'done')),
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_user_feedback_created
        ON user_feedback(created_at);
      CREATE INDEX IF NOT EXISTS idx_user_feedback_device
        ON user_feedback(device_id);
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

  // 已应用 migration 也必须核对 checksum，避免不同分支复用同一编号时静默跳过建表。
  for (const migration of MIGRATIONS) {
    const appliedChecksum = applied.get(migration.id);
    const expectedChecksum = computeChecksum(migration.up);
    if (appliedChecksum && appliedChecksum !== expectedChecksum) {
      throw new Error(
        `Migration #${migration.id} checksum 不匹配。已应用: ${appliedChecksum}, 当前: ${expectedChecksum}。可能存在编号冲突，拒绝启动。`
      );
    }
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
