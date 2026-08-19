import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

const DEVICE_ID = "feedback-device";
const ADMIN_HEADERS = { "x-holo-admin-token": "secret-admin-token" };
// 最小合法 JPEG：FFD8 魔数 + 填充字节（路由只校验魔数与大小）
const TINY_JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]);

function createTestApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const imagesDir = mkdtempSync(join(tmpdir(), "holo-feedback-"));
  return {
    app: createApp({
      database,
      feedbackImagesDir: imagesDir,
      auth: { enforceAppAttest: false },
      admin: {
        token: "secret-admin-token",
        username: "admin",
        password: "secret-password",
        sessionSecret: "secret-session",
      },
      ...overrides,
    }),
    imagesDir,
  };
}

function feedbackBody(extra = {}) {
  return JSON.stringify({
    category: "suggestion",
    content: "希望周历支持双指缩放",
    contactType: "wechat",
    contactValue: "holofan_2026",
    appVersion: "1.0.0",
    osVersion: "iOS 18.5",
    ...extra,
  });
}

async function submitFeedback(app, body, headers = {}) {
  return app.request("/v1/feedback", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
      ...headers,
    },
    body,
  });
}

test("user_feedback table is created by migrations", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const tables = database.db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
    .all()
    .map((row) => row.name);
  assert.ok(tables.includes("user_feedback"));
});

test("a device can submit feedback and it is persisted", async () => {
  const { app } = createTestApp();

  const response = await submitFeedback(app, feedbackBody());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });

  const list = await app.request("/v1/admin/feedback", { headers: ADMIN_HEADERS });
  assert.equal(list.status, 200);
  const { feedback } = await list.json();
  assert.equal(feedback.length, 1);
  assert.equal(feedback[0].category, "suggestion");
  assert.equal(feedback[0].content, "希望周历支持双指缩放");
  assert.equal(feedback[0].contact_type, "wechat");
  assert.equal(feedback[0].contact_value, "holofan_2026");
  assert.equal(feedback[0].app_version, "1.0.0");
  assert.equal(feedback[0].status, "new");
  assert.equal(feedback[0].device_id, DEVICE_ID);
});

test("feedback images are written to the images dir and referenced in the row", async () => {
  const { app, imagesDir } = createTestApp();

  const response = await submitFeedback(app, feedbackBody({
    images: [TINY_JPEG.toString("base64"), TINY_JPEG.toString("base64")],
  }));
  assert.equal(response.status, 200);

  const files = readdirSync(imagesDir).sort();
  assert.equal(files.length, 2);
  assert.match(files[0], /^1-0\.jpg$/);
  assert.deepEqual(readFileSync(join(imagesDir, files[0])), TINY_JPEG);

  const { feedback } = await (await app.request("/v1/admin/feedback", { headers: ADMIN_HEADERS })).json();
  assert.deepEqual(feedback[0].imageFiles, files);

  const image = await app.request(`/admin/feedback/images/${files[0]}`, { headers: ADMIN_HEADERS });
  assert.equal(image.status, 200);
  assert.equal(image.headers.get("content-type"), "image/jpeg");
});

test("invalid payloads are rejected: category, content, contactType, images", async () => {
  const { app } = createTestApp();

  const badCategory = await submitFeedback(app, feedbackBody({ category: "complaint" }));
  assert.equal(badCategory.status, 400);

  const noContent = await submitFeedback(app, feedbackBody({ content: "   " }));
  assert.equal(noContent.status, 400);

  const orphanContact = await submitFeedback(app, feedbackBody({ contactType: "fax" }));
  assert.equal(orphanContact.status, 400);

  const tooManyImages = await submitFeedback(app, feedbackBody({
    images: Array.from({ length: 4 }, () => TINY_JPEG.toString("base64")),
  }));
  assert.equal(tooManyImages.status, 400);

  const notJpeg = await submitFeedback(app, feedbackBody({
    images: [Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString("base64")],
  }));
  assert.equal(notJpeg.status, 400);

  const oversized = await submitFeedback(app, feedbackBody({
    images: [Buffer.concat([TINY_JPEG, Buffer.alloc(1536 * 1024)]).toString("base64")],
  }), { "x-holo-device-id": "oversize-device" });
  assert.equal(oversized.status, 413);
});

test("feedback requires device identity when app attest is enforced", async () => {
  const { app } = createTestApp({ auth: { enforceAppAttest: true } });

  const response = await app.request("/v1/feedback", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: feedbackBody(),
  });
  assert.equal(response.status, 401);
});

test("repeated feedback from one device is rate limited", async () => {
  const { app } = createTestApp({
    limits: { feedbackRequestsPerMinute: 1, feedbackRequestsPerDay: 5 },
  });

  const first = await submitFeedback(app, feedbackBody());
  assert.equal(first.status, 200);

  const second = await submitFeedback(app, feedbackBody({ content: "再来一条" }));
  assert.equal(second.status, 429);
  assert.equal((await second.json()).error.code, "FEEDBACK_RATE_LIMITED");
});

test("admin feedback endpoints require authorization", async () => {
  const { app } = createTestApp();

  const page = await app.request("/admin/feedback");
  assert.equal(page.status, 302);

  const json = await app.request("/v1/admin/feedback");
  assert.equal(json.status, 401);

  const image = await app.request("/admin/feedback/images/1-0.jpg");
  assert.equal(image.status, 302);
});

test("authorized admin sees HTML page with badges, filters and contact", async () => {
  const { app } = createTestApp();
  await submitFeedback(app, feedbackBody({ contactType: "phone", contactValue: "13800138866" }));

  const page = await app.request("/admin/feedback", { headers: ADMIN_HEADERS });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type"), /text\/html/);
  assert.match(page.headers.get("content-security-policy"), /img-src 'self'/);
  const html = await page.text();
  assert.match(html, /用户反馈/);
  assert.match(html, /13800138866/);
  assert.match(html, /功能建议/);
  assert.match(html, /标记已处理/);

  const filtered = await app.request("/admin/feedback?category=issue", { headers: ADMIN_HEADERS });
  const filteredHtml = await filtered.text();
  assert.doesNotMatch(filteredHtml, /希望周历支持双指缩放/);
});

test("admin can mark feedback done and revert it", async () => {
  const { app } = createTestApp();
  await submitFeedback(app, feedbackBody());

  const done = await app.request("/admin/feedback/1/status", {
    method: "POST",
    headers: { ...ADMIN_HEADERS, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ status: "done", back: "/admin/feedback" }).toString(),
  });
  assert.equal(done.status, 302);

  const afterDone = await (await app.request("/v1/admin/feedback", { headers: ADMIN_HEADERS })).json();
  assert.equal(afterDone.feedback[0].status, "done");

  const revert = await app.request("/admin/feedback/1/status", {
    method: "POST",
    headers: { ...ADMIN_HEADERS, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ status: "new", back: "/admin/feedback" }).toString(),
  });
  assert.equal(revert.status, 302);

  const afterRevert = await (await app.request("/v1/admin/feedback", { headers: ADMIN_HEADERS })).json();
  assert.equal(afterRevert.feedback[0].status, "new");
});

test("image route rejects path traversal style names", async () => {
  const { app } = createTestApp();
  await submitFeedback(app, feedbackBody());

  const denied = await app.request("/admin/feedback/images/..%2F..%2Fetc%2Fpasswd", { headers: ADMIN_HEADERS });
  assert.ok(denied.status === 404 || denied.status === 400);
});
