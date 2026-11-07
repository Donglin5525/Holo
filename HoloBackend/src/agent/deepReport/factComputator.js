// 深度报告 C 方案（2026-11-07 设计）：事实清单计算器——纯程序从加密快照算出带编号的
// 事实（F001…），模型写作只许引用这些数字。口径与实验 facts2/facts3（Python）一致：
// 上期=紧邻前移同长度窗口；自然月口径算个人历史；带 project 的支出单列为一次性项目；
// 收入按分类拆开并标注疑似退款；备注跨条同词归并到人/事；习惯给中断与恢复的规律；
// 一起变化检查与 iOS 生活体检台账同口径（对齐≥10 天、|r|≥0.35、Top3）。
// 快照自带的 financeEvidenceLedger / crossDomainCheckup 台账文本原文收录（不重算），
// 且 crossDomainCheckup 在场时跳过本文件的习惯本期对比行（台账带每周目标口径更准）。
import { extractStats } from "./numberCheck.js";

const TZ_OFFSET_MS = 8 * 3600 * 1000;
const WD = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

const fmt2 = (n) => (Math.round(n * 100) / 100).toFixed(2);
const g = (n) => Number(n.toFixed(1)).toString();
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};
const localDate = (ms) => new Date(ms + TZ_OFFSET_MS);
const ymd = (ms) => localDate(ms).toISOString().slice(0, 10);
const md = (ms) => localDate(ms).toISOString().slice(5, 10);
const weekday = (ms) => WD[localDate(ms).getUTCDay()];
const monthKey = (ms) => localDate(ms).toISOString().slice(0, 7);

/** 主窗口=answerTask 冻结窗；无窗用快照全窗。上期=紧邻前移同长度（上界=本期起点） */
export function resolveAnalysisWindow(snapshot) {
  const genMs = Date.parse(snapshot?.generatedAt ?? "") || Date.now();
  const range = snapshot?.answerTask?.primaryTimeRange;
  const toMs = (v) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return null;
    return n >= 1e11 ? n : n >= 1e8 ? n * 1000 : null;
  };
  if (range && toMs(range.start) != null && toMs(range.end) != null && toMs(range.start) < toMs(range.end)) {
    const start = toMs(range.start);
    const end = toMs(range.end);
    return {
      genMs,
      label: typeof range.label === "string" && range.label ? range.label : "分析范围",
      startMs: start,
      endMs: end,
      prevStartMs: start - (end - start),
      hasPrev: true,
    };
  }
  const days = Number(snapshot?.historyDays) > 0 ? Number(snapshot.historyDays) : 180;
  return {
    genMs,
    label: `快照全窗（最近${days}天）`,
    startMs: genMs - days * 86400_000,
    endMs: genMs,
    prevStartMs: null,
    hasPrev: false,
  };
}

/** 自然月跨度按「快照全窗」（historyDays），与问句冻结窗无关——个人历史不被问句窗口截断 */
function monthSpans(snapshot) {
  const genMs = Date.parse(snapshot?.generatedAt ?? "") || Date.now();
  const days = Number(snapshot?.historyDays) > 0 ? Number(snapshot.historyDays) : 180;
  const startMs = genMs - days * 86400_000;
  const endMs = genMs;
  const spans = [];
  let cur = Date.UTC(new Date(startMs + TZ_OFFSET_MS).getUTCFullYear(), new Date(startMs + TZ_OFFSET_MS).getUTCMonth(), 1) - TZ_OFFSET_MS;
  for (;;) {
    const d = localDate(cur);
    const next = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1) - TZ_OFFSET_MS;
    if (cur >= endMs) break;
    const label = `${d.getUTCMonth() + 1}月`;
    const full = cur >= startMs && next <= endMs;
    const partialLabel = cur < startMs ? `${d.getUTCMonth() + 1}月（${localDate(startMs).getUTCDate()}日起）` : next > endMs ? `${d.getUTCMonth() + 1}月（1-${localDate(endMs).getUTCDate()}日）` : label;
    spans.push({ label: partialLabel, full, start: Math.max(cur, startMs), end: Math.min(next, endMs) });
    cur = next;
  }
  return spans;
}

class Sheet {
  constructor() {
    this.lines = [];
    this.entries = [];
    this.headers = [];
    this.n = 0;
  }
  header(text) {
    this.headers.push(text);
    this.lines.push(text);
  }
  section(title) {
    this.lines.push("", `【${title}】`);
  }
  note(text) {
    this.lines.push(`     ${text}`);
  }
  add(text) {
    this.n += 1;
    const id = `F${String(this.n).padStart(3, "0")}`;
    this.entries.push({ id, text });
    this.lines.push(`${id} ${text}`);
    return id;
  }
  build() {
    const whitelist = [];
    const seen = new Set();
    for (const h of this.headers) {
      // 头部含窗口天数等「背景数字」，报告可能引用，一并进白名单
      for (const v of extractStats(h).map((x) => x.value)) {
        const k = v.toFixed(2);
        if (!seen.has(k)) { seen.add(k); whitelist.push(v); }
      }
    }
    for (const e of this.entries) {
      e.values = extractStats(e.text).map((s) => s.value);
      for (const v of e.values) {
        const k = v.toFixed(2);
        if (!seen.has(k)) {
          seen.add(k);
          whitelist.push(v);
        }
      }
    }
    return { text: `${this.lines.join("\n").trim()}\n`, entries: this.entries, whitelist };
  }
}

