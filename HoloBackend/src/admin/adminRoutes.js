import {
  assertAdminAuthorized,
  clearAdminSessionCookie,
  createAdminSessionCookie,
  isPasswordLoginEnabled,
  validateAdminLogin,
} from "./adminAuth.js";
import { renderAdminLoginPage, renderAdminLogsPage } from "./adminLogsPage.js";
import { renderAdminPromptEditorPage, renderAdminPromptsPage, renderAdminPromptHistoryPage } from "./adminPromptsPage.js";
import { renderAdminReportsPage } from "./adminReportsPage.js";
import { renderAdminFeatureFlagsPage } from "./adminFeatureFlagsPage.js";
import { renderAdminAiMetricsPage } from "./adminAiMetricsPage.js";
import { buildEntitlementOverview, renderAdminEntitlementsPage } from "./adminEntitlementsPage.js";
import { getPrompt, getPromptHistory, getPromptVersionEntry, listPrompts, resetPrompt, rollbackPrompt, updatePrompt } from "../prompts/promptRegistry.js";

// 每次调用返回新对象，避免 @hono/node-server 写入 Content-Length 时污染共享引用
function htmlHeaders() {
  return {
    "content-type": "text/html; charset=UTF-8",
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    "x-content-type-options": "nosniff",
  };
}

