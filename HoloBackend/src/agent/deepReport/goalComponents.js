// 目标复盘的事实与组件（2026-11-20 报告改版 C2）：输入 iOS 冻结的 goalReview（GoalEvaluationSnapshot）
// + 快照数据集，输出「结果进度 / 关联事项状态 / 前后对比 / 缺口 / 起步期里程碑」组件、对应事实句、
// 以及写作骨架（本次允许写哪几个小节）。口径：组件统一看「近 8 周，且不早于目标起点」；
// 结果未知就是未知（缺测/过期不画假进度）；执行与结果分开说。
import {
  DAY_MS, mdLabel, dailyOnOff, habitStripRow, weeklyAverages, RECENT_DAYS,
} from "./componentComputator.js";

const LOOKBACK_CAP_DAYS = 56;
const EARLY_STAGE_DAYS = 14;
const round1 = (n) => Math.round(n * 10) / 10;
const fmt = (n) => {
  if (!Number.isFinite(n)) return "";
  return Math.abs(n) >= 1000 ? Math.round(n).toLocaleString("en-US") : String(round1(n));
};
const clamp01 = (n) => Math.min(1, Math.max(0, n));
const parseMs = (v) => {
  const t = Date.parse(v ?? "");
  return Number.isFinite(t) ? t : null;
};

const WEIGHT_GOAL = /(体重|减重|减肥|减脂|瘦)/;
const DIET_ITEM = /(饮食|吃|餐|热量|卡路里|碳水|外卖)/;

function resultValue(result) {
  if (typeof result?.value === "number") return result.value;
  if (result?.moneyValue != null && Number.isFinite(Number(result.moneyValue))) return Number(result.moneyValue);
  return null;
}

/** 进度状态：结果进度 vs 时间进度（程序判定） */
function progressStatus(fraction, timeFraction) {
  if (fraction == null) return { label: "进行中", tone: "neutral" };
  if (fraction >= 1) return { label: "已达成", tone: "good" };
  if (timeFraction == null) return { label: "进行中", tone: "neutral" };
  const gap = timeFraction - fraction;
  if (gap <= 0.05) return { label: "按计划", tone: "good" };
  if (gap <= 0.15) return { label: "略落后", tone: "warn" };
  return { label: "落后", tone: "bad" };
}

/** 线性外推达成日期：pace=每周变化，remaining=距目标差值；方向不对返回 null */
function etaMs(nowMs, remaining, pace) {
  if (!pace || Math.sign(pace) !== Math.sign(remaining)) return null;
  const weeks = remaining / pace;
  if (!Number.isFinite(weeks) || weeks > 260) return null;
  return nowMs + weeks * 7 * DAY_MS;
}