function financeRows(snapshot) {
  const rows = snapshot?.datasets?.["finance.transactions"]?.rows ?? [];
  return rows
    .filter((r) => typeof r.occurredAt === "string")
    .map((r) => ({ ...r, t: Date.parse(r.occurredAt) }))
    .filter((r) => Number.isFinite(r.t));
}

const inWin = (t, s, e) => t >= s && t <= e;
const isProj = (r) => Boolean(r.project);
const expense = (r) => r.type === "expense";
const total = (rs) => rs.reduce((a, r) => a + (Number(r.amount) || 0), 0);
const byCat = (rs) => {
  const out = new Map();
  for (const r of rs) {
    const k = r.category || "未分类";
    const cur = out.get(k) ?? { sum: 0, n: 0 };
    cur.sum += Number(r.amount) || 0;
    cur.n += 1;
    out.set(k, cur);
  }
  return out;
};
/** 与 Python 实验一致的「多了/少了」句式 */
function delta(cur, prev, unit = "元", digits = 2) {
  const d = cur - prev;
  if (Math.abs(d) < 0.005) return "持平";
  const pct = prev ? `（${d >= 0 ? "+" : "-"}${Math.abs((d / prev) * 100).toFixed(1)}%）` : "（上期为 0，无法算幅度）";
  return `${d >= 0 ? "多了" : "少了"} ${Math.abs(d).toFixed(digits)} ${unit}${pct}`;
}

function financeSection(S, snapshot, rows, w) {
  const cur = rows.filter((r) => expense(r) && inWin(r.t, w.startMs, w.endMs));
  const prev = w.hasPrev ? rows.filter((r) => expense(r) && inWin(r.t, w.prevStartMs, w.startMs - 1)) : [];
  S.section("财务·总览（全部支出，含一次性项目）");
  S.add(`本期支出合计 ${fmt2(total(cur))} 元，共 ${cur.length} 笔。`);
  if (w.hasPrev) {
    S.add(`上期支出合计 ${fmt2(total(prev))} 元，共 ${prev.length} 笔；总支出比上期${delta(total(cur), total(prev))}。`);
  }
  const hasProj = [...cur, ...prev].some(isProj);
  let dailyCur = cur;
  let dailyPrev = prev;
  if (hasProj) {
    S.section("财务·一次性项目拆分（带「项目」标记的支出，比如一趟旅行）");
    const projects = new Set([...cur, ...prev].filter(isProj).map((r) => r.project));
    for (const p of projects) {
      S.add(`项目「${p}」：本期 ${fmt2(total(cur.filter((r) => r.project === p)))} 元（${cur.filter((r) => r.project === p).length} 笔）；上期 ${fmt2(total(prev.filter((r) => r.project === p)))} 元（${prev.filter((r) => r.project === p).length} 笔）。`);
    }
    dailyCur = cur.filter((r) => !isProj(r));
    dailyPrev = prev.filter((r) => !isProj(r));
    S.add(`剔除项目后的日常支出：本期 ${fmt2(total(dailyCur))} 元（${dailyCur.length} 笔），上期 ${fmt2(total(dailyPrev))} 元（${dailyPrev.length} 笔）；日常支出比上期${delta(total(dailyCur), total(dailyPrev))}。`);
    const dAll = total(cur) - total(prev);
    const dProj = total(cur.filter(isProj)) - total(prev.filter(isProj));
    const dDaily = total(dailyCur) - total(dailyPrev);
    if (Math.abs(dAll) > 0.005 && dProj * dAll > 0 && Math.abs(dProj) <= Math.abs(dAll)) {
      S.add(`拆开看：总支出的变化里，${((Math.abs(dProj) / Math.abs(dAll)) * 100).toFixed(1)}% 来自一次性项目，其余来自日常支出。`);
    } else if (Math.abs(dProj) > 0.005 && Math.abs(dDaily) > 0.005 && dProj * dDaily < 0) {
      S.add(`拆开看：项目支出${delta(total(cur.filter(isProj)), total(prev.filter(isProj)))}，日常支出${delta(total(dailyCur), total(dailyPrev))}，两者方向相反，不能合并归因。`);
    }
  }
  incomeSection(S, rows, w);
  categorySection(S, dailyCur, dailyPrev, w, hasProj);
  bandsSection(S, dailyCur, dailyPrev, w, hasProj);
  S.section("财务·本期单笔最大的 10 笔");
  for (const r of [...cur].sort((a, b) => b.amount - a.amount).slice(0, 10)) {
    S.add(`${ymd(r.t)} ${fmt2(r.amount)} 元，分类 ${r.category}，备注「${r.text || "无"}」${r.project ? `，项目 ${r.project}` : ""}。`);
  }
  const notes = new Map();
  for (const r of cur) {
    const key = (r.text || "").trim() || `（无备注·${r.category}）`;
    const c = notes.get(key) ?? { n: 0, sum: 0 };
    c.n += 1;
    c.sum += Number(r.amount) || 0;
    notes.set(key, c);
  }
  const rep = [...notes.entries()].filter(([, v]) => v.n >= 2).sort((a, b) => b[1].n - a[1].n || b[1].sum - a[1].sum).slice(0, 10);
  if (rep.length) {
    S.section("财务·本期出现次数最多的消费（备注完全相同的归并）");
    for (const [k, v] of rep) S.add(`「${k}」：${v.n} 次，合计 ${fmt2(v.sum)} 元，平均每次 ${fmt2(v.sum / v.n)} 元。`);
  }
  tokenSection(S, cur, "本期", total(cur));
  return { cur, prev, dailyCur, dailyPrev, hasProj };
}

