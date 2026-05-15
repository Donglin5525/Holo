import { escapeHtml } from "./adminLogsPage.js";

export function renderAdminPromptsPage({ prompts, notice = null, error = null }) {
  const rows = prompts
    .map(
      (prompt) => `
        <tr>
          <td><a href="/admin/prompts/${encodeURIComponent(prompt.type)}">${escapeHtml(prompt.type)}</a></td>
          <td>${escapeHtml(prompt.version)}</td>
          <td>${escapeHtml(prompt.source)}</td>
          <td>${escapeHtml(prompt.contentLength)}</td>
          <td>${escapeHtml(prompt.updatedAt ?? "-")}</td>
        </tr>
      `,
    )
    .join("");

  return renderAdminShell({
    title: "Prompt 管理",
    active: "prompts",
    body: `
      ${renderNotice(notice, error)}
      <section class="panel">
        <table>
          <thead>
            <tr>
              <th>类型</th>
              <th>版本</th>
              <th>来源</th>
              <th>长度</th>
              <th>更新时间</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `,
  });
}

export function renderAdminPromptEditorPage({ prompt, notice = null, error = null }) {
  return renderAdminShell({
    title: `编辑 Prompt：${prompt.type}`,
    active: "prompts",
    body: `
      ${renderNotice(notice, error)}
      <section class="panel meta">
        <div><strong>版本</strong><span>${escapeHtml(prompt.version)}</span></div>
        <div><strong>来源</strong><span>${escapeHtml(prompt.source)}</span></div>
        <div><strong>更新时间</strong><span>${escapeHtml(prompt.updatedAt ?? "-")}</span></div>
      </section>
      <section class="panel">
        <form method="post" action="/admin/prompts/${encodeURIComponent(prompt.type)}">
          <label>
            Prompt 内容
            <textarea class="prompt-editor" name="content" required>${escapeHtml(prompt.content)}</textarea>
          </label>
          <div class="actions">
            <button type="submit">保存 Prompt</button>
            <button type="submit" name="action" value="reset" class="secondary">恢复默认</button>
          </div>
        </form>
      </section>
    `,
  });
}

export function renderAdminShell({ title, active, body }) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} - Holo Admin</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1180px; margin: 0 auto; padding: 24px; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 16px; font-size: 24px; letter-spacing: 0; }
    .panel { background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; padding: 16px; margin: 16px 0; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; border-bottom: 1px solid #e4e7eb; padding: 10px; vertical-align: top; }
    th { font-size: 12px; color: #52606d; }
    label { display: grid; gap: 8px; color: #52606d; }
    textarea { width: 100%; box-sizing: border-box; border: 1px solid #bcccdc; border-radius: 8px; padding: 12px; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; background: #fff; color: #1f2933; }
    .prompt-editor { min-height: 62vh; resize: vertical; }
    button { height: 38px; border: 0; border-radius: 8px; padding: 0 14px; background: #0967d2; color: #fff; font: inherit; cursor: pointer; }
    button.secondary { background: #e4e7eb; color: #1f2933; }
    .actions { display: flex; gap: 10px; margin-top: 12px; }
    .meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
    .meta div { display: grid; gap: 4px; }
    .meta strong { font-size: 12px; color: #52606d; }
    .notice { padding: 10px 12px; border-radius: 8px; background: #d3f9d8; color: #1b5e20; }
    .error-message { padding: 10px 12px; border-radius: 8px; background: #ffdddd; color: #8a1c1c; }
    a { color: #0967d2; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      .panel { background: #1f2937; border-color: #374151; }
      th, .meta strong, label { color: #9ca3af; }
      th, td { border-color: #374151; }
      textarea { background: #111827; border-color: #4b5563; color: #e5e7eb; }
      button.secondary { background: #374151; color: #e5e7eb; }
      nav a.active { background: #1e3a8a; color: #bfdbfe; }
      a, nav a { color: #93c5fd; }
    }
  </style>
</head>
<body>
  <main>
    <nav>
      <a class="${active === "logs" ? "active" : ""}" href="/admin/logs">Logs</a>
      <a class="${active === "prompts" ? "active" : ""}" href="/admin/prompts">Prompts</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>${escapeHtml(title)}</h1>
    ${body}
  </main>
</body>
</html>`;
}

function renderNotice(notice, error) {
  if (error === "prompt_not_found") {
    return '<p class="error-message">Prompt 不存在。</p>';
  }

  if (error === "content_required") {
    return '<p class="error-message">Prompt 内容不能为空。</p>';
  }

  if (notice === "prompt_saved") {
    return '<p class="notice">Prompt 已保存，下一次后端调用会使用新版本。</p>';
  }

  if (notice === "prompt_reset") {
    return '<p class="notice">Prompt 已恢复默认版本。</p>';
  }

  return "";
}