export function registerAdminRoutes(app, { config, logStore, runTestChat, getReleaseStatus, reportStore, featureFlagStore, db, acceptanceStore, entitlementResolver }) {
  app.get("/admin/login", (context) => {
    if (!isPasswordLoginEnabled(config)) {
      return adminJson(
        context,
        { error: { code: "ADMIN_PASSWORD_LOGIN_DISABLED", message: "Admin password login is disabled" } },
        404,
      );
    }

    return new Response(renderAdminLoginPage(), { headers: htmlHeaders() });
  });

  app.post("/admin/login", async (context) => {
    if (!isPasswordLoginEnabled(config)) {
      return adminJson(
        context,
        { error: { code: "ADMIN_PASSWORD_LOGIN_DISABLED", message: "Admin password login is disabled" } },
        404,
      );
    }

    const body = new URLSearchParams(await context.req.text());
    const ok = validateAdminLogin(config, {
      username: body.get("username") ?? "",
      password: body.get("password") ?? "",
    });
    if (!ok) {
      return new Response(renderAdminLoginPage({ error: "账号或密码不正确" }), {
        status: 401,
        headers: htmlHeaders(),
      });
    }

    return redirect("/admin/logs", {
      "set-cookie": createAdminSessionCookie(config),
    });
  });

  app.get("/admin/logout", () => {
    return redirect("/admin/login", {
      "set-cookie": clearAdminSessionCookie(),
    });
  });

  app.get("/admin", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    return redirect("/admin/logs");
  });

  // 服务端功能开关（P2 路由急停）：GET 列表 + POST 单个切换，修改即经订阅状态下发生效
  app.get("/admin/feature-flags", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }
    return new Response(
      renderAdminFeatureFlagsPage({
        flags: featureFlagStore.listWithMeta(),
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
      }),
      { headers: htmlHeaders() },
    );
  });

  app.post("/admin/feature-flags/:flag", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }
    const flag = context.req.param("flag");
    const body = new URLSearchParams(await context.req.text());
    const value = body.get("value") === "true";
    try {
      featureFlagStore.set(flag, value);
      console.log(`[Admin] feature flag ${flag} → ${value}`);
      return redirect(`/admin/feature-flags?notice=${encodeURIComponent(`已将 ${flag} 设为${value ? "开启" : "关闭"}`)}`);
    } catch (err) {
      return redirect(`/admin/feature-flags?error=${encodeURIComponent(err.message)}`);
    }
  });

  // AI 调用指标聚合（P2 仪表盘）：按 purpose 汇总 30 天 + 近 14 日趋势
  app.get("/admin/ai-metrics", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }
    return new Response(
      renderAdminAiMetricsPage(buildAiMetrics({ db })),
      { headers: htmlHeaders() },
    );
  });

  app.get("/admin/prompts", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    return new Response(
      renderAdminPromptsPage({
        prompts: listPrompts(),
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
      }),
      { headers: htmlHeaders() },
    );
  });

  app.get("/admin/prompts/:type", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    const prompt = getPrompt(context.req.param("type"));
    if (!prompt) {
      return redirect("/admin/prompts?error=prompt_not_found");
    }

    return new Response(
      renderAdminPromptEditorPage({
        prompt,
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
      }),
      { headers: htmlHeaders() },
    );
  });

  // Prompt 版本历史页面
  app.get("/admin/prompts/:type/history", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    const type = context.req.param("type");
    const history = getPromptHistory(type);
    const currentPrompt = getPrompt(type);

    return new Response(
      renderAdminPromptHistoryPage({
        type,
        history,
        currentVersion: currentPrompt?.version ?? 0,
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
      }),
      { headers: htmlHeaders() },
    );
  });

  // Prompt 版本 Diff 查看
  app.get("/admin/prompts/:type/diff/:version", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return adminJson(context, auth.body, auth.status);
    }

    const type = context.req.param("type");
    const version = Number(context.req.param("version"));
    const entry = getPromptVersionEntry(type, version);

    if (!entry) {
      return adminJson(context, { error: { code: "VERSION_NOT_FOUND" } }, 404);
    }

    return adminJson(context, {
      type,
      version: entry.version,
      content: entry.content,
      diff: entry.diff_from_prev,
      source: entry.source,
      createdAt: entry.created_at,
    });
  });

  // Prompt 回滚
  app.post("/admin/prompts/:type/rollback", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    const type = context.req.param("type");
    const body = new URLSearchParams(await context.req.text());
    const targetVersion = Number(body.get("version"));

    if (!targetVersion) {
      return redirect(`/admin/prompts/${encodeURIComponent(type)}/history?error=invalid_version`);
    }

    const result = rollbackPrompt(type, targetVersion);
    if (!result) {
      return redirect(`/admin/prompts/${encodeURIComponent(type)}/history?error=rollback_failed`);
    }

    return redirect(`/admin/prompts/${encodeURIComponent(type)}/history?notice=rolled_back_to_v${targetVersion}`);
  });

  app.post("/admin/prompts/:type", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    const type = context.req.param("type");
    const body = new URLSearchParams(await context.req.text());
    if (body.get("action") === "reset") {
      // resetPrompt 内部 SQLite 写失败会抛出（不再吞错），必须兜底成错误 redirect 而非 500
      try {
        const prompt = resetPrompt(type);
        if (!prompt) {
          return redirect("/admin/prompts?error=prompt_not_found");
        }
        return redirect(`/admin/prompts/${encodeURIComponent(type)}?notice=prompt_reset`);
      } catch (err) {
        console.error(`[Admin] reset prompt ${type} 失败:`, err.message);
        return redirect(`/admin/prompts/${encodeURIComponent(type)}?error=prompt_reset_failed`);
      }
    }

    const content = body.get("content") ?? "";
    if (!content.trim()) {
      return redirect(`/admin/prompts/${encodeURIComponent(type)}?error=content_required`);
    }

    const changeNote = (body.get("change_note") ?? "").trim() || null;
    let prompt;
    try {
      prompt = updatePrompt(type, content, changeNote);
    } catch (err) {
      console.error(`[Admin] save prompt ${type} 失败:`, err.message);
      return redirect(`/admin/prompts/${encodeURIComponent(type)}?error=prompt_save_failed`);
    }
    if (!prompt) {
      return redirect("/admin/prompts?error=prompt_not_found");
    }

    return redirect(`/admin/prompts/${encodeURIComponent(type)}?notice=prompt_saved`);
  });

  app.post("/admin/test-chat", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    const body = new URLSearchParams(await context.req.text());
    const message = (body.get("message") ?? "").trim();
    const purpose = normalizePurpose(body.get("purpose") ?? "chat", config);
    if (!message) {
      return redirect("/admin/logs?error=message_required");
    }

    try {
      await runTestChat({
        message: message.slice(0, 2_000),
        purpose,
      });
      return redirect("/admin/logs?notice=test_sent");
    } catch {
      return redirect("/admin/logs?error=test_failed");
    }
  });

  // Prompt 测试 — 使用当前编辑中的 Prompt 作为 system message
  app.post("/admin/prompts/:type/test", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return adminJson(context, { error: "未授权" }, 401);
    }

    const type = context.req.param("type");
    const prompt = getPrompt(type);
    if (!prompt) {
      return adminJson(context, { error: "Prompt 不存在" }, 404);
    }

    const body = new URLSearchParams(await context.req.text());
    const message = (body.get("message") ?? "").trim();
    const purpose = normalizePurpose(body.get("purpose") ?? "chat", config);
    if (!message) {
      return adminJson(context, { error: "消息内容不能为空" }, 400);
    }

    try {
      const result = await runTestChat({
        message: message.slice(0, 2_000),
        purpose,
        systemPrompt: prompt.content,
      });
      const responseText = result?.result?.choices?.[0]?.message?.content ?? JSON.stringify(result?.result ?? result, null, 2);
      return adminJson(context, { result: responseText });
    } catch (err) {
      return adminJson(context, { error: `测试失败: ${err.message}` }, 500);
    }
  });

  app.get("/v1/admin/logs", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return adminJson(context, auth.body, auth.status);
    }

    return adminJson(context, {
      logs: logStore.list(),
    });
  });

  app.get("/v1/admin/release/status", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return adminJson(context, auth.body, auth.status);
    }
    return adminJson(context, getReleaseStatus());
  });

  app.get("/v1/admin/reports", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return adminJson(context, auth.body, auth.status);
    }
    return adminJson(context, { reports: reportStore ? reportStore.list() : [] });
  });

  app.get("/v1/admin/logs/:id", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return adminJson(context, auth.body, auth.status);
    }

    const log = logStore.get(context.req.param("id"));
    if (!log) {
      return adminJson(
        context,
        { error: { code: "ADMIN_LOG_NOT_FOUND", message: "Log entry was not found" } },
        404,
      );
    }

    return adminJson(context, { log });
  });

  app.get("/admin/logs", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    return new Response(
      renderAdminLogsPage({
        logs: logStore.list().map((log) => logStore.get(log.id) ?? log),
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
        token: context.req.query("token") ?? "",
      }),
      { headers: htmlHeaders() },
    );
  });

  // 权益管理：运营手动给设备开/撤 Plus 覆盖（测试期补偿、种子用户），写入即经订阅状态下发生效
  app.get("/admin/entitlements", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }
    const { devices } = buildEntitlementOverview({ db, acceptanceStore, entitlementResolver });
    return new Response(
      renderAdminEntitlementsPage({
        overrides: acceptanceStore.list(),
        devices,
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
      }),
      { headers: htmlHeaders() },
    );
  });

  app.post("/admin/entitlements/override", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }
    const body = new URLSearchParams(await context.req.text());
    const deviceId = (body.get("deviceId") ?? "").trim();
    const tier = body.get("tier") ?? "plus";
    const days = body.get("days");
    try {
      if (!deviceId) throw new Error("设备 ID 不能为空");
      if (tier !== "free" && tier !== "plus") throw new Error("权益只能是 plus 或 free");
      let expiresAt = null;
      if (days !== null && days !== "") {
        const count = Number(days);
        if (!Number.isInteger(count) || count < 1 || count > 3650) {
          throw new Error("有效天数须为 1~3650 的整数");
        }
        expiresAt = new Date(Date.now() + count * 86400000).toISOString();
      }
      acceptanceStore.set(deviceId, tier, expiresAt);
      console.log(`[Admin] entitlement override ${deviceId} → ${tier}${expiresAt ? ` until ${expiresAt}` : " (永久)"}`);
      return redirect(`/admin/entitlements?notice=${encodeURIComponent(`已将 ${deviceId.slice(0, 8)}… 设为 ${tier}${expiresAt ? `，${days} 天后到期` : "（永久）"}`)}`);
    } catch (err) {
      return redirect(`/admin/entitlements?error=${encodeURIComponent(err.message)}`);
    }
  });

  app.post("/admin/entitlements/override/remove", async (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }
    const body = new URLSearchParams(await context.req.text());
    const deviceId = (body.get("deviceId") ?? "").trim();
    acceptanceStore.clear(deviceId);
    console.log(`[Admin] entitlement override removed for ${deviceId}`);
    return redirect(`/admin/entitlements?notice=${encodeURIComponent(`已撤销 ${deviceId.slice(0, 8)}… 的覆盖，回退到按购买记录判定`)}`);
  });

  app.get("/admin/reports", (context) => {
    const auth = assertAdminAuthorized(context, config);
    if (!auth.ok) {
      return redirect("/admin/login");
    }

    return new Response(
      renderAdminReportsPage({
        reports: reportStore ? reportStore.list() : [],
        notice: context.req.query("notice") ?? null,
        error: context.req.query("error") ?? null,
      }),
      { headers: htmlHeaders() },
    );
  });
}

