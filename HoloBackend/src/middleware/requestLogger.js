/**
 * 请求耗时日志中间件
 * - 内存队列批量写入 SQLite（避免同步写阻塞 event loop）
 * - 控制台结构化输出
 * - 队列满时丢弃 request_logs，不阻塞主链路
 */

import { formatLocalTimestamp } from "../time.js";

const MAX_QUEUE_SIZE = 500;
const FLUSH_INTERVAL_MS = 2000;
const CLEANUP_OLDER_THAN_DAYS = 7;

/** 会话关联键：客户端 x-holo-session-id 头（8-64 字符 UUID）；后台唤醒进程不带 → null */
function readSessionId(c) {
  const sessionId = c.req.header('x-holo-session-id');
  return typeof sessionId === 'string' && sessionId.length >= 8 && sessionId.length <= 64
    ? sessionId
    : null;
}

export function createRequestLogger(db) {
  const queue = [];
  let flushTimer = null;

  const insertStmt = db.prepare(`
    INSERT INTO request_logs (method, path, status_code, duration_ms, device_id, user_agent, session_id)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);

  const flush = () => {
    if (queue.length === 0) return;

    const batch = queue.splice(0, queue.length);
    try {
      const transaction = db.transaction(() => {
        for (const entry of batch) {
          insertStmt.run(
            entry.method,
            entry.path,
            entry.statusCode,
            entry.durationMs,
            entry.deviceId,
            entry.userAgent,
            entry.sessionId
          );
        }
      });
      transaction();
    } catch (err) {
      console.error('[RequestLogger] 批量写入失败:', err.message);
    }
  };

  const startFlushTimer = () => {
    if (flushTimer) return;
    flushTimer = setInterval(flush, FLUSH_INTERVAL_MS);
    flushTimer.unref?.(); // 不阻止进程退出
  };

  /** 启动时清理过期日志 */
  const cleanupOld = () => {
    try {
      const result = db
        .prepare(
          `DELETE FROM request_logs WHERE created_at < datetime('now', '-${CLEANUP_OLDER_THAN_DAYS} days')`
        )
        .run();
      if (result.changes > 0) {
        console.log(`[RequestLogger] 清理 ${result.changes} 条过期 request_logs`);
      }
    } catch (err) {
      console.error('[RequestLogger] 清理过期日志失败:', err.message);
    }
  };

  /** 优雅关闭 */
  const shutdown = () => {
    if (flushTimer) {
      clearInterval(flushTimer);
      flushTimer = null;
    }
    flush(); // 最后一次 flush
  };

  return {
    /**
     * Hono 中间件
     * 排除 /admin/* 静态页面请求
     */
    middleware: async (c, next) => {
      const start = performance.now();
      await next();
      const durationMs = Math.round(performance.now() - start);

      // 控制台结构化输出
      const timestamp = formatLocalTimestamp();
      console.log(`[${timestamp}] ${c.req.method} ${c.req.path} ${c.res.status} ${durationMs}ms`);

      // 排除 admin 页面请求
      if (c.req.path.startsWith('/admin')) return;

      // 投递到队列（满时丢弃）
      if (queue.length >= MAX_QUEUE_SIZE) {
        console.warn('[RequestLogger] 队列已满，丢弃 request_log');
        return;
      }

      const deviceId =
        c.req.header('x-holo-device-id') || c.req.header('x-device-id') || c.req.query('device_id') || null;

      queue.push({
        method: c.req.method,
        path: c.req.path,
        statusCode: c.res.status,
        durationMs,
        deviceId,
        userAgent: c.req.header('user-agent') || null,
        // 会话关联键（2026-10-19 前后端链路打通）：与 product_events / ai_call_logs 同列对齐
        sessionId: readSessionId(c),
      });
    },

    startFlushTimer,
    cleanupOld,
    shutdown,
  };
}
