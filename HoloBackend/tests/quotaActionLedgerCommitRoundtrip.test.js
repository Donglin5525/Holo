import assert from "node:assert/strict";
import { test } from "node:test";

import { createDatabase } from "../src/db/database.js";
import { createQuotaActionLedgerStore } from "../src/usage/quotaActionLedgerStore.js";

// 回归锁（2026-09-19 生产实锤）：reserve() 返回值曾被 snapshot 覆盖丢失
// subjectId/actionId，云端执行器把返回值原样回传 commit/release 时
// WHERE 全空匹配，commit 静默失效——云端深度分析完成后额度永远停留
// reserved（不扣费）。凭证字段必须随返回值带回且可直接回传。

function createStore() {
  const database = createDatabase({ dbPath: ":memory:" });
  return createQuotaActionLedgerStore(database.db);
}

const INPUT = {
  subjectId: "purchase:ledger-roundtrip",
  quotaType: "deepAnalysis",
  actionId: "roundtrip-1",
  tier: "free",
};

test("reserve 返回值可直接回传 commit（执行器契约）", () => {
  const store = createStore();
  const reservation = store.reserve(INPUT);
  assert.equal(reservation.allowed, true);
  assert.equal(reservation.subjectId, INPUT.subjectId);
  assert.equal(reservation.actionId, INPUT.actionId);
  assert.equal(reservation.quotaType, INPUT.quotaType);

  const after = store.commit(reservation);
  assert.equal(after.used, 1, "commit 必须让已用计数 +1");

  // 再 reserve 同一 action 命中幂等行（committed 状态），不重复计数
  const dup = store.reserve(INPUT);
  assert.equal(dup.duplicate, true);
  assert.equal(dup.used, 1);
});

test("reserve 返回值可直接回传 release（失败路径契约）", () => {
  const store = createStore();
  const reservation = store.reserve(INPUT);
  store.release(reservation);

  const peek = store.peek(INPUT);
  assert.equal(peek.used, 0, "release 后不得残留计数");
  assert.equal(peek.available, peek.limit, "release 后可用余量应回满");
});

// 回归锁（2026-10-31 审计 D1）：actionId 由客户端任意指定且不绑定请求内容，
// 旧实现把「已存在记录」一律按幂等放行——重放同一个键即可绕过全部次数池。
test("宽限期外的 committed 键重放必须重新计数（防一个键吃掉次数池）", () => {
  const clock = { now: Date.UTC(2026, 9, 31, 0, 0, 0) };
  const now = () => new Date(clock.now);
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createQuotaActionLedgerStore(database.db, { now });
  // 用 chat（免费 15 次/日）：deepAnalysis 只有 2 次，走不到第三次重放
  const REPLAY_INPUT = { ...INPUT, subjectId: "purchase:ledger-replay", quotaType: "chat" };

  const first = store.reserve(REPLAY_INPUT);
  store.commit(first);
  assert.equal(first.duplicate, false);

  // 宽限期内重放同一键 = 合法重试，不重复计数
  clock.now += 60_000;
  const quickRetry = store.reserve(REPLAY_INPUT);
  assert.equal(quickRetry.duplicate, true);
  assert.equal(quickRetry.used, 1);

  // 宽限期外重放同一键 = 新请求：落 #1 后缀新行并计数
  clock.now += 11 * 60 * 1000;
  const replay = store.reserve(REPLAY_INPUT);
  assert.equal(replay.duplicate, false);
  assert.equal(replay.actionId, `${REPLAY_INPUT.actionId}#1`, "服务端后缀键必须随返回值带回供 commit/release");
  store.commit(replay);
  assert.equal(store.peek(REPLAY_INPUT).used, 2);

  // 连续重放：#1 已提交且是服务端铸的键，不得幂等放行——继续 #2 重新计数
  const replay2 = store.reserve(REPLAY_INPUT);
  assert.equal(replay2.duplicate, false);
  assert.equal(replay2.actionId, `${REPLAY_INPUT.actionId}#2`);
  store.commit(replay2);
  assert.equal(store.peek(REPLAY_INPUT).used, 3);
});
