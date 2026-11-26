// 想法主题归类评测 · 向量库
//
// ThoughtSemanticEmbeddingExecutor 的 JS 移植：正文先脱敏；≤2000 UTF-16 的想法整条编码，
// 长文按 2000 切段、按段长加权求平均，最后 L2 归一化。向量按 contentHash 缓存落盘，
// 同一份数据重跑不重复花钱。

import { mkdirSync } from "node:fs";
import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { runLanes } from "./lanes.mjs";
import {
  chunks, contentHash, normalize, prefix, redactForUpload, toHalfPrecision,
  vectorFromBase64, vectorToBase64,
} from "./text.mjs";

export const EMBEDDING_DIMENSIONS = 1024;
const EMBED_BATCH = 16;
const CHUNK_MAX_UTF16 = 2_000;
const CACHE_FORMAT_VERSION = 1;

export class VectorStore {
  #cache = new Map();
  #dirty = false;

  constructor({ client, cachePath, deviceId }) {
    this.client = client;
    this.cachePath = cachePath;
    this.deviceId = deviceId;
  }

  static async open({ client, cachePath, deviceId }) {
    const store = new VectorStore({ client, cachePath, deviceId });
    const raw = await readFile(cachePath, "utf8").catch(() => null);
    if (raw !== null) {
      const parsed = JSON.parse(raw);
      if (parsed.formatVersion !== CACHE_FORMAT_VERSION || parsed.dimensions !== EMBEDDING_DIMENSIONS) {
        throw new Error(`向量缓存格式不符：${cachePath}`);
      }
      for (const [hash, encoded] of Object.entries(parsed.vectors)) {
        store.#cache.set(hash, vectorFromBase64(encoded, EMBEDDING_DIMENSIONS));
      }
    }
    return store;
  }

  get(hash) {
    return this.#cache.get(hash) ?? null;
  }

  #store(hash, vector) {
    // 客户端把向量以 Float16 落库并建索引，召回时读回的就是这个精度
    this.#cache.set(hash, toHalfPrecision(vector));
    this.#dirty = true;
  }

  /** 给所有可处理的想法补齐向量；已有缓存的跳过。lanes = 并行通道数（每条通道一个设备号）。 */
  async ensureThoughtVectors(thoughts, { lanes = 1 } = {}) {
    const pending = new Map();
    const longForm = [];
    for (const thought of thoughts) {
      if (!thought.processable || this.#cache.has(thought.contentHash)) continue;
      const redacted = redactForUpload(thought.text);
      if (redacted.length > CHUNK_MAX_UTF16) longForm.push({ thought, redacted });
      else pending.set(thought.contentHash, redacted);
    }
    const hashes = [...pending.keys()];
    const jobs = [];
    for (let offset = 0; offset < hashes.length; offset += EMBED_BATCH) {
      const batch = hashes.slice(offset, offset + EMBED_BATCH);
      jobs.push({ texts: batch.map((hash) => pending.get(hash)), hashes: batch });
    }
    for (const { thought, redacted } of longForm) jobs.push({ thought, segments: chunks(redacted, CHUNK_MAX_UTF16) });
    await runLanes(jobs, lanes, async (job, laneIndex) => {
      const deviceId = `${this.deviceId}-${laneIndex}`;
      if (job.hashes !== undefined) {
        const vectors = await this.client.embed(job.texts, deviceId);
        job.hashes.forEach((hash, index) => this.#store(hash, normalize(vectors[index])));
        return;
      }
      const weighted = new Float64Array(EMBEDDING_DIMENSIONS);
      let totalWeight = 0;
      for (let offset = 0; offset < job.segments.length; offset += EMBED_BATCH) {
        const batch = job.segments.slice(offset, offset + EMBED_BATCH);
        const vectors = await this.client.embed(batch.map((segment) => segment.text), deviceId);
        vectors.forEach((raw, index) => {
          const normalized = normalize(raw);
          const weight = batch[index].text.length;
          for (let i = 0; i < weighted.length; i += 1) weighted[i] += normalized[i] * weight;
          totalWeight += weight;
        });
      }
      this.#store(job.thought.contentHash, normalize(weighted));
    });
    return pending.size + longForm.length;
  }

  /** 无成员的手动主题用「标题 + 定义」的向量参与召回（ThoughtTopicCandidateEngine）。 */
  async topicProfile(title, definition) {
    const text = prefix(redactForUpload(`${title}\n${definition ?? ""}`), CHUNK_MAX_UTF16);
    const hash = contentHash(text);
    if (!this.#cache.has(hash)) {
      const [raw] = await this.client.embed([text], this.deviceId);
      this.#store(hash, normalize(raw));
    }
    return this.#cache.get(hash);
  }

  async flush() {
    if (!this.#dirty) return;
    mkdirSync(dirname(this.cachePath), { recursive: true });
    const payload = JSON.stringify({
      formatVersion: CACHE_FORMAT_VERSION,
      dimensions: EMBEDDING_DIMENSIONS,
      vectors: Object.fromEntries([...this.#cache].map(([hash, vector]) => [hash, vectorToBase64(vector)])),
    });
    const temporary = `${this.cachePath}.tmp`;
    await writeFile(temporary, payload);
    await rename(temporary, this.cachePath);
    this.#dirty = false;
  }
}