function incomeSection(S, rows, w) {
  const cur = rows.filter((r) => r.type === "income" && inWin(r.t, w.startMs, w.endMs));
  const prev = w.hasPrev ? rows.filter((r) => r.type === "income" && inWin(r.t, w.prevStartMs, w.startMs - 1)) : [];
  if (!cur.length && !prev.length) return;
  S.section("财务·收入构成");
  S.add(`本期收入合计 ${fmt2(total(cur))} 元（${cur.length} 笔）${w.hasPrev ? `；上期 ${fmt2(total(prev))} 元（${prev.length} 笔）；收入比上期${delta(total(cur), total(prev))}` : ""}。`);
  const expenseCats = new Set(rows.filter(expense).map((r) => r.category));
  const cw = byCat(cur);
  const cp = byCat(prev);
  for (const c of [...new Set([...cw.keys(), ...cp.keys()])].sort((a, b) => (cw.get(b)?.sum ?? 0) + (cp.get(b)?.sum ?? 0) - ((cw.get(a)?.sum ?? 0) + (cp.get(a)?.sum ?? 0)))) {
    const a = cw.get(c) ?? { sum: 0, n: 0 };
    const b = cp.get(c) ?? { sum: 0, n: 0 };
    S.add(`收入·${c}：本期 ${fmt2(a.sum)} 元（${a.n} 笔）${w.hasPrev ? `；上期 ${fmt2(b.sum)} 元（${b.n} 笔）；${delta(a.sum, b.sum)}` : ""}${expenseCats.has(c) ? "（该分类同时也是支出分类，这类收入可能是退款或报销，不是工资类收入）" : ""}。`);
  }
  for (const [name, xs] of [["本期", cur], ["上期", prev]]) {
    if (xs.length) {
      S.note(`${name}收入明细：${xs.sort((a, b) => a.t - b.t).map((r) => `${md(r.t)} ${fmt2(r.amount)} 元 ${r.category}${r.text ? `「${r.text}」` : ""}`).join("；")}`);
    }
  }
}

function categorySection(S, cur, prev, w, dailyOnly) {
  const base = total(cur);
  S.section(`财务·${dailyOnly ? "日常支出分类（剔除项目" : "支出分类"}${w.hasPrev ? "；上期为同长度前一段" : "；范围内全部支出"}）`);
  const cw = byCat(cur);
  const cp = byCat(prev);
  let cats = [...cw.keys()].sort((a, b) => cw.get(b).sum - cw.get(a).sum).slice(0, 10);
  if (w.hasPrev) {
    const movers = [...new Set([...cw.keys(), ...cp.keys()])]
      .sort((a, b) => Math.abs((cw.get(b)?.sum ?? 0) - (cp.get(b)?.sum ?? 0)) - Math.abs((cw.get(a)?.sum ?? 0) - (cp.get(a)?.sum ?? 0)))
      .slice(0, 8);
    cats = [...new Set([...cats, ...movers])];
  }
  for (const c of cats) {
    const a = cw.get(c) ?? { sum: 0, n: 0 };
    const b = cp.get(c) ?? { sum: 0, n: 0 };
    let line = `${c}：本期 ${fmt2(a.sum)} 元（${a.n} 笔，占${dailyOnly ? "日常" : "本期"}支出 ${base ? ((a.sum / base) * 100).toFixed(1) : "0.0"}%）`;
    if (w.hasPrev) {
      line += `；上期 ${fmt2(b.sum)} 元（${b.n} 笔）；${delta(a.sum, b.sum)}`;
      if (a.n + b.n >= 3 && Math.abs(a.sum - b.sum) >= 0.005) {
        const avg = (a.sum + b.sum) / (a.n + b.n);
        if (Math.abs(a.sum - b.sum) / avg >= 1) {
          line += `；差额约合 ${(Math.abs(a.sum - b.sum) / avg).toFixed(1)} 笔该类的平均消费（两期平均每笔 ${fmt2(avg)} 元）`;
        }
      }
    } else if (a.n) {
      line += `；平均每笔 ${fmt2(a.sum / a.n)} 元`;
    }
    S.add(`${line}。`);
  }
}

function bandsSection(S, cur, prev, w, dailyOnly) {
  const sum = total(cur);
  S.section(`财务·单笔金额分档（判断「少数大额」还是「多笔小额」${dailyOnly ? "；剔除项目" : ""}）`);
  for (const [lo, hi, name] of [[0, 50, "50 元以下"], [50, 200, "50–200 元"], [200, 1000, "200–1000 元"], [1000, Infinity, "1000 元及以上"]]) {
    const xs = cur.filter((r) => r.amount >= lo && r.amount < hi);
    let line = `本期单笔${name}：${xs.length} 笔，合计 ${fmt2(total(xs))} 元，占${dailyOnly ? "日常" : "本期"}支出 ${sum ? ((total(xs) / sum) * 100).toFixed(1) : "0.0"}%`;
    if (w.hasPrev) {
      const ys = prev.filter((r) => r.amount >= lo && r.amount < hi);
      line += `；上期 ${ys.length} 笔，合计 ${fmt2(total(ys))} 元`;
    }
    S.add(`${line}。`);
  }
}

const isCJK = (t) => /[\u4e00-\u9fff]/.test(t);

