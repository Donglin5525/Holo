// 深度报告 C 方案（2026-11-07 设计 docs/_common/plans/2026-11-07-深度分析C方案正式设计）：
// 数字核对器——从报告文本逐句提取数字/约数（阿拉伯数字含千分位、万/千/k、多/来、
// 中文数字两万/一万八/三成/十二顿），与事实清单的数字白名单核对（±2%、×100 换算、
// 约数区间）。日期/时刻/年份不是统计数字，先剔除。口径与实验 run_bc.mjs 一致，
// 另加中文日期剔除。纯函数、零模型。

const CJK_DATE = /(?:\d{4}|[一二两三四五六七八九十]{1,4})\s*[年月](?:\s*(?:\d{1,2}|[一二两三四五六七八九十]{1,3})\s*[月日号]?)?/g;
const CJK_SHORT_DATE = /(?<![0-9])(?:\d{1,2}|\b一?[一二两三四五六七八九十]{1,3}\b)\s*[月日号](?![0-9])/g;

/** 把「不是统计数字」的内容先替换掉：日期、时刻、星期序数、英文月份写法 */
export function stripNonStats(text) {
  return String(text)
    .replace(/\d{4}[-/.年]\s*\d{1,2}[-/.月]\s*\d{1,2}日?/g, " ")
    .replace(/\d{4}年/g, " ")
    .replace(/\d{1,2}月\d{1,2}[日号]/g, " ")
    .replace(/\d{1,2}[月日号](?![0-9])/g, " ")
    .replace(/\b\d{1,2}-\d{1,2}\b/g, " ")
    .replace(/\d{1,2}:\d{2}/g, " ")
    .replace(/\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b/gi, " ")
    .replace(/\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\b/gi, " ")
    .replace(/第?\d+\s*(?:周|天前|天后)/g, " ")
    .replace(CJK_DATE, " ")
    .replace(CJK_SHORT_DATE, " ");
}

const CN = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
const CN_UNITS = { 十: 10, 百: 100, 千: 1000 };

/** 中文数字串 → 数值与最小单位（「一万八」=18000、「三千五」=3500、「六百」=600、「十二」=12） */
function cnToNumber(run) {
  let total = 0;
  let section = 0;
  let num = null;
  let lastUnit = 1;
  let minUnit = 1;
  for (const ch of run) {
    if (ch in CN) num = CN[ch];
    else if (ch === "万") {
      total += (section + (num ?? 0)) * 10000;
      section = 0;
      num = null;
      lastUnit = 10000;
      minUnit = 10000;
    } else if (ch in CN_UNITS) {
      section += (num ?? 1) * CN_UNITS[ch];
      num = null;
      lastUnit = CN_UNITS[ch];
      minUnit = CN_UNITS[ch];
    }
  }
  if (num != null) {
    if (lastUnit >= 10) {
      section += (num * lastUnit) / 10;
      minUnit = lastUnit / 10;
    } else section += num;
  }
  return { value: total + section, minUnit };
}

/** 中文写的数也进核对（≥10 才查，与阿拉伯数字口径一致）：两万、一万八、六百多、三成、十二顿 */
export function extractChineseStats(text) {
  const out = [];
  const t = stripNonStats(text);
  for (const m of t.matchAll(/[一二两三四五六七八九十百千万]+/g)) {
    const run = m[0];
    if (/^[百千万]/.test(run)) continue;
    const after = t.slice(m.index + run.length, m.index + run.length + 3);
    if (/^成/.test(after)) {
      if (/^[一二三四五六七八九]$/.test(run) && !/^成(?:功|立|绩|本|熟|为|年|员|交|长|人|果|就|型|不变)/.test(after)) {
        out.push({ raw: `${run}成`, value: CN[run] * 10, scaled: true });
      }
      continue;
    }
    const { value, minUnit } = cnToNumber(run);
    if (!Number.isFinite(value) || value < 10) continue;
    const approxUp = /^[多余]/.test(after);
    if (!/[百千万]/.test(run)) {
      if (/^[来几]/.test(after)) continue;
      if (!/^[多余]?\s*(?:天|次|笔|顿|支|个|条|周|元|块|小时|分钟|杯|趟|岁|斤|公斤)/.test(after)) continue;
    }
    out.push({
      raw: run + (approxUp ? after[0] : ""),
      value,
      scaled: /[百千万]/.test(run),
      ...(approxUp ? { range: [value, value + minUnit] } : {}),
    });
  }
  return out;
}

