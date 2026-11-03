/**
 * 模型引用对齐回原文（2026-10-19 brief 空转根治）。
 *
 * 证据契约不变：最终入库的引用必须是原文的精确子串。变化的只是把「排版级微差」
 * 的修正从模型侧挪到服务端——空白多少、大小写、弯/直/中文引号形态这类差异
 * 不再整体拒绝（生产实锤：quote_not_verbatim 是 brief/relate 502 的绝对主因，
 * qwen 对逐字复制的遵循度撑不起硬校验）。对齐不上返回 null，调用方照旧拒绝：
 * 不做模糊/相似匹配，排版之外的任何字符差异都视为模型在改写。
 */

// 弯引号/中文引号归一为直引号：排版差异，非内容差异。
const FLAT_QUOTES = new Map([
  ["\u201C", "\""], ["\u201D", "\""], ["\u2018", "'"], ["\u2019", "'"],
  ["\u300C", "\""], ["\u300D", "\""], ["\u300E", "\""], ["\u300F", "\""],
]);

/** 归一化文本 + 原文下标映射（归一化串第 i 个字符来自原文 map[i]）。 */
function normalizedWithMap(s) {
  const chars = [];
  const map = [];
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (/\s/.test(ch)) continue;
    chars.push((FLAT_QUOTES.get(ch) ?? ch).toLowerCase());
    map.push(i);
  }
  return { text: chars.join(""), map };
}

/**
 * quote 是 source 的逐字子串 → 原样返回；
 * 仅排版微差 → 返回覆盖命中区间的原文精确子串（slice 连续区间天然包住被吞的中间空白）；
 * 对不上 → null。
 */
export function alignQuoteToSource(quote, source) {
  if (typeof quote !== "string" || typeof source !== "string" || !quote.length) return null;
  if (source.includes(quote)) return quote;
  const q = normalizedWithMap(quote);
  if (!q.text.length) return null;
  const s = normalizedWithMap(source);
  const hit = s.text.indexOf(q.text);
  if (hit < 0) return null;
  return source.slice(s.map[hit], s.map[hit + q.text.length - 1] + 1);
}
