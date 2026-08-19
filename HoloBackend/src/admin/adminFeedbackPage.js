import { escapeHtml } from "./adminLogsPage.js";
import { formatLocalTimestamp } from "../time.js";

/**
 * 用户反馈管理页（设置页「反馈给开发者」通道）
 * 查看用户提交的反馈（类型/内容/截图/联系方式/诊断信息），标记处理状态。
 * 页面无 JS（CSP 限制）：截图缩略图点开新标签页看原图，筛选走 query 参数。
 */
const CATEGORY_LABELS = {
  suggestion: "功能建议",
  issue: "问题反馈",
  other: "其他",
};

const CONTACT_META = {
  wechat: { icon: "💬", label: "微信", color: "#07C160" },
  qq: { icon: "🐧", label: "QQ", color: "#12B7F5" },
  email: { icon: "✉️", label: "邮箱", color: "#2563eb" },
  phone: { icon: "📱", label: "手机", color: "#ea580c" },
};

function todayKeyUtc8() {
  return new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
}

function isCreatedToday(createdAt) {
  const epoch = Date.parse(`${createdAt}Z`);
  if (Number.isNaN(epoch)) return false;
  return new Date(epoch + 8 * 3600_000).toISOString().slice(0, 10) === todayKeyUtc8();
}

function renderContactBadge(feedback) {
  if (!feedback.contact_value) return `<span class="contact none">未留</span>`;
  const meta = CONTACT_META[feedback.contact_type] ?? CONTACT_META.wechat;
  return `<span class="contact" style="color:${meta.color};background:${meta.color}1a;">${meta.icon} ${escapeHtml(feedback.contact_value)}</span>`;
}

function renderImages(feedback) {
  if (feedback.imageFiles.length === 0) return "";
  const thumbs = feedback.imageFiles
    .map(
      (file) => `
        <a class="thumb" href="/admin/feedback/images/${escapeHtml(file)}" target="_blank" rel="noopener">
          <img src="/admin/feedback/images/${escapeHtml(file)}" alt="反馈截图 ${escapeHtml(file)}">
        </a>`,
    )
    .join("");
  return `<div class="thumbs">${thumbs}</div>`;
}

function renderFilterChips(active) {
  const categories = [
    { key: "", label: "全部类型" },
    { key: "suggestion", label: "功能建议" },
    { key: "issue", label: "问题反馈" },
    { key: "other", label: "其他" },
  ];
  const statuses = [
    { key: "", label: "全部状态" },
    { key: "new", label: "未处理" },
    { key: "done", label: "已处理" },
  ];
  const chip = (kind, item) => {
    const on = active[kind] === item.key;
    const params = new URLSearchParams();
    const other = kind === "category" ? "status" : "category";
    if (item.key) params.set(kind, item.key);
    if (active[other]) params.set(other, active[other]);
    const query = params.toString();
    return `<a class="chip${on ? " on" : ""}" href="/admin/feedback${query ? `?${query}` : ""}">${item.label}</a>`;
  };
  return `<div class="filters">
    ${categories.map((item) => chip("category", item)).join("")}
    <span class="sep"></span>
    ${statuses.map((item) => chip("status", item)).join("")}
  </div>`;
}

