import {
  assertAdminAuthorized,
  clearAdminSessionCookie,
  createAdminSessionCookie,
  isPasswordLoginEnabled,
  validateAdminLogin,
} from "./adminAuth.js";
import { renderAdminLoginPage, renderAdminLogsPage } from "./adminLogsPage.js";
import { renderAdminPromptEditorPage, renderAdminPromptsPage, renderAdminPromptHistoryPage } from "./adminPromptsPage.js";
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

export function registerAdminRoutes(app, { config, logStore, runTestChat }) {
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
      const prompt = resetPrompt(type);
      if (!prompt) {
        return redirect("/admin/prompts?error=prompt_not_found");
      }
      return redirect(`/admin/prompts/${encodeURIComponent(type)}?notice=prompt_reset`);
    }

    const content = body.get("content") ?? "";
    if (!content.trim()) {
      return redirect(`/admin/prompts/${encodeURIComponent(type)}?error=content_required`);
    }

    const changeNote = (body.get("change_note") ?? "").trim() || null;
    const prompt = updatePrompt(type, content, changeNote);
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
    const purpose = normalizePurpose(body.get("purpose") ?? "chat");
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
    const purpose = normalizePurpose(body.get("purpose") ?? "chat");
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
}

function normalizePurpose(value) {
  if (["chat", "intent", "insight"].includes(value)) {
    return value;
  }

  return "chat";
}

function adminJson(context, body, status = 200) {
  context.header("cache-control", "no-store");
  context.header("x-content-type-options", "nosniff");
  return context.json(body, status);
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
