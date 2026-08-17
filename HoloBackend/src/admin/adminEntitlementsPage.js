import { escapeHtml } from "./adminLogsPage.js";

/**
 * 权益管理页：运营手动给设备开通/撤销 Plus 覆盖（测试期补偿、种子用户等）。
 * 覆盖写入 subscription_acceptance_overrides，优先级高于真实购买记录；
 * 带有效期的覆盖到期自动失效，用户回退到按购买记录判定。
 */

// subject_id 形如 purchase:{uuid} / acceptance:{uuid}:{tier}；deviceId 本身是 UUID，不含冒号
function deviceIdFromSubjectId(subjectId) {
  const separator = subjectId.indexOf(":");
  const prefix = subjectId.slice(0, separator);
  const rest = subjectId.slice(separator + 1);
  if (prefix === "acceptance") {
    const lastColon = rest.lastIndexOf(":");
    return rest.slice(0, lastColon);
  }
  return rest;
}

export function buildEntitlementOverview({ db, acceptanceStore, entitlementResolver, limit = 200 }) {
  const rows = db
    .prepare(
      `
      SELECT subject_id, MAX(updated_at_ms) AS last_active_ms, COUNT(*) AS action_count
      FROM quota_action_ledger
      GROUP BY subject_id
      ORDER BY last_active_ms DESC
      LIMIT ?
    `,
    )
    .all(limit);

  const devices = rows.map((row) => {
    const deviceId = deviceIdFromSubjectId(row.subject_id);
    const entitlement = entitlementResolver.resolve(deviceId);
    return {
      deviceId,
      lastActiveAt: new Date(row.last_active_ms).toISOString(),
      actionCount: row.action_count,
      tier: entitlement.tier,
      tierSource: entitlement.source,
    };
  });
  return { devices };
}

function formatDateTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return escapeHtml(String(value));
  return date.toISOString().replace("T", " ").slice(0, 19) + " UTC";
}

function formatRelative(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  const diffMs = Date.now() - date.getTime();
  const minutes = Math.round(diffMs / 60000);
  if (minutes < 1) return "刚刚";
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  return `${Math.round(hours / 24)} 天前`;
}

function tierBadge(tier, expired) {
  if (tier === "plus") {
    return expired ? '<span class="tier expired">Plus(已过期)</span>' : '<span class="tier plus">Plus</span>';
  }
  return '<span class="tier free">Free</span>';
}

