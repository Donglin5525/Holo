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
  thought_voice_summary: "thought_voice_summary",
  memory_observer: "memory_observer",
  memory_domain_extraction: "memory_domain_extraction",
  memory_cross_domain_fusion: "memory_cross_domain_fusion",
  finance_action_parser: "finance_action_parser",
  task_action_parser: "task_action_parser",
  thought_organization: "thought_organization",
  thought_tag_convergence: "thought_tag_convergence",
  category_pattern_induction: "category_pattern_induction",
  agent_loop: "agent_loop",
});

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
  const finalSystemContent = PERSONA_PREAMBLE
    ? `${PERSONA_PREAMBLE}\n\n${systemContent}`
    : systemContent;

  return {
    promptType,
    promptVersion: prompt.version,
    messages: [
      { role: "system", content: finalSystemContent },
      ...messages,
    ],
  };
}

export function promptTypeForPurpose(purpose) {
  return PURPOSE_PROMPT_TYPES[purpose] ?? null;
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
