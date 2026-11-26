// 想法主题归类评测 · 数据集（中间格式）加载与校验
//
// 评测脚本只认本格式。东林提供的原始数据先由转换脚本转成它，格式说明见本目录 README.md。

import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { contentHash, normalizeUUID, redactForUpload } from "./text.mjs";

export const DATASET_FORMAT_VERSION = 1;

const VISIBLE_TOPIC_STATUSES = new Set(["active", "candidate", "classification"]);
const LINK_SOURCES = new Set(["user", "ai", "legacy"]);
const LINK_STATES = new Set(["active", "rejected", "superseded"]);
const SPLITS = new Set(["dev", "holdout"]);

function requireText(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) throw new Error(`${label} 必须是非空字符串`);
  return value;
}

/** 空串与缺省同等对待：客户端对空定义/空摘要按「没有」处理，送空串会被后端 400 拒绝。 */
function optionalText(value) {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function requireTime(value, label) {
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) throw new Error(`${label} 必须是可解析的时间，收到：${String(value)}`);
  return ms;
}

function normalizeTopic(row) {
  const status = row.status ?? (row.kind === "category" ? "classification" : "active");
  if (!VISIBLE_TOPIC_STATUSES.has(status)) throw new Error(`主题 ${row.id} 的 status 不可见或未知：${status}`);
  const classification = status === "classification";
  if (row.kind !== undefined && row.kind !== (classification ? "category" : "thread")) {
    throw new Error(`主题 ${row.id} 的 kind 与 status 不一致（classification ⇔ category）`);
  }
  return {
    id: normalizeUUID(row.id, "主题 id"),
    title: requireText(row.title, `主题 ${row.id} 的 title`),
    // Topic.isClassificationTopic：status == classification 才是用户启用的归档类别
    isClassification: classification,
    // Topic.isVisibleTopic：active / candidate / classification
    isVisible: row.deleted !== true,
    categoryDefinition: optionalText(row.categoryDefinition),
    // AI 起草的类别理解（本机 category_brief）；legacy 判定在无用户规则时回退用它
    briefDefinition: optionalText(row.briefDefinition),
    summary: optionalText(row.summary),
    createdAtMs: row.createdAt === undefined ? null : requireTime(row.createdAt, `主题 ${row.id} 的 createdAt`),
  };
}

function normalizeThought(row, topics) {
  const id = normalizeUUID(row.id, "想法 id");
  const createdAtMs = requireTime(row.createdAt, `想法 ${id} 的 createdAt`);
  const text = requireText(row.text, `想法 ${id} 的 text`);
  const links = (row.links ?? []).map((link) => {
    const topicId = normalizeUUID(link.topicId, `想法 ${id} 的 link.topicId`);
    if (!topics.has(topicId)) throw new Error(`想法 ${id} 关联了不存在的主题 ${topicId}`);
    if (!LINK_SOURCES.has(link.source)) throw new Error(`想法 ${id} → ${topicId} 的 source 必须是 user / ai / legacy`);
    if (!LINK_STATES.has(link.state)) throw new Error(`想法 ${id} → ${topicId} 的 state 必须是 active / rejected / superseded`);
    return { topicId, source: link.source, state: link.state, basisTextHash: link.basisTextHash ?? null };
  });
  const gold = row.gold == null ? null : {
    topicIds: row.gold.topicIds.map((topicId) => normalizeUUID(topicId, `想法 ${id} 的 gold.topicIds`)),
    unsure: row.gold.unsure === true,
  };
  for (const topicId of gold?.topicIds ?? []) {
    if (!topics.has(topicId)) throw new Error(`想法 ${id} 的金标引用了不存在的主题 ${topicId}`);
  }
  if (row.split !== undefined && row.split !== null && !SPLITS.has(row.split)) {
    throw new Error(`想法 ${id} 的 split 必须是 dev / holdout`);
  }
  const redacted = redactForUpload(text);
  return {
    id,
    text,
    createdAtMs,
    updatedAtMs: row.updatedAt === undefined ? createdAtMs : requireTime(row.updatedAt, `想法 ${id} 的 updatedAt`),
    archived: row.archived === true,
    // 「不参与 AI」标签 / 已退出整理的想法：不建向量、不送判、也不当代表例
    aiVisible: row.aiVisible !== false,
    // 脱敏后无内容（纯图/纯占位）在客户端按 text_unavailable 合法完成，不送判
    processable: row.aiVisible !== false && redacted.trim().length > 0,
    links,
    split: row.split ?? null,
    gold,
    contentHash: contentHash(text),
  };
}

export async function loadDataset(filePath) {
  const raw = JSON.parse(await readFile(filePath, "utf8"));
  if (raw.formatVersion !== DATASET_FORMAT_VERSION) {
    throw new Error(`数据集 formatVersion 必须是 ${DATASET_FORMAT_VERSION}，收到：${String(raw.formatVersion)}`);
  }
  const topics = new Map();
  for (const row of raw.topics ?? []) {
    const topic = normalizeTopic(row);
    if (topics.has(topic.id)) throw new Error(`主题 id 重复：${topic.id}`);
    topics.set(topic.id, topic);
  }
  const thoughts = [];
  const seen = new Set();
  for (const row of raw.thoughts ?? []) {
    // 软删想法的关系两侧在客户端都已冻结，不进评测语料
    if (row.deleted === true) continue;
    const thought = normalizeThought(row, topics);
    if (seen.has(thought.id)) throw new Error(`想法 id 重复：${thought.id}`);
    seen.add(thought.id);
    thoughts.push(thought);
  }
  return { name: raw.name ?? basename(filePath, ".json"), topics, thoughts };
}
