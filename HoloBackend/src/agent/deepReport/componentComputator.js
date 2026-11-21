// 深度报告数据组件计算器（2026-11-20 报告改版 C1）：纯程序从快照算出「可以画成组件」的数据，
// 模型不产数字。每个组件带 keywords（就位用，mapper 找第一个提到关键词的小节）或 anchorTitle
// （目标骨架小节关键词），并附 factLines——同一批数字写进事实清单，正文与组件同源、过数字核对。
// 门槛（数据不够就不出）：习惯条需窗口 ≥7 天且该习惯有记录；按月柱需 ≥3 个月且非全零；
// 测量型趋势需 ≥4 个周均点。方案：docs/_common/plans/2026-11-20-深度报告可读性与目标复盘改版/01-方案.md §3.1
export const DAY_MS = 86400_000;
const TZ_OFFSET_MS = 8 * 3600 * 1000;

export const dayIndex = (ms) => Math.floor((ms + TZ_OFFSET_MS) / DAY_MS);
export const mdLabel = (ms) => {
  const d = new Date(ms + TZ_OFFSET_MS);
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
};
const round1 = (n) => Math.round(n * 10) / 10;
const fmt1 = (n) => String(round1(n));
const sum = (xs) => xs.reduce((a, b) => a + b, 0);

/** 逐日 0/1：窗口末日往前 days 天（旧→新） */
export function dailyOnOff(rows, endMs, days, isOn = (r) => Number(r.value) > 0) {
  const endDay = dayIndex(endMs - 1);
  const startDay = endDay - days + 1;
  const out = new Array(days).fill(0);
  for (const r of rows) {
    const t = Date.parse(r.occurredAt ?? r.date ?? "");
    if (!Number.isFinite(t)) continue;
    const i = dayIndex(t) - startDay;
    if (i >= 0 && i < days && isOn(r)) out[i] = 1;
  }
  return out;
}

/** 状态规则（程序判定，方案 §3.1）：稳 / 略降 / 掉档 / 已停 / 回升；数据不足返回 null */
export const RECENT_DAYS = 21;
export function habitStatus(days) {
  const n = days.length;
  const total = sum(days);
  if (!total) return null;
  if (n >= 21 && sum(days.slice(-14)) === 0 && total >= 3) {
    return { label: "已停", tone: "bad", early: total * 7 / n, late: 0 };
  }
  if (n < 35) return null;
  const earlyDays = days.slice(0, n - RECENT_DAYS);
  const late = (sum(days.slice(-RECENT_DAYS)) * 7) / RECENT_DAYS;
  const early = (sum(earlyDays) * 7) / earlyDays.length;
  if (early === 0) return late > 0 ? { label: "回升", tone: "good", early, late } : null;
  const ratio = late / early;
  if (ratio >= 0.8) return { label: "稳", tone: "good", early, late };
  if (ratio < 0.7) return { label: "掉档", tone: "bad", early, late };
  return { label: "略降", tone: "warn", early, late };
}

/** 一个习惯的组件行 + 事实句 */
export function habitStripRow(name, days, sub = null) {
  const status = habitStatus(days);
  const doneDays = sum(days);
  const weeks = Math.round(days.length / 7);
  const perWeek = (doneDays * 7) / days.length;
  const row = {
    name,
    sub: sub ?? `约每周 ${fmt1(perWeek)} 次`,
    rateText: `${doneDays} 天`,
    statusLabel: status?.label ?? null,
    tone: status?.tone ?? null,
    days,
  };
  let fact = `${name}：近 ${weeks} 周有 ${doneDays} 天完成，约每周 ${fmt1(perWeek)} 次`;
  if (status?.label === "已停") {
    fact += `；最近 14 天没有记录（程序判定：已停）`;
  } else if (status) {
    fact += `；前 ${weeks - 3} 周约每周 ${fmt1(status.early)} 次，近 3 周约每周 ${fmt1(status.late)} 次（程序判定：${status.label}）`;
  }
  return { row, status, fact: `${fact}。`, change: status ? Math.abs(status.late - status.early) + (status.label === "已停" ? 10 : 0) : 0 };
}

/** 每周均值序列（测量型：体重等），按窗口末日往前对齐的整周切块 */
export function weeklyAverages(rows, endMs, weeks, valueOf = (r) => Number(r.value)) {
  const endDay = dayIndex(endMs - 1);
  const points = [];
  for (let w = weeks - 1; w >= 0; w -= 1) {
    const hi = endDay - w * 7;
    const lo = hi - 6;
    const vals = rows
      .filter((r) => {
        const t = Date.parse(r.occurredAt ?? r.date ?? "");
        if (!Number.isFinite(t)) return false;
        const d = dayIndex(t);
        return d >= lo && d <= hi;
      })
      .map(valueOf)
      .filter((v) => Number.isFinite(v) && v > 0);
    // 标签 = 该周首日（本地日界）
    if (vals.length) points.push({ label: mdLabel(lo * DAY_MS - TZ_OFFSET_MS), value: round1(sum(vals) / vals.length) });
  }
  return points;
}

