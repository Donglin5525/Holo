import defaultPrompts from "./defaultPrompts.json" with { type: "json" };
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as Diff from "diff";

const PROMPT_VERSIONS = {
  system_prompt: 2,
  intent_recognition: 22,
  memory_insight_generation: 6,
  analysis_prompt: 3,
  annual_review: 1,
  thought_voice_summary: 2,
  flexible_query_planner: 3,
  finance_action_parser: 1,
  task_action_parser: 1,
  health_insight_generation: 2,
};
const PROMPT_CONTRACT_APPENDICES = {
  intent_recognition: `

[HOLO_QUERY_AGGREGATE_V22]
平均每笔/每次/每顿及同批次数/总额→flexible_data_query；平均每天/每周、趋势/结构→query_analysis。“吃了多少吨麦当劳”同“平均一顿”按顿。例：“最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱”→flexible_data_query，保留麦当劳/最近一个月。`,
  flexible_query_planner: `

[HOLO_QUERY_AGGREGATE_PLANNER_V3]
- calculation = "averageAmount" 时必须输出 averageUnit："transaction"（每笔）、"occurrence"（每次）或 "meal"（每顿）。
- 同时查询次数、总额和均价时，使用 operation = "sumAmount" + calculation = "averageAmount"，不要拆成多个查询，也不要让模型自行计算金额。
- “吨麦当劳”在“吃了多少吨/平均一顿”的上下文中按“顿”的口误理解。
- 示例：{"status":"ready","clarificationQuestion":null,"plan":{"domain":"finance","operation":"sumAmount","filters":{"type":"expense","amountGreaterThan":null,"amountGreaterThanOrEqual":null,"amountLessThan":null,"amountLessThanOrEqual":null,"amountEqual":null,"keywords":["麦当劳"],"excludedKeywords":[],"categoryNames":[],"startDate":"{{thirtyDaysAgoDate}}","endDate":"{{todayISODate}}","accountNames":[],"includeNote":true,"includeRemark":true,"includeTags":true,"includeCategory":true},"calculation":"averageAmount","averageUnit":"meal","sort":{"field":"date","direction":"desc"},"limit":20,"explanationHints":[]}}`,
};
const PROMPT_TYPES = Object.keys(defaultPrompts);
const MANAGED_PROMPTS_PATH = join(dirname(fileURLToPath(import.meta.url)), "managedPrompts.json");

let managedPrompts = loadManagedPrompts();
let _db = null;

function applyPromptContract(type, content) {
  if (!content) return content;
  const appendix = PROMPT_CONTRACT_APPENDICES[type];
  if (!appendix) return content;
  const marker = appendix.match(/\[([A-Z0-9_]+)\]/)?.[0];
  return marker && content.includes(marker) ? content : `${content}${appendix}`;
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

      if (latest.content === defaultContent) continue;

      const version = latest.version + 1;
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
    try {
      _db.prepare(
        'INSERT INTO prompt_versions (prompt_type, version, content, diff_from_prev, source, change_note) VALUES (?, ?, ?, ?, ?, ?)'
      ).run(type, version, content, diffText, 'managed', changeNote ?? null);
    } catch (err) {
      console.error('[PromptRegistry] SQLite 版本写入失败:', err.message);
    }
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

  // 存入 SQLite 作为 reset 版本
  if (_db) {
    try {
      _db.prepare(
        'INSERT INTO prompt_versions (prompt_type, version, content, diff_from_prev, source, change_note) VALUES (?, ?, ?, ?, ?, ?)'
      ).run(type, version, defaultContent, diffText, 'reset', null);
    } catch (err) {
      console.error('[PromptRegistry] SQLite reset 写入失败:', err.message);
    }
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
    if (existsSync(MANAGED_PROMPTS_PATH)) {
      unlinkSync(MANAGED_PROMPTS_PATH);
    }
    return;
  }

  writeFileSync(MANAGED_PROMPTS_PATH, `${JSON.stringify(managedPrompts, null, 2)}\n`);
}
