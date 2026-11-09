// §provider-model-pairing（2026-11-09 语音摘要事故）防回归：路由的 provider 与 model 必须来自同一条回退链。
// thought_voice_summary 曾 provider 跟随 HOLO_CHAT_PROVIDER、model 写死 "deepseek-flash"：10-15 全量切 qwen 后
// 变成「qwen + deepseek-flash」，上游 MODEL_UNAVAILABLE，语音智能总结 100% 失败 25 天；DeepSeek 时代组合恰好同厂商，无从察觉。
// 本测试模拟「只切 HOLO_CHAT_PROVIDER / HOLO_CHAT_MODEL 这一对」的换模型操作，断言任何 LLM 路由都不出现跨厂商配对。
import assert from "node:assert/strict";
import { test } from "node:test";

// 非 LLM 生成通道：embedding 走独立的 HOLO_EMBEDDING_* 链，不随聊天模型切换。
const NON_LLM_EXEMPT = new Set(["thought_embedding", "personal_context_embedding"]);

function vendorOf(name) {
  if (name.startsWith("qwen")) return "qwen";
  if (name.startsWith("deepseek")) return "deepseek";
  return name;
}

// config.js 在模块加载时读取环境变量：清空 HOLO_* 后只设聊天这一对，以独立模块实例加载。
async function routesWithChatModel(provider, model) {
  const saved = { ...process.env };
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("HOLO_")) delete process.env[key];
  }
  process.env.HOLO_CHAT_PROVIDER = provider;
  process.env.HOLO_CHAT_MODEL = model;
  try {
    const { loadConfig } = await import(`../src/config.js?pairing=${provider}`);
    return loadConfig().routes;
  } finally {
    for (const key of Object.keys(process.env)) {
      if (!(key in saved)) delete process.env[key];
    }
    Object.assign(process.env, saved);
  }
}

for (const [provider, model] of [["qwen", "qwen3.7-flash"], ["deepseek", "deepseek-flash"]]) {
  test(`只切 HOLO_CHAT_* 到 ${provider}：所有 LLM 路由的 provider 与 model 同厂商`, async () => {
    const routes = await routesWithChatModel(provider, model);
    const mismatched = Object.entries(routes)
      .filter(([purpose]) => !NON_LLM_EXEMPT.has(purpose))
      .filter(([, route]) => route.provider !== "mock" && vendorOf(route.provider) !== vendorOf(route.model))
      .map(([purpose, route]) => `${purpose}=${route.provider}+${route.model}`);
    assert.deepEqual(mismatched, [], `跨厂商 provider/model 配对（换模型时整条路由会失败）: ${mismatched.join(", ")}`);
  });
}
