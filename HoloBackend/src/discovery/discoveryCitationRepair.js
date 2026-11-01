/**
 * 「一个发现」候选引用的确定性修复（2026-11-02 1.1.5 重设计 S1/S7）。
 *
 * 原则：只做「把模型产物拉回原文」的机械修复，绝不生成或改写内容——
 * 修复后的 quote 必须是证据原文的真实子串；锚不定就原样交给客户端逐字闸如实拒绝。
 */

const QUOTE_NOISE = /[\s“”「」『』"']/u;
const ANCHOR_SPAN = 8;
// 锚定区间最多允许比模型引用长一倍：前后缀相距过远说明跨了大段无关原文，宁可不锚
const MAX_SPAN_RATIO = 2;

/**
 * 从客户端 anchorNow（RFC3339）取时区偏移；Z 归一为 +00:00；取不到返回 null（不猜测）。
 * @param {unknown} anchorNow
 * @returns {string|null}
 */
export function timezoneOffsetOf(anchorNow) {
  if (typeof anchorNow !== "string") return null;
  const match = /T\d{2}:\d{2}:\d{2}(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/.exec(anchorNow);
  if (!match) return null;
  return match[1] === "Z" ? "+00:00" : match[1];
}

/** 归一化（删空白与引号、转小写），同时保留「归一化下标 → 原文下标」映射。 */
function normalizeWithMap(text) {
  const chars = [];
  const rawIndex = [];
  const units = Array.from(String(text));
  let offset = 0;
  for (const unit of units) {
    if (!QUOTE_NOISE.test(unit)) {
      chars.push(unit.toLowerCase());
      rawIndex.push(offset);
    }
    offset += unit.length;
  }
  return { key: chars.join(""), chars, rawIndex };
}

/**
 * 把模型轻微改写的引用锚定回原文的精确片段。
 * - 已是原文子串 → 原样返回；
 * - 前后各 8 个有效字分别在原文中命中且顺序正确、跨度不超过引用长度的 2 倍 → 返回原文对应片段；
 * - 否则返回 null（调用方保持原引用不动）。
 * @param {string} source 证据原文
 * @param {string} quote 模型给出的引用
 * @returns {string|null}
 */
export function anchorQuoteToSource(source, quote) {
  if (typeof source !== "string" || typeof quote !== "string") return null;
  if (quote.length > 0 && source.includes(quote)) return quote;
  const q = normalizeWithMap(quote);
  if (q.chars.length < ANCHOR_SPAN) return null;
  const s = normalizeWithMap(source);
  const prefix = q.chars.slice(0, ANCHOR_SPAN).join("");
  const suffix = q.chars.slice(-ANCHOR_SPAN).join("");
  // 归一化串按「字」切分后的下标（Array.from 处理代理对），与 rawIndex 一一对应
  const startChar = charIndexOf(s.chars, prefix, 0, false);
  if (startChar < 0) return null;
  const endChar = charIndexOf(s.chars, suffix, startChar, true);
  if (endChar < startChar) return null;
  const spanChars = endChar + ANCHOR_SPAN - startChar;
  if (spanChars > q.chars.length * MAX_SPAN_RATIO) return null;
  const rawStart = s.rawIndex[startChar];
  const lastChar = endChar + ANCHOR_SPAN - 1;
  const rawEnd = s.rawIndex[lastChar] + Array.from(source.slice(s.rawIndex[lastChar]))[0].length;
  const anchored = source.slice(rawStart, rawEnd);
  return anchored.length >= 6 ? anchored : null;
}

function charIndexOf(chars, needle, fromChar, last) {
  const needleChars = Array.from(needle);
  const limit = chars.length - needleChars.length;
  const matchesAt = (i) => needleChars.every((c, k) => chars[i + k] === c);
  if (last) {
    for (let i = limit; i >= fromChar; i--) if (matchesAt(i)) return i;
    return -1;
  }
  for (let i = fromChar; i <= limit; i++) if (matchesAt(i)) return i;
  return -1;
}

/**
 * 定量句分级（与客户端 DiscoveryCoordinator.gradeQuantitative 同口径）：
 * forbidden（百分比/相关性）> explicitNumber（阿拉伯数字）> countWord（中文数词）> none。
 */
export function gradeQuantitative(text) {
  const value = String(text ?? "");
  if (/[%％]|百分比|相关系数|相关性/.test(value)) return "forbidden";
  if (/[0-9]/.test(value)) return "explicitNumber";
  if (/[两三四五六七八九十]|几次|多次|每隔/.test(value)) return "countWord";
  return "none";
}

/**
 * 数词兜底：「这两次」类数词句客户端要求 ≥2 条引用（由引用集复算次数）。
 * 模型常只给 1 条时，从**本候选的支撑证据**里补齐，quote 取该证据原文首句（确定性截取）。
 * 阿拉伯数字句（客户端只认 metricIDs）与禁用句（一律拒）不补——补了只会给核验塞噪声。
 * @returns {number} 新增引用条数
 */
export function padCountWordCitations(candidate, evidenceBlocks) {
  if (!candidate || !Array.isArray(candidate.supportEvidenceIDs) || !Array.isArray(candidate.claims)) return 0;
  let added = 0;
  for (const claim of candidate.claims) {
    if (!claim || !Array.isArray(claim.citations)) continue;
    if (gradeQuantitative(claim.text) !== "countWord") continue;
    if (Array.isArray(claim.metricIDs) && claim.metricIDs.length > 0) continue;
    for (const evidenceID of candidate.supportEvidenceIDs) {
      if (claim.citations.length >= 2) break;
      if (claim.citations.some((citation) => citation?.evidenceID === evidenceID)) continue;
      const source = evidenceBlocks.get(evidenceID);
      if (typeof source !== "string") continue;
      const firstSentence = source.split(/(?<=[。！？!?])/u)[0] || source.slice(0, 40);
      if (firstSentence.length >= 4) {
        claim.citations.push({ evidenceID, quote: firstSentence });
        added += 1;
      }
    }
  }
  return added;
}