/** 备注里跨条出现的同一个词（人名/事项）归并；过滤系统标签与过长短词 */
function tokenSection(S, scope, scopeName, scopeTotal) {
  const stats = new Map();
  for (const r of scope) {
    const note = (r.text || "").trim();
    for (const t of new Set(note.split(/\s+/))) {
      if (!t || t.length > (isCJK(t) ? 6 : 12) || t.includes("自动") || /^[\d.]+$/.test(t)) continue;
      const s = stats.get(t) ?? { n: 0, sum: 0, notes: new Set(), items: [] };
      s.n += 1;
      s.sum += Number(r.amount) || 0;
      s.notes.add(note);
      s.items.push(r);
      stats.set(t, s);
    }
  }
  const picked = [...stats.entries()].filter(([, s]) => s.n >= 2 && s.notes.size >= 2).sort((a, b) => b[1].sum - a[1].sum).slice(0, 6);
  if (!picked.length) return;
  S.section(`财务·备注里反复出现的人或事（${scopeName}；不同备注里出现同一个词就归到一起）`);
  for (const [t, s] of picked) {
    const items = s.items.sort((a, b) => a.t - b.t).map((r) => `${md(r.t)}「${r.text || ""}」${fmt2(r.amount)} 元（${r.category}）`).join("、");
    S.add(`「${t}」：${s.n} 笔，合计 ${fmt2(s.sum)} 元，占${scopeName}支出 ${scopeTotal ? ((s.sum / scopeTotal) * 100).toFixed(1) : "0.0"}%：${items}。`);
  }
}

function projectSection(S, snapshot, rows) {
  const projs = new Map();
  for (const r of rows) {
    if (isProj(r) && expense(r)) {
      const list = projs.get(r.project) ?? [];
      list.push(r);
      projs.set(r.project, list);
    }
  }
  for (const [p, ex] of projs) {
    ex.sort((a, b) => a.t - b.t);
    const tot = total(ex);
    S.section(`财务·项目「${p}」（快照内全部记录，不限本期）`);
    S.add(`项目「${p}」：支出合计 ${fmt2(tot)} 元，共 ${ex.length} 笔，记录日期从 ${ymd(ex[0].t)} 到 ${ymd(ex[ex.length - 1].t)}。`);
    for (const [c, v] of [...byCat(ex).entries()].sort((a, b) => b[1].sum - a[1].sum)) {
      S.add(`项目「${p}」分类 ${c}：${fmt2(v.sum)} 元（${v.n} 笔，占该项目 ${tot ? ((v.sum / tot) * 100).toFixed(1) : "0.0"}%）。`);
    }
    for (const r of [...ex].sort((a, b) => b.amount - a.amount).slice(0, 8)) {
      S.add(`项目「${p}」大额：${ymd(r.t)} ${fmt2(r.amount)} 元，${r.category}，「${r.text || "无"}」。`);
    }
    const daily = new Map();
    for (const r of ex) daily.set(ymd(r.t), (daily.get(ymd(r.t)) ?? 0) + r.amount);
    S.add(`项目「${p}」花钱最多的 5 天：${[...daily.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([d, v]) => `${d.slice(5)} ${fmt2(v)} 元`).join("；")}。`);
    tokenSection(S, ex, `项目「${p}」`, tot);
    const hist = monthlyDailySpend(snapshot, rows);
    const full = hist.filter((h) => h.full).map((h) => h.sum);
    if (full.length >= 2) {
      S.add(`项目「${p}」的花费约等于 ${(tot / median(full)).toFixed(1)} 个月的日常支出（按过去 ${full.length} 个完整自然月剔除项目后日常支出的中位数 ${fmt2(median(full))} 元）。`);
    }
  }
}

function monthlyDailySpend(snapshot, rows) {
  return monthSpans(snapshot).map((s) => ({
    label: s.label,
    full: s.full,
    sum: total(rows.filter((r) => expense(r) && !isProj(r) && r.t >= s.start && r.t < s.end)),
  }));
}

function fixedLargeCategories(spans, rows) {
  const cnt = new Map();
  for (const s of spans.filter((s) => s.full)) {
    for (const c of new Set(rows.filter((r) => expense(r) && !isProj(r) && r.t >= s.start && r.t < s.end && r.amount >= 1000).map((r) => r.category))) {
      cnt.set(c, (cnt.get(c) ?? 0) + 1);
    }
  }
  return [...cnt.entries()].filter(([, k]) => k >= 3).map(([c]) => c);
}

