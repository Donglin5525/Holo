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
