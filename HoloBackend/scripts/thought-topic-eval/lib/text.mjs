// 想法主题归类评测 · 文本与向量工具
//
// iOS 端三处的 JS 移植：ThoughtSemanticText（contentHash / chunks / prefix / quoteMatches）、
// ThoughtIndexV2Policy.redactedText(forUpload:)、SemanticVectorMath。
// 评测请求必须与客户端逐字同口径，否则引文回源、候选召回、「改字后失效」的模拟都会失真。

import { createHash, randomUUID } from "node:crypto";

const GRAPHEME_SEGMENTER = new Intl.Segmenter("zh", { granularity: "grapheme" });

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g;
const PHONE_PATTERN = /1[3-9]\d{9}/g;
const LONG_NUMBER_PATTERN = /\d{10,18}/g;

/** ThoughtIndexV2Policy.redactedText(forUpload:)：邮箱 → 手机号 → 长数字串，顺序不可换。 */
export function redactForUpload(text) {
  return text
    .replace(EMAIL_PATTERN, "[email]")
    .replace(PHONE_PATTERN, "[phone]")
    .replace(LONG_NUMBER_PATTERN, "[number]");
}

/** ThoughtSemanticText.contentHash：去首尾空白后 SHA-256 前 8 字节十六进制（16 个字符）。 */
export function contentHash(text) {
  return createHash("sha256").update(text.trim(), "utf8").digest("hex").slice(0, 16);
}

/** ThoughtSemanticText.chunks：按完整字符边界切分，保留每段 UTF-16 偏移。 */
export function chunks(text, maxUTF16) {
  if (!(maxUTF16 > 0)) return [];
  const result = [];
  let current = "";
  let offset = 0;
  let length = 0;
  for (const { segment } of GRAPHEME_SEGMENTER.segment(text)) {
    const units = segment.length;
    if (length + units > maxUTF16 && current.length > 0) {
      result.push({ text: current, offsetUTF16: offset });
      offset += length;
      current = "";
      length = 0;
    }
    current += segment;
    length += units;
  }
  if (current.length > 0) result.push({ text: current, offsetUTF16: offset });
  return result;
}

export function prefix(text, maxUTF16) {
  return chunks(text, maxUTF16)[0]?.text ?? "";
}

/** ThoughtSemanticText.quoteMatches：range 落在完整字符边界，且切片逐字等于 quote。 */
export function quoteMatches(quote, text, range) {
  if (!quote || !Array.isArray(range) || range.length !== 2) return false;
  const [start, end] = range;
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end <= start || end > text.length) return false;
  const boundaries = new Set([0]);
  let offset = 0;
  for (const { segment } of GRAPHEME_SEGMENTER.segment(text)) {
    offset += segment.length;
    boundaries.add(offset);
  }
  if (!boundaries.has(start) || !boundaries.has(end)) return false;
  return text.slice(start, end) === quote;
}

/** 数据集里的 id 统一成大写 UUID（Swift 的 uuidString 形态，落库截断就按它排序）。 */
export function normalizeUUID(value, label = "id") {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new Error(`${label} 必须是 UUID，收到：${String(value)}`);
  }
  return value.toUpperCase();
}

export const randomOperationId = () => randomUUID().toUpperCase();

/** 由内容稳定推导 UUID（版本位与变体位按 UUID v4 置好）：同一份数据重跑得到同一批 id。 */
export function stableUuid(...parts) {
  const digest = createHash("sha256").update(parts.join("\u0000"), "utf8").digest().subarray(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x40;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = digest.toString("hex").toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Swift String `<` 的近似：按码点逐位比较（JS 的 `<` 按 UTF-16 码元，增补平面字符会排错）。 */
export function compareCodePoints(a, b) {
  const left = a[Symbol.iterator]();
  const right = b[Symbol.iterator]();
  for (;;) {
    const lhs = left.next();
    const rhs = right.next();
    if (lhs.done || rhs.done) return lhs.done && rhs.done ? 0 : lhs.done ? -1 : 1;
    if (lhs.value.codePointAt(0) !== rhs.value.codePointAt(0)) {
      return lhs.value.codePointAt(0) < rhs.value.codePointAt(0) ? -1 : 1;
    }
  }
}

/** SemanticVectorMath.normalized：L2 归一化，零向量原样返回。 */
export function normalize(vector) {
  let squared = 0;
  for (const value of vector) squared += value * value;
  const norm = Math.sqrt(squared);
  if (norm === 0) return Float32Array.from(vector);
  return Float32Array.from(vector, (value) => value / norm);
}

/** SemanticVectorMath.cosineSimilarity：两边均已归一化，直接点积。 */
export function cosine(a, b) {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += a[i] * b[i];
  return sum;
}

/** 客户端向量以 Float16 落库与建索引，召回计算前同样舍入，避免阈值边缘与真机不一致。 */
export function toHalfPrecision(vector) {
  const result = new Float32Array(vector.length);
  for (let i = 0; i < vector.length; i += 1) result[i] = Math.f16round(vector[i]);
  return result;
}

/** Float32 向量 ↔ base64（缓存落盘用，逐位无损）。 */
export function vectorToBase64(vector) {
  return Buffer.from(vector.buffer, vector.byteOffset, vector.byteLength).toString("base64");
}

export function vectorFromBase64(value, dimensions) {
  const bytes = Buffer.from(value, "base64");
  if (bytes.length !== dimensions * 4) throw new Error(`向量缓存长度不符：期望 ${dimensions * 4} 字节，收到 ${bytes.length}`);
  // Node 的 Buffer 可能来自共享池、字节偏移不是 4 的倍数；拷贝到独立缓冲区再按 Float32 读
  return new Float32Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
}
