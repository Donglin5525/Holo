import assert from "node:assert/strict";
import { test } from "node:test";

import {
  buildDeterministicIntentCompletion,
  resolveDeterministicIntent,
} from "../src/intentResponseStabilizer.js";

test("个人近期整体状态问法稳定路由到跨域 query_analysis", () => {
  const cases = [
    "我最近状态怎么样",
    "我最近状态如何",
    "最近我咋样",
    "帮我看看我近期的整体情况",
    "总结一下我这段时间的表现",
    "我最近过得好不好？",
    "最近状态怎么样",
  ];

  for (const input of cases) {
    const results = Array.from({ length: 20 }, () => resolveDeterministicIntent(input));
    for (const result of results) {
      assert.equal(result?.mode, "query", input);
      assert.equal(result?.needsClarification, false, input);
      assert.equal(result?.items[0]?.intent, "query_analysis", input);
      assert.equal(result?.items[0]?.extractedData?.analysisDomain, "cross_domain", input);
      assert.equal(result?.items[0]?.extractedData?.analysisScope, "holistic", input);
      assert.equal(result?.items[0]?.extractedData?.periodLabel, "最近", input);
    }
    assert.equal(new Set(results.map((result) => JSON.stringify(result))).size, 1, input);
  }
});

test("单域和多域状态问法保留分析范围", () => {
  const sleep = resolveDeterministicIntent("我最近睡眠怎么样");
  assert.equal(sleep?.items[0]?.extractedData?.analysisDomain, "health");
  assert.equal(sleep?.items[0]?.extractedData?.subDomain, "sleep");

  const finance = resolveDeterministicIntent("最近财务状态怎么样");
  assert.equal(finance?.items[0]?.extractedData?.analysisDomain, "finance");
  assert.equal(finance?.items[0]?.extractedData?.analysisScope, "domain");

  const crossDomain = resolveDeterministicIntent("我最近财务和健康状态怎么样");
  assert.equal(crossDomain?.items[0]?.extractedData?.analysisDomain, "cross_domain");
  assert.equal(crossDomain?.items[0]?.extractedData?.analysisScope, "holistic");

  const habits = resolveDeterministicIntent("我最近打卡情况怎么样");
  assert.equal(habits?.items[0]?.extractedData?.analysisDomain, "habit");

  const weeklySteps = resolveDeterministicIntent("这周步数趋势");
  assert.equal(weeklySteps?.items[0]?.extractedData?.analysisDomain, "health");
  assert.equal(weeklySteps?.items[0]?.extractedData?.periodLabel, "本周");
});

test("闲聊、外部对象、陈述句和执行混合输入不被确定性规则误接管", () => {
  const cases = [
    "你最近怎么样",
    "他最近状态怎么样",
    "我们最近状态怎么样",
    "孩子最近状态怎么样",
    "Holo 服务状态怎么样",
    "今天天气怎么样",
    "我的项目最近状态怎么样",
    "我们公司的项目最近状态怎么样",
    "最近麦当劳怎么样",
    "我最近状态不好",
    "我的状态",
    "我最近状态怎么样，顺便提醒我晚上八点喝水",
    "我最近支出很多，帮我记一笔 35 元午饭",
  ];

  for (const input of cases) {
    assert.equal(resolveDeterministicIntent(input), null, input);
  }
});

test("确定性结果生成兼容 Chat Completions 的 JSON 响应", () => {
  const completion = buildDeterministicIntentCompletion(
    [
      { role: "system", content: "系统规则" },
      { role: "user", content: "我最近状态怎么样" },
    ],
    "deepseek-v4-flash",
  );

  assert.equal(completion?.id, "holo-deterministic-intent");
  assert.equal(completion?.provider, "holo-rules");
  assert.equal(completion?.model, "deepseek-v4-flash");
  const parsed = JSON.parse(completion.choices[0].message.content);
  assert.equal(parsed.items[0].intent, "query_analysis");
  assert.equal(parsed.needsClarification, false);
});