function habitRowsByName(snapshot) {
  const by = new Map();
  for (const r of snapshot?.datasets?.["habit.daily"]?.rows ?? []) {
    if (!r?.habit) continue;
    const list = by.get(r.habit) ?? [];
    list.push(r);
    by.set(r.habit, list);
  }
  return by;
}

export function windowDays(w, cap = 56) {
  const end = Math.min(w.endMs, w.genMs ?? w.endMs);
  return Math.max(0, Math.min(cap, Math.round((end - w.startMs) / DAY_MS)));
}

/** 通用报告组件（非目标）：习惯条 / 任务与想法按月柱 / 测量型习惯周均趋势 */
export function computeGenericComponents(snapshot, w) {
  const components = [];
  const factLines = [];
  const endMs = Math.min(w.endMs, w.genMs ?? w.endMs);
  const days = windowDays(w);
  const byHabit = habitRowsByName(snapshot);

  // 1) 习惯条：打卡型 + 正向计数型（戒断类上限语义相反，不画「完成」格）
  if (days >= 7) {
    const candidates = [];
    for (const [name, rows] of byHabit) {
      const h = rows[0];
      if (h.type === "measure" || h.polarity === "negative") continue;
      const onOff = dailyOnOff(rows, endMs, days);
      if (!sum(onOff)) continue;
      candidates.push(habitStripRow(name, onOff));
    }
    candidates.sort((a, b) => b.change - a.change);
    if (candidates.length) {
      const shown = candidates.slice(0, 4);
      factLines.push(...shown.map((c) => c.fact));
      components.push({
        kind: "habitStrip",
        keywords: shown.map((c) => c.row.name),
        payload: {
          title: `习惯 · 近 ${Math.round(days / 7)} 周 · 每格 1 天`,
          rows: shown.map((c) => c.row),
          foldedNote: candidates.length > 4 ? `其他 ${candidates.length - 4} 个习惯变化不大，未展开` : null,
          startLabel: mdLabel(endMs - days * DAY_MS),
          endLabel: "今天",
        },
      });
    }
  }

  // 2) 测量型习惯（体重等）周均趋势：≥4 个周均点
  for (const [name, rows] of byHabit) {
    if (rows[0].type !== "measure") continue;
    const points = weeklyAverages(rows, endMs, Math.min(12, Math.max(1, Math.round(days / 7))));
    if (points.length < 4) continue;
    factLines.push(`${name}每周平均值（近 ${points.length} 周）：${points.map((p) => `${p.label} 那周 ${p.value}`).join("、")}。`);
    components.push({
      kind: "trendLine",
      keywords: [name],
      payload: { title: `${name}每周平均`, unit: rows[0].unit || null, points, caption: null },
    });
    break; // 一份通用报告最多一张趋势图，图多了又变回堆砌
  }

  // 3) 任务 / 想法按月柱：窗口 ≥60 天、≥3 个月、非全零（只画数量，月份序列不再写进正文）
  if ((w.endMs - w.startMs) / DAY_MS >= 60) {
    for (const [dataset, title, unit, keyword] of [["task.daily", "每月完成任务", "个", "任务"], ["thought.daily", "每月想法记录", "条", "想法"]]) {
      const rows = snapshot?.datasets?.[dataset]?.rows ?? [];
      if (!rows.length) continue;
      const bars = monthlyBars(rows, w.startMs, endMs);
      if (bars.length < 3 || bars.every((b) => b.value === 0)) continue;
      const last = bars[bars.length - 1];
      components.push({
        kind: "barSeries",
        keywords: [keyword],
        payload: { title, unit, bars, caption: last.partial ? `${last.label}还没过完` : null },
      });
    }
  }
  return { components, factLines };
}

function monthlyBars(rows, startMs, endMs) {
  const buckets = new Map();
  for (const r of rows) {
    const t = Date.parse(r.occurredAt ?? r.date ?? "");
    if (!Number.isFinite(t) || t < startMs || t > endMs) continue;
    const d = new Date(t + TZ_OFFSET_MS);
    const key = d.getUTCFullYear() * 100 + d.getUTCMonth();
    buckets.set(key, (buckets.get(key) ?? 0) + (Number(r.value) || 0));
  }
  const endDate = new Date(endMs + TZ_OFFSET_MS);
  const endKey = endDate.getUTCFullYear() * 100 + endDate.getUTCMonth();
  return [...buckets.keys()].sort((a, b) => a - b).slice(-6).map((key) => ({
    label: `${(key % 100) + 1}月`,
    value: buckets.get(key),
    partial: key === endKey,
  })).map(({ partial, ...bar }) => ({ ...bar, ...(partial ? { partial } : {}) }));
}
