import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

const DEVICE_ID = "report-device";
const ADMIN_HEADERS = { "x-holo-admin-token": "secret-admin-token" };

function createTestApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  return createApp({
    database,
    auth: { enforceAppAttest: false },
    admin: {
      token: "secret-admin-token",
      username: "admin",
      password: "secret-password",
      sessionSecret: "secret-session",
    },
    ...overrides,
  });
}

function reportBody(extra = {}) {
  return JSON.stringify({
    messageId: "msg-1",
    reason: "包含不当内容",
    contentSnapshot: "AI 生成的冒犯性内容",
    ...extra,
  });
}

async function submitReport(app, body, headers = {}) {
  return app.request("/v1/reports", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
      ...headers,
    },
    body,
  });
}

test("content_reports table is created by migrations", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const tables = database.db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
    .all()
    .map((row) => row.name);
  assert.ok(tables.includes("content_reports"));
});

test("a signed-in device can submit a content report and it is persisted", async () => {
  const app = createTestApp();

  const response = await submitReport(app, reportBody());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });

  const list = await app.request("/v1/admin/reports", { headers: ADMIN_HEADERS });
  assert.equal(list.status, 200);
  const { reports } = await list.json();
  assert.equal(reports.length, 1);
  assert.equal(reports[0].message_id, "msg-1");
  assert.equal(reports[0].reason, "包含不当内容");
  assert.equal(reports[0].content_snapshot, "AI 生成的冒犯性内容");
  assert.equal(reports[0].status, "pending");
  assert.equal(reports[0].device_id, DEVICE_ID);
});

test("missing messageId or reason is rejected with 400", async () => {
  const app = createTestApp();

  const noMessageId = await submitReport(
    app,
    JSON.stringify({ reason: "包含不当内容" }),
  );
  assert.equal(noMessageId.status, 400);

  const noReason = await submitReport(
    app,
    JSON.stringify({ messageId: "msg-1" }),
  );
  assert.equal(noReason.status, 400);
});

test("report requires device identity when app attest is enforced", async () => {
  const app = createTestApp({ auth: { enforceAppAttest: true } });

  const response = await app.request("/v1/reports", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: reportBody(),
  });
  assert.equal(response.status, 401);
});

test("repeated reports from one device are rate limited", async () => {
  const app = createTestApp({
    limits: { reportRequestsPerMinute: 1, reportRequestsPerDay: 5 },
  });

  const first = await submitReport(app, reportBody({ messageId: "msg-1" }));
  assert.equal(first.status, 200);

  const second = await submitReport(app, reportBody({ messageId: "msg-2" }));
  assert.equal(second.status, 429);
  const error = (await second.json()).error;
  assert.equal(error.code, "REPORT_RATE_LIMITED");
});

test("admin reports endpoint requires admin authorization", async () => {
  const app = createTestApp();
  await submitReport(app, reportBody());

  const denied = await app.request("/v1/admin/reports");
  assert.equal(denied.status, 401);
});

test("authorized admin can view reports via JSON and HTML page", async () => {
  const app = createTestApp();
  await submitReport(app, reportBody({ detail: "冒犯性表述" }));

  const json = await app.request("/v1/admin/reports", { headers: ADMIN_HEADERS });
  assert.equal(json.status, 200);
  const { reports } = await json.json();
  assert.equal(reports.length, 1);
  assert.equal(reports[0].detail, "冒犯性表述");

  const page = await app.request("/admin/reports", { headers: ADMIN_HEADERS });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type"), /text\/html/);
  const html = await page.text();
  assert.match(html, /AI 内容举报/);
  assert.match(html, /冒犯性表述/);
});