export function renderAdminEntitlementsPage({ overrides, devices, notice = null, error = null }) {
  const overrideRows = overrides
    .map(
      (row) => `
      <tr>
        <td><code>${escapeHtml(row.deviceId)}</code></td>
        <td>${tierBadge(row.tier, row.expired)}</td>
        <td>${row.expiresAt ? formatDateTime(row.expiresAt) : "永久"}</td>
        <td>${formatDateTime(row.updatedAt)}</td>
        <td>
          <form method="post" action="/admin/entitlements/override/remove">
            <input type="hidden" name="deviceId" value="${escapeHtml(row.deviceId)}">
            <button type="submit" class="danger">撤销覆盖</button>
          </form>
        </td>
      </tr>`,
    )
    .join("");

  const deviceRows = devices
    .map(
      (device) => `
      <tr>
        <td><code>${escapeHtml(device.deviceId)}</code></td>
        <td>${tierBadge(device.tier, false)}<small class="src">${device.tierSource === "acceptance" ? "覆盖" : "购买"}</small></td>
        <td>${formatRelative(device.lastActiveAt)}</td>
        <td>${device.actionCount}</td>
        <td>
          <form method="post" action="/admin/entitlements/override" class="inline-form">
            <input type="hidden" name="deviceId" value="${escapeHtml(device.deviceId)}">
            <input type="hidden" name="tier" value="plus">
            <label>有效天数 <input type="number" name="days" min="1" max="3650" placeholder="空=永久" style="width:90px"></label>
            <button type="submit">开 Plus</button>
          </form>
        </td>
      </tr>`,
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
  <title>Holo Admin · 权益管理</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 24px; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1040px; margin: 0 auto; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; flex-wrap: wrap; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 6px; font-size: 24px; }
    h2 { margin: 28px 0 10px; font-size: 18px; }
    p { margin: 0 0 18px; color: #52606d; }
    table { border-collapse: collapse; width: 100%; background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; }
    th, td { text-align: left; padding: 12px 14px; border-bottom: 1px solid #e4e7eb; font-size: 14px; }
    th { color: #52606d; font-size: 12px; }
    code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .tier { display: inline-block; border-radius: 999px; padding: 3px 10px; font-size: 12px; }
    .tier.plus { background: #fef3c7; border: 1px solid #fcd34d; color: #92400e; }
    .tier.free { background: #f0f4f8; border: 1px solid #d9e2ec; color: #52606d; }
    .tier.expired { opacity: 0.6; }
    .src { color: #9aa5b1; margin-left: 6px; }
    button { border: 1px solid #d9e2ec; background: #f0f4f8; border-radius: 8px; padding: 6px 12px; cursor: pointer; font-size: 13px; }
    button.danger { background: #fee2e2; border-color: #fca5a5; color: #991b1b; }
    .inline-form { display: flex; gap: 8px; align-items: center; font-size: 13px; }
    .grant-card { background: #fff; border: 1px solid #d9e2ec; border-radius: 8px; padding: 16px; margin-bottom: 20px; }
    .grant-card form { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .grant-card input[type="text"] { flex: 1; min-width: 260px; padding: 8px 10px; border: 1px solid #cbd2d9; border-radius: 8px; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .grant-card input[type="number"] { width: 90px; padding: 8px 10px; border: 1px solid #cbd2d9; border-radius: 8px; }
    .grant-card select { padding: 8px 10px; border: 1px solid #cbd2d9; border-radius: 8px; }
    .notice { border-radius: 8px; padding: 10px 14px; margin-bottom: 16px; }
    .notice.ok { background: #dcfce7; color: #166534; }
    .notice.err { background: #fee2e2; color: #991b1b; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      p, th { color: #9ca3af; }
      table, .grant-card { background: #1f2937; border-color: #374151; }
      th, td { border-bottom-color: #374151; }
      .tier.free { background: #374151; border-color: #4b5563; color: #d1d5db; }
      nav a { color: #93c5fd; }
      nav a.active { background: #1e3a8a; color: #bfdbfe; }
      .notice.ok { background: #14532d; color: #bbf7d0; }
      .notice.err { background: #7f1d1d; color: #fecaca; }
      button { background: #374151; border-color: #4b5563; color: #e5e7eb; }
      .grant-card input, .grant-card select { background: #111827; border-color: #4b5563; color: #e5e7eb; }
    }
  </style>
</head>
<body>
  <main>
    <nav>
      <a href="/admin/logs">日志</a>
      <a href="/admin/prompts">提示词</a>
      <a href="/admin/feature-flags">功能开关</a>
      <a href="/admin/ai-metrics">AI 指标</a>
      <a href="/admin/reports">举报</a>
      <a href="/admin/entitlements" class="active">权益管理</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>权益管理</h1>
    <p>手动给设备开通 Plus 覆盖（测试期补偿/种子用户）。覆盖优先于购买记录，App 下次刷新订阅状态即生效；带有效期的覆盖到期自动回退。</p>
    ${noticeHtml}

    <div class="grant-card">
      <form method="post" action="/admin/entitlements/override">
        <input type="text" name="deviceId" placeholder="设备 ID（UUID）" required>
        <select name="tier">
          <option value="plus">Plus</option>
          <option value="free">Free</option>
        </select>
        <label>有效天数 <input type="number" name="days" min="1" max="3650" placeholder="空=永久"></label>
        <button type="submit">保存覆盖</button>
      </form>
    </div>

    <h2>当前覆盖（${overrides.length}）</h2>
    <table>
      <thead>
        <tr><th>设备 ID</th><th>权益</th><th>有效期至</th><th>更新时间</th><th>操作</th></tr>
      </thead>
      <tbody>
        ${overrideRows || '<tr><td colspan="5">暂无覆盖</td></tr>'}
      </tbody>
    </table>

    <h2>最近活跃设备（按额度账本聚合，前 ${devices.length}）</h2>
    <table>
      <thead>
        <tr><th>设备 ID</th><th>当前权益</th><th>最近活跃</th><th>动作数</th><th>快捷操作</th></tr>
      </thead>
      <tbody>
        ${deviceRows || '<tr><td colspan="5">暂无活跃设备</td></tr>'}
      </tbody>
    </table>
  </main>
</body>
</html>`;
}
