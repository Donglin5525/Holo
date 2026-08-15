import defaultPrompts from "./defaultPrompts.json" with { type: "json" };
import intentsRegistry from "./intents.json" with { type: "json" };
import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as Diff from "diff";

const PROMPT_VERSIONS = {
  system_prompt: 4,                 // v4: 删除重复表达边界块与档案规则块，由 Persona Preamble 接管
  intent_recognition: 26,           // v26: P3 瘦身——删与分流规则重复的 few-shot 3 条，flexible 摘要与 V23 聚合契约对齐
  memory_insight_generation: 10,    // v10: 按日/周/月/季扩大内容深度，强化证据与情绪推断边界
  replay_digest_consolidation: 1,   // v1: 周期回放历史归纳器，每次回放后把本期并入累计摘要
  analysis_prompt: 5,               // v5: 温档（洞察方法论+few-shot），删重复边界块与输出格式段由 Preamble/契约接管
  annual_review: 2,
  thought_voice_summary: 3,                 // v3: 从「保守润色」转向「主动提炼」；加情绪/状态白名单、自我纠正、口癖清单、用户小前缀保留
  flexible_query_planner: 4,
  finance_action_parser: 1,
  task_action_parser: 1,
  health_insight_generation: 2,
  thought_organization: 4,                  // v4: 加 recentAITags 字段 + 标签复用软约束升级为硬约束
  thought_task_extraction: 1,
  thought_tag_convergence: 2,
  agent_loop: 20,                  // v20: dataGapHints 遗漏数据提示 + _search 跨字段搜索
  memory_domain_extraction: 2,
  memory_cross_domain_fusion: 2,
};
const PROMPT_CONTRACT_APPENDICES = {
  system_prompt: [defaultPrompts._consumer_readable_answer_v1_contract],
  analysis_prompt: [defaultPrompts._consumer_readable_answer_v1_contract],
  agent_loop: [
    defaultPrompts._agent_loop_v10_contract,
    defaultPrompts._agent_loop_v11_contract,
    defaultPrompts._agent_loop_v14_contract,
    defaultPrompts._agent_loop_v15_contract,
    defaultPrompts._agent_loop_v16_contract,
  ],
  memory_insight_generation: [defaultPrompts._memory_semantic_v2_contract],
  memory_domain_extraction: [defaultPrompts._memory_domain_quality_v2_contract],
  memory_cross_domain_fusion: [defaultPrompts._memory_cross_domain_quality_v2_contract],
  intent_recognition: [
    `

[HOLO_QUERY_AGGREGATE_V23]
“最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱”及同批次数/总额/平均每笔/每次/每顿→flexible_data_query；“吨”按顿。必须输出 single_action，items 仅 1 项，保留 categoryCandidate/periodLabel；不要拆成 multi_action。`,
    defaultPrompts._intent_personal_state_v24_contract,
  ],
  flexible_query_planner: `

[HOLO_QUERY_AGGREGATE_PLANNER_V4]
- calculation = "averageAmount" 时必须输出 averageUnit："transaction"（每笔）、"occurrence"（每次）或 "meal"（每顿）。
- 同时查询次数、总额和均价时，使用 operation = "sumAmount" + calculation = "averageAmount"，不要拆成多个查询，也不要让模型自行计算金额。
- “吨麦当劳”在“吃了多少吨/平均一顿”的上下文中按“顿”的口误理解。
- 可直接解析的 ready 计划必须输出 explanationHints: []；不要记录“吨”与“顿”的纠错说明，不要在 JSON 字符串中嵌入未转义引号。
- 示例：{"status":"ready","clarificationQuestion":null,"plan":{"domain":"finance","operation":"sumAmount","filters":{"type":"expense","amountGreaterThan":null,"amountGreaterThanOrEqual":null,"amountLessThan":null,"amountLessThanOrEqual":null,"amountEqual":null,"keywords":["麦当劳"],"excludedKeywords":[],"categoryNames":[],"startDate":"{{thirtyDaysAgoDate}}","endDate":"{{todayISODate}}","accountNames":[],"includeNote":true,"includeRemark":true,"includeTags":true,"includeCategory":true},"calculation":"averageAmount","averageUnit":"meal","sort":{"field":"date","direction":"desc"},"limit":20,"explanationHints":[]}}`,
};
const PROMPT_TYPES = Object.keys(defaultPrompts).filter((type) => !type.startsWith("_"));
const MANAGED_PROMPTS_PATH = join(dirname(fileURLToPath(import.meta.url)), "managedPrompts.json");

let managedPrompts = loadManagedPrompts();
let _db = null;

