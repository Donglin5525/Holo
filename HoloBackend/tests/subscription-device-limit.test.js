import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

// 回归锁（2026-10-31 审计 D2）：StoreKit 2 JWS 是不记名凭证，entitlement 只按
// device_id 落库且无 originalTransactionId 归属校验——同一份 Plus 凭证提交到
// 任意多台设备，每台各享完整 Plus 配额池，直接对应收入损失。

const PLUS_MONTHLY = "com.tangyuxuan.holo.plus.monthly";
const FUTURE_ISO = new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString();

function createTestApp({ deviceLimit = 2 } = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    subscription: { deviceLimit },
    appleReceiptVerifier: {
      async verify() {
        return {
          tier: "plus",
          productId: PLUS_MONTHLY,
          originalTransactionId: "otid-1",
          latestTransactionId: "t-1",
          environment: "Production",
          expiresAt: FUTURE_ISO,
          revokedAt: null,
        };
      },
    },
  });
  return app;
}

async function sync(app, deviceId) {
  return app.request("/v1/subscription/sync", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify({ productId: PLUS_MONTHLY, signedTransactionInfo: "any" }),
  });
}

test("同一笔购买的绑定设备数达到上限后拒绝新设备", async () => {
  const app = createTestApp({ deviceLimit: 2 });

  const first = await sync(app, "device-a");
  assert.equal(first.status, 200);
  const second = await sync(app, "device-b");
  assert.equal(second.status, 200);

  const third = await sync(app, "device-c");
  assert.equal(third.status, 409);
  const body = await third.json();
  assert.equal(body.error.code, "SUBSCRIPTION_DEVICE_LIMIT");
  assert.equal(body.error.deviceLimit, 2);
});

test("已绑定同一笔购买的设备重复 sync 不受上限影响", async () => {
  const app = createTestApp({ deviceLimit: 2 });

  assert.equal((await sync(app, "device-a")).status, 200);
  assert.equal((await sync(app, "device-b")).status, 200);
  // 设备 A 换机重装/续期后的 re-sync 必须照常通过
  const resync = await sync(app, "device-a");
  assert.equal(resync.status, 200);
  const body = await resync.json();
  assert.equal(body.tier, "plus");
});
