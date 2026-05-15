export function renderAdminLogsPage({ logs, token, notice = null, error = null }) {
  const rows = logs
    .map((log) => {
      const detailHref = `/v1/admin/logs/${encodeURIComponent(log.id)}?token=${encodeURIComponent(token)}`;
      const userText = extractUserText(log);
      const assistantText = extractAssistantText(log);
      return `
        <article class="log">
          <header>
            <strong>${escapeHtml(log.purpose)} / ${escapeHtml(log.model)}</strong>
            <span class="status ${escapeHtml(log.status)}">${escapeHtml(log.status)}</span>
          </header>
          <dl>
            <div><dt>Time</dt><dd>${escapeHtml(log.startedAt)}</dd></div>
            <div><dt>Duration</dt><dd>${log.durationMs == null ? "pending" : `${log.durationMs}ms`}</dd></div>
            <div><dt>Provider</dt><dd>${escapeHtml(log.provider)}</dd></div>
            <div><dt>Device</dt><dd>${escapeHtml(log.deviceId)}</dd></div>
            <div><dt>Stream</dt><dd>${log.stream ? "true" : "false"}</dd></div>
            <div><dt>Error</dt><dd>${escapeHtml(log.errorCode ?? log.error?.code ?? "-")}</dd></div>
          </dl>
          <section class="snippet">
            <h2>用户输入</h2>
            <pre>${escapeHtml(userText || "-")}</pre>
          </section>
          <section class="snippet">
            <h2>模型输出</h2>
            <pre>${escapeHtml(assistantText || log.error?.message || "-")}</pre>
          </section>
          <details>
            <summary>查看完整请求 / 响应</summary>
            <section class="snippet">
              <h2>Request JSON</h2>
              <pre>${escapeHtml(JSON.stringify(log.request ?? null, null, 2))}</pre>
            </section>
            <section class="snippet">
              <h2>Response JSON</h2>
              <pre>${escapeHtml(JSON.stringify(log.response ?? log.error ?? null, null, 2))}</pre>
            </section>
          </details>
          <a href="${detailHref}">Open JSON detail</a>
        </article>
      `;
    })
    .join("");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="10">
  <title>Holo Admin Logs</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 24px; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1040px; margin: 0 auto; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 6px; font-size: 24px; letter-spacing: 0; }
    p { margin: 0 0 18px; color: #52606d; }
    .toolbar { display: flex; justify-content: space-between; align-items: center; gap: 16px; margin-bottom: 16px; }
    .toolbar p { margin: 0; }
    .panel { background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; padding: 16px; margin: 16px 0; }
    .panel h2 { margin: 0 0 12px; font-size: 16px; letter-spacing: 0; }
    form { display: grid; gap: 12px; }
    label { display: grid; gap: 6px; font-size: 13px; color: #52606d; }
    textarea, select { border: 1px solid #bcccdc; border-radius: 8px; padding: 10px 12px; font: inherit; background: #fff; color: #1f2933; }
    textarea { min-height: 72px; resize: vertical; }
    button { width: fit-content; height: 38px; border: 0; border-radius: 8px; padding: 0 14px; background: #0967d2; color: #fff; font: inherit; cursor: pointer; }
    .notice { padding: 10px 12px; border-radius: 8px; background: #d3f9d8; color: #1b5e20; }
    .error-message { padding: 10px 12px; border-radius: 8px; background: #ffdddd; color: #8a1c1c; }
    .log { background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; padding: 16px; margin: 12px 0; }
    header { display: flex; justify-content: space-between; gap: 12px; align-items: center; }
    h2 { font-size: 13px; margin: 0 0 6px; color: #52606d; letter-spacing: 0; }
    .status { border-radius: 999px; padding: 3px 9px; font-size: 12px; background: #e4e7eb; }
    .status.success { background: #d3f9d8; color: #1b5e20; }
    .status.error { background: #ffdddd; color: #8a1c1c; }
    dl { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px 18px; margin: 14px 0; }
    dt { font-size: 12px; color: #7b8794; }
    dd { margin: 3px 0 0; overflow-wrap: anywhere; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0 0 12px; padding: 10px 12px; border-radius: 8px; background: #f0f4f8; color: #1f2933; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
    summary { cursor: pointer; color: #0967d2; margin: 8px 0 12px; }
    a { color: #0967d2; text-decoration: none; }
    .logout { margin-left: 10px; }
    a:hover { text-decoration: underline; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      p { color: #9ca3af; }
      .panel, .log { background: #1f2937; border-color: #374151; }
      dt { color: #9ca3af; }
      h2, label { color: #9ca3af; }
      textarea, select { background: #111827; border-color: #4b5563; color: #e5e7eb; }
      pre { background: #111827; color: #e5e7eb; }
      a, nav a, summary { color: #93c5fd; }
      nav a.active { background: #1e3a8a; color: #bfdbfe; }
    }
  </style>
</head>
<body>
  <main>
    <nav>
      <a class="active" href="/admin/logs">Logs</a>
      <a href="/admin/prompts">Prompts</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>Holo Admin Logs</h1>
    <div class="toolbar">
      <p>最近 AI 调用详情日志。页面每 10 秒自动刷新，日志仅保存在当前后端进程内存中。</p>
    </div>
    ${renderNotice(notice, error)}
    <section class="panel">
      <h2>测试 AI 调用</h2>
      <form method="post" action="/admin/test-chat">
        <label>
          Purpose
          <select name="purpose">
            <option value="chat">chat</option>
            <option value="intent">intent</option>
            <option value="insight">insight</option>
          </select>
        </label>
        <label>
          Message
          <textarea name="message" maxlength="2000" required>午饭35</textarea>
        </label>
        <button type="submit">发送测试调用</button>
      </form>
    </section>
    ${rows || '<section class="panel"><p>暂无日志。可以先发送一条测试调用，或在 App 里触发一次 AI 请求。</p></section>'}
  </main>
</body>
</html>`;
}

export function renderAdminLoginPage({ error = null } = {}) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Holo Admin Login</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f7f7f5; color: #1f2933; }
    main { width: min(360px, calc(100vw - 40px)); }
    h1 { margin: 0 0 18px; font-size: 24px; letter-spacing: 0; }
    form { display: grid; gap: 14px; }
    label { display: grid; gap: 6px; font-size: 14px; color: #52606d; }
    input { height: 42px; border: 1px solid #bcccdc; border-radius: 8px; padding: 0 12px; font: inherit; background: #fff; color: #1f2933; }
    button { height: 42px; border: 0; border-radius: 8px; background: #0967d2; color: #fff; font: inherit; cursor: pointer; }
    .error { margin: 0 0 14px; color: #b91c1c; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      label { color: #9ca3af; }
      input { background: #1f2937; border-color: #4b5563; color: #e5e7eb; }
    }
  </style>
</head>
<body>
  <main>
    <h1>Holo Admin</h1>
    ${error ? `<p class="error">${escapeHtml(error)}</p>` : ""}
    <form method="post" action="/admin/login">
      <label>
        账号
        <input name="username" autocomplete="username" required>
      </label>
      <label>
        密码
        <input name="password" type="password" autocomplete="current-password" required>
      </label>
      <button type="submit">登录</button>
    </form>
  </main>
</body>
</html>`;
}

export function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderNotice(notice, error) {
  if (error === "message_required") {
    return '<p class="error-message">请输入测试消息。</p>';
  }

  if (error === "test_failed") {
    return '<p class="error-message">测试调用失败，已记录错误日志。请检查模型配置或 API Key。</p>';
  }

  if (notice === "test_sent") {
    return '<p class="notice">测试调用已发送，最新日志在下方。</p>';
  }

  return "";
}

function extractUserText(log) {
  return log.request?.messages?.findLast((message) => message.role === "user")?.content ?? "";
}

function extractAssistantText(log) {
  const messageContent = log.response?.choices?.[0]?.message?.content;
  if (messageContent) {
    return messageContent;
  }

  return log.response?.text ?? "";
}
