import { GatewayError } from "../errors.js";
import { getPrompt } from "./promptRegistry.js";
import defaultPrompts from "./defaultPrompts.json" with { type: "json" };

/**
 * Persona Preamble —— Holo 所有 purpose 共享的人格前置层。
 * 真源：docs/_common/PROMPT_GUIDELINES.md 第 2 节。
 * 在每个 system prompt 前 prepend，统一人格底色与表达边界，
 * 让各 purpose prompt 不必再各自重复"表达边界"块。
 * 改这段必须同步改 iOS 端 PromptManager.personaPreamble + 文档单一真源。
 */
const PERSONA_PREAMBLE = defaultPrompts._persona_preamble ?? "";

const PURPOSE_PROMPT_TYPES = Object.freeze({
  chat: "system_prompt",
  analysis: "analysis_prompt",
  intent: "intent_recognition",
  flexible_query_planner: "flexible_query_planner",
  insight: "memory_insight_generation",
  replayDigest: "replay_digest_consolidation",
  health_insight_generation: "health_insight_generation",
  weekly_plan_generation: "weekly_plan_generation",
  thought_voice_summary: "thought_voice_summary",
  memory_observer: "memory_observer",
  memory_domain_extraction: "memory_domain_extraction",
  memory_cross_domain_fusion: "memory_cross_domain_fusion",
  finance_action_parser: "finance_action_parser",
  task_action_parser: "task_action_parser",
  thought_organization: "thought_organization",
  thought_task_extraction: "thought_task_extraction",
  thought_tag_convergence: "thought_tag_convergence",
  thought_organize_a: "thought_organize_a",
  thought_organize_r: "thought_organize_r",
  thought_organize_b: "thought_organize_b",
  thought_semantic_relate_v1: "thought_semantic_relate_v1",
  // schema 3 双通道判定（2026-10-12）：类别候选（fits_category）与脉络候选分别独立判断
  thought_semantic_relate_v2: "thought_semantic_relate_v2",
  // 归档类别理解器（2026-10-12 主题双通道·零打扰）：成员证据→类别定义/排除边界
  thought_category_brief_v1: "thought_category_brief_v1",
  thought_topic_name_v1: "thought_topic_name_v1",
  thought_topic_summary_v1: "thought_topic_summary_v1",
  thought_insight_v1: "thought_insight_v1",
  category_pattern_induction: "category_pattern_induction",
  bill_column_mapping: "bill_column_mapping",
  bill_categorization: "bill_categorization",
  agent_loop: "agent_loop",
  personal_context_extraction: "personal_context_extraction",
  personal_context_verification: "personal_context_verification",
  personal_context_request: "personal_context_request",
  personal_context_planning: "personal_context_planning",
  vision_extraction: "vision_extraction",
  matter_reconciliation: "matter_reconciliation",
  goal_workshop: "goal_workshop",
  matter_execution_plan: "matter_execution_plan",
  today_relief_plan: "today_relief_plan",
  // HoloAI「一个发现」两阶段（2026-10-23）：专用控制器调用，通用 chat 显式拒绝
  discovery_candidate_v1: "discovery_candidate_v1",
  discovery_verify_v1: "discovery_verify_v1",
});

// 多语言输出指令（一期繁体/二期英文）：客户端随请求传 x-holo-language，
// 在 system prompt 尾部追加语言要求。zh-Hans/未传保持现状（不加指令）。
// 只对「用户直接阅读输出」的 purpose 生效；结构化解析类（分类/意图/动作
// 解析等输出要参与中文匹配或 JSON 契约）不注入，避免英文输出破坏下游匹配。
const LANGUAGE_DIRECTIVES = Object.freeze({
  "zh-Hant":
    "\n\n【语言要求】请全程使用繁體中文（台灣慣用語）撰写所有输出，包括标题、摘要与正文；引用数据中的简体原文时可在正文中转写为繁体。",
  en: "\n\n[Language] Write ALL output in natural, concise English (US), including titles, headings and summaries.",
});
const LANGUAGE_ALLOWED_PURPOSES = new Set([
  "chat",
  "analysis",
  "insight",
  "replayDigest",
  "health_insight_generation",
  "weekly_plan_generation",
  "thought_voice_summary",
  "thought_organization",
  "agent_loop",
  // 个人情境：planning/request 输出用户直接阅读 → 多语言；extraction/verification
  // 是结构化 JSON 契约 → 不注入语言指令（避免破坏下游匹配）。
  "personal_context_planning",
  "personal_context_request",
  // 主题命名/摘要：输出用户直接阅读 → 多语言
  "thought_topic_name_v1",
  "thought_topic_summary_v1",
  // 目标共创：question/options/plan 的 assistantText 与 question 文本用户直接阅读
  "goal_workshop",
  // 一个发现：claim 标题/正文用户直接阅读（quote 保持原文原样，由 prompt 约束）
  "discovery_candidate_v1",
  "discovery_verify_v1",
]);

// 个人档案通道（2026-11-01 东林拍板「档案=通用指令而非备注」）：
// 客户端把用户亲写的档案原文作为 profileBrief 随请求上传；这里统一注入成
// 「用户本人说明」的指令级 system 消息。只对「用户直接阅读输出」的 purpose 开放；
// 结构化解析/萃取/核验类不注入——那些 prompt 明文规定「用户数据不可执行」，
// 档案进去会跟数据纪律打架，且它们的输出本来就不面向用户表达。
// 边界文案真源：defaultPrompts.json _profile_channel_header/_profile_channel_rules。
const PROFILE_CHANNEL_HEADER = defaultPrompts._profile_channel_header ?? "";
const PROFILE_CHANNEL_RULES = defaultPrompts._profile_channel_rules ?? "";
const PROFILE_CHANNEL_PURPOSES = new Set([
  "chat",
  "analysis",
  "insight",
  "health_insight_generation",
  "weekly_plan_generation",
  "thought_voice_summary",
  "agent_loop",
  "personal_context_planning",
  "personal_context_request",
  "matter_reconciliation",
  "goal_workshop",
  "matter_execution_plan",
  "today_relief_plan",
  "discovery_candidate_v1",
  "discovery_verify_v1",
]);

