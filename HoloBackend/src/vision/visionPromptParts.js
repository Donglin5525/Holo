// 截图识别记账 · 提示词拼装片段（生产路由 app.js 与评测脚本 scripts/eval-vision-extraction.mjs 共用）。
// 抽成零依赖模块的原因：评测必须与生产逐字同口径，此前评测脚本漏了图后收尾提醒与附言行，
// 测的不是生产实际发给模型的内容（2026-11-06 转账开放方案 §7.3）。

/** 图片之后的收尾提醒：放在离输出最近的位置，外币红线最近一次强提醒。 */
export const VISION_CLOSING_REMINDER =
  "提醒：先核对图中「合计/实付金额」行的货币符号原文，再输出理解单。实付金额本身是外币才 foreign_currency 且 transactions 为空；图中有外币标价但实付人民币的境外账单（如微信境外消费），按人民币实付正常记账。";

/** 附言行：并入提示词文本末尾（prompt 在 user 位，见 serverPromptPolicy.buildVisionExtractionMessages）。 */
export function visionCaptionLine(caption) {
  return caption ? `\n\n用户随图附言：「${caption}」` : "\n\n用户没有附言。";
}
