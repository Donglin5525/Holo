import { test } from "node:test";
import assert from "node:assert/strict";
import { extractStats, extractChineseStats, statMatches, flagSentenceNumbers, stripNonStats } from "../src/agent/deepReport/numberCheck.js";

test("阿拉伯数字：千分位/万/千/k/区间", () => {
  const stats = extractStats("共 15,322 元、约1.5万，花了3000，15.3k，600多，比上月少了 55.6%");
  const raws = stats.map((s) => s.raw);
  assert.deepEqual(raws, ["15,322", "1.5万", "3000", "15.3k", "600多", "55.6"]);
});

test("中文数字：两万/一万八/六百多/三成/十二顿", () => {
  const raws = extractStats("少了将近两万，其中一万八来自旅行，日常只少了六百多，约占三成，停了十二天，健身二十次", { decimals: true }).map((s) => s.raw);
  assert.deepEqual(raws, ["两万", "一万八", "六百多", "三成", "十二", "二十"]);
});

test("日期与时刻不算统计数字", () => {
  assert.deepEqual(extractStats("10月30日花了 500 元，11-03 又花 200，23:30 买夜宵，2026年共花 12000"), [
    { raw: "500", value: 500, scaled: false },
    { raw: "200", value: 200, scaled: false },
    { raw: "12000", value: 12000, scaled: false },
  ]);
});

test("约数与取整能对上白名单", () => {
  const allowed = [19162.93, 611.44, 1550.2, 1333.25];
  assert.equal(statMatches({ value: 19000, scaled: true }, allowed), true, "将近 1.9 万");
  assert.equal(statMatches({ value: 15322, scaled: false }, [15321.96]), true, "1550.20 写 1550");
  assert.equal(statMatches({ value: 20000, scaled: true }, allowed), true, "两万 对 19162.93（5% 内）");
  assert.equal(statMatches({ value: 7486, scaled: false }, allowed), false, "凭空数字必须被拦");
});

test("区间约数：600多 匹配 611.44", () => {
  const s = extractStats("日常只少了 600多 元")[0];
  assert.equal(statMatches(s, [611.44]), true);
  assert.equal(statMatches(s, [9999]), false);
});

test("逐句核对只挑数字对不上的句子", () => {
  // 白名单与 factComputator 同构：普通数值 + 计数（counted）两类
  const allowed = [{ value: 15321.96 }, { value: 19162.93 }, { value: 121, counted: true }];
  const flagged = flagSentenceNumbers("支出 15322 元，环比少了将近 1.9 万。戒烟累计 121 支。任务少了 14 个。", allowed);
  assert.equal(flagged.length, 1, "14 无据（「个」不在计数集、≥10 走普通核对）仍要拦");
  assert.match(flagged[0].sentence, /任务少了 14 个/);
  const flagged2 = flagSentenceNumbers("戒烟累计 110 支。", allowed);
  assert.equal(flagged2.length, 1);
  assert.match(flagged2[0].sentence, /110/);
});