/** 阿拉伯数字提取；小数（<10 且带小数位）在 options.decimals 时也提取 */
export function extractStats(text, options = {}) {
  const out = [];
  const re = /(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?\s*(万|千|[kK](?![a-zA-Z]))?/g;
  const stripped = stripNonStats(text);
  for (const m of stripped.matchAll(re)) {
    let v = Number(m[1].replace(/,/g, "") + (m[2] ?? ""));
    if (m[3] === "万") v *= 10000;
    else if (m[3] === "千" || m[3] === "k" || m[3] === "K") v *= 1000;
    if (!Number.isFinite(v)) continue;
    if (v < 10 && !(options.decimals && m[2])) continue;
    const tail = stripped.slice(m.index + m[0].length, m.index + m[0].length + 1);
    if (!m[2] && !m[3] && /[多余]/.test(tail)) {
      const unit = 10 ** Math.max((m[1].replace(/,/g, "").match(/0+$/) ?? [""])[0].length, 0);
      out.push({ raw: m[0].trim() + tail, value: v, scaled: false, range: [v, v + Math.max(unit, 1)] });
      continue;
    }
    out.push({ raw: m[0].trim(), value: v, scaled: Boolean(m[3]) });
  }
  out.push(...extractChineseStats(text));
  return out;
}

export function numberMatchesAllowed(value, allowed) {
  for (const allowedValue of allowed) {
    if (Math.abs(Math.abs(value) - Math.abs(allowedValue)) <= Math.max(0.05, Math.abs(allowedValue) * 0.02)) return true;
    if (Math.abs(value * 100 - allowedValue) <= Math.max(0.05, Math.abs(allowedValue) * 0.02)) return true;
    if (Math.abs(value - allowedValue * 100) <= Math.max(0.05, Math.abs(allowedValue) * 0.02)) return true;
  }
  return false;
}

export function statMatches(stat, allowed) {
  if (stat.range) return allowed.some((a) => Math.abs(a) >= stat.range[0] && Math.abs(a) < stat.range[1]);
  // 只做同量级 ±2% 匹配；刻意不做生产 verifyDelivery 的「×100 百分比桥接」——
  // 白名单本身已同时给出原值与百分数，桥接会让 99999 逃过 1000 的匹配（2026-11-07 实测）
  if (allowed.some((a) => Math.abs(Math.abs(stat.value) - Math.abs(a)) <= Math.max(0.05, Math.abs(a) * 0.02))) return true;
  // 「约 1.5 万」这类换单位的约数：放宽到 5%（只对带万/千/k 的约数）
  if (stat.scaled) return allowed.some((a) => Math.abs(stat.value - Math.abs(a)) <= Math.abs(a) * 0.05);
  return false;
}

export function splitSentences(text) {
  const parts = [];
  for (const line of String(text).split("\n")) {
    const segs = line.match(/[^。！？!?；;]+[。！？!?；;]?|[^。！？!?；;]+$/g) ?? [line];
    for (const s of segs) {
      const sub = s.split(/(?<=[.](?:\s))(?=[A-Z*\-•])/);
      parts.push(...sub);
    }
  }
  return parts.map((s) => s.trim()).filter(Boolean);
}

/** 逐句核对：返回数字白名单里找不到的句子 */
export function flagSentenceNumbers(text, allowed) {
  const flagged = [];
  for (const sentence of splitSentences(text)) {
    const bad = extractStats(sentence, { decimals: true }).filter((x) => !statMatches(x, allowed));
    if (bad.length) flagged.push({ sentence, numbers: bad.map((b) => b.raw) });
  }
  return flagged;
}
