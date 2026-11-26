// 想法主题归类评测 · 直连模型前的环境准备
//
// 必须在加载后端 config.js 之前 import：config.js 在模块加载时就把环境变量读完了，
// 之后再改 process.env 不会生效（2026-11-25 实踩：设置晚了，923 次调用落到了 deepseek-chat，
// 违反「DeepSeek 系只准 deepseek-flash」的红线）。
// 与 serve.sh 同一口径：线上归类、起名、类别理解用的是 qwen / qwen3.7-flash；本机 .env 默认是 deepseek-chat。

import "dotenv/config";

if (!process.env.QWEN_API_KEY && process.env.DASHSCOPE_API_KEY) process.env.QWEN_API_KEY = process.env.DASHSCOPE_API_KEY;
process.env.HOLO_CHAT_PROVIDER = "qwen";
process.env.HOLO_CHAT_MODEL = "qwen3.7-flash";
process.env.HOLO_CHAT_REASONING_EFFORT = "none";
process.env.HOLO_THOUGHT_SEMANTIC_PROVIDER = "qwen";
process.env.HOLO_THOUGHT_SEMANTIC_MODEL = "qwen3.7-flash";

/** 线上归类判定实际使用的路由；直连模型前调一次，不对就停。 */
export function assertProductionRoute(route) {
  if (route?.provider !== "qwen" || route?.model !== "qwen3.7-flash") {
    throw new Error(`模型路由不是线上的 qwen/qwen3.7-flash，而是 ${route?.provider}/${route?.model}；请先 import ./production-model-env.mjs`);
  }
  return route;
}
