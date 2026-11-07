import { test } from "node:test";
import assert from "node:assert/strict";
import { extractCountedStats, flagSentenceNumbers, statMatches } from "../src/agent/deepReport/numberCheck.js";

// 修复 2（2026-11-07 东林拍板「个位数也要处理」）：计数核对正反例锁死
test("计数提取：该查的都要查到", () => {
  const raws = (t) => extractCountedStats(t).map((x) => x.raw);
  assert.deepEqual(raws("健身 5 次"), ["5次"]);
  assert.deepEqual(raws("停了 7.5 天"), ["7.5天"]);
  assert.deepEqual(raws("少了两天，超了四条"), ["两天", "四条"]);
  assert.deepEqual(raws("三个小时，两周，8 笔"), ["8笔", "三个小时", "两周"]); // 阿拉伯先、中文后
  assert.deepEqual(raws("三个月 / 3 个月 / 30天"), ["3个月", "30天", "三个月"]); // 阿拉伯先、中文后
});

test("计数提取：泛指与日期一律不查（误报治理）", () => {
  const never = ["这两天很忙", "每周复盘一次", "两天前开始", "三天内结束", "周日去练", "周末两天",
    "一天一次", "半个月", "六月你好", "6月花了500元", "上次那三回不算", "近两周", "下月"];
  for (const t of never) {
    assert.deepEqual(extractCountedStats(t), [], `不应提取：${t}`);
  }
});

test("计数匹配：精确对表，差 1 即错", () => {
  const allowed = [{ value: 3, counted: true }, { value: 20, counted: true }];
  assert.equal(statMatches({ value: 3, counted: true }, allowed), true, "清单 3 天，报告 3 天");
  assert.equal(statMatches({ value: 2, counted: true }, allowed), false, "清单 3 天，报告 2 天 → 拦");
  assert.equal(statMatches({ value: 2, counted: true }, [{ value: 2.04 }]), false, "计数不吃金额白名单");
});

test("逐句核对：少了两天对上清单 3 天被点名", () => {
  const flagged = flagSentenceNumbers("健身比上期少了两天。", [{ value: 3, counted: true }]);
  assert.equal(flagged.length, 1);
  assert.match(flagged[0].sentence, /少了两天/);
  assert.deepEqual(flagged[0].numbers, ["两天"]);
});
