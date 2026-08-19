import { escapeHtml } from "./adminLogsPage.js";

/**
 * AI 调用指标聚合页（P2 仪表盘）。
 * 按 purpose 聚合 ai_call_logs（30 天保留）：调用量 / 平均时延 / p50 / p90 / 错误率 + 最近 14 日趋势。
 */

function percentile(sortedValues, ratio) {
  if (sortedValues.length === 0) return null;
  const index = Math.min(sortedValues.length - 1, Math.floor(ratio * sortedValues.length));
  return sortedValues[index];
}

export function renderAdminAiMetricsPage({ byPurpose, dailyTrend }) {
  const purposeRows = byPurpose
    .map(
      (row) => `
      <tr>
        <td><code>${escapeHtml(row.purpose)}</code></td>
        <td>${row.calls}</td>
        <td>${row.errors}（${row.errorRate}%）</td>
        <td>${row.avgMs ?? "—"} ms</td>
        <td>${row.p50Ms ?? "—"} ms</td>
        <td>${row.p90Ms ?? "—"} ms</td>
        <td>${row.maxMs ?? "—"} ms</td>
      </tr>`
    )
    .join("");

  // dailyTrend = { headers: [purpose...], days: [{ date, cells: [{ calls, avgMs, errors } | null, ...] }] }
  const trendHeader = (dailyTrend?.headers ?? [])
    .map((purpose) => `<th>${escapeHtml(purpose)}</th>`)
    .join("");

  const trendRows = (dailyTrend?.days ?? [])
    .map(
      (day) => `
      <tr>
        <td>${escapeHtml(day.date)}</td>
        ${day.cells
          .map(
            (cell) => `
        <td>${cell ? `${cell.calls} 次${cell.avgMs != null ? ` · ${cell.avgMs}ms` : ""}${cell.errors > 0 ? ` · 错 ${cell.errors}` : ""}` : "—"}</td>`
          )
          .join("")}
      </tr>`
    )
    .join("");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Holo Admin · AI 指标</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 24px; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1040px; margin: 0 auto; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; flex-wrap: wrap; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 6px; font-size: 24px; }
    p { margin: 0 0 18px; color: #52606d; }
    h2 { font-size: 16px; margin: 28px 0 10px; }
    table { border-collapse: collapse; width: 100%; background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; margin-bottom: 8px; }
    th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid #e4e7eb; font-size: 14px; }
    th { color: #52606d; font-size: 12px; }
    code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
    td { font-variant-numeric: tabular-nums; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      p, th { color: #9ca3af; }
      table { background: #1f2937; border-color: #374151; }
      th, td { border-bottom-color: #374151; }
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
      <a class="active" href="/admin/ai-metrics">AI 指标</a>
      <a href="/admin/feature-flags">功能开关</a>
      <a href="/admin/entitlements">权益管理</a>
      <a href="/admin/feedback">用户反馈</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>AI 调用指标</h1>
    <p>ai_call_logs 聚合（保留 30 天，UTC 时区）。错误 = error_message 非空；p50/p90 基于成功调用。</p>

    <h2>按用途汇总（近 30 天）</h2>
    <table>
      <thead>
        <tr><th>purpose</th><th>调用</th><th>错误</th><th>平均时延</th><th>p50</th><th>p90</th><th>最大</th></tr>
      </thead>
      <tbody>${purposeRows || '<tr><td colspan="7">暂无数据</td></tr>'}</tbody>
    </table>

    <h2>近 14 日趋势</h2>
    <table>
      <thead>
        <tr><th>日期</th>${trendHeader}</tr>
      </thead>
      <tbody>${trendRows || '<tr><td colspan="8">暂无数据</td></tr>'}</tbody>
    </table>
  </main>
</body>
</html>`;
}
