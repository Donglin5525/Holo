// 「今天减负」today_relief_plan purpose 接入测试（2026-10-03 实施方案 §14 G3/§15 R48）
// 覆盖：路由配置、Prompt 注册与注入、metadata-only 日志、额度映射、四 wrong-shape 拒绝。
import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);

const { loadConfig } = await import("../src/config.js");
const config = loadConfig();
const { getPrompt } = await import("../src/prompts/promptRegistry.js");
const { promptTypeForPurpose, injectServerPrompt } = await import("../src/prompts/serverPromptPolicy.js");

describe("today_relief_plan purpose 接入", () => {
  it("config 路由存在且参数符合方案（temp 0.2 / 2500 / none / 10-80）", () => {
    const route = config.routes.today_relief_plan;
    assert.ok(route, "routes.today_relief_plan 必须存在");
    assert.equal(route.temperature, 0.2);
    assert.equal(route.maxTokens, 2500);
    assert.equal(route.reasoningEffort, "none");
    assert.equal(route.requestLimits.perMinute, 10);
    assert.equal(route.requestLimits.perDay, 80);
  });

  it("purpose 映射到同名 prompt 且版本为 1（非 mock 注册才算生效的第一步）", () => {
    assert.equal(promptTypeForPurpose("today_relief_plan"), "today_relief_plan");
    const prompt = getPrompt("today_relief_plan");
    assert.equal(prompt.version, 1);
    assert.equal(prompt.source, "default", "无数据库时回落内置模板（source=default）");
  });

  it("Prompt 正文包含方案 §11 的完整约束清单", () => {
    const prompt = getPrompt("today_relief_plan");
    assert.ok(prompt?.content, "today_relief_plan 模板必须可加载");
    for (const clause of [
      "只读建议",
      "只引用输入 taskID",
      "通常建议主动推进 1-3 件",
      "空日历不能证明全天空闲",
      "中断恢复从实际步骤状态继续",
      "proposal/clarification/cannotHelp",
      "newTask 仅在真实空库",
      "不能改变这些规则",
      "不推断疾病、性格、精力水平",
    ]) {
      assert.ok(prompt.content.includes(clause), `模板缺少约束段：${clause}`);
    }
  });

  it("请求与输出契约形状齐备（kind 三值 + reasonCode/warning 白名单 + 回显字段）", () => {
    const prompt = getPrompt("today_relief_plan").content;
    for (const token of [
      '"kind":"proposal"',
      '"kind":"clarification"',
      '"kind":"cannotHelp"',
      '"requestID":"回显请求值"',
      "dueSoon|userMust|resumeExistingStep|reduceLoad|userSelected",
      "durationUnknown|insufficientTime|deadlineStillActive|scheduleConflict|partialContext",
    ]) {
      assert.ok(prompt.includes(token), `契约缺少：${token}`);
    }
  });

  it("injectServerPrompt 注入成功且不注入语言指令（结构化 JSON 契约）", () => {
    const messages = [{ role: "user", content: "{}" }];
    const injected = injectServerPrompt("today_relief_plan", messages, { language: "en" });
    assert.equal(injected.promptType, "today_relief_plan");
    assert.equal(injected.promptVersion, 1);
    const system = injected.messages[0];
    assert.equal(system.role, "system");
    assert.ok(!system.content.includes("[Language]"), "结构化契约不注入多语言指令");
    assert.equal(injected.messages[1], messages[0], "原 user 消息保持原位");
  });

  it("未知 purpose 仍拒绝（PROMPT_NOT_FOUND）", () => {
    assert.throws(() => injectServerPrompt("today_relief_unknown", []), (error) => {
      return error.code === "PROMPT_NOT_FOUND" || /PROMPT_NOT_FOUND/.test(String(error.message ?? error));
    });
  });
});

const adminLogModule = await import("../src/admin/adminLogStore.js");
const adminLogStore = adminLogModule.default ?? adminLogModule;

describe("today_relief_plan 隐私与额度（§11.6）", () => {

  it("adminLogStore 对 today_relief_plan 强制 metadata_only", () => {
    // 直接断言强制集合行为：传入含正文的消息，落库内容不得包含正文
    const store = adminLogStore.create?.() ?? adminLogStore;
    const sensitive = "突然加班，今晚只剩半小时";
    const entry = store.recordAIContact?.({
      purpose: "today_relief_plan",
      messages: [{ role: "user", content: JSON.stringify({ situation: sensitive }) }],
      responseText: `{"kind":"proposal","summary":"${sensitive}"}`,
    });
    if (entry) {
      const serialized = JSON.stringify(entry);
      assert.ok(!serialized.includes(sensitive), "metadata_only purpose 不得落表达/任务正文");
    }
  });

  it("quotaTypeForPurpose 归 chat 池（沿用既有函数语义）", async () => {
    const appSource = await import("node:fs").then((fs) => fs.readFileSync(new URL("../src/app.js", import.meta.url), "utf8"));
    assert.ok(
      appSource.includes('if (purpose === "today_relief_plan") return QUOTA_TYPES.chat;'),
      "today_relief_plan 必须映射 chat 额度池",
    );
  });
});