function historySection(S, snapshot, rows, w) {
  const spans = monthSpans(snapshot);
  const hist = monthlyDailySpend(snapshot, rows);
  const full = hist.filter((h) => h.full);
  if (full.length < 2) return null;
  const fixed = fixedLargeCategories(spans, rows);
  S.section("财务·个人历史（自然月，剔除项目后的日常支出）");
  for (const s of spans) {
    const xs = rows.filter((r) => expense(r) && !isProj(r) && r.t >= s.start && r.t < s.end);
    const big = xs.filter((r) => r.amount >= 1000 && !fixed.includes(r.category)).sort((a, b) => b.amount - a.amount);
    S.add(`${s.label}日常支出 ${fmt2(total(xs))} 元${big.length ? `，其中单笔 1000 元以上的非固定大额：${big.map((r) => `${r.category}「${r.text || "无备注"}」${fmt2(r.amount)} 元`).join("、")}` : ""}。`);
  }
  if (fixed.length) {
    S.note(`每月固定出现的大额分类（不算非固定大额）：${fixed.join("、")}`);
    for (const c of fixed) {
      const items = rows.filter((r) => expense(r) && !isProj(r) && r.category === c && r.amount >= 1000).sort((a, b) => a.t - b.t);
      const amts = new Set(items.map((r) => Math.round(r.amount * 100) / 100));
      const notes = new Set(items.map((r) => (r.text || "").trim()).filter(Boolean));
      let line = `固定大额·${c}：${items.length} 笔，${amts.size === 1 ? `每笔都是 ${fmt2(items[0].amount)} 元` : `金额 ${[...amts].sort((a, b) => a - b).map(fmt2).join("、")} 元`}，从 ${md(items[0].t)} 到 ${md(items[items.length - 1].t)} 大约每月一笔${notes.size ? `，备注「${[...notes].join("」「")}」` : ""}`;
      if (amts.size === 1 && items.length >= 3) line += "；每月同一金额，像是分期或固定订阅，不是一次性购买";
      S.add(`${line}。`);
    }
  }
  const vals = full.map((h) => h.sum);
  const lo = full.reduce((a, b) => (b.sum < a.sum ? b : a));
  const hi = full.reduce((a, b) => (b.sum > a.sum ? b : a));
  S.add(`过去 ${full.length} 个完整自然月，日常支出月均 ${fmt2(mean(vals))} 元、中位数 ${fmt2(median(vals))} 元；最低是${lo.label} ${fmt2(lo.sum)} 元，最高是${hi.label} ${fmt2(hi.sum)} 元（偏高的月份多半有非固定大额，见上）。`);
  if (w.hasPrev) {
    const curSum = total(rows.filter((r) => expense(r) && !isProj(r) && inWin(r.t, w.startMs, w.endMs)));
    const rank = 1 + vals.filter((v) => v < curSum).length;
    S.add(`本期（约 ${Math.round((w.endMs - w.startMs) / 86400_000)} 天）日常支出 ${fmt2(curSum)} 元，比这 ${full.length} 个月的中位数${delta(curSum, median(vals))}；和这 ${full.length} 个月放在一起从低到高排第 ${rank}。`);
  }
  return fixed;
}

function habitRows(snapshot) {
  const by = new Map();
  for (const r of snapshot?.datasets?.["habit.daily"]?.rows ?? []) {
    if (!r.occurredAt || !r.habit) continue;
    const t = Date.parse(r.occurredAt);
    if (!Number.isFinite(t)) continue;
    const list = by.get(r.habit) ?? [];
    list.push({ ...r, t });
    by.set(r.habit, list);
  }
  for (const list of by.values()) list.sort((a, b) => a.t - b.t);
  return by;
}