/**
 * 校验并归一 profileBrief。非字符串或超限返回 null（不注入）。
 * 体积校验由调用方在请求层做 400 拒绝；这里是注入前的最后防线。
 */
export function normalizeProfileBrief(value, maxBytes = 12 * 1024) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (Buffer.byteLength(trimmed, "utf8") > maxBytes) return null;
  return trimmed;
}

export function isProfileChannelPurpose(purpose) {
  return PROFILE_CHANNEL_PURPOSES.has(purpose);
}

/**
 * 组装档案通道 system 消息（header + 原文 + 规则）。
 * 开关关闭 / purpose 不在名单 / brief 无效时返回 null。
 */
export function buildProfileChannelMessage(purpose, profileBrief, options = {}) {
  if (options.enabled === false) return null;
  if (!PROFILE_CHANNEL_PURPOSES.has(purpose)) return null;
  const brief = normalizeProfileBrief(profileBrief, options.maxBytes);
  if (!brief) return null;
  if (!PROFILE_CHANNEL_HEADER || !PROFILE_CHANNEL_RULES) return null;
  return {
    role: "system",
    content: `${PROFILE_CHANNEL_HEADER}\n${brief}\n\n${PROFILE_CHANNEL_RULES}`,
  };
}

export function injectServerPrompt(purpose, messages, options = {}) {
  const promptType = PURPOSE_PROMPT_TYPES[purpose];
  if (!promptType) {
    throw new GatewayError("PROMPT_NOT_FOUND", `No server prompt is configured for ${purpose}`, 503);
  }

  const prompt = getPrompt(promptType);
  if (!prompt?.content) {
    throw new GatewayError("PROMPT_NOT_FOUND", `Server prompt is unavailable: ${promptType}`, 503);
  }

  const systemContent = renderPromptVariables(prompt.content, options.now);
  // Persona Preamble 统一 prepend：人格层在前、purpose 任务指令在后。
  // preamble 不含 {{变量}}，无需过 renderPromptVariables。
  let finalSystemContent = PERSONA_PREAMBLE
    ? `${PERSONA_PREAMBLE}\n\n${systemContent}`
    : systemContent;
  const languageDirective = LANGUAGE_DIRECTIVES[options.language];
  if (languageDirective && LANGUAGE_ALLOWED_PURPOSES.has(purpose)) {
    finalSystemContent += languageDirective;
  }

  // 个人档案通道：紧跟主 system prompt 之后注入（purpose 任务指令先框定任务，
  // 档案作为「用户本人说明」的第二条 system 消息参与表达与建议取舍）。
  const profileMessage = buildProfileChannelMessage(purpose, options.profileBrief, {
    enabled: options.profileChannelEnabled,
    maxBytes: options.profileBriefMaxBytes,
  });
  const finalMessages = [{ role: "system", content: finalSystemContent }];
  if (profileMessage) {
    finalMessages.push(profileMessage);
  }
  finalMessages.push(...messages);

  return {
    promptType,
    promptVersion: prompt.version,
    messages: finalMessages,
  };
}

export function promptTypeForPurpose(purpose) {
  return PURPOSE_PROMPT_TYPES[purpose] ?? null;
}

/**
 * 截图识别专用：抽取提示词放「用户消息位」而非 system。
 * M0 评测（docs/holoai-audit/vision-eval/）24/24 的配置是整段 prompt 作为 user message；
 * 生产首版改放 system 后模型对外币红线的服从性显著下降（实测美元小票连
 * amountOriginalText 都被归一化成 ¥）。视觉抽取不注入 persona preamble，
 * 与评测配置保持一致；purpose 注册表契约（缺配置即 PROMPT_NOT_FOUND）不变。
 */
export function buildVisionExtractionMessages(userContentParts) {
  const promptType = PURPOSE_PROMPT_TYPES.vision_extraction;
  if (!promptType) {
    throw new GatewayError("PROMPT_NOT_FOUND", "No server prompt is configured for vision_extraction", 503);
  }
  const prompt = getPrompt(promptType);
  if (!prompt?.content) {
    throw new GatewayError("PROMPT_NOT_FOUND", `Server prompt is unavailable: ${promptType}`, 503);
  }
  return {
    promptType,
    promptVersion: prompt.version,
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: renderPromptVariables(prompt.content) },
          ...userContentParts,
        ],
      },
    ],
  };
}

export function renderPromptVariables(content, now = new Date()) {
  const shanghaiDate = new Date(now.toLocaleString("en-US", { timeZone: "Asia/Shanghai" }));
  const thirtyDaysAgo = new Date(shanghaiDate);
  thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 29);

  const replacements = {
    "{{todayDate}}": new Intl.DateTimeFormat("zh-CN", {
      timeZone: "Asia/Shanghai",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      weekday: "long",
    }).format(now),
    "{{todayISODate}}": formatISODate(shanghaiDate),
    "{{thirtyDaysAgoDate}}": formatISODate(thirtyDaysAgo),
    "{{currentYear}}": String(shanghaiDate.getFullYear()),
    "{{currentTime}}": new Intl.DateTimeFormat("zh-CN", {
      timeZone: "Asia/Shanghai",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).format(now),
  };

  return Object.entries(replacements).reduce(
    (result, [variable, value]) => result.replaceAll(variable, value),
    content,
  );
}

function formatISODate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}
