import { escapeHtml } from "./adminLogsPage.js";
import { formatLocalTimestamp } from "../time.js";

/**
 * AI 内容举报管理页（App Store Guideline 1.2）
 * 供后台人工审核用户举报的 AI 生成内容。
 */
export function renderAdminReportsPage({ reports, notice = null, error = null }) {
  const cards = reports
    .map((report) => {
      const snapshot = report.content_snapshot
        ? `<section class="snippet"><h2>内容快照</h2><pre>${escapeHtml(report.content_snapshot)}</pre></section>`
        : "";
      const detail = report.detail
        ? `<section class="snippet"><h2>补充说明</h2><pre>${escapeHtml(report.detail)}</pre></section>`
        : "";
      return `
        <article class="log">
          <header>
            <strong>${escapeHtml(report.reason)}</strong>
            <span class="status ${escapeHtml(report.status)}">${escapeHtml(report.status)}</span>
          </header>
          <dl>
            <div><dt>提交时间</dt><dd>${escapeHtml(formatLocalTimestamp(report.created_at))}</dd></div>
            <div><dt>举报 ID</dt><dd>${escapeHtml(report.id)}</dd></div>
            <div><dt>消息 ID</dt><dd>${escapeHtml(report.message_id)}</dd></div>
            <div><dt>设备</dt><dd>${escapeHtml(report.device_id)}</dd></div>
          </dl>
          ${detail}
          ${snapshot}
        </article>
      `;
    })
    .join("");

  const empty = reports.length === 0
    ? `<p>暂无举报记录。</p>`
    : "";

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Holo Admin · 内容举报</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 24px; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1040px; margin: 0 auto; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 6px; font-size: 24px; }
    p { margin: 0 0 18px; color: #52606d; }
    .log { background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; padding: 16px; margin: 12px 0; }
    header { display: flex; justify-content: space-between; gap: 12px; align-items: center; }
    h2 { font-size: 13px; margin: 0 0 6px; color: #52606d; }
    .status { border-radius: 999px; padding: 3px 9px; font-size: 12px; background: #e4e7eb; }
    dl { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px 18px; margin: 14px 0; }
    dt { font-size: 12px; color: #7b8794; }
    dd { margin: 3px 0 0; overflow-wrap: anywhere; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0 0 12px; padding: 10px 12px; border-radius: 8px; background: #f0f4f8; color: #1f2933; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
    a { color: #0967d2; text-decoration: none; }
    a:hover { text-decoration: underline; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      p { color: #9ca3af; }
      .log { background: #1f2937; border-color: #374151; }
      dt, h2 { color: #9ca3af; }
      pre { background: #111827; color: #e5e7eb; }
      a, nav a { color: #93c5fd; }
      nav a.active { background: #1e3a8a; color: #bfdbfe; }
    }
  </style>
</head>
<body>
  <main>
    <nav>
      <a href="/admin/logs">Logs</a>
      <a href="/admin/prompts">Prompts</a>
      <a class="active" href="/admin/reports">举报</a>
      <a href="/admin/ai-metrics">AI 指标</a>
      <a href="/admin/feature-flags">功能开关</a>
      <a href="/admin/entitlements">权益管理</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>AI 内容举报</h1>
    <p>用户举报的 AI 生成内容，时间按 UTC+8 展示。状态默认 pending，人工处理后由数据库直接更新。</p>
    ${renderNotice(notice, error)}
    ${empty}
    ${cards}
  </main>
</body>
</html>`;
}

function renderNotice(notice, error) {
  if (notice) return `<div class="notice" style="padding:10px 12px;border-radius:8px;background:#d3f9d8;color:#1b5e20;">${escapeHtml(notice)}</div>`;
  if (error) return `<div class="notice" style="padding:10px 12px;border-radius:8px;background:#ffdddd;color:#8a1c1c;">${escapeHtml(error)}</div>`;
  return "";
}
