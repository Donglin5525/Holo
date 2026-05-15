import Database from 'better-sqlite3';
import { mkdirSync, copyFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { runMigrations } from './migrations.js';

const DEFAULT_DB_PATH = '/data/holo-backend.db';

function getBackupDir(dbPath) {
  return join(dirname(dbPath), 'backups');
}

/**
 * 创建 SQLite 数据库连接（单例）
 * - WAL 模式
 * - integrity_check 启动校验
 * - busy_timeout 写锁等待
 * - 自动执行 migration
 * - 优雅关闭
 */
export function createDatabase({ dbPath = DEFAULT_DB_PATH } = {}) {
  const isMemory = dbPath === ':memory:';
  if (!isMemory) {
    const dir = dirname(dbPath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }

  const db = new Database(dbPath);

  // 启动前完整性校验
  const integrityResult = db.pragma('integrity_check');
  if (integrityResult[0]?.integrity_check !== 'ok') {
    db.close();
    throw new Error(
      `SQLite integrity_check 失败，数据库可能损坏: ${dbPath}。请从 ${getBackupDir(dbPath)} 恢复备份。`
    );
  }

  // WAL 模式 — 提升并发读写性能
  db.pragma('journal_mode = WAL');

  // 写锁等待 5 秒，避免短时间写冲突直接失败
  db.pragma('busy_timeout = 5000');

  // 备份数据库文件（用于 migration 前的安全网，内存数据库不备份）
  const backupDir = getBackupDir(dbPath);
  const backupDatabase = () => {
    if (isMemory) return '(memory-db)';
    if (!existsSync(backupDir)) {
      mkdirSync(backupDir, { recursive: true });
    }
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backupPath = join(backupDir, `holo-backend-${timestamp}.db`);
    // 先 checkpoint WAL 到主文件
    db.pragma('wal_checkpoint(TRUNCATE)');
    copyFileSync(dbPath, backupPath);
    return backupPath;
  };

  // 执行 migration
  runMigrations(db, { backupFn: backupDatabase });

  return {
    db,

    /** 优雅关闭 */
    close() {
      db.close();
    },

    /** 备份数据库 */
    backup: backupDatabase,
  };
}
