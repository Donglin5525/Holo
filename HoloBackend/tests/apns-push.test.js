import assert from "node:assert/strict";
import { test } from "node:test";
import { EventEmitter } from "node:events";
import { generateKeyPairSync } from "node:crypto";
import { randomBytes } from "node:crypto";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createDeviceTokenStore } from "../src/push/deviceTokenStore.js";
import { createApnsSender } from "../src/push/apnsSender.js";

// —— 测试用 EC P-256 密钥（与 APNs .p8 同格式）——
const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const TEST_KEY_PEM = privateKey.export({ type: "pkcs8", format: "pem" });
const TOKEN = randomBytes(32).toString("hex");

/**
 * fake http2.connect：handler(authority, headers, body) → {status, body?}。
 * 模拟 sender 消费的事件序列：response → data → end。
 */
function fakeConnect(handler) {
  const calls = [];
  const makeClient = () => {
    const client = Object.assign(new EventEmitter(), { destroyed: false, closed: false });
    client.request = (headers) => {
      const request = new EventEmitter();
      request.setTimeout = () => {};
      request.close = () => {};
      request.setEncoding = () => {};
      request.end = (payload) => {
        const body = payload ? JSON.parse(payload) : null;
        calls.push({ authority: client._authority, headers, body });
        const result = handler(calls[calls.length - 1]);
        setImmediate(() => {
          request.emit("response", { ":status": result.status });
          if (result.body) request.emit("data", JSON.stringify(result.body));
          request.emit("end");
        });
      };
      return request;
    };
    return client;
  };
  const connect = (authority) => {
    const client = makeClient();
    client._authority = authority;
    return client;
  };
  connect.calls = calls;
  return connect;
}

function makeSender(handler, overrides = {}) {
  return createApnsSender({
    keyPem: TEST_KEY_PEM,
    keyId: "TESTKEYID1",
    teamId: "TESTTEAMID",
    bundleId: "com.test.app",
    connect: fakeConnect(handler),
    ...overrides,
  });
}

test("apnsSender：未配置密钥返回 disabled（发送 no-op）", async () => {
  const sender = createApnsSender({});
  assert.equal(sender.configured, false);
  const result = await sender.send({ token: TOKEN, title: "t", body: "b" });
  assert.equal(result.ok, false);
  assert.equal(result.skipped, "not_configured");
});

test("apnsSender：production 200 直发成功并回写环境", async () => {
  const sender = makeSender(() => ({ status: 200 }));
  const result = await sender.send({ token: TOKEN, title: "深度分析完成", body: "结果已就绪" });
  assert.equal(result.ok, true);
  assert.equal(result.environment, "production");
});

test("apnsSender：BadDeviceToken 自动回退 sandbox，请求头与 payload 正确", async () => {
  let senderRef;
  const connect = fakeConnect(({ authority }) => {
    if (authority.includes("sandbox")) return { status: 200 };
    return { status: 400, body: { reason: "BadDeviceToken" } };
  });
  const sender = createApnsSender({
    keyPem: TEST_KEY_PEM, keyId: "K", teamId: "T", bundleId: "com.test.app", connect,
  });
  senderRef = sender;
  const result = await senderRef.send({ token: TOKEN, title: "t", body: "b" });
  assert.equal(result.ok, true);
  assert.equal(result.environment, "sandbox");
  assert.equal(connect.calls.length, 2);
  assert.equal(connect.calls[0].authority, "https://api.push.apple.com");
  assert.equal(connect.calls[1].authority, "https://api.sandbox.push.apple.com");
  // JWT 头 + topic + alert payload
  assert.match(connect.calls[0].headers.authorization, /^bearer .+\..+\..+$/);
  assert.equal(connect.calls[0].headers["apns-topic"], "com.test.app");
  assert.equal(connect.calls[0].body.aps.alert.title, "t");
  assert.equal(connect.calls[0].body.aps.sound, "default");
});

test("apnsSender：已验证 sandbox 环境直发不再试探 production", async () => {
  const connect = fakeConnect(() => ({ status: 200 }));
  const sender = createApnsSender({
    keyPem: TEST_KEY_PEM, keyId: "K", teamId: "T", bundleId: "com.test.app", connect,
  });
  await sender.send({ token: TOKEN, environment: "sandbox", title: "t", body: "b" });
  assert.equal(connect.calls.length, 1);
  assert.equal(connect.calls[0].authority.includes("sandbox"), true);
});

test("apnsSender：410 Unregistered 返回 unregistered（调用方删行）", async () => {
  const sender = makeSender(() => ({ status: 410, body: { reason: "Unregistered" } }));
  const result = await sender.send({ token: TOKEN, title: "t", body: "b" });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "unregistered");
});

test("deviceTokenStore：upsert/换token清环境/markEnvironment/remove", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createDeviceTokenStore(database.db);
  store.upsert("d1", "a".repeat(64));
  store.markEnvironment("d1", "production");
  assert.equal(store.get("d1").environment, "production");
  // 同 token 重复上报：无操作（环境保留）
  store.upsert("d1", "a".repeat(64));
  assert.equal(store.get("d1").environment, "production");
  // token 轮换：清空已验证环境（新 token 环境未知）
  store.upsert("d1", "b".repeat(64));
  assert.equal(store.get("d1").environment, null);
  assert.equal(store.get("d1").token, "b".repeat(64));
  store.remove("d1");
  assert.equal(store.get("d1"), null);
});

test("端点：合法 token 上报落库；非法格式 400", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createDeviceTokenStore(database.db);
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 100,
      chatRequestsPerDay: 1000,
    },
    aiCallLogs: { enabled: false },
    runtimeEnvironment: "test",
    deviceTokenStore: store,
  });
  const ok = await app.request("/v1/ai/agent/cloud/device-token", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "device-push" },
    body: JSON.stringify({ token: TOKEN.toUpperCase() }),
  });
  assert.equal(ok.status, 200);
  assert.equal(store.get("device-push").token, TOKEN);

  const bad = await app.request("/v1/ai/agent/cloud/device-token", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "device-push" },
    body: JSON.stringify({ token: "not-hex" }),
  });
  assert.equal(bad.status, 400);
});