function habitSection(S, snapshot, w, rows, skipCurrent) {
  const by = habitRows(snapshot);
  if (!by.size) return;
  if (!skipCurrent) {
    S.section("习惯（「完成」= 当天有打卡；计数型给数量；测量型给测量值）");
    for (const [name, rs] of by) {
      const h = rs[0];
      const cur = rs.filter((r) => inWin(r.t, w.startMs, w.endMs));
      const prev = w.hasPrev ? rs.filter((r) => inWin(r.t, w.prevStartMs, w.startMs - 1)) : [];
      const days = (w.endMs - w.startMs) / 86400_000;
      if (h.type === "check") {
        const d = cur.filter((r) => r.value > 0).length;
        const p = prev.filter((r) => r.value > 0).length;
        S.add(`${name}（打卡型，目标 ${h.goal}）：本期完成 ${d} 天，约每周 ${((d * 7) / days).toFixed(1)} 次${w.hasPrev ? `；上期完成 ${p} 天，约每周 ${((p * 7) / days).toFixed(1)} 次；完成天数${delta(d, p, "天", 0)}` : ""}。`);
      } else if (h.type === "count") {
        const tw = cur.reduce((a, r) => a + (r.value || 0), 0);
        const tp = prev.reduce((a, r) => a + (r.value || 0), 0);
        const over = cur.filter((r) => h.goal && r.value > h.goal).length;
        S.add(`${name}（计数型，${h.polarity === "negative" ? "每日上限" : "每日目标"} ${h.goal} ${h.unit || ""}）：本期累计 ${g(tw)} ${h.unit || ""}，日均 ${(tw / days).toFixed(1)} ${h.unit || ""}，超过上限 ${over} 天${w.hasPrev ? `；上期累计 ${g(tp)} ${h.unit || ""}，日均 ${(tp / days).toFixed(1)} ${h.unit || ""}，超过上限 ${prev.filter((r) => h.goal && r.value > h.goal).length} 天` : ""}。`);
        if (h.polarity === "negative") quitJuxtapose(S, name, cur, tw, rows, w, h);
      } else if (h.type === "measure") {
        const mv = cur.filter((r) => typeof r.value === "number" && r.value > 0).map((r) => r.value);
        const mp = prev.filter((r) => typeof r.value === "number" && r.value > 0).map((r) => r.value);
        S.add(`${name}（测量型，单位 ${h.unit || "无"}）：本期测量 ${mv.length} 次${mv.length ? `，均值 ${mean(mv).toFixed(2)}，最近一次 ${g(mv[mv.length - 1])}` : "（无测量记录）"}${w.hasPrev ? `；上期测量 ${mp.length} 次${mp.length ? `，均值 ${mean(mp).toFixed(2)}` : "（无测量记录）"}` : ""}。`);
      }
    }
  }
  const spans = monthSpans(snapshot);
  S.section("习惯·个人历史（快照全部记录，按自然月）");
  for (const [name, rs] of by) {
    const parts = [];
    for (const s of spans) {
      const xs = rs.filter((r) => r.t >= s.start && r.t < s.end);
      if (!xs.length) continue;
      if (xs[0].type === "check") parts.push(`${s.label} 完成 ${xs.filter((r) => r.value > 0).length} 天`);
      else if (xs[0].type === "count") parts.push(`${s.label} 日均 ${(xs.reduce((a, r) => a + (r.value || 0), 0) / Math.max((s.end - s.start) / 86400_000, 1)).toFixed(1)} ${xs[0].unit || ""}`);
      else {
        const mv = xs.filter((r) => r.value > 0).map((r) => r.value);
        if (mv.length) parts.push(`${s.label} 均值 ${mean(mv).toFixed(2)} ${xs[0].unit || ""}`);
      }
    }
    if (parts.length) S.add(`${name}按月：${parts.join("；")}。`);
  }
  const genDay = localDate(w.genMs);
  const yesterdayEnd = Date.UTC(genDay.getUTCFullYear(), genDay.getUTCMonth(), genDay.getUTCDate()) - TZ_OFFSET_MS - 1;
  for (const [name, rs] of by) {
    if (rs[0].type !== "check") {
      if (rs[0].type === "count") {
        const wd = new Map();
        for (const r of rs) {
          const k = localDate(r.t).getUTCDay();
          wd.set(k, [...(wd.get(k) ?? []), r.value || 0]);
        }
        const goal = rs[0].goal;
        S.add(`${name}：按星期的日均数量 ${WD.map((n, i) => wd.has(i) ? `${n} ${mean(wd.get(i)).toFixed(1)}` : null).filter(Boolean).join("、")}；超过每日上限 ${goal} 的天数按星期 ${WD.map((n, i) => `${n} ${(wd.get(i) ?? []).filter((v) => goal && v > goal).length}`).join("、")}。`);
      }
      continue;
    }
    const done = rs.filter((r) => r.value > 0).map((r) => r.t);
    if (done.length < 4) {
      S.add(`${name}：快照内只完成 ${done.length} 次，样本太少，不能判断中断和恢复的规律。`);
      continue;
    }
    const wdCnt = new Map();
    for (const t of done) wdCnt.set(localDate(t).getUTCDay(), (wdCnt.get(localDate(t).getUTCDay()) ?? 0) + 1);
    const maxWd = Math.max(...wdCnt.values());
    S.add(`${name}：快照内完成 ${done.length} 次；完成次数按星期 ${WD.map((n, i) => `${n} ${wdCnt.get(i) ?? 0}`).join("、")}，最多的是${WD.filter((_, i) => wdCnt.get(i) === maxWd).join("、")}。`);
    const last = done[done.length - 1];
    const missedDays = Math.floor((yesterdayEnd - last) / 86400_000);
    if (missedDays < 2) {
      S.add(`${name}：最近一次完成是 ${md(last)}（${weekday(last)}），目前没有中断。`);
      continue;
    }
    const gaps = [];
    for (let i = 1; i < done.length; i += 1) {
      const gapDays = Math.floor((done[i] - done[i - 1]) / 86400_000) - 1;
      if (gapDays >= 4) gaps.push({ days: gapDays, resume: done[i] });
    }
    let line = `${name}：最近一次完成是 ${md(last)}（${weekday(last)}），之后到昨天已有 ${missedDays} 天没有完成（今天不算）`;
    if (gaps.length) {
      const lens = gaps.map((x) => x.days);
      const rCnt = new Map();
      for (const x of gaps) rCnt.set(localDate(x.resume).getUTCDay(), (rCnt.get(localDate(x.resume).getUTCDay()) ?? 0) + 1);
      const topR = Math.max(...rCnt.values());
      line += `；过去中断 4 天以上共 ${gaps.length} 次，中断天数中位数 ${median(lens)} 天、最长 ${Math.max(...lens)} 天，其中比这次更长的有 ${lens.filter((d) => d > missedDays).length} 次；中断后恢复的那天最常见的是${WD.filter((_, i) => rCnt.get(i) === topR).join("、")}（${gaps.length} 次里有 ${topR} 次）`;
    }
    S.add(`${line}。`);
  }
}

/** 戒断类习惯与相关消费并列（只并列不推算） */
function quitJuxtapose(S, name, cur, tw, rows, w, h) {
  const kw = name.replace(/^[戒少不控减]/, "");
  if (!kw) return;
  const related = rows.filter((r) => expense(r) && inWin(r.t, w.startMs, w.endMs) && (r.category || "").includes(kw) || (r.text || "").includes(kw) && expense(r) && inWin(r.t, w.startMs, w.endMs));
  if (!related.length) return;
  const shown = related.sort((a, b) => a.t - b.t).slice(-8);
  S.add(`${name}与相关消费并列（分类或备注含「${kw}」，只并列不推算）：本期记录累计 ${g(tw)} ${h.unit || ""}；同期相关消费 ${related.length} 笔，合计 ${fmt2(total(related))} 元（${related.length > 8 ? "最近 8 笔：" : ""}${shown.map((r) => `${md(r.t)} ${fmt2(r.amount)} 元（${r.category}${r.text ? `，「${r.text}」` : ""}）`).join("、")}）。每笔买了多少，账单里没有记。`);
}