/** intents.json（单一事实源）渲染出的意图字段段与例段；defaultPrompts 骨架用 marker 引用 */
export function buildIntentSection() {
  const lines = intentsRegistry.intents.map((entry) => `- ${entry.ids.join(" / ")}：${entry.summary}`);
  return `意图字段：\n${lines.join("\n")}`;
}

export function buildIntentExamples() {
  const lines = intentsRegistry.intents.flatMap((entry) => entry.examples.map((example) => `- ${example}`));
  return `例：\n${lines.join("\n")}`;
}

export function getIntentsRegistry() {
  return intentsRegistry;
}

/** 把骨架中的 {{HOLO_INTENT_SECTION}} / {{HOLO_INTENT_EXAMPLES}} 替换为注册表渲染产物（无 marker 时原样返回） */
function renderIntentSectionMarkers(content) {
  if (!content) return content;
  return content
    .replaceAll("{{HOLO_INTENT_SECTION}}", buildIntentSection())
    .replaceAll("{{HOLO_INTENT_EXAMPLES}}", buildIntentExamples());
}

function applyPromptContract(type, content) {
  if (!content) return content;
  let normalizedContent = renderIntentSectionMarkers(content);
  if (type === "agent_loop") {
    normalizedContent = normalizedContent.replace(
      '{"status":"need_tools | need_more_analysis | final_claims","reasoning":"string","toolRequests":[{"id":"string","tool":"string","query":"string","parameters":{}}],',
      '{"status":"need_tools | need_more_analysis | final_claims","reasoning":"string","toolRequests":[{"id":"string","tool":"string","query":"string","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{},"dynamicPlan":null,"crossDomainPlan":null}],'
    );
  }
  if (type === "memory_insight_generation") {
    normalizedContent = normalizedContent
      .replaceAll("memoryCandidate 包含 3 个字段：", "memoryCandidate 包含 4 个字段：")
      .replace(
        /(\"memoryCandidate\"\s*:\s*\{\s*)(\"semanticType\")/g,
        '$1"subjectKey": "string, 跨周期稳定主题键，如 habit:running",\n        $2'
      );
  }
  const appendices = PROMPT_CONTRACT_APPENDICES[type];
  if (!appendices) return normalizedContent;
  const normalizedAppendices = Array.isArray(appendices) ? appendices : [appendices];
  for (const appendix of normalizedAppendices) {
    if (!appendix) continue;
    const marker = appendix.match(/\[([A-Z0-9_]+)\]/)?.[0];
    if (!marker || !normalizedContent.includes(marker)) {
      normalizedContent += appendix;
    }
  }
  return normalizedContent;
}

/** 注入 SQLite 数据库连接（由 app.js 调用） */
export function setDatabase(db) {
  _db = db;
  migrateFromJson();
  syncDefaultPromptsToHistory();
}

/** 首次启动时将 managedPrompts.json 迁移到 SQLite（一次性） */
function migrateFromJson() {
  if (!_db) return;

  const count = _db.prepare('SELECT COUNT(*) as cnt FROM prompt_versions').get()?.cnt ?? 0;
  if (count > 0) return; // 已有数据，跳过迁移

  for (const [type, prompt] of Object.entries(managedPrompts)) {
    if (!PROMPT_TYPES.includes(type)) continue;
    try {
      _db.prepare(
        'INSERT INTO prompt_versions (prompt_type, version, content, source) VALUES (?, ?, ?, ?)'
      ).run(type, prompt.version, prompt.content, 'managed');
    } catch (err) {
      console.error(`[PromptRegistry] 迁移 ${type} 失败:`, err.message);
    }
  }

  if (Object.keys(managedPrompts).length > 0) {
    console.log(`[PromptRegistry] 已从 managedPrompts.json 迁移 ${Object.keys(managedPrompts).length} 个 Prompt`);
  }
}

/** 将 defaultPrompts.json 的内容登记进 SQLite 历史，确保代码侧 Prompt 变更在后台可见 */
function syncDefaultPromptsToHistory() {
  if (!_db) return;

  for (const type of PROMPT_TYPES) {
    const defaultContent = applyPromptContract(type, defaultPrompts[type]);
    if (!defaultContent) continue;

    try {
      const latest = _db.prepare(
        'SELECT version, content FROM prompt_versions WHERE prompt_type = ? ORDER BY version DESC LIMIT 1'
      ).get(type);

      if (!latest) {
        const version = PROMPT_VERSIONS[type] ?? 1;
        _db.prepare(
          'INSERT INTO prompt_versions (prompt_type, version, content, diff_from_prev, source, change_note) VALUES (?, ?, ?, ?, ?, ?)'
        ).run(
          type,
          version,
          defaultContent,
          buildDiff('', defaultContent),
          'default',
          '自动登记默认 Prompt 基线：来自 defaultPrompts.json'
        );
        continue;
      }

      const baselineVersion = PROMPT_VERSIONS[type] ?? latest.version;
      if (latest.content === defaultContent && latest.version >= baselineVersion) continue;

      // 代码侧声明的版本是最低基线；旧环境可能只记录了较早的历史版本，
      // 不能因为数据库历史较短而让线上版本号低于 PROMPT_VERSIONS。
      const version = Math.max(
        latest.version + 1,
        baselineVersion
      );
      _db.prepare(
        'INSERT INTO prompt_versions (prompt_type, version, content, diff_from_prev, source, change_note) VALUES (?, ?, ?, ?, ?, ?)'
      ).run(
        type,
        version,
        defaultContent,
        buildDiff(latest.content, defaultContent),
        'default_sync',
        '自动同步默认 Prompt 文件变更：defaultPrompts.json 已更新'
      );
      console.log(`[PromptRegistry] 已同步默认 Prompt 到历史: ${type} v${version}`);
    } catch (err) {
      console.error(`[PromptRegistry] 同步默认 Prompt ${type} 失败:`, err.message);
    }
  }
}

export function listPrompts() {
  return PROMPT_TYPES.map((type) => ({
    type,
    version: getPromptVersion(type),
    source: getPromptSource(type),
    updatedAt: getPromptUpdatedAt(type),
    contentLength: getPrompt(type)?.content.length ?? 0,
  }));
}

/** 返回所有 Prompt 的元数据（不含正文），供 iOS 判断缓存版本 */
export function listPromptMetadata() {
  return PROMPT_TYPES.map((type) => ({
    type,
    version: getPromptVersion(type),
    source: getPromptSource(type),
    updatedAt: getPromptUpdatedAt(type),
  }));
}

export function getPrompt(type) {
  if (!PROMPT_TYPES.includes(type)) {
    return null;
  }

  // 优先从 SQLite 读取最新版本
  if (_db) {
    try {
      const row = _db.prepare(
        'SELECT version, content, source, created_at, change_note FROM prompt_versions WHERE prompt_type = ? ORDER BY version DESC LIMIT 1'
      ).get(type);
      if (row) {
        return {
          type,
          version: row.version,
          source: row.source,
          updatedAt: row.created_at,
          content: row.content,
          lastChangeNote: row.change_note ?? null,
        };
      }
    } catch (err) {
      console.error('[PromptRegistry] SQLite getPrompt 失败:', err.message);
    }
  }

  // 降级到 JSON/默认
  const managedPrompt = managedPrompts[type];
  const content = applyPromptContract(type, managedPrompt?.content ?? defaultPrompts[type]);
  if (!content) return null;

  return {
    type,
    version: getPromptVersion(type),
    source: managedPrompt ? "managed" : "default",
    updatedAt: managedPrompt?.updatedAt ?? null,
    content,
    lastChangeNote: null,
  };
}

export function updatePrompt(type, content, changeNote = null) {
  if (!PROMPT_TYPES.includes(type)) {
    return null;
  }

  const previous = getPrompt(type);
  const prevContent = previous?.content ?? '';
  const version = (previous?.version ?? PROMPT_VERSIONS[type] ?? 1) + 1;

  const diffText = buildDiff(prevContent, content);

  // 存入 SQLite
  if (_db) {
    // 写入失败必须抛出（admin 分支负责兜底 redirect）——吞错会让 SQLite 停留在旧版本，
    // getPrompt 优先读 SQLite 导致返回 stale 内容且 source 错标，是「恢复默认 500≠302」flaky 的根因之一
    _db.prepare(
      'INSERT INTO prompt_versions (prompt_type, version, content, diff_from_prev, source, change_note) VALUES (?, ?, ?, ?, ?, ?)'
    ).run(type, version, content, diffText, 'managed', changeNote ?? null);
  }

  // 同步更新 JSON（兼容降级）
  const updatedAt = new Date().toISOString();
  managedPrompts = {
    ...managedPrompts,
    [type]: { type, version, content, updatedAt },
  };
  saveManagedPrompts();

  return getPrompt(type);
}

export function resetPrompt(type) {
  if (!PROMPT_TYPES.includes(type)) {
    return null;
  }

  const defaultContent = applyPromptContract(type, defaultPrompts[type]);
  if (!defaultContent) return null;

  const previous = getPrompt(type);
  const version = (previous?.version ?? PROMPT_VERSIONS[type] ?? 1) + 1;

  const diffText = buildDiff(previous?.content ?? '', defaultContent);

  // 存入 SQLite 作为 reset 版本（失败抛出，理由同 updatePrompt）
  if (_db) {
    _db.prepare(
      'INSERT INTO prompt_versions (prompt_type, version, content, diff_from_prev, source, change_note) VALUES (?, ?, ?, ?, ?, ?)'
    ).run(type, version, defaultContent, diffText, 'reset', null);
  }

  // 同步清理 JSON managed
  const { [type]: _removed, ...rest } = managedPrompts;
  managedPrompts = rest;
  saveManagedPrompts();

  return getPrompt(type);
}

/** 获取指定 Prompt 的版本历史 */
export function getPromptHistory(type) {
  if (!_db) return [];
  try {
    return _db.prepare(
      'SELECT id, prompt_type, version, diff_from_prev, source, created_at, change_note, LENGTH(content) as content_length FROM prompt_versions WHERE prompt_type = ? ORDER BY version DESC'
    ).all(type);
  } catch (err) {
    console.error('[PromptRegistry] SQLite getHistory 失败:', err.message);
    return [];
  }
}

/** 获取指定版本的内容 */
export function getPromptVersionEntry(type, version) {
  if (!_db) return null;
  try {
    return _db.prepare(
      'SELECT * FROM prompt_versions WHERE prompt_type = ? AND version = ?'
    ).get(type, version);
  } catch (err) {
    console.error('[PromptRegistry] SQLite getVersion 失败:', err.message);
    return null;
  }
}

/** 回滚到指定版本 — 将目标版本内容作为新版本写入 */
export function rollbackPrompt(type, targetVersion) {
  if (!PROMPT_TYPES.includes(type)) return null;

  const target = getPromptVersionEntry(type, targetVersion);
  if (!target) return null;

  return updatePrompt(type, target.content);
}

function getPromptSource(type) {
  if (_db) {
    try {
      const row = _db.prepare(
        'SELECT source FROM prompt_versions WHERE prompt_type = ? ORDER BY version DESC LIMIT 1'
      ).get(type);
      if (row) return row.source;
    } catch { /* fall through */ }
  }
  return managedPrompts[type] ? "managed" : "default";
}

function getPromptUpdatedAt(type) {
  if (_db) {
    try {
      const row = _db.prepare(
        'SELECT created_at FROM prompt_versions WHERE prompt_type = ? ORDER BY version DESC LIMIT 1'
      ).get(type);
      if (row) return row.created_at;
    } catch { /* fall through */ }
  }
  return managedPrompts[type]?.updatedAt ?? null;
}

function getPromptVersion(type) {
  if (_db) {
    try {
      const row = _db.prepare(
        'SELECT version FROM prompt_versions WHERE prompt_type = ? ORDER BY version DESC LIMIT 1'
      ).get(type);
      if (row) return row.version;
    } catch { /* fall through */ }
  }
  return managedPrompts[type]?.version ?? PROMPT_VERSIONS[type] ?? 1;
}

function buildDiff(prevContent, nextContent) {
  const diffParts = Diff.diffLines(prevContent, nextContent);
  return diffParts
    .map((part) => {
      const prefix = part.added ? '+' : part.removed ? '-' : ' ';
      return part.value.split('\n').map((line) => `${prefix}${line}`).join('\n');
    })
    .join('\n');
}

function loadManagedPrompts() {
  if (!existsSync(MANAGED_PROMPTS_PATH)) {
    return {};
  }

  try {
    return JSON.parse(readFileSync(MANAGED_PROMPTS_PATH, "utf8"));
  } catch {
    return {};
  }
}

function saveManagedPrompts() {
  if (Object.keys(managedPrompts).length === 0) {
    try {
      if (existsSync(MANAGED_PROMPTS_PATH)) {
        unlinkSync(MANAGED_PROMPTS_PATH);
      }
    } catch (err) {
      // 并行测试/多进程下的 ENOENT 竞态不值得炸掉调用方；写侧真正的失败由原子 rename 兜底
      console.error('[PromptRegistry] unlink managedPrompts.json 失败:', err.message);
    }
    return;
  }

  // 原子写（带 PID 的临时文件 + rename）：node --test 并行跑多个测试文件时共享此文件，
  // 非原子写在竞争下会留下半写 JSON，被 loadManagedPrompts 静默吞成 {}（内容丢失）；
  // 临时文件带 PID 避免两个进程 rename 同一个 tmp 时互相 ENOENT
  const tmpPath = `${MANAGED_PROMPTS_PATH}.${process.pid}.tmp`;
  writeFileSync(tmpPath, `${JSON.stringify(managedPrompts, null, 2)}\n`);
  renameSync(tmpPath, MANAGED_PROMPTS_PATH);
}
