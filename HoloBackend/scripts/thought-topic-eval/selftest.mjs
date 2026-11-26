#!/usr/bin/env node
// 想法主题归类评测 · 移植自查
//
// 客户端逻辑搬到 JS 后，用几组手算可核对的输入防「移植走样」。
// 用法：node scripts/thought-topic-eval/selftest.mjs   （零网络、零费用）

import assert from "node:assert/strict";

import {
  ContractViolationError, acceptLegacyResponse, buildLegacyCandidates, buildLegacyRequests, commitLegacy,
} from "./lib/legacy.mjs";
import {
  canRecordAIV3Decision, categorySampleRank, isEffectiveMember, membershipSource,
} from "./lib/projection.mjs";
import { CALIBRATION_SEED, recall } from "./lib/recall.mjs";
import { clusterComponents, fingerprint } from "./lib/discovery.mjs";
import {
  chunks, compareCodePoints, contentHash, prefix, quoteMatches, redactForUpload, stableUuid,
  vectorFromBase64, vectorToBase64,
} from "./lib/text.mjs";

const thought = (id, text, links = [], extra = {}) => ({
  id, text, links, contentHash: contentHash(text), archived: false, aiVisible: true, updatedAtMs: 1, ...extra,
});
const topic = (id, title, isClassification, extra = {}) => ({
  id, title, isClassification, isVisible: true, categoryDefinition: null, briefDefinition: null, summary: null, ...extra,
});