function counterSection(S, snapshot, w) {
  const spans = monthSpans(snapshot);
  for (const [dataset, title, unit, isTask] of [["task.daily", "任务", "个", true], ["thought.daily", "想法记录", "条", false]]) {
    const rows = (snapshot?.datasets?.[dataset]?.rows ?? [])
      .map((r) => ({ ...r, t: Date.parse(r.occurredAt) }))
      .filter((r) => Number.isFinite(r.t));
    if (!rows.length) continue;
    S.section(title);
    const cur = rows.filter((r) => inWin(r.t, w.startMs, w.endMs));
    const prev = w.hasPrev ? rows.filter((r) => inWin(r.t, w.prevStartMs, w.startMs - 1)) : [];
    const n = cur.reduce((a, r) => a + (r.value || 0), 0);
    const d = cur.filter((r) => r.value > 0).length;
    let line = `本期${isTask ? "完成任务" : "记录想法"} ${g(n)} ${unit}，分布在 ${d} 天`;
    if (isTask) line += `（其中高优先级 ${g(cur.reduce((a, r) => a + (r.highPriorityValue || 0), 0))} 个）`;
    if (w.hasPrev) {
      const np = prev.reduce((a, r) => a + (r.value || 0), 0);
      const dp = prev.filter((r) => r.value > 0).length;
      line += `；上期 ${g(np)} ${unit}，分布在 ${dp} 天；${delta(n, np, unit, 0)}`;
    }
    S.add(`${line}。${isTask ? "任务内容不在数据里，原因不能判断。" : "想法正文不在数据里，主题和原因不能判断。"}`);
    S.add(`${title}按月：${spans.map((s) => `${s.label} ${g(rows.filter((r) => r.t >= s.start && r.t < s.end).reduce((a, r) => a + (r.value || 0), 0))} ${unit}`).join("；")}。`);
  }
}

function pearson(xs, ys) {
  const n = xs.length;
  const mx = mean(xs);
  const my = mean(ys);
  let cov = 0;
  let vx = 0;
  let vy = 0;
  for (let i = 0; i < n; i += 1) {
    cov += (xs[i] - mx) * (ys[i] - my);
    vx += (xs[i] - mx) ** 2;
    vy += (ys[i] - my) ** 2;
  }
  return vx <= 0 || vy <= 0 ? null : cov / (Math.sqrt(vx) * Math.sqrt(vy));
}

/** 与 iOS 生活体检台账同口径：按天对齐、对齐≥10 天、|r|≥0.35、Top3 */
function comovementSection(S, snapshot, w) {
  const dayKey = (t) => ymd(t);
  const spend = new Map();
  for (const r of financeRows(snapshot)) {
    if (expense(r) && inWin(r.t, w.startMs, w.endMs)) spend.set(dayKey(r.t), (spend.get(dayKey(r.t)) ?? 0) + r.amount);
  }
  const seriesOf = (dataset, pick) => {
    const m = new Map();
    for (const r of snapshot?.datasets?.[dataset]?.rows ?? []) {
      const t = Date.parse(r.occurredAt);
      if (Number.isFinite(t) && inWin(t, w.startMs, w.endMs)) {
        const k = dayKey(t);
        const v = pick(r);
        if (v != null) m.set(k, (m.get(k) ?? 0) + v);
      }
    }
    return m;
  };
  const tasks = seriesOf("task.daily", (r) => r.value);
  const thoughts = seriesOf("thought.daily", (r) => r.value);
  const met = new Map();
  for (const [, rs] of habitRows(snapshot)) {
    if (rs[0].type !== "check" || rs[0].polarity !== "positive") continue;
    for (const r of rs) {
      if (r.value > 0 && inWin(r.t, w.startMs, w.endMs)) {
        const k = dayKey(r.t);
        met.set(k, (met.get(k) ?? 0) + 1);
      }
    }
  }
  const series = [["每日支出", spend], ["完成任务数", tasks], ["想法条数", thoughts], ["达标习惯数", met]].filter(([, m]) => m.size >= 10);
  const hasHealth = Boolean(snapshot?.datasets?.["health.sleep"]?.rows?.length || snapshot?.datasets?.["health.steps"]?.rows?.length);
  S.section("一起变化检查（按天对齐）");
  if (!series.length) {
    S.add("检查范围：本期各领域按天记录不足 10 天，做不了按天对齐的同步变化检查。");
  } else {
    S.add(`检查范围：本期内${series.map(([n]) => n).join("、")}两两之间按天对齐的同步变化（至少对齐 10 天、相关系数绝对值达到 0.35 才算）。${hasHealth ? "" : "睡眠、步数本次没有数据，没参与。"}`);
  }
  const found = [];
  for (let i = 0; i < series.length; i += 1) {
    for (let j = i + 1; j < series.length; j += 1) {
      const keys = [...series[i][1].keys()].filter((k) => series[j][1].has(k));
      if (keys.length < 10) continue;
      const r = pearson(keys.map((k) => series[i][1].get(k)), keys.map((k) => series[j][1].get(k)));
      if (r != null && Math.abs(r) >= 0.35) found.push({ a: series[i][0], b: series[j][0], r, n: keys.length });
    }
  }
  if (found.length) {
    for (const f of found.sort((x, y) => Math.abs(y.r) - Math.abs(x.r)).slice(0, 3)) {
      S.add(`${f.a} 与 ${f.b}：相关系数 ${f.r >= 0 ? "+" : "-"}${Math.abs(f.r).toFixed(2)}，对齐 ${f.n} 天（${f.r > 0 ? "同向" : "反向"}变化，只代表同时发生，不代表因果）。`);
    }
  } else {
    S.add("结果：本期没有发现达到标准的「一起变化」。");
  }
}

