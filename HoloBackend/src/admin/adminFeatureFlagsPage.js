import { escapeHtml } from "./adminLogsPage.js";

/**
 * 服务端功能开关页（P2 路由急停）。
 * 开关值经 /v1/subscription/status 下发客户端；修改即生效，无需发版。
 */
export function renderAdminFeatureFlagsPage({ flags, notice = null, error = null }) {
  const rows = flags
    .map(
      (flag) => `
      <tr>
        <td><code>${escapeHtml(flag.flag)}</code></td>
        <td>${flag.defaultValue ? "开" : "关"}</td>
        <td>
          <form method="post" action="/admin/feature-flags/${encodeURIComponent(flag.flag)}">
            <button type="submit" name="value" value="${flag.enabled ? "false" : "true"}" class="toggle ${flag.enabled ? "on" : "off"}">
              ${flag.enabled ? "已开启 · 点击关闭" : "已关闭 · 点击开启"}
            </button>
          </form>
        </td>
        <td>${flag.overridden ? "已覆盖默认" : "默认值"}</td>
      </tr>`
    )
    .join("");

  const noticeHtml = notice
    ? `<p class="notice ok">${escapeHtml(notice)}</p>`
    : error
      ? `<p class="notice err">${escapeHtml(error)}</p>`
      : "";

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Holo Admin · 功能开关</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 24px; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1040px; margin: 0 auto; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; flex-wrap: wrap; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 6px; font-size: 24px; }
    p { margin: 0 0 18px; color: #52606d; }
    table { border-collapse: collapse; width: 100%; background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; }
    th, td { text-align: left; padding: 12px 14px; border-bottom: 1px solid #e4e7eb; font-size: 14px; }
    th { color: #52606d; font-size: 12px; }
    code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .toggle { border: 1px solid #d9e2ec; background: #f0f4f8; border-radius: 999px; padding: 6px 14px; cursor: pointer; font-size: 13px; }
    .toggle.on { background: #dcfce7; border-color: #86efac; color: #166534; }
    .toggle.off { background: #fee2e2; border-color: #fca5a5; color: #991b1b; }
    .notice { border-radius: 8px; padding: 10px 14px; margin-bottom: 16px; }
    .notice.ok { background: #dcfce7; color: #166534; }
    .notice.err { background: #fee2e2; color: #991b1b; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      p, th { color: #9ca3af; }
      table { background: #1f2937; border-color: #374151; }
      th, td { border-bottom-color: #374151; }
      .toggle { background: #111827; border-color: #374151; color: #e5e7eb; }
      .toggle.on { background: #052e16; border-color: #166534; color: #86efac; }
      .toggle.off { background: #450a0a; border-color: #991b1b; color: #fca5a5; }
      nav a { color: #93c5fd; }
      nav a.active { background: #1e3a8a; color: #bfdbfe; }
    }
  </style>
</head>
<body>
  <main>
    <nav>
      <a href="/admin/logs">Logs</a>
      <a href="/admin/prompts">Prompts</a>
      <a href="/admin/reports">举报</a>
      <a href="/admin/ai-metrics">AI 指标</a>
      <a class="active" href="/admin/feature-flags">功能开关</a>
      <a href="/admin/entitlements">权益管理</a>
      <a href="/admin/feedback">用户反馈</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>功能开关</h1>
    <p>服务端可控的客户端行为开关，经订阅状态接口下发。修改即生效（客户端下次刷新时应用），无需发版。默认值在 featureFlagStore.js 的 DEFAULT_FLAGS 声明。</p>
    ${noticeHtml}
    <table>
      <thead>
        <tr><th>开关</th><th>出厂默认</th><th>当前值</th><th>状态</th></tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  </main>
</body>
</html>`;
}
