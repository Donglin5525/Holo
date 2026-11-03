import { createHash } from "node:crypto";

/**
 * 「一个发现」候选包双端确定性序列化（实施包 03 §3.4）。
 *
 * 候选 hash 必须双端一致：键排序、UTF-8、数字固定格式；
 * 不用语言默认 hash、不把对象字段顺序当内容。
 *
 * 规则（JS 侧，Swift 侧需逐一对应）：
 * - 对象键按 UTF-16 码元升序排序后输出；
 * - 数组保持原顺序；
 * - 数字：非有限数拒绝；整数直接十进制；小数用最短十进制表示（Number.prototype.toString），
 *   与 JSON.stringify 一致；-0 归一为 0；
 * - 字符串按 JSON 转义规则（JSON.stringify），整体 UTF-8 编码后做 sha256。
 * - null / true / false 字面量；undefined 与函数为非法输入（尽早暴露，不静默吞）。
 */

export function canonicalJsonString(value) {
  return serialize(value);
}

export function canonicalSha256(value) {
  return createHash("sha256").update(Buffer.from(serialize(value), "utf8")).digest("hex");
}

function serialize(value) {
  if (value === null) return "null";
  const type = typeof value;
  if (type === "boolean") return value ? "true" : "false";
  if (type === "number") return serializeNumber(value);
  if (type === "string") return JSON.stringify(value);
  if (type === "object") {
    if (Array.isArray(value)) {
      return `[${value.map((item) => serialize(item)).join(",")}]`;
    }
    const keys = Object.keys(value).sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${serialize(value[key])}`)
      .join(",")}}`;
  }
  throw new Error(`canonical JSON 不支持的值类型: ${type}`);
}

function serializeNumber(value) {
  if (!Number.isFinite(value)) {
    throw new Error("canonical JSON 不支持非有限数字");
  }
  if (Object.is(value, -0)) return "0";
  return String(value);
}