const tests = [
  ["contentHash：去首尾空白后取 SHA-256 前 8 字节", () => {
    assert.equal(contentHash("  abc \n"), "ba7816bf8f01cfea");
  }],
  ["chunks / prefix：按完整字符边界切分并保留 UTF-16 偏移", () => {
    assert.deepEqual(chunks("a😀b", 1), [
      { text: "a", offsetUTF16: 0 }, { text: "😀", offsetUTF16: 1 }, { text: "b", offsetUTF16: 3 },
    ]);
    assert.equal(prefix("你好世界", 3), "你好世");
    assert.equal(prefix("你好世界", 5), "你好世界");
  }],
  ["redactForUpload：邮箱 → 手机号 → 长数字串（顺序与客户端一致）", () => {
    assert.equal(redactForUpload("a@b.com / 13800138000 / 110101200101012345"), "[email] / [phone] / [number]");
    // 长数字串里内嵌手机号形态时，中间先被手机号规则吃掉，剩余位数不足 10 位不再脱敏。
    // 与客户端行为一致；是线上脱敏的既有盲点，不是移植偏差。
    assert.equal(redactForUpload("110101199001011234"), "110101[phone]4");
  }],
  ["quoteMatches：区间落在字符边界且切片逐字相等", () => {
    assert.equal(quoteMatches("好世", "你好世界", [1, 3]), true);
    assert.equal(quoteMatches("😀", "a😀b", [1, 3]), true);
    assert.equal(quoteMatches("😀", "a😀b", [1, 2]), false);
    assert.equal(quoteMatches("好世", "你好世界", [1, 9]), false);
  }],
  ["compareCodePoints：按码点而非 UTF-16 码元比较", () => {
    assert.equal(compareCodePoints("\u{1F600}", "\uFFFD"), 1);
    assert.equal("\u{1F600}" < "\uFFFD", true);
  }],
  ["向量缓存编解码逐位无损", () => {
    const vector = Float32Array.from([0.5, -1.25, 1e-8, 0]);
    assert.deepEqual([...vectorFromBase64(vectorToBase64(vector), 4)], [...vector]);
  }],
  ["关系投影：用户决定 > 墓碑 > AI；AI 关系只对生成它的正文有效", () => {
    const current = thought("t1", "正文", [{ topicId: "A", source: "ai", state: "active" }]);
    const stale = thought("t2", "改过的正文", [{ topicId: "A", source: "ai", state: "active", basisTextHash: "0000000000000000" }]);
    const rejected = thought("t3", "正文", [{ topicId: "A", source: "ai", state: "active" }, { topicId: "A", source: "user", state: "rejected" }]);
    assert.equal(isEffectiveMember(current, "A"), true);
    assert.equal(isEffectiveMember(stale, "A"), false);
    assert.equal(isEffectiveMember(rejected, "A"), false);
    assert.equal(canRecordAIV3Decision(rejected, "A"), false);
    assert.equal(canRecordAIV3Decision(current, "A"), true);
    assert.equal(membershipSource(current, "A"), "ai");
    assert.equal(categorySampleRank(current, "A"), 1);
    assert.equal(categorySampleRank(thought("t4", "无关系"), "A"), 3);
  }],
  ["commitLegacy：按主题 UUID 字母序截断到 3；未选中的既有 AI 归属被撤销；用户关系不动", () => {
    const target = thought("t", "正文", [
      { topicId: "B", source: "ai", state: "active" },
      { topicId: "C", source: "ai", state: "active" },
      { topicId: "U", source: "user", state: "active" },
      { topicId: "R", source: "user", state: "rejected" },
    ]);
    const outcome = commitLegacy(target, ["C", "R", "E", "D"].map((topicId) => ({ topicId })));
    assert.deepEqual(outcome.committed, ["C", "D", "E"]);
    assert.deepEqual(outcome.truncated, ["R"]);
    assert.deepEqual(outcome.superseded, ["B"]);
    // 墓碑 pair 即便排进前三也写不进去
    assert.deepEqual(commitLegacy(target, [{ topicId: "R" }]).committed, []);
  }],
  ["acceptLegacyResponse：信封 / 候选数 / 主题侧依据三道复核", () => {
    const request = {
      schemaVersion: 3, operationId: "OP", textRevision: "REV",
      candidates: [{ ref: "P0", title: "甲", definition: "个人观察与反思", representatives: [{ ref: "R0", text: "跑步训练" }] }],
    };
    const chunk = { request, chunkText: "今天跑了五公里，有点累。" };
    const topicByRef = { P0: "A" };
    const envelope = { schemaVersion: 3, operationId: "OP", textRevision: "REV" };
    const accepted = acceptLegacyResponse(chunk, topicByRef, { ...envelope, decisions: [
      { candidateRef: "P0", relation: "fits_category", quote: "有点累", rangeUTF16: [8, 11], representativeRef: "definition", representativeQuote: "反思" },
    ] });
    assert.deepEqual(accepted.positives, [{ topicId: "A", relation: "fits_category" }]);
    assert.deepEqual(accepted.verdicts, { A: "fits_category" });
    // 主题侧引文回不了源 → 协议违约
    assert.throws(() => acceptLegacyResponse(chunk, topicByRef, { ...envelope, decisions: [
      { candidateRef: "P0", relation: "fits_category", quote: "有点累", rangeUTF16: [8, 11], representativeRef: "definition", representativeQuote: "不存在" },
    ] }), ContractViolationError);
    // 缺主题侧依据 → 不归属，但不算违约
    const skipped = acceptLegacyResponse(chunk, topicByRef, { ...envelope, decisions: [
      { candidateRef: "P0", relation: "fits_category", quote: "有点累", rangeUTF16: [8, 11] },
    ] });
    assert.deepEqual(skipped.positives, []);
    assert.deepEqual(skipped.verdicts, { A: "fits_category" });
    assert.throws(() => acceptLegacyResponse(chunk, topicByRef, { ...envelope, decisions: [] }), /decisions_missing/);
    assert.throws(() => acceptLegacyResponse(chunk, topicByRef, { ...envelope, operationId: "OTHER", decisions: [] }), /envelope/);
  }],
  ["buildLegacyCandidates：类别代表例用户确认优先；无用户规则时回退 AI 类别理解", () => {
    const user = thought("u1", "用户放入的样例", [{ topicId: "A", source: "user", state: "active" }], { updatedAtMs: 1 });
    const auto = thought("a1", "AI 归入的样例", [{ topicId: "A", source: "ai", state: "active" }], { updatedAtMs: 9 });
    const target = thought("x1", "目标想法");
    const withBrief = { thoughts: [user, auto, target], topics: new Map([["A", topic("A", "甲", true, { briefDefinition: "AI 起草的定义" })]]) };
    const { candidates, topicByRef } = buildLegacyCandidates(withBrief, target, { candidates: [{ topicId: "A", kind: "category" }] });
    assert.equal(topicByRef.P0, "A");
    assert.deepEqual(candidates[0].representatives.map((item) => item.ref), ["u1", "a1"]);
    assert.equal(candidates[0].definition, "AI 起草的定义");
    const withoutBrief = { ...withBrief, topics: new Map([["A", topic("A", "甲", true)]]) };
    assert.equal("definition" in buildLegacyCandidates(withoutBrief, target, { candidates: [{ topicId: "A", kind: "category" }] }).candidates[0], false);
  }],
  ["buildLegacyRequests：正文先脱敏再按 4000 分段；信封字段与客户端一致", () => {
    const target = thought("t", `记录 13800138000。${"长".repeat(4_000)}尾巴`);
    const candidates = [{ ref: "P0", title: "甲", kind: "category", representatives: [] }];
    const requests = buildLegacyRequests(target, candidates);
    assert.equal(requests.length, 2);
    assert.equal(requests[0].chunkText.startsWith("记录 [phone]。"), true);
    assert.equal(requests[0].chunkText.length, 4_000);
    assert.equal(requests[1].chunkText.endsWith("尾巴"), true);
    assert.equal(requests[0].request.target.ref, "T0");
    assert.equal(requests[0].request.schemaVersion, 3);
    assert.equal(requests[0].request.engineVersion, "thought_semantic_v3.2");
    assert.equal(requests[0].request.textRevision, target.contentHash);
    assert.deepEqual(requests[0].request.candidates, candidates);
  }],
  ["recall：类别全量直达；脉络走质心 / 向量门槛；墓碑压召回；主题 ≤3 时全部进候选；留一法", async () => {
    const map = new Map([
      [contentHash("成员一"), Float32Array.from([1, 0])],
      [contentHash("成员二"), Float32Array.from([0, 1])],
      [contentHash("目标"), Float32Array.from([1, 0])],
    ]);
    const profiles = [];
    const vectors = {
      get: (hash) => map.get(hash) ?? null,
      topicProfile: async (title) => {
        profiles.push(title);
        return Float32Array.from([0, 1]);
      },
    };
    const topics = new Map([
      ["A", topic("A", "甲", true)],
      ["B", topic("B", "乙", false)],
      ["C", topic("C", "丙", false)],
      ["D", topic("D", "丁", false)],
      ["E", topic("E", "戊", false)],
    ]);
    const asThread = (item) => ({ id: item.id, title: item.title, definition: "" });
    const thoughts = [
      thought("m1", "成员一", [{ topicId: "B", source: "user", state: "active" }]),
      thought("m2", "成员二", [{ topicId: "C", source: "ai", state: "active" }]),
    ];
    const state = {
      topics, thoughts, vectors, calibration: CALIBRATION_SEED,
      categoryTopics: [topics.get("A")],
      threadTopics: ["B", "C", "D", "E"].map((id) => asThread(topics.get(id))),
      memberCountById: new Map([["A", 0]]),
    };
    const target = thought("t", "目标");
    const outcome = await recall(state, target);
    assert.deepEqual(outcome.candidates.map((item) => [item.topicId, item.kind]), [["A", "category"], ["B", "thread"]]);
    // 无成员向量的丁、戊走标题向量；丙有质心但方向正交，不进候选
    assert.deepEqual(profiles, ["丁", "戊"]);
    // 用户拒绝过甲类别 → 该类别不再进候选
    const rejected = thought("t2", "目标", [{ topicId: "A", source: "user", state: "rejected" }]);
    assert.deepEqual((await recall(state, rejected)).candidates.map((item) => item.topicId), ["B"]);
    // 脉络主题只剩一个时，即便没有任何成员向量也进候选
    const few = { ...state, topics: new Map([["A", topics.get("A")], ["B", topics.get("B")]]), threadTopics: [asThread(topics.get("B"))], thoughts: [] };
    assert.deepEqual((await recall(few, target)).candidates.map((item) => item.topicId), ["A", "B"]);
    // 留一法：正在评测的想法不算成员——否则它自己的向量会把主题质心拉向自己
    const member = thought("t5", "目标", [{ topicId: "B", source: "user", state: "active" }]);
    const withSelf = { ...state, thoughts: [member] };
    assert.deepEqual((await recall(withSelf, member)).candidates.map((item) => item.topicId), ["A", "B"]);
    assert.deepEqual((await recall(withSelf, { ...member, links: [] }, { excludeThoughtId: member.id })).candidates.map((item) => item.topicId), ["A"]);
    // 两个类别成员数相同：去掉自己之后，自己所在的类别排到后面（标题用 a / b，避免依赖汉字编码顺序）
    const mine = topic("A", "a", true);
    const theirs = topic("F", "b", true);
    const owner = thought("t7", "目标", [{ topicId: "A", source: "user", state: "active" }]);
    const pair = {
      ...state,
      topics: new Map([["A", mine], ["F", theirs]]),
      thoughts: [thought("t6", "别的笔记", [{ topicId: "F", source: "user", state: "active" }]), owner],
      categoryTopics: [mine, theirs],
      memberCountById: new Map([["A", 1], ["F", 1]]),
    };
    const categoryOrder = async (exclude) => (await recall(pair, exclude ? { ...owner, links: [] } : owner, { excludeThoughtId: exclude ? owner.id : null }))
      .candidates.filter((item) => item.kind === "category").map((item) => item.topicId);
    assert.deepEqual(await categoryOrder(false), ["A", "F"]);
    assert.deepEqual(await categoryOrder(true), ["F", "A"]);
  }],
  ["clusterComponents：≥ 阈值才连边、并查集传递成簇、成员不足不成簇；fingerprint 与成员顺序无关", () => {
    // a—b 0.875、b—c 0.75、a—c 0.125：a、c 不直接相连也会被 b 串进同一簇；d、e 各自孤立
    const ids = ["a", "b", "c", "d", "e"];
    const vectors = new Map(ids.map((id) => [id, Float32Array.of(1)]));
    const similarity = { "a|b": 0.875, "b|c": 0.75, "a|c": 0.125 };
    const lookup = (id) => ids
      .filter((other) => other !== id && similarity[[id, other].sort().join("|")] !== undefined)
      .map((other) => ({ id: other, similarity: similarity[[id, other].sort().join("|")] }));
    assert.deepEqual(clusterComponents(ids, vectors, 0.55, 3, lookup), [{ members: ["a", "b", "c"], cohesion: 0.8125 }]);
    // 门槛提到 0.8：只剩 a—b 一条边，成员不足 3，不成簇
    assert.deepEqual(clusterComponents(["a", "b", "c"], vectors, 0.8, 3, lookup), []);
    assert.equal(fingerprint(["b", "a"]), fingerprint(["a", "b"]));
    assert.notEqual(fingerprint(["a", "b"]), fingerprint(["a", "c"]));
  }],
  ["stableUuid：同样输入得到同一个合法 UUID", () => {
    const id = stableUuid("holo-preset", "工作与事业");
    assert.equal(id, stableUuid("holo-preset", "工作与事业"));
    assert.match(id, /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/);
  }],
];

// 一次列出全部失败，不在第一处就停：预期值写错时能一轮看全
const failures = [];
for (const [name, body] of tests) {
  try {
    await body();
    console.log(`✓ ${name}`);
  } catch (error) {
    failures.push(name);
    console.log(`✗ ${name}\n    ${String(error.message).split("\n").slice(0, 6).join("\n    ")}`);
  }
}
if (failures.length > 0) {
  console.error(`移植自查失败 ${failures.length} / ${tests.length} 项`);
  process.exit(1);
}
console.log(`移植自查通过 ${tests.length} 项`);
