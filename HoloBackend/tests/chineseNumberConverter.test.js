import assert from "node:assert/strict";
import { test } from "node:test";

import { normalizeChineseNumbers } from "../src/chineseNumberConverter.js";
import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

// —— 单元测试：纯函数行为 ——

test("货币单位触发转换", () => {
  assert.equal(normalizeChineseNumbers("今天午饭花了二十元"), "今天午饭花了20元");
  assert.equal(normalizeChineseNumbers("花了三百块"), "花了300块");
  assert.equal(normalizeChineseNumbers("十五块五毛"), "15块5毛");
});

test("量词触发转换", () => {
  assert.equal(normalizeChineseNumbers("一共五个人"), "一共5个人");
  assert.equal(normalizeChineseNumbers("去了三次健身房"), "去了3次健身房");
  assert.equal(normalizeChineseNumbers("买了三百二十五个苹果"), "买了325个苹果");
});

test("多字量词触发转换", () => {
  assert.equal(normalizeChineseNumbers("体重七十公斤"), "体重70公斤");
  assert.equal(normalizeChineseNumbers("跑了三公里"), "跑了3公里");
  assert.equal(normalizeChineseNumbers("长五厘米"), "长5厘米");
});

test("时间单位触发转换", () => {
  assert.equal(normalizeChineseNumbers("二零二六年三月五号"), "2026年3月5号");
  assert.equal(normalizeChineseNumbers("大概八点半到"), "大概8点半到");
  assert.equal(normalizeChineseNumbers("二零二五年一月"), "2025年1月");
});

test("「第」前缀触发转换", () => {
  assert.equal(normalizeChineseNumbers("第三天就完成了"), "第3天就完成了");
});

test("万/亿大单位触发转换", () => {
  assert.equal(normalizeChineseNumbers("房价两百万"), "房价2000000");
  assert.equal(normalizeChineseNumbers("赚了三千万"), "赚了30000000");
});

test("年份逐位读法转阿拉伯数字", () => {
  assert.equal(normalizeChineseNumbers("二零二六年"), "2026年");
});

test("位值制数值解析", () => {
  assert.equal(normalizeChineseNumbers("一千二百三十四个"), "1234个");
  assert.equal(normalizeChineseNumbers("九千九百九十九元"), "9999元");
});

test("成语中的数字保留中文", () => {
  assert.equal(normalizeChineseNumbers("一五一十地讲了一遍"), "一五一十地讲了1遍");
  assert.equal(normalizeChineseNumbers("心里七上八下的"), "心里七上八下的");
  assert.equal(normalizeChineseNumbers("说三道四"), "说三道四");
  assert.equal(normalizeChineseNumbers("一日千里"), "一日千里");
  assert.equal(normalizeChineseNumbers("千载难逢的机会"), "千载难逢的机会");
  assert.equal(normalizeChineseNumbers("百发百中"), "百发百中");
});

test("概数保留中文", () => {
  assert.equal(normalizeChineseNumbers("大概三五个就够了"), "大概三五个就够了");
});

test("无数字的文本原样返回", () => {
  assert.equal(normalizeChineseNumbers("今天天气不错"), "今天天气不错");
  assert.equal(normalizeChineseNumbers("我很开心"), "我很开心");
});

test("空字符串和非法输入安全返回", () => {
  assert.equal(normalizeChineseNumbers(""), "");
  // null/undefined 视为空文本，返回空串（不抛异常）。
  assert.equal(normalizeChineseNumbers(null), "");
  assert.equal(normalizeChineseNumbers(undefined), "");
});

// —— 端到端测试：ASR 路由层注入转换 ——

function createAsrTestApp(transcript, overrides = {}) {
  return createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 20,
      chatRequestsPerDay: 50,
      asrRequestsPerMinute: 2,
      asrRequestsPerDay: 10,
      asrMaxBytes: 1024,
    },
    asrProvider: {
      async transcribe() {
        return { text: transcript, provider: "test-asr", duration: null, confidence: null };
      },
    },
    ...overrides,
  });
}

async function postTranscript(app) {
  const body = new FormData();
  body.set("audio", new Blob(["voice-bytes"], { type: "audio/wav" }), "voice.wav");
  const response = await app.request("/v1/asr/transcriptions", {
    method: "POST",
    headers: { "x-holo-device-id": "device-number-conv" },
    body,
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("ASR 转写结果的中文数字被归一化", async () => {
  const app = createAsrTestApp("今天午饭花了二十元，去了三次");
  const json = await postTranscript(app);
  assert.equal(json.text, "今天午饭花了20元，去了3次");
});

test("开关关闭时不对转写结果做数字归一化", async () => {
  const app = createAsrTestApp("今天午饭花了二十元", {
    asr: { chineseNumberConversionEnabled: false },
  });
  const json = await postTranscript(app);
  assert.equal(json.text, "今天午饭花了二十元");
});
