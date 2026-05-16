import { randomUUID } from "node:crypto";

const DEFAULT_MAX_ENTRIES = 200;
const DEFAULT_MAX_DETAIL_CHARS = 20_000;
const LOG_RETENTION_DAYS = 30;
const HOT_CACHE_SIZE = 50;
const CONTENT_CAPTURE_MAX_CHARS = 2000;

// 基础脱敏规则（低误伤）
const REDACTION_PATTERNS = [
  { regex: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, replace: '[email]' },
  { regex: /1[3-9]\d{9}/g, replace: '[phone]' },
  { regex: /Bearer\s+[A-Za-z0-9\-._~+/]+=*/g, replace: 'Bearer [token]' },
  { regex: /(?:api[_-]?key|secret|token|password)\s*[:=]\s*["']?[A-Za-z0-9\-._~+/]{8,}/gi, replace: '[redacted]' },
  { regex: /\d{10,}/g, replace: '[number]' },
];

function redactText(text) {
  if (typeof text !== 'string') return text;
  let result = text;
  for (const { regex, replace } of REDACTION_PATTERNS) {
    result = result.replace(regex, replace);
  }
  return result;
}

export function createAdminLogStore(options = {}) {
  const maxEntries = positiveNumber(options.maxEntries, DEFAULT_MAX_ENTRIES);
  const maxDetailChars = positiveNumber(options.maxDetailChars, DEFAULT_MAX_DETAIL_CHARS);
  const db = options.db ?? null;
  const contentCaptureEnabled = options.contentCaptureEnabled ?? false;

  // 内存热缓存（最近 50 条完整记录，用于快速访问）
  const hotCache = [];

  // SQLite prepared statements（延迟初始化）
  let stmts = null;
  function getStmts() {
    if (stmts || !db) return stmts;
    stmts = {
      insertLog: db.prepare(`
        INSERT INTO ai_call_logs (device_id, call_type, purpose, provider, model, is_stream,
          prompt_type, prompt_version, request_summary, response_summary,
          redaction_applied, content_capture_enabled, asr_file_type, asr_result_length)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `),
      updateLog: db.prepare(`
        UPDATE ai_call_logs SET
          duration_ms = ?,
          error_message = ?,
          response_summary = ?,
          asr_result_length = ?
        WHERE rowid = ?
      `),
      listLogs: db.prepare(`
        SELECT id, device_id, call_type, purpose, provider, model, is_stream,
          duration_ms, error_message, asr_file_type, asr_result_length, created_at
        FROM ai_call_logs ORDER BY id DESC LIMIT ?
      `),
      getLog: db.prepare(`
        SELECT * FROM ai_call_logs WHERE id = ?
      `),
      cleanup: db.prepare(`
        DELETE FROM ai_call_logs WHERE created_at < datetime('now', '-${LOG_RETENTION_DAYS} days')
      `),
    };
    return stmts;
  }

  function startAiCall(input) {
    const now = new Date();
    const callType = input.request?.asr ? 'asr' : 'chat';
    const id = randomUUID();

    // 构建请求/响应摘要
    let requestSummary = null;
    if (contentCaptureEnabled && input.request && !input.request?.asr) {
      requestSummary = truncateText(
        redactText(JSON.stringify(input.request)),
        CONTENT_CAPTURE_MAX_CHARS
      );
    }

    const entry = {
      id,
      type: callType === 'asr' ? 'asr.transcriptions' : 'ai.chat.completions',
      status: 'pending',
      startedAt: now.toISOString(),
      finishedAt: null,
      durationMs: null,
      deviceId: input.deviceId,
      purpose: input.purpose,
      provider: input.provider,
      model: input.model,
      stream: input.stream,
      request: truncateDeep(input.request, maxDetailChars),
      response: null,
      error: null,
      asrFileType: input.asrFileType ?? null,
      asrResultLength: null,
    };

    // 内存缓存
    hotCache.unshift(entry);
    if (hotCache.length > HOT_CACHE_SIZE) hotCache.length = HOT_CACHE_SIZE;

    // SQLite 持久化
    const s = getStmts();
    if (s) {
      try {
        const result = s.insertLog.run(
          input.deviceId,
          callType,
          input.purpose ?? null,
          input.provider ?? null,
          input.model ?? null,
          input.stream ? 1 : 0,
          input.promptType ?? null,
          input.promptVersion ?? null,
          requestSummary,
          null, // response_summary — 调用完成后填充
          contentCaptureEnabled ? 1 : 0,
          contentCaptureEnabled ? 1 : 0,
          input.asrFileType ?? null,
          null  // asr_result_length — 调用完成后填充
        );
        entry._rowId = result.lastInsertRowid;
      } catch (err) {
        console.error('[AdminLogStore] SQLite insert 失败:', err.message);
      }
    }

    return entry.id;
  }

  function finishAiCall(id, result) {
    const entry = hotCache.find((item) => item.id === id);
    if (!entry) return;

    const now = new Date();
    entry.status = result.status;
    entry.finishedAt = now.toISOString();
    entry.durationMs = now.getTime() - Date.parse(entry.startedAt);
    entry.response = result.response == null ? null : truncateDeep(result.response, maxDetailChars);
    entry.error = result.error == null ? null : truncateDeep(result.error, maxDetailChars);

    if (result.asrResultLength != null) {
      entry.asrResultLength = result.asrResultLength;
    }

    // SQLite 更新
    const s = getStmts();
    if (s && entry._rowId) {
      try {
        let responseSummary = null;
        if (contentCaptureEnabled && result.response) {
          responseSummary = truncateText(
            redactText(JSON.stringify(result.response)),
            CONTENT_CAPTURE_MAX_CHARS
          );
        }
        s.updateLog.run(
          entry.durationMs,
          entry.error ? JSON.stringify(entry.error) : null,
          responseSummary,
          entry.asrResultLength ?? null,
          entry._rowId
        );
      } catch (err) {
        console.error('[AdminLogStore] SQLite update 失败:', err.message);
      }
    }
  }

  function list() {
    const results = [];
    const seenIds = new Set();

    // 先从热缓存获取最近记录
    for (const entry of hotCache) {
      seenIds.add(entry.id);
      results.push({
        id: entry.id,
        type: entry.type,
        status: entry.status,
        startedAt: entry.startedAt,
        finishedAt: entry.finishedAt,
        durationMs: entry.durationMs,
        deviceId: entry.deviceId,
        purpose: entry.purpose,
        provider: entry.provider,
        model: entry.model,
        stream: entry.stream,
        errorCode: entry.error?.code ?? null,
        asrFileType: entry.asrFileType ?? null,
        asrResultLength: entry.asrResultLength ?? null,
      });
    }

    // 再从 SQLite 补充热缓存没有的旧记录
    const s = getStmts();
    if (s) {
      try {
        const rows = s.listLogs.all(maxEntries);
        for (const row of rows) {
          const id = String(row.id);
          if (!seenIds.has(id)) {
            results.push({
              id,
              type: row.call_type === 'asr' ? 'asr.transcriptions' : 'ai.chat.completions',
              status: row.error_message ? 'error' : 'success',
              startedAt: row.created_at,
              finishedAt: row.created_at,
              durationMs: row.duration_ms,
              deviceId: row.device_id,
              purpose: row.purpose,
              provider: row.provider,
              model: row.model,
              stream: row.is_stream === 1,
              errorCode: row.error_message ?? null,
              asrFileType: row.asr_file_type ?? null,
              asrResultLength: row.asr_result_length ?? null,
            });
          }
        }
      } catch (err) {
        console.error('[AdminLogStore] SQLite list 失败:', err.message);
      }
    }

    return results;
  }

  function get(id) {
    // 先查热缓存
    const cached = hotCache.find((entry) => entry.id === id);
    if (cached) return cached;

    // 再查 SQLite
    const s = getStmts();
    if (s) {
      try {
        const row = s.getLog.get(Number(id) || 0);
        if (!row) return null;
        return {
          id: String(row.id),
          type: row.call_type === 'asr' ? 'asr.transcriptions' : 'ai.chat.completions',
          status: row.error_message ? 'error' : (row.duration_ms != null ? 'success' : 'pending'),
          startedAt: row.created_at,
          finishedAt: row.created_at,
          durationMs: row.duration_ms,
          deviceId: row.device_id,
          purpose: row.purpose,
          provider: row.provider,
          model: row.model,
          stream: row.is_stream === 1,
          request: row.request_summary ? JSON.parse(row.request_summary) : null,
          response: row.response_summary ? JSON.parse(row.response_summary) : null,
          error: row.error_message ? JSON.parse(row.error_message) : null,
          asrFileType: row.asr_file_type ?? null,
          asrResultLength: row.asr_result_length ?? null,
        };
      } catch (err) {
        console.error('[AdminLogStore] SQLite get 失败:', err.message);
      }
    }

    return null;
  }

  /** 启动时清理过期日志 */
  function cleanup() {
    const s = getStmts();
    if (s) {
      try {
        const result = s.cleanup.run();
        if (result.changes > 0) {
          console.log(`[AdminLogStore] 清理 ${result.changes} 条过期日志`);
        }
      } catch (err) {
        console.error('[AdminLogStore] 清理过期日志失败:', err.message);
      }
    }
  }

  // 启动时自动清理
  cleanup();

  return {
    maxDetailChars,
    startAiCall,
    finishAiCall,
    list,
    get,
    cleanup,
  };
}

export function truncateText(value, maxChars) {
  if (typeof value !== "string" || value.length <= maxChars) {
    return value;
  }

  return `${value.slice(0, maxChars)}\n...[truncated ${value.length - maxChars} chars]`;
}

function truncateDeep(value, maxChars) {
  if (typeof value === "string") {
    return truncateText(value, maxChars);
  }

  if (Array.isArray(value)) {
    return value.map((item) => truncateDeep(item, maxChars));
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nestedValue]) => [key, truncateDeep(nestedValue, maxChars)]),
    );
  }

  return value;
}

function positiveNumber(value, fallback) {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}