export function computeGoalComponents(snapshot, w) {
  const gr = snapshot?.goalReview;
  if (!gr || typeof gr !== "object") return null;
  const nowMs = w.genMs ?? Date.now();
  const result = gr.result ?? {};
  const startMs = parseMs(result.baselineObservedAt);
  const deadlineMs = parseMs(gr.deadline);
  const ageDays = startMs ? Math.max(0, Math.floor((nowMs - startMs) / DAY_MS)) : null;
  const lookbackDays = Math.max(7, Math.min(LOOKBACK_CAP_DAYS, ageDays ?? LOOKBACK_CAP_DAYS));
  const weeks = Math.max(1, Math.round(lookbackDays / 7));
  const timeFraction = startMs && deadlineMs && deadlineMs > startMs ? clamp01((nowMs - startMs) / (deadlineMs - startMs)) : null;

  const components = [];
  const factLines = [];
  const gaps = [];
  const unit = result.unit ?? (result.moneyValue != null ? "元" : "");
  const status = result.status ?? "missing";
  const measurable = status !== "not_applicable";
  const value = resultValue(result);

  factLines.push(`本次复盘的目标是「${gr.goalTitle ?? "这个目标"}」。下面的组件与本节数字统一按近 ${weeks} 周（不早于目标起点）计算${ageDays != null ? `；目标已进行 ${ageDays} 天` : ""}${timeFraction != null ? `，时间已过 ${Math.round(timeFraction * 100)}%` : ""}。`);

  // ---------- 结果 ----------
  const byHabit = new Map();
  for (const r of snapshot?.datasets?.["habit.daily"]?.rows ?? []) {
    if (!r?.habit) continue;
    (byHabit.get(r.habit) ?? byHabit.set(r.habit, []).get(r.habit)).push(r);
  }
  const resultRows = result.sourceKind === "habit" ? byHabit.get(result.sourceLabel) ?? [] : [];
  const seriesPoints = resultRows.length
    ? weeklyAverages(resultRows, nowMs, weeks)
    : (Array.isArray(snapshot?.goalResultSeries?.points) ? snapshot.goalResultSeries.points.filter((p) => Number.isFinite(p?.value)) : []);

  let progressComponent = null;
  let resultPace = null;
  if (measurable) {
    const fraction = typeof result.progressFraction === "number" ? clamp01(result.progressFraction) : null;
    const target = typeof result.targetValue === "number" ? result.targetValue : null;
    const baseline = typeof result.baselineValue === "number" ? result.baselineValue : null;
    if (status === "observed" && value != null) {
      const st = progressStatus(fraction, timeFraction);
      const projections = [];
      if (seriesPoints.length >= 3 && target != null) {
        const n = seriesPoints.length;
        const last = seriesPoints[n - 1].value;
        const overall = (last - seriesPoints[0].value) / (n - 1);
        const remaining = target - last;
        const recent = n >= 5 ? (last - seriesPoints[n - 4].value) / 3 : null;
        resultPace = { overall, recent, early: n >= 5 ? (seriesPoints[n - 4].value - seriesPoints[0].value) / (n - 4) : null };
        const describe = (pace, label) => {
          const eta = etaMs(nowMs, remaining, pace);
          const good = eta != null && (deadlineMs == null || eta <= deadlineMs);
          const valueText = eta == null ? "暂未朝目标方向变化" : `约 ${mdLabel(eta)} 达成`;
          projections.push({ label, value: valueText, tone: good ? "good" : "warn" });
          factLines.push(`${label}（每周约 ${fmt(pace)} ${unit}）：${valueText}${deadlineMs && eta != null ? (good ? "，赶得上截止日" : "，会晚于截止日") : ""}。`);
        };
        describe(overall, "按整体节奏");
        if (recent != null && Math.abs(recent - overall) > Math.abs(overall) * 0.3) describe(recent, "按最近 3 周节奏");
      }
      progressComponent = {
        kind: "progress",
        anchorTitle: null,
        payload: {
          title: `目标进度 · ${result.sourceLabel ?? "结果"}`,
          unit: unit || null,
          current: round1(value),
          start: baseline != null ? round1(baseline) : null,
          target,
          fraction,
          timeFraction,
          statusLabel: st.label,
          tone: st.tone,
          isStale: false,
          caption: [baseline != null ? `起点 ${fmt(baseline)}${unit}${startMs ? `（${mdLabel(startMs)}）` : ""}` : null,
            target != null ? `目标 ${fmt(target)}${unit}${deadlineMs ? `（${mdLabel(deadlineMs)}）` : ""}` : null].filter(Boolean).join(" · ") || null,
          projections,
        },
      };
      factLines.push(`目标结果（${result.sourceLabel ?? "结果"}）：最新 ${fmt(value)}${unit}${parseMs(result.observedAt) ? `（${mdLabel(parseMs(result.observedAt))}）` : ""}${baseline != null ? `，起点 ${fmt(baseline)}${unit}` : ""}${target != null ? `，目标 ${fmt(target)}${unit}` : ""}${fraction != null ? `；结果进度约 ${Math.round(fraction * 100)}%` : ""}（程序判定：${st.label}）。`);
    } else if (status === "stale") {
      const lastMs = parseMs(result.observedAt);
      const gapDays = lastMs ? Math.floor((nowMs - lastMs) / DAY_MS) : null;
      progressComponent = {
        kind: "progress",
        anchorTitle: null,
        payload: {
          title: `目标进度 · ${result.sourceLabel ?? "结果"}`, unit: unit || null,
          current: value != null ? round1(value) : null, start: baseline, target,
          fraction: typeof result.progressFraction === "number" ? clamp01(result.progressFraction) : null,
          timeFraction, statusLabel: "数据中断", tone: "warn", isStale: true,
          caption: lastMs ? `最后一次记录 ${mdLabel(lastMs)}，之后没有新数据` : "最近没有新数据", projections: [],
        },
      };
      gaps.push({ icon: "⏸️", title: gapDays != null ? `结果数据中断 ${gapDays} 天` : "结果数据中断", body: `${lastMs ? `最后一次是 ${mdLabel(lastMs)}，` : ""}现在没法判断进度，也不做完成预测。`, action: "补记一次" });
      factLines.push(`目标结果（${result.sourceLabel ?? "结果"}）已经 ${gapDays ?? "多"} 天没有新记录${value != null ? `，最后一次是 ${fmt(value)}${unit}` : ""}；进度和完成时间都不能判断（程序判定：数据中断）。`);
    } else {
      progressComponent = {
        kind: "progress",
        anchorTitle: null,
        payload: {
          title: `目标进度 · ${result.sourceLabel ?? "结果"}`, unit: unit || null, current: null, start: null, target,
          fraction: null, timeFraction, statusLabel: "缺结果数据", tone: "warn", isStale: true,
          caption: result.unavailableReason ?? "还没有可用的结果记录", projections: [],
        },
      };
      gaps.push({ icon: "📝", title: "还没有结果数据", body: result.unavailableReason ?? "目标的结果指标还没有记录，只能先看行动做得怎么样。", action: "去记录一次" });
      factLines.push(`目标结果（${result.sourceLabel ?? "结果"}）没有可用记录${result.unavailableReason ? `（${result.unavailableReason}）` : ""}，进度不能判断。`);
    }
  } else {
    gaps.push({ icon: "🎯", title: "这个目标没有可衡量的结果", body: "现在只能看到做没做，看不出结果有没有变化。", action: "＋ 给目标加一个结果指标" });
    factLines.push("这个目标是过程型目标，没有结果指标，只能评估行动完成情况。");
  }
  if (progressComponent) components.push(progressComponent);

  if (seriesPoints.length >= 4) {
    const plan = (() => {
      const target = result.targetValue;
      const baseline = result.baselineValue;
      if (typeof target !== "number" || typeof baseline !== "number" || !startMs || !deadlineMs) return null;
      const at = (ms) => round1(baseline + (target - baseline) * clamp01((ms - startMs) / (deadlineMs - startMs)));
      return { planStart: at(nowMs - (seriesPoints.length - 1) * 7 * DAY_MS), planEnd: at(nowMs) };
    })();
    const slowed = resultPace?.recent != null && resultPace?.early != null
      && Math.abs(resultPace.recent) < Math.abs(resultPace.early) * 0.7;
    components.push({
      kind: "trendLine",
      anchorTitle: "结果",
      payload: {
        title: `每周平均${result.sourceLabel ?? ""}`, unit: unit || null, points: seriesPoints,
        ...(plan ?? {}),
        highlightFrom: slowed ? seriesPoints.length - 3 : null,
        caption: slowed ? "近 3 周明显变慢" : null,
      },
    });
    factLines.push(`${result.sourceLabel ?? "结果"}每周平均：${seriesPoints.map((p) => `${p.label} 那周 ${p.value}`).join("、")}。`);
  }

  // ---------- 关联事项 ----------
  const execution = Array.isArray(gr.execution) ? gr.execution.filter((e) => e && !e.isUnavailable) : [];
  const habitItems = execution.filter((e) => e.entityType === "habit" && e.title !== result.sourceLabel);
  const taskItems = execution.filter((e) => e.entityType === "task");
  const rows = habitItems.map((item) => {
    const days = dailyOnOff(byHabit.get(item.title) ?? [], nowMs, lookbackDays);
    return { item, days, ...habitStripRow(item.title, days) };
  });
  markFollowers(rows);
  for (const r of rows) {
    if (!r.days.some(Boolean)) {
      r.row.statusLabel = "没开始";
      r.row.tone = "warn";
      r.fact = `${r.item.title}：近 ${weeks} 周没有记录。`;
    }
  }
  rows.sort((a, b) => b.change - a.change);
  if (rows.length) {
    components.push({
      kind: "habitStrip",
      anchorTitle: "关联事项",
      payload: {
        title: `关联习惯 · 每格 1 天，每组 1 周`,
        rows: rows.slice(0, 4).map((r) => r.row),
        foldedNote: rows.length > 4 ? `其他 ${rows.length - 4} 个关联习惯变化不大，未展开` : null,
        startLabel: mdLabel(nowMs - lookbackDays * DAY_MS),
        endLabel: "今天",
      },
    });
    factLines.push(...rows.map((r) => r.fact));
  }
  const tasksDone = taskItems.filter((t) => t.taskCompleted === true).length;
  const tasksOverdue = taskItems.filter((t) => t.taskIsOverdue === true && t.taskCompleted !== true).length;
  if (taskItems.length) {
    factLines.push(`关联任务 ${taskItems.length} 个，已完成 ${tasksDone} 个${tasksOverdue ? `，逾期未完成 ${tasksOverdue} 个` : ""}。`);
  }

  // 数字卡：任务完成 + 变化最大的两个习惯（≥2 张才出）
  const tiles = [];
  if (taskItems.length) tiles.push({ label: "关联任务", value: `${tasksDone}`, unit: `/${taskItems.length}`, delta: tasksOverdue ? `逾期 ${tasksOverdue} 个` : null, tone: tasksOverdue ? "warn" : "neutral" });
  for (const r of rows.filter((x) => x.status && x.status.early > 0).slice(0, 3 - tiles.length)) {
    const pct = Math.round(((r.status.late - r.status.early) / r.status.early) * 100);
    tiles.push({ label: r.item.title, value: `${r.days.filter(Boolean).length}`, unit: "天", delta: `近 3 周 ${pct >= 0 ? "↑" : "↓"}${Math.abs(pct)}%`, tone: pct <= -30 ? "bad" : pct < -5 ? "warn" : "good" });
    factLines.push(`${r.item.title}近 3 周的频率比之前${pct >= 0 ? "多" : "少"} ${Math.abs(pct)}%。`);
  }
  if (tiles.length >= 2) components.push({ kind: "kpiTiles", anchorTitle: null, payload: { tiles } });

  // 前后对比：有掉档/已停/回升的习惯，且回看 ≥5 周
  const changed = rows.filter((r) => ["掉档", "已停", "回升"].includes(r.status?.label));
  if (lookbackDays >= 35 && changed.length) {
    const earlyWeeks = weeks - RECENT_DAYS / 7;
    const leftRows = changed.slice(0, 2).map((r) => ({ label: r.item.title, value: `${round1(r.status.early)} 次/周` }));
    const rightRows = changed.slice(0, 2).map((r) => ({ label: r.item.title, value: `${round1(r.status.late)} 次/周` }));
    if (resultPace?.early != null && resultPace?.recent != null) {
      leftRows.push({ label: result.sourceLabel ?? "结果", value: `${resultPace.early > 0 ? "+" : ""}${fmt(resultPace.early)} ${unit}/周` });
      rightRows.push({ label: result.sourceLabel ?? "结果", value: `${resultPace.recent > 0 ? "+" : ""}${fmt(resultPace.recent)} ${unit}/周` });
      factLines.push(`${result.sourceLabel ?? "结果"}的每周变化：前 ${earlyWeeks} 周约 ${fmt(resultPace.early)} ${unit}，近 3 周约 ${fmt(resultPace.recent)} ${unit}。这只说明两者同时发生，不能证明因果。`);
    }
    components.push({
      kind: "periodCompare",
      anchorTitle: "关联事项",
      payload: { left: { label: `前 ${earlyWeeks} 周`, rows: leftRows }, right: { label: "近 3 周", rows: rightRows }, caption: "同一个人、两种节奏下的对比" },
    });
  }

  // ---------- 缺口 ----------
  if (!execution.length) {
    gaps.push({ icon: "🔗", title: "没有关联任何行动", body: "目标下面还没有挂习惯或任务，只能看结果，看不到你做了什么。", action: "＋ 关联习惯或任务" });
    factLines.push("这个目标没有关联任何习惯或任务。");
  }
  const goalText = `${gr.goalTitle ?? ""}${result.sourceLabel ?? ""}`;
  if (WEIGHT_GOAL.test(goalText) && !execution.some((e) => DIET_ITEM.test(e.title ?? ""))) {
    gaps.push({ icon: "🍱", title: "没有饮食记录", body: "减重有一大半取决于吃，这部分没有数据，体重变化的原因只能从运动和作息看。", action: "＋ 关联一个记录饮食的习惯" });
    factLines.push("这个减重目标没有关联任何饮食记录，体重变化的原因无法从饮食角度判断。");
  }
  const notStarted = rows.find((r) => r.row.statusLabel === "没开始");
  if (notStarted) gaps.push({ icon: "🌱", title: `${notStarted.item.title}还没开始记录`, body: "关联了但近期没有任何打卡，看不出它对目标的作用。", action: null });
  const unknown = (gr.coverage?.unknown ?? []).find((u) => typeof u === "string" && u.trim());
  if (unknown && gaps.length < 3) gaps.push({ icon: "❔", title: "还有看不到的部分", body: unknown, action: null });
  if (gaps.length) {
    components.push({ kind: "gapCards", anchorTitle: "还缺什么", payload: { cards: gaps.slice(0, 3) } });
    factLines.push(`数据缺口：${gaps.slice(0, 3).map((g) => g.title).join("；")}。`);
  }

  // ---------- 起步期 ----------
  const recordedDays = rows.reduce((a, r) => a + r.days.filter(Boolean).length, 0);
  if ((ageDays != null && ageDays < EARLY_STAGE_DAYS) || (rows.length && recordedDays < 10 && seriesPoints.length < 2)) {
    const base = startMs ?? nowMs;
    components.push({
      kind: "milestones",
      anchorTitle: null,
      payload: {
        title: "再记录多久能看出什么",
        items: [
          { label: "今天", body: "能看到每个习惯有没有开始做", done: true },
          { label: `第 14 天 · ${mdLabel(base + 14 * DAY_MS)}`, body: "结果每周记录 2 次以上，就能判断方向" },
          { label: `第 21 天 · ${mdLabel(base + 21 * DAY_MS)}`, body: "能判断哪个习惯稳、哪个在掉，并给出完成预测" },
        ],
      },
    });
    factLines.push(`目标还在起步期（数据不足 2 周），不做趋势判断和完成预测。`);
  }

  const skeleton = [
    measurable ? "结果" : null,
    execution.length ? "关联事项" : null,
    gaps.length ? "还缺什么" : null,
    "下一步",
  ].filter(Boolean);
  return { components, factLines, skeleton, goalTitle: gr.goalTitle ?? "这个目标", relatedHabitNames: new Set([...habitItems.map((h) => h.title), result.sourceLabel].filter(Boolean)) };
}

/** 打卡日与另一习惯重合 ≥85%（且自身 ≥5 天、不多于对方）→ 标「跟随」 */
function markFollowers(rows) {
  const followers = new Set();
  rows.forEach((a, ai) => {
    const aOn = a.days.filter(Boolean).length;
    if (aOn < 5 || a.status?.label === "已停") return;
    for (const [bi, b] of rows.entries()) {
      if (a === b || followers.has(b)) continue;
      const bOn = b.days.filter(Boolean).length;
      // 天数相同时排在后面的才算跟随（执行列表顺序 = 用户关联顺序）
      if (bOn < aOn || (bOn === aOn && bi > ai)) continue;
      const overlap = a.days.filter((v, i) => v && b.days[i]).length;
      if (overlap / aOn >= 0.85) {
        a.row.statusLabel = `跟随${b.item.title}`;
        a.row.tone = "neutral";
        a.fact = a.fact.replace(/（程序判定：[^）]*）/, "").replace(/。$/, `；打卡日和${b.item.title}几乎完全重合（程序判定：跟随${b.item.title}）。`);
        followers.add(a);
        break;
      }
    }
  });
}