export function renderAdminFeedbackPage({ feedbackList, active = { category: "", status: "" }, notice = null, error = null }) {
  const todayCount = feedbackList.filter((item) => isCreatedToday(item.created_at)).length;
  const openCount = feedbackList.filter((item) => item.status === "new").length;

  const cards = feedbackList
    .map((feedback) => {
      const categoryLabel = CATEGORY_LABELS[feedback.category] ?? feedback.category;
      const isDone = feedback.status === "done";
      const keepQuery = new URLSearchParams();
      if (active.category) keepQuery.set("category", active.category);
      if (active.status) keepQuery.set("status", active.status);
      const backPath = `/admin/feedback${keepQuery.toString() ? `?${keepQuery.toString()}` : ""}`;
      const statusAction = isDone
        ? { value: "new", label: "恢复未处理" }
        : { value: "done", label: "标记已处理" };
      return `
        <article class="card${feedback.status === "new" ? " unread" : ""}${isDone ? " done" : ""}">
          <header>
            <span class="cat ${escapeHtml(feedback.category)}">${categoryLabel}</span>
            <time>${escapeHtml(formatLocalTimestamp(feedback.created_at))}</time>
            <span class="status ${escapeHtml(feedback.status)}">${isDone ? "已处理" : "未处理"}</span>
          </header>
          <pre class="content">${escapeHtml(feedback.content)}</pre>
          ${renderImages(feedback)}
          <footer>
            ${renderContactBadge(feedback)}
            <span class="meta">App ${escapeHtml(feedback.app_version ?? "—")}</span>
            <span class="meta">${escapeHtml(feedback.os_version ?? "—")}</span>
            <span class="meta device">${escapeHtml(feedback.device_id)}</span>
            <form method="post" action="/admin/feedback/${feedback.id}/status">
              <input type="hidden" name="status" value="${statusAction.value}">
              <input type="hidden" name="back" value="${escapeHtml(backPath)}">
              <button type="submit"${isDone ? " class=\"ghost\"" : ""}>${statusAction.label}</button>
            </form>
          </footer>
        </article>
      `;
    })
    .join("");

  const empty = feedbackList.length === 0 ? `<p class="empty">当前筛选条件下暂无反馈。</p>` : "";

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Holo Admin · 用户反馈</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 24px; background: #f7f7f5; color: #1f2933; }
    main { max-width: 1040px; margin: 0 auto; }
    nav { display: flex; gap: 12px; align-items: center; margin-bottom: 20px; flex-wrap: wrap; }
    nav a { color: #0967d2; text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    nav a.active { background: #dbeafe; color: #1d4ed8; }
    h1 { margin: 0 0 6px; font-size: 24px; }
    p.lead { margin: 0 0 18px; color: #52606d; }
    .stats { display: flex; gap: 10px; margin-bottom: 14px; }
    .stat { font-size: 13px; font-weight: 600; padding: 6px 12px; border-radius: 9px; background: #e4e7eb; color: #3e4c59; }
    .stat.hot { background: #ffedd5; color: #c2410c; }
    .filters { display: flex; gap: 8px; align-items: center; margin-bottom: 16px; flex-wrap: wrap; }
    .chip { font-size: 13px; text-decoration: none; color: #52606d; border: 1.5px solid #d9e2ec; border-radius: 999px; padding: 5px 13px; }
    .chip.on { background: #0967d2; border-color: #0967d2; color: #fff; }
    .sep { width: 1px; height: 20px; background: #d9e2ec; margin: 0 4px; }
    .card { background: #fff; border: 1px solid #d9e2ec; border-radius: 10px; padding: 16px; margin: 12px 0; }
    .card.unread { border-left: 3px solid #ea580c; }
    .card.done { opacity: 0.72; }
    .card header { display: flex; gap: 12px; align-items: center; }
    .cat { font-size: 12px; font-weight: 700; padding: 3px 9px; border-radius: 6px; background: #e4e7eb; color: #3e4c59; }
    .cat.suggestion { background: #ede9fe; color: #6d28d9; }
    .cat.issue { background: #ffedd5; color: #c2410c; }
    time { font-size: 12px; color: #7b8794; }
    .status { margin-left: auto; font-size: 12px; font-weight: 700; padding: 3px 10px; border-radius: 6px; }
    .status.new { background: #ffedd5; color: #c2410c; }
    .status.done { background: #d3f9d8; color: #14532d; }
    pre.content { white-space: pre-wrap; overflow-wrap: anywhere; margin: 12px 0; padding: 10px 12px; border-radius: 8px; background: #f0f4f8; font: 13px/1.6 inherit; }
    .thumbs { display: flex; gap: 10px; margin: 4px 0 12px; }
    .thumb img { width: 56px; height: 74px; object-fit: cover; border-radius: 8px; border: 1px solid #d9e2ec; display: block; }
    .thumb:hover img { box-shadow: 0 4px 12px rgba(0,0,0,.18); }
    .card footer { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; border-top: 1px dashed #e4e7eb; padding-top: 10px; margin-top: 4px; }
    .contact { font-size: 12px; font-weight: 700; padding: 3px 10px; border-radius: 7px; }
    .contact.none { background: #e4e7eb; color: #7b8794; font-weight: 500; }
    .meta { font-size: 12px; color: #7b8794; }
    .meta.device { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; }
    footer form { margin-left: auto; }
    footer button { font: inherit; font-size: 12px; font-weight: 700; color: #c2410c; background: #ffedd5; border: none; border-radius: 8px; padding: 6px 13px; cursor: pointer; }
    footer button.ghost { color: #7b8794; background: #e4e7eb; }
    .empty { color: #7b8794; }
    @media (prefers-color-scheme: dark) {
      body { background: #111827; color: #e5e7eb; }
      p.lead { color: #9ca3af; }
      .card { background: #1f2937; border-color: #374151; }
      .card.unread { border-left-color: #f97316; }
      .cat, .chip { color: #9ca3af; border-color: #374151; }
      .cat.suggestion { background: #2e1065; color: #c4b5fd; }
      .cat.issue { background: #431407; color: #fdba74; }
      .stat { background: #374151; color: #d1d5db; }
      .stat.hot { background: #431407; color: #fdba74; }
      .sep { background: #374151; }
      time, .meta, .empty { color: #9ca3af; }
      pre.content { background: #111827; }
      .thumb img { border-color: #374151; }
      .contact.none { background: #374151; color: #9ca3af; }
      .status.new { background: #431407; color: #fdba74; }
      .status.done { background: #052e16; color: #86efac; }
      footer button { background: #431407; color: #fdba74; }
      footer button.ghost { background: #374151; color: #9ca3af; }
      a, nav a { color: #93c5fd; }
      nav a.active { background: #1e3a8a; color: #bfdbfe; }
      .chip.on { background: #1d4ed8; border-color: #1d4ed8; }
    }
  </style>
</head>
<body>
  <main>
    <nav>
      <a href="/admin/logs">Logs</a>
      <a href="/admin/prompts">Prompts</a>
      <a href="/admin/reports">举报</a>
      <a class="active" href="/admin/feedback">用户反馈</a>
      <a href="/admin/ai-metrics">AI 指标</a>
      <a href="/admin/feature-flags">功能开关</a>
      <a href="/admin/entitlements">权益管理</a>
      <a href="/admin/logout">退出</a>
    </nav>
    <h1>用户反馈</h1>
    <p class="lead">设置页「反馈给开发者」提交的反馈，时间按 UTC+8 展示；点截图在新标签页查看原图。</p>
    <div class="stats">
      <span class="stat hot">今日 +${todayCount}</span>
      <span class="stat hot">未处理 ${openCount}</span>
      <span class="stat">累计 ${feedbackList.length}</span>
    </div>
    ${renderFilterChips(active)}
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
