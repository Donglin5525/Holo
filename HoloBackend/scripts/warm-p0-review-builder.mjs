// warm-p0-review-builder.mjs
// 温暖陪伴 P0 盲评材料生成器：读 P0前/P0后两份样本 JSONL，
// 产出单文件 HTML（匿名 A/B 对照 + 页内打分统计 + 保真率技术面板）。
// 层1（主评）：同一份 P0 后模型输出分别过「旧 iOS 重组」与「新 iOS 重组」——
//              剔除模型随机性，纯测管线损耗（P0 的问题就是"温度生成了但被丢掉"）。
// 层2（参考）：P0 前端到端 vs P0 后端到端——真实升级后的整体变化感。
// 用法：node warm-p0-review-builder.mjs <before.jsonl> <after.jsonl> <out.html>

import { readFileSync, writeFileSync } from "node:fs";

const SEED_LCG = 987654321;

function lcg(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

function readJsonl(path) {
  return readFileSync(path, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function sanitize(text) {
  if (!text) return null;
  const trimmed = String(text).trim();
  if (!trimmed) return null;
  // 与 iOS containsInternalToken 同源的简化版：内部前缀/下划线/公式调用
  if (/(health\.|finance\.|habit\.|task\.|goal\.|thought\.|memory\.|insight\.|profile\.|conversation\.|dynamic\.)/.test(trimmed)) return null;
  if (trimmed.includes("_") || trimmed.includes(" = ") || trimmed.includes("计算结果")) return null;
  if (/[A-Za-z_]{2,}\(/.test(trimmed)) return null;
  return trimmed;
}

// ---- 与 iOS HoloAgentResultRenderer.cloudSectionTitle 同源的语义短标题 ----
function shortTitle(text) {
  let cleaned = text.trim();
  for (const prefix of ["观察", "本期"]) {
    if (cleaned.startsWith(prefix)) cleaned = cleaned.slice(prefix.length);
  }
  const separators = new Set("，,；;。.!！?？：:\n");
  let first = "";
  for (const ch of cleaned) {
    if (separators.has(ch)) break;
    first += ch;
  }
  first = first || cleaned;
  const title = Array.from(first).slice(0, 14).join("").trim();
  return title || "数据解读";
}

function cloudSectionTitle(body, usedTitles) {
  const title = shortTitle(body);
  const unique = usedTitles.has(title) ? "数据解读" : title;
  usedTitles.add(unique);
  return unique;
}

// ---- 旧 iOS finalize（HoloCloudAnalysisService P0 前的形态） ----
function renderLegacy(result) {
  const claims = (result.claims ?? [])
    .map((c) => sanitize(c.displayText ?? c.summary))
    .filter(Boolean);
  const sections = claims.map((body, i) => ({
    title: `发现 ${i + 1}`, body, interpretation: null,
  }));
  return {
    title: sanitize(result.title) ?? "深度分析",
    summary: claims.length === 0 ? "本期暂无显著观察" : claims.join("；"),
    keyInsight: null,
    sections,
  };
}

// ---- 新 iOS finalize（composedCloudNarrative） ----
function renderWarm(result) {
  const usedTitles = new Set();
  const sections = (result.claims ?? [])
    .map((c) => ({
      body: sanitize(c.displayText ?? c.summary),
      kind: c.type ?? null,
      interpretation: sanitize(c.interpretation),
    }))
    .filter((c) => c.body)
    .map((c) => ({
      title: cloudSectionTitle(c.body, usedTitles),
      body: c.body,
      interpretation: c.interpretation,
    }));
  const narrative = sanitize(result.narrativeSummary);
  const bodies = sections.map((s) => s.body);
  return {
    title: sanitize(result.title) ?? "深度分析",
    summary: narrative ?? (bodies.length === 0 ? "本期暂无显著观察" : bodies.join("；")),
    keyInsight: sanitize(result.keyInsight),
    sections,
  };
}

function escapeHtml(text) {
  return String(text ?? "")
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function cardHtml(view, side) {
  const insight = view.keyInsight
    ? `<div class="insight">💡 ${escapeHtml(view.keyInsight)}</div>`
    : "";
  const sections = view.sections.map((s) => `
    <div class="section">
      <div class="section-title">${escapeHtml(s.title)}</div>
      <div class="section-body">${escapeHtml(s.body)}</div>
      ${s.interpretation ? `<div class="interp">这对你来说：${escapeHtml(s.interpretation)}</div>` : ""}
    </div>`).join("");
  return `
  <div class="card ${side}">
    <div class="card-title">${escapeHtml(view.title)}</div>
    ${insight}
    <div class="summary">${escapeHtml(view.summary)}</div>
    ${sections || `<div class="section"><div class="section-body">${escapeHtml(view.summary)}</div></div>`}
  </div>`;
}

function main() {
  const [beforePath, afterPath, outPath] = process.argv.slice(2);
  if (!beforePath || !afterPath || !outPath) {
    console.error("用法: node warm-p0-review-builder.mjs <before.jsonl> <after.jsonl> <out.html>");
    process.exit(2);
  }
  const before = new Map(readJsonl(beforePath).map((r) => [r.id, r]));
  const after = new Map(readJsonl(afterPath).map((r) => [r.id, r]));

  const rand = lcg(SEED_LCG);
  const pairs = [];
  for (const [id, afterRec] of after) {
    if (afterRec.status !== "completed" || !afterRec.result) continue;
    const warmSide = rand() < 0.5 ? "A" : "B";
    const legacySide = warmSide === "A" ? "B" : "A";
    pairs.push({
      id,
      question: afterRec.question,
      warmSide,
      legacySide,
      warm: renderWarm(afterRec.result),
      legacy: renderLegacy(afterRec.result),
      e2eBefore: before.get(id) ?? null,
    });
  }

  // 保真率技术面板数据：after 样本里模型生成叙事字段且 iOS 可用的比例
  const tech = { total: 0, narrativeGen: 0, narrativeUsable: 0, keyInsightGen: 0, keyInsightUsable: 0, interpGen: 0, interpUsable: 0, claimsWithInterp: 0 };
  for (const [, rec] of after) {
    if (rec.status !== "completed" || !rec.result) continue;
    tech.total += 1;
    const r = rec.result;
    if (r.narrativeSummary && r.narrativeSummary.trim()) { tech.narrativeGen += 1; if (sanitize(r.narrativeSummary)) tech.narrativeUsable += 1; }
    if (r.keyInsight && r.keyInsight.trim()) { tech.keyInsightGen += 1; if (sanitize(r.keyInsight)) tech.keyInsightUsable += 1; }
    const claims = r.claims ?? [];
    const gen = claims.filter((c) => c.interpretation && String(c.interpretation).trim());
    if (gen.length > 0) { tech.interpGen += 1; if (gen.some((c) => sanitize(c.interpretation))) tech.interpUsable += 1; }
    tech.claimsWithInterp += gen.length;
  }

  const items = pairs.map((p) => `
  <section class="pair" data-id="${p.id}">
    <div class="q">${escapeHtml(p.id)} · ${escapeHtml(p.question)}</div>
    <div class="cards">
      ${cardHtml(p.warmSide === "A" ? p.warm : p.legacy, "a")}
      ${cardHtml(p.warmSide === "B" ? p.warm : p.legacy, "b")}
    </div>
    <div class="vote">
      <button class="pick" data-side="A">左边更好</button>
      <button class="pick" data-side="B">右边更好</button>
      <button class="pick" data-side="tie">差不多</button>
      <span class="note">更好 = 更像在对你说话、更能看下去（不是更长）</span>
    </div>
    <details class="e2e"><summary>参考：P0 前线上真实结果（端到端旧管线）</summary>${
      p.e2eBefore && p.e2eBefore.result
        ? cardHtml(renderLegacy(p.e2eBefore.result), "before")
        : `<div class="section"><div class="section-body">该样本 P0 前未完成（status=${escapeHtml(p.e2eBefore?.status ?? "missing")}）</div></div>`
    }</details>
  </section>`).join("");

  const html = `<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>温暖陪伴 P0 · 叙事契约盲评</title>
<style>
  :root { color-scheme: light; }
  body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 0; background: #f5f4f1; color: #1d1d1f; }
  header { padding: 28px 20px 12px; max-width: 860px; margin: 0 auto; }
  header h1 { font-size: 22px; margin: 0 0 8px; }
  header p { color: #555; font-size: 14px; line-height: 1.7; margin: 4px 0; }
  .bar { position: sticky; top: 0; background: rgba(245,244,241,.95); backdrop-filter: blur(8px); border-bottom: 1px solid #ddd; z-index: 9; padding: 10px 20px; }
  .bar-inner { max-width: 860px; margin: 0 auto; display: flex; gap: 16px; align-items: center; font-size: 14px; flex-wrap: wrap; }
  .bar b { font-size: 16px; }
  main { max-width: 860px; margin: 0 auto; padding: 12px 20px 80px; }
  .pair { background: #fff; border-radius: 16px; padding: 18px; margin: 16px 0; box-shadow: 0 1px 4px rgba(0,0,0,.06); }
  .q { font-weight: 600; font-size: 16px; margin-bottom: 12px; }
  .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 700px) { .cards { grid-template-columns: 1fr; } }
  .card { border: 1px solid #e5e3de; border-radius: 12px; padding: 14px; background: #fbfaf8; }
  .card.before { background: #f3f3f3; }
  .card-title { font-weight: 700; font-size: 15px; margin-bottom: 8px; }
  .insight { background: #fff7e6; border: 1px solid #f5e0b0; border-radius: 8px; padding: 8px 10px; font-size: 14px; margin-bottom: 8px; }
  .summary { font-size: 14px; line-height: 1.7; margin-bottom: 10px; }
  .section { border-top: 1px dashed #e0ded8; padding: 8px 0 4px; }
  .section-title { font-size: 13px; font-weight: 600; color: #444; margin-bottom: 3px; }
  .section-body { font-size: 14px; line-height: 1.65; }
  .interp { font-size: 13px; color: #6b6b6b; margin-top: 4px; font-style: normal; background: #f4f4f0; border-radius: 6px; padding: 6px 8px; }
  .vote { display: flex; gap: 8px; align-items: center; margin-top: 12px; flex-wrap: wrap; }
  .vote button { border: 1px solid #c9c6bf; background: #fff; border-radius: 999px; padding: 6px 14px; font-size: 13px; cursor: pointer; }
  .vote button.chosen { background: #1d1d1f; color: #fff; border-color: #1d1d1f; }
  .vote .note { color: #888; font-size: 12px; }
  .pair.voted { outline: 2px solid #b7e3c8; }
  .e2e { margin-top: 10px; font-size: 13px; color: #666; }
  .e2e summary { cursor: pointer; }
  .e2e .card { margin-top: 8px; }
  details.tech { background: #fff; border-radius: 12px; padding: 14px 18px; margin: 14px 0; font-size: 13px; line-height: 1.8; }
  details.tech table { border-collapse: collapse; }
  details.tech td, details.tech th { border: 1px solid #e2e0da; padding: 4px 10px; text-align: left; }
</style>
</head>
<body>
<header>
  <h1>温暖陪伴 P0 · 叙事契约盲评</h1>
  <p>同一份模型分析结果，分别用「P0 前的 iOS 重组」与「P0 后的 iOS 重组」渲染成两张卡。两卡的事实与数字完全相同，只有表达层不同——评的就是温度是不是早就生成了、只是被链路丢掉。</p>
  <p>评法：每题点一个「更好」（更好 = 更像在对你说话、更能看下去，不是更长）。全部点完看顶部胜率——出口门禁：新版胜率 ≥ 65%。</p>
</header>
<div class="bar"><div class="bar-inner">
  <span>已评 <b id="voted">0</b>/${pairs.length}</span>
  <span>新版胜 <b id="warm">0</b></span>
  <span>旧版胜 <b id="legacy">0</b></span>
  <span>持平 <b id="tie">0</b></span>
  <span>新版胜率 <b id="rate">—</b></span>
</div></div>
<main>
<details class="tech"><summary>技术面板：叙事字段端到端保真（P0 后 · ${tech.total} 条完成样本）</summary>
  <table>
    <tr><th>字段</th><th>模型生成率</th><th>iOS 可用率（过防线）</th></tr>
    <tr><td>narrativeSummary 自然摘要</td><td>${tech.narrativeGen}/${tech.total}</td><td>${tech.narrativeUsable}/${tech.narrativeGen || 0}</td></tr>
    <tr><td>keyInsight 核心洞察</td><td>${tech.keyInsightGen}/${tech.total}</td><td>${tech.keyInsightUsable}/${tech.keyInsightGen || 0}</td></tr>
    <tr><td>interpretation 生活解读</td><td>${tech.interpGen}/${tech.total} 条结果（共 ${tech.claimsWithInterp} 张卡）</td><td>${tech.interpUsable}/${tech.interpGen || 0}</td></tr>
  </table>
  <p style="color:#777">P0 门禁口径：模型生成了叙事字段时，经协议解码 + 防线后 100% 可用（保真率 100%）；「生成率」本身反映模型按提示词 v21 的产出意愿，是 P2 表达层的目标。</p>
</details>
${items}
</main>
<script>
  const map = ${JSON.stringify(Object.fromEntries(pairs.map((p) => [p.id, p.warmSide])))};
  let voted = 0, warm = 0, legacy = 0, tie = 0;
  document.querySelectorAll(".pair").forEach((pair) => {
    const id = pair.dataset.id;
    pair.querySelectorAll(".pick").forEach((btn) => {
      btn.addEventListener("click", () => {
        if (pair.classList.contains("voted")) return;
        pair.classList.add("voted");
        pair.querySelectorAll(".pick").forEach((b) => b.classList.remove("chosen"));
        btn.classList.add("chosen");
        voted += 1;
        const side = btn.dataset.side;
        if (side === "tie") tie += 1;
        else if (side === map[id]) warm += 1;
        else legacy += 1;
        document.getElementById("voted").textContent = voted;
        document.getElementById("warm").textContent = warm;
        document.getElementById("legacy").textContent = legacy;
        document.getElementById("tie").textContent = tie;
        const denom = warm + legacy;
        document.getElementById("rate").textContent = denom === 0 ? "—" :
          Math.round((warm / denom) * 100) + "%（忽略持平）";
      });
    });
  });
</script>
</body>
</html>`;

  writeFileSync(outPath, html);
  console.log(`[review] ${pairs.length} 对盲评样本 → ${outPath}`);
  console.log(`[review] 技术面板：narrative ${tech.narrativeUsable}/${tech.narrativeGen}/${tech.total} · keyInsight ${tech.keyInsightUsable}/${tech.keyInsightGen}/${tech.total} · interpretation ${tech.interpUsable}/${tech.interpGen}/${tech.total}`);
}

main();