function normalizePurpose(value, config) {
  if (value && Object.prototype.hasOwnProperty.call(config.routes, value)) {
    return value;
  }
  return "chat";
}

function adminJson(context, body, status = 200) {
  context.header("cache-control", "no-store");
  context.header("x-content-type-options", "nosniff");
  return context.json(body, status);
}

/** ai_call_logs 聚合：30 天按 purpose 汇总（p50/p90 在 JS 内算分位）+ 近 14 日趋势 */
function buildAiMetrics({ db }) {
  const rows = db
    .prepare(
      `SELECT purpose, duration_ms, error_message FROM ai_call_logs
       WHERE created_at >= datetime('now', '-30 days')`
    )
    .all();

  const byPurposeMap = new Map();
  for (const row of rows) {
    const purpose = row.purpose ?? "(unknown)";
    const entry = byPurposeMap.get(purpose) ?? { durations: [], errors: 0, calls: 0 };
    entry.calls += 1;
    if (row.error_message) {
      entry.errors += 1;
    } else if (row.duration_ms != null) {
      entry.durations.push(row.duration_ms);
    }
    byPurposeMap.set(purpose, entry);
  }

  const byPurpose = [...byPurposeMap.entries()]
    .map(([purpose, entry]) => {
      const sorted = [...entry.durations].sort((a, b) => a - b);
      const sum = sorted.reduce((acc, value) => acc + value, 0);
      return {
        purpose,
        calls: entry.calls,
        errors: entry.errors,
        errorRate: entry.calls > 0 ? ((entry.errors / entry.calls) * 100).toFixed(1) : "0.0",
        avgMs: sorted.length > 0 ? Math.round(sum / sorted.length) : null,
        p50Ms: sorted.length > 0 ? percentile(sorted, 0.5) : null,
        p90Ms: sorted.length > 0 ? percentile(sorted, 0.9) : null,
        maxMs: sorted.length > 0 ? sorted[sorted.length - 1] : null,
      };
    })
    .sort((a, b) => b.calls - a.calls);

  // 近 14 日趋势（UTC 日期）
  const dailyRows = db
    .prepare(
      `SELECT date(created_at) as date, purpose, COUNT(*) as calls,
              AVG(CASE WHEN error_message IS NULL THEN duration_ms END) as avg_ms,
              SUM(CASE WHEN error_message IS NOT NULL THEN 1 ELSE 0 END) as errors
       FROM ai_call_logs
       WHERE created_at >= datetime('now', '-14 days')
       GROUP BY date(created_at), purpose
       ORDER BY date(created_at) ASC`
    )
    .all();

  const purposes = [...new Set(dailyRows.map((row) => row.purpose ?? "(unknown)"))];
  const byDate = new Map();
  for (const row of dailyRows) {
    const purpose = row.purpose ?? "(unknown)";
    const day = byDate.get(row.date) ?? { date: row.date, cells: new Map() };
    day.cells.set(purpose, {
      calls: row.calls,
      avgMs: row.avg_ms != null ? Math.round(row.avg_ms) : null,
      errors: row.errors ?? 0,
    });
    byDate.set(row.date, day);
  }

  const dailyTrend = {
    headers: purposes,
    days: [...byDate.values()].map((day) => ({
      date: day.date,
      cells: purposes.map((purpose) => day.cells.get(purpose) ?? null),
    })),
  };

  return { byPurpose, dailyTrend };
}

function percentile(sortedValues, ratio) {
  if (sortedValues.length === 0) return null;
  const index = Math.min(sortedValues.length - 1, Math.floor(ratio * sortedValues.length));
  return sortedValues[index];
}

function redirect(location, headers = {}) {
  return new Response(null, {
    status: 302,
    headers: {
      location,
      "cache-control": "no-store",
      ...headers,
    },
  });
}