function healthSection(S, snapshot, w) {
  const sleep = (snapshot?.datasets?.["health.sleep"]?.rows ?? [])
    .map((r) => ({ ...r, t: Date.parse(r.occurredAt) }))
    .filter((r) => Number.isFinite(r.t) && typeof r.value === "number");
  if (sleep.length) {
    const cur = sleep.filter((r) => inWin(r.t, w.startMs, w.endMs));
    const prev = w.hasPrev ? sleep.filter((r) => inWin(r.t, w.prevStartMs, w.startMs - 1)) : [];
    const vals = cur.map((r) => r.value);
    if (vals.length) {
      S.section("健康·睡眠（时长单位小时；结构字段缺失代表设备没记录，不是 0）");
      S.add(`本期睡眠日均 ${mean(vals).toFixed(1)} 小时，共 ${vals.length} 晚；最短 ${Math.min(...vals).toFixed(1)} 小时、最长 ${Math.max(...vals).toFixed(1)} 小时，不足 6 小时 ${vals.filter((v) => v < 6).length} 晚。`);
      if (prev.length) S.add(`上期日均 ${mean(prev.map((r) => r.value)).toFixed(1)} 小时（${prev.length} 晚）；${delta(mean(vals), mean(prev.map((r) => r.value)), "小时", 1)}。`);
      const withStage = cur.filter((r) => typeof r.deepHours === "number");
      if (withStage.length) {
        S.add(`睡眠结构（${withStage.length} 晚有阶段数据）：深睡日均 ${mean(withStage.map((r) => r.deepHours)).toFixed(1)} 小时、REM 日均 ${mean(withStage.map((r) => r.remHours)).toFixed(1)} 小时${cur.some((r) => typeof r.efficiency === "number") ? `，睡眠效率均值 ${mean(cur.filter((r) => typeof r.efficiency === "number").map((r) => r.efficiency)).toFixed(0)}` : ""}。只能评估时长与结构，不做睡眠质量的医学判断。`);
      } else {
        S.add("本期没有睡眠阶段数据（需要佩戴手表等设备），只能评估时长，不能判断睡眠质量。");
      }
    }
  }
  const steps = (snapshot?.datasets?.["health.steps"]?.rows ?? [])
    .map((r) => ({ ...r, t: Date.parse(r.occurredAt) }))
    .filter((r) => Number.isFinite(r.t) && typeof r.value === "number");
  if (steps.length) {
    const cur = steps.filter((r) => inWin(r.t, w.startMs, w.endMs));
    const prev = w.hasPrev ? steps.filter((r) => inWin(r.t, w.prevStartMs, w.startMs - 1)) : [];
    if (cur.length) {
      S.add(`本期步数日均 ${Math.round(mean(cur.map((r) => r.value)))} 步（${cur.length} 天）${prev.length ? `；上期日均 ${Math.round(mean(prev.map((r) => r.value)))} 步` : ""}。`);
    }
  }
}

function contextSection(S, snapshot, rows) {
  S.section("其他背景与口径");
  const datasets = snapshot?.datasets ?? {};
  if (!Object.keys(datasets).some((k) => k.startsWith("health."))) {
    S.add("睡眠、步数等健康数据：本次快照没有记录，不能判断。");
  }
  S.add("目标进度：快照里没有目标进度记录，不能判断。");
  S.add("预算：快照里没有预算数据，不能说超预算或达成预算。");
  const midnight = rows.filter((r) => r.occurredAt.slice(11, 16) === "00:00").length;
  if (rows.length) {
    const share = Math.round((midnight / rows.length) * 100);
    if (share >= 5) S.add(`账单里 ${share}% 的记录时刻是 00:00 整（补记的默认时刻），不能据此判断几点花的钱。`);
  }
  for (const r of (datasets["anniversary.events"]?.rows ?? []).slice(0, 3)) {
    if (r.title) S.add(`纪念日：${r.title} 还有 ${r.daysUntil} 天（${String(r.occurredAt).slice(0, 10)}）。`);
  }
  const insights = (datasets["insight.records"]?.rows ?? []).slice(0, 6);
  if (insights.length) {
    S.note(`Holo 近期写过的回放标题（背景，不含新数字）：${insights.map((r) => `${String(r.occurredAt).slice(5, 10)}「${r.title}」`).join("；")}`);
  }
}

export function computeFactSheet(snapshot) {
  const w = resolveAnalysisWindow(snapshot);
  const S = new Sheet();
  const today = localDate(w.genMs);
  S.header(`分析范围：${ymd(w.startMs)} ${localDate(w.startMs).toISOString().slice(11, 16)} 至 ${ymd(w.endMs)} ${localDate(w.endMs).toISOString().slice(11, 16)}（${w.label}，约 ${Math.round((w.endMs - w.startMs) / 86400_000)} 天）。${w.hasPrev ? `「上期」= 紧挨着的前一段同样长度：${ymd(w.prevStartMs)} 至 ${ymd(w.startMs - 1)}。` : "本题没有指定时间，范围是快照全部数据，不做上期对比。"}今天是 ${ymd(w.genMs)}（${weekday(w.genMs)}）。`);
  const rows = financeRows(snapshot);
  financeSection(S, snapshot, rows, w);
  projectSection(S, snapshot, rows);
  historySection(S, snapshot, rows, w);
  // 快照自带的 crossDomainCheckup/financeEvidenceLedger 台账刻意不进清单：
  // 台账按 29 天窗、清单按问句冻结窗，两套数字同页会让模型混用口径（评测实锤）；
  // 习惯的每周目标语义因此退化为按天折算，与实验验证配置一致。台账仍随快照留存。
  habitSection(S, snapshot, w, rows, false);
  counterSection(S, snapshot, w);
  comovementSection(S, snapshot, w);
  healthSection(S, snapshot, w);
  contextSection(S, snapshot, rows);
  return { ...S.build(), window: w };
}
