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

test("为未来事件做准备的规划问法确定性路由到 contextual_planning（录屏原句 100 次一致）", () => {
  const cases = [
    // 录屏原句（2026-09-09 23:23 录屏暴露的同句路由漂移）
    "要去日本旅行，要提前做什么准备",
    // 同义表达覆盖：旅行/搬家/考试/就医/项目发布/重要决策（实施方案 §12.1）
    "下个月要搬家了，帮我整理一份搬家前的准备清单",
    "我下周要去云南玩，出发前要做什么准备",
    "九月底要去成都出差，帮我规划一下出发前的安排",
    "下周六要考驾照科目三，帮我安排下考前要准备的事",
    "过两天要去医院做体检，需要提前准备什么",
    "我负责的项目下周要上线了，帮我梳理下上线前还要做哪些事",
    "家里老人下个月要做手术，帮我列一下术前要准备的注意事项",
    "春节要回老家，帮我提前规划下回家前要安排的事情",
    "下周一开始要给孩子断奶，帮我准备下需要的东西和步骤",
    "我打算月底开始跑步减肥，帮我规划下开始前要做哪些准备",
    "朋友下周日结婚我要去当伴郎，需要提前准备什么",
    "下周要在年会上做汇报演讲，帮我规划下要准备的内容",
    "十一要带爸妈去自驾游，出发前要我准备哪些东西",
    "我下个月要搬进新办公室，帮我列一下搬迁前要安排的事",
    "后天要去办护照，我需要提前准备什么材料",
    "下周家里要来客人，帮我提前规划下要准备的事",
    "我准备下个月开始学车，帮我梳理下报名前要做的事",
    "年底要办婚礼了，帮我规划下提前半年就要开始的准备事项",
    "下周要去国外留学，行前要做什么准备",
    "我月底要第一次独自带娃出门，帮我列下出门前要准备的东西",
  ];

  for (const input of cases) {
    const results = Array.from({ length: 100 }, () => resolveDeterministicIntent(input));
    for (const result of results) {
      assert.equal(result?.mode, "query", input);
      assert.equal(result?.needsClarification, false, input);
      assert.equal(result?.items?.[0]?.intent, "contextual_planning", input);
      assert.equal(result?.items?.[0]?.routeSource, "deterministic", input);
      assert.equal(result?.items?.[0]?.routeReasonCode, "EVENT_PREPARATION_PLAN", input);
    }
    assert.equal(new Set(results.map((result) => JSON.stringify(result))).size, 1, input);
  }
});

test("单项写操作、数据明细查询、纯外部事实与无准备请求的陈述不被规划规则接管", () => {
  const cases = [
    // 单项写操作（明确落在写链路）
    "帮我创建一个去日本旅行的待办",
    "记一笔机票 3000 元",
    "帮我记录一下明天要给妈妈打电话",
    "创建任务：周三下午取护照",
    // 已指定数据明细查询
    "查一下我上个月在日本花了多少钱",
    // 纯外部事实
    "日本现在几点",
    "今天天气怎么样",
    "日本签证需要哪些材料",
    // 未来事件但没有准备/规划请求——留给模型路由判断
    "我要去日本旅行",
    "国庆我打算宅在家里",
  ];

  for (const input of cases) {
    assert.equal(resolveDeterministicIntent(input), null, input);
  }
});

test("规划规则不抢已有状态查询规则（近期状态问法仍归 query_analysis）", () => {
  const cases = [
    "我最近状态怎么样",
    "最近财务状态怎么样",
    "我最近睡眠怎么样",
  ];

  for (const input of cases) {
    const result = resolveDeterministicIntent(input);
    assert.equal(result?.items?.[0]?.intent, "query_analysis", input);
    assert.notEqual(result?.items?.[0]?.intent, "contextual_planning", input);
  }
});
