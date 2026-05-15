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
          <td><a href="/admin/prompts/${encodeURIComponent(prompt.type)}/history">历史</a></td>
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
              <th>操作</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `,
  });
}

export function renderAdminPromptEditorPage({ prompt, notice = null, error = null, testResult = null, testError = null }) {
  return renderAdminShell({
    title: `编辑 Prompt：${prompt.type}`,
    active: "prompts",
    body: `
      ${renderNotice(notice, error)}
      <section class="panel meta">
        <div><strong>版本</strong><span>${escapeHtml(prompt.version)}</span></div>
        <div><strong>来源</strong><span>${escapeHtml(prompt.source)}</span></div>
        <div><strong>更新时间</strong><span>${escapeHtml(prompt.updatedAt ?? "-")}</span></div>
        <div><a href="/admin/prompts/${encodeURIComponent(prompt.type)}/history">查看版本历史</a></div>
      </section>
      <section class="panel">
        <form method="post" action="/admin/prompts/${encodeURIComponent(prompt.type)}">
          <label>
            Prompt 内容
            <textarea class="prompt-editor" name="content" required>${escapeHtml(prompt.content)}</textarea>
          </label>
          <label style="margin-top:12px">
            变更说明（可选）
            <textarea name="change_note" rows="2" placeholder="描述本次修改的原因或内容，方便日后回顾">${escapeHtml(prompt.lastChangeNote ?? "")}</textarea>
          </label>
          <div class="actions">
            <button type="submit">保存 Prompt</button>
            <button type="submit" name="action" value="reset" class="secondary">恢复默认</button>
          </div>
        </form>
      </section>
      <section class="panel">
        <h2 style="font-size:16px;margin:0 0 12px">测试 Prompt</h2>
        <form id="prompt-test-form">
          <label>
            Purpose
            <select name="purpose">
              <option value="chat">chat</option>
              <option value="intent">intent</option>
              <option value="insight">insight</option>
            </select>
          </label>
          <label style="margin-top:8px">
            消息内容
            <textarea name="message" rows="3" placeholder="输入测试消息" required></textarea>
          </label>
          <div class="actions">
            <button type="submit">发送测试</button>
          </div>
        </form>
        ${testError ? `<p class="error-message" style="margin-top:12px">${escapeHtml(testError)}</p>` : ''}
        ${testResult ? `<details open style="margin-top:12px"><summary>测试结果</summary><pre class="diff-view">${escapeHtml(testResult)}</pre></details>` : ''}
        <script>
        (function() {
          var form = document.getElementById('prompt-test-form');
          form.addEventListener('submit', function(e) {
            e.preventDefault();
            var data = new FormData(form);
            var resultArea = form.querySelector('details, .error-message');
            var body = new URLSearchParams({
              purpose: data.get('purpose'),
              message: data.get('message')
            });
            fetch('/admin/prompts/${encodeURIComponent(prompt.type)}/test', {
              method: 'POST',
              headers: { 'content-type': 'application/x-www-form-urlencoded' },
              body: body.toString()
            }).then(function(r) {
              return r.json();
            }).then(function(json) {
              var container = document.getElementById('test-result');
              if (!container) {
                container = document.createElement('div');
                container.id = 'test-result';
                form.parentNode.appendChild(container);
              }
              if (json.error) {
                container.innerHTML = '<p class="error-message" style="margin-top:12px">' + json.error + '</p>';
              } else {
                container.innerHTML = '<details open style="margin-top:12px"><summary>测试结果</summary><pre class="diff-view">' + json.result.replace(/&/g,'&amp;').replace(/</g,'&lt;') + '</pre></details>';
              }
            }).catch(function(err) {
              var container = document.getElementById('test-result');
              if (!container) {
                container = document.createElement('div');
                container.id = 'test-result';
                form.parentNode.appendChild(container);
              }
              container.innerHTML = '<p class="error-message" style="margin-top:12px">请求失败: ' + err.message + '</p>';
            });
          });
        })();
        </script>
      </section>
    `,
  });
}

/** Prompt 版本历史页面 — 版本列表 + Diff 视图 + 回滚按钮 */
export function renderAdminPromptHistoryPage({ type, history, currentVersion, notice = null, error = null }) {
  const versionRows = history.map((entry) => {
    const isCurrent = entry.version === currentVersion;
    const diffSummary = entry.diff_from_prev
      ? entry.diff_from_prev.split('\n').filter((l) => l.startsWith('+') || l.startsWith('-')).slice(0, 3).join('\n')
      : '(初始版本)';

    return `
      <tr>
        <td><strong>v${escapeHtml(entry.version)}</strong>${isCurrent ? ' <span class="current-badge">当前</span>' : ''}</td>
        <td>${escapeHtml(entry.source)}</td>
        <td>${escapeHtml(entry.created_at ?? "-")}</td>
        <td>${escapeHtml(entry.content_length)} 字</td>
        <td>${entry.change_note ? escapeHtml(entry.change_note) : '<span style="color:#9ca3af">-</span>'}</td>
        <td>
          <details>
            <summary>查看 Diff</summary>
            <pre class="diff-view">${escapeHtml(entry.diff_from_prev ?? '(无变更)')}</pre>
          </details>
        </td>
        <td>
          ${isCurrent
            ? '<span class="secondary" style="opacity:0.5">-</span>'
            : `<form method="post" action="/admin/prompts/${encodeURIComponent(type)}/rollback" style="display:inline"
                 onsubmit="return confirm('确认回滚到 v${escapeHtml(entry.version)}？这会创建一个新版本。')">
                 <input type="hidden" name="version" value="${escapeHtml(entry.version)}">
                 <button type="submit" class="secondary small">回滚</button>
               </form>`
          }
        </td>
      </tr>
    `;
  }).join('');

  return renderAdminShell({
    title: `版本历史：${type}`,
    active: "prompts",
    body: `
      ${renderNotice(notice, error)}
      <section class="panel">
        <div style="margin-bottom:12px">
          <a href="/admin/prompts/${encodeURIComponent(type)}">&larr; 返回编辑器</a>
        </div>
        <table>
          <thead>
            <tr>
              <th>版本</th>
              <th>来源</th>
              <th>时间</th>
              <th>长度</th>
              <th>变更说明</th>
              <th>Diff</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>${versionRows}</tbody>
        </table>
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
    button.small { height: 28px; font-size: 12px; padding: 0 10px; }
    button.secondary { background: #e4e7eb; color: #1f2933; }
    .actions { display: flex; gap: 10px; margin-top: 12px; }
    .meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
    .meta div { display: grid; gap: 4px; }
    .meta strong { font-size: 12px; color: #52606d; }
    .notice { padding: 10px 12px; border-radius: 8px; background: #d3f9d8; color: #1b5e20; }
    .error-message { padding: 10px 12px; border-radius: 8px; background: #ffdddd; color: #8a1c1c; }
    .current-badge { display: inline-block; font-size: 11px; background: #dbeafe; color: #1d4ed8; padding: 2px 6px; border-radius: 4px; }
    .diff-view { max-height: 300px; overflow: auto; font-size: 12px; white-space: pre-wrap; background: #f8f9fa; padding: 8px; border-radius: 4px; margin-top: 4px; }
    details summary { cursor: pointer; color: #0967d2; font-size: 13px; }
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
      .current-badge { background: #1e3a8a; color: #bfdbfe; }
      .diff-view { background: #0d1117; }
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

  if (error === "rollback_failed") {
    return '<p class="error-message">回滚失败，目标版本不存在。</p>';
  }

  if (error === "invalid_version") {
    return '<p class="error-message">无效的版本号。</p>';
  }

  if (notice === "prompt_saved") {
    return '<p class="notice">Prompt 已保存，下一次后端调用会使用新版本。</p>';
  }

  if (notice === "prompt_reset") {
    return '<p class="notice">Prompt 已恢复默认版本。</p>';
  }

  if (notice?.startsWith("rolled_back_to_v")) {
    return `<p class="notice">已回滚到 ${escapeHtml(notice.replace("rolled_back_to_", ""))}，新版本已创建。</p>`;
  }

  return "";
}
