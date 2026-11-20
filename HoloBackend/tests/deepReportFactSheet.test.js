// 深度报告事实清单补算（2026-11-21 评测 R1 待修 #3-#7）：用评测集合成人设锁定口径
import { test } from "node:test";
import assert from "node:assert/strict";
import { computeFactSheet } from "../src/agent/deepReport/factComputator.js";
import { CASES, buildSnapshot } from "../scripts/deep-report-eval/personas.mjs";

const sheetOf = (id) => computeFactSheet(buildSnapshot(CASES.find((c) => c.id === id))).text;

test("#3 新用户：开始记账前的月份标「没有记录」，不当成 0 元、不和空上期比", () => {
  const text = sheetOf("D1_new_checkup");
  assert.doesNotMatch(text, /日常支出 0\.00 元/, "无记录月份不能写成花了 0 元");
  assert.doesNotMatch(text, /比上期多了 463/, "上期没记账时不做增减对比");
  assert.match(text, /上期没有记账记录/);
});

test("#4 睡眠：给出入睡时间均值（跨零点）及本期与上期对比", () => {
  const text = sheetOf("A1_lin_checkup");
  const line = text.split("\n").find((l) => l.includes("入睡时间："));
  assert.ok(line, "必须有入睡时间事实");
  assert.match(line, /本期平均 0[01]:\d{2}/, "加班期平均入睡在 0-1 点");
  assert.match(line, /上期平均 23:\d{2}/);
  assert.match(line, /推迟/);
});

test("#5 高频备注带上期次数；深夜时段消费给本期与上期对比", () => {
  const text = sheetOf("A1_lin_checkup");
  assert.match(text, /「深夜外卖」：\d+ 次.*上期 \d+ 次/);
  assert.match(text, /22 点到次日 4 点.*本期 \d+ 笔.*上期 \d+ 笔/);
});

test("#6 计数型习惯列出超标日期，并与同日较大支出并列", () => {
  const text = sheetOf("C1_zhou_habit");
  const line = text.split("\n").find((l) => l.includes("超过上限的日子"));
  assert.ok(line, "必须列出超标日期");
  assert.match(line, /10-30（周五/);
  assert.match(line, /11-13（周五/);
  assert.match(line, /同事聚餐/);
  assert.match(line, /只并列/);
});

test("#7 一起变化检查纳入睡眠时长、入睡时间与步数", () => {
  const text = sheetOf("A1_lin_checkup");
  const scope = text.split("\n").find((l) => l.includes("检查范围"));
  assert.match(scope, /睡眠时长/);
  assert.match(scope, /入睡时间/);
  assert.match(scope, /步数/);
});
