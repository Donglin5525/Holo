import { AsyncLocalStorage } from "node:async_hooks";
import { createHash, randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";

// 仅后台维护共用此预算；主动聊天、分析、语音不占用。
export const BACKGROUND_PURPOSES = new Set([
  "personal_context_extraction", "personal_context_verification",
  "memory_observer", "memory_domain_extraction", "memory_cross_domain_fusion",
  "thought_organization", "thought_tag_convergence",
  "thought_organize_a", "thought_organize_r", "thought_organize_b",
  "thought_semantic_relate_v1", "thought_category_brief_v1",
  "thought_topic_name_v1", "thought_topic_summary_v1",
]);

export const BACKGROUND_PATHS = {
  "/v1/thoughts/organize": "thought_organize_a",
  "/v1/thoughts/semantic-relate": "thought_semantic_relate_v1",
  "/v1/thoughts/category-brief": "thought_category_brief_v1",
  "/v1/thoughts/topic-name": "thought_topic_name_v1",
  "/v1/thoughts/topic-summary": "thought_topic_summary_v1",
};

const hash = (value) => createHash("sha256").update(value).digest("hex");
const micro = (cny) => Math.ceil(cny * 1_000_000);
const validTokens = (value) => Number.isSafeInteger(value) && value >= 0;

export function backgroundSubject(deviceId, entitlement) {
  // 只采用服务端已验证的原始交易号；验收模式切换不重置预算。
  return hash(entitlement?.originalTransactionId
    ? `purchase:${entitlement.environment}:${entitlement.originalTransactionId}`
    : `device:${deviceId}`);
}

function periods(now) {
  const local = new Date(now + 8 * 3600_000).toISOString();
  const day = local.slice(0, 10);
  const month = local.slice(0, 7);
  const resetDay = Date.parse(`${day}T00:00:00+08:00`) + 86400_000;
  const [year, mon] = month.split("-").map(Number);
  const resetMonth = Date.UTC(year, mon, 1) - 8 * 3600_000;
  return { day, month, resetDay, resetMonth };
}

export function createBackgroundCostGuard(db, config, now = Date.now) {
  for (const key of ["dailyCNY", "monthlyCNY", "globalDailyCNY", "globalMonthlyCNY",
    "inputPerMillionCNY", "outputPerMillionCNY", "cachedPerMillionCNY", "maxInputBytes", "minBuild"]) {
    if (!Number.isFinite(config[key]) || config[key] <= 0) {
      throw new Error(`Invalid background cost guard setting: ${key}`);
    }
  }
  db.exec(`
    CREATE TABLE IF NOT EXISTS background_cost_calls (
      id TEXT PRIMARY KEY, subject TEXT NOT NULL, day TEXT NOT NULL, month TEXT NOT NULL,
      purpose TEXT NOT NULL, reserved_micro INTEGER NOT NULL, charged_micro INTEGER,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS background_cost_day ON background_cost_calls(day, subject);
    CREATE INDEX IF NOT EXISTS background_cost_month ON background_cost_calls(month, subject);
    CREATE TABLE IF NOT EXISTS background_brief_attempts (
      fingerprint TEXT PRIMARY KEY, retry_at INTEGER NOT NULL
    );
  `);
  // 只保留核账所需的近 90 天元数据；当前月预算与在途预留不会被清理。
  db.prepare("DELETE FROM background_cost_calls WHERE created_at < ?").run(now() - 90 * 86400_000);
  db.prepare("DELETE FROM background_brief_attempts WHERE retry_at <= ?").run(now());
  const scope = new AsyncLocalStorage();
  const sum = db.prepare(`SELECT COALESCE(SUM(COALESCE(charged_micro, reserved_micro)), 0) AS spent
    FROM background_cost_calls WHERE (day = @period OR month = @period)
    AND (@subject IS NULL OR subject = @subject)`);
  const insert = db.prepare(`INSERT INTO background_cost_calls
    (id, subject, day, month, purpose, reserved_micro, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`);
  const settle = db.prepare("UPDATE background_cost_calls SET charged_micro = ? WHERE id = ? AND charged_micro IS NULL");

  function limits(subject) {
    const p = periods(now());
    return [
      [subject, p.day, config.dailyCNY, p.resetDay],
      [subject, p.month, config.monthlyCNY, p.resetMonth],
      [null, p.day, config.globalDailyCNY, p.resetDay],
      [null, p.month, config.globalMonthlyCNY, p.resetMonth],
    ];
  }

  function checkBudget(subject, amount) {
    for (const [owner, period, cny, reset] of limits(subject)) {
      const spent = sum.get({ subject: owner, period }).spent;
      if (spent + amount > micro(cny)) {
        throw new GatewayError("BACKGROUND_BUDGET_EXCEEDED", "Background budget exceeded", 429, {
          resetAt: new Date(reset).toISOString(),
        });
      }
    }
  }

  const reserve = db.transaction((request) => {
    const subject = scope.getStore();
    if (!subject) throw new GatewayError("BACKGROUND_CONTEXT_REQUIRED", "Missing cost subject", 503);
    const bytes = Buffer.byteLength(JSON.stringify(request.messages ?? []));
    if (bytes > config.maxInputBytes) {
      throw new GatewayError("BACKGROUND_INPUT_TOO_LARGE", "Background context exceeds limit", 413);
    }
    if (!Number.isSafeInteger(request.maxTokens) || request.maxTokens <= 0) {
      throw new GatewayError("BACKGROUND_CONTEXT_REQUIRED", "Missing output limit", 503);
    }
    // UTF-8 字节数是文本 token 的保守上界；另留消息协议开销，不依赖中文字符估算。
    const reserved = Math.ceil((bytes + 64 * ((request.messages?.length ?? 0) + 1))
      * config.inputPerMillionCNY + request.maxTokens * config.outputPerMillionCNY);
    checkBudget(subject, reserved);
    const id = randomUUID();
    const p = periods(now());
    insert.run(id, subject, p.day, p.month, request.purpose, reserved, now());
    return id;
  });

  function finish(id, usage) {
    // 超时、断流或缺 usage 可能已经计费，保留完整预留；重启后也不能退回预算。
    if (!validTokens(usage?.prompt_tokens) || !validTokens(usage?.completion_tokens)) return;
    const cached = Math.min(usage.prompt_tokens, Math.max(0,
      Number(usage.prompt_cache_hit_tokens ?? usage.prompt_tokens_details?.cached_tokens) || 0));
    const charged = Math.ceil((usage.prompt_tokens - cached) * config.inputPerMillionCNY
      + cached * config.cachedPerMillionCNY + usage.completion_tokens * config.outputPerMillionCNY);
    // reasoning_tokens 属于 completion_tokens，不能重复收费。
    settle.run(charged, id);
  }

  function wrapProvider(provider) {
    const wrapped = { ...provider };
    for (const method of ["complete", "completeViaStream"]) {
      if (typeof provider[method] !== "function") continue;
      wrapped[method] = async (request) => {
        if (!BACKGROUND_PURPOSES.has(request.purpose)) return provider[method](request);
        const id = reserve.immediate(request);
        const result = await provider[method](request);
        finish(id, result?.usage);
        return result;
      };
    }
    if (typeof provider.stream === "function") {
      wrapped.stream = async function* (request) {
        if (!BACKGROUND_PURPOSES.has(request.purpose)) { yield* provider.stream(request); return; }
        const id = reserve.immediate(request);
        let pending = "";
        let usage;
        try {
          for await (const chunk of provider.stream(request)) {
            if (typeof chunk === "string") {
              pending += chunk;
              let newline;
              while ((newline = pending.indexOf("\n")) !== -1) {
                const line = pending.slice(0, newline).trim();
                pending = pending.slice(newline + 1);
                if (line.startsWith("data:")) {
                  try { usage = JSON.parse(line.slice(5)).usage ?? usage; } catch { /* 非 JSON 结束帧 */ }
                }
              }
            } else { usage = chunk?.usage ?? usage; }
            yield chunk;
          }
        } finally { finish(id, usage); }
      };
    }
    return wrapped;
  }

  const acquireBrief = db.transaction((fingerprint) => {
    const row = db.prepare("SELECT retry_at FROM background_brief_attempts WHERE fingerprint = ?").get(fingerprint);
    if (row?.retry_at > now()) {
      throw new GatewayError("BACKGROUND_RETRY_DEFERRED", "Unchanged brief is cooling down", 429, {
        resetAt: new Date(row.retry_at).toISOString(),
      });
    }
    // 进程崩溃也保持冷却，避免启动后立即重放。
    db.prepare("INSERT OR REPLACE INTO background_brief_attempts VALUES (?, ?)").run(fingerprint, now() + 86400_000);
  });

  return {
    run: (subject, action) => scope.run(subject, action),
    wrapProviders: (providers) => new Map([...providers].map(([name, provider]) => [name, wrapProvider(provider)])),
    checkIngress({ subject, userAgent, body }) {
      const build = /\bHolo\/(\d+)\b/i.exec(userAgent ?? "");
      if (build && Number(build[1]) < config.minBuild) {
        throw new GatewayError("BACKGROUND_CLIENT_UPDATE_REQUIRED", "Old background client blocked", 426);
      }
      if (Buffer.byteLength(JSON.stringify(body)) > config.maxInputBytes) {
        throw new GatewayError("BACKGROUND_INPUT_TOO_LARGE", "Background context exceeds limit", 413);
      }
      checkBudget(subject, 1);
    },
    async briefAttempt(key, action) {
      const fingerprint = hash(JSON.stringify([scope.getStore() ?? key[0], ...key.slice(1)]));
      acquireBrief.immediate(fingerprint);
      try {
        const result = await action();
        db.prepare("DELETE FROM background_brief_attempts WHERE fingerprint = ?").run(fingerprint);
        return result;
      } catch (error) {
        // 无效输出需等内容变化或 24 小时；上游暂时故障至少间隔 1 小时。
        const delay = error.code === "MODEL_OUTPUT_INVALID" || error.code === "EMPTY_MODEL_RESPONSE"
          ? 86400_000 : 3600_000;
        db.prepare("UPDATE background_brief_attempts SET retry_at = ? WHERE fingerprint = ?")
          .run(now() + delay, fingerprint);
        throw error;
      }
    },
  };
}
