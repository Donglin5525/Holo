import { test } from "node:test";
import assert from "node:assert/strict";
import { parseReport, sanitizeParagraphText, mapReportToResult } from "../src/agent/deepReport/mapper.js";

test("解析：标题/小节/段落/数据说明", () => {
  const parsed = parseReport("# 整体平稳，健身断了\n\n先说结论：这 30 天过得稳。\n\n## 钱去哪了\n\n房租是最大头。\n\n超市去了两次。\n\n数据说明：睡眠无数据，无法判断。");
  assert.equal(parsed.title, "整体平稳，健身断了");
  assert.deepEqual(parsed.sections.map((s) => s.title), ["钱去哪了"]);
  assert.deepEqual(parsed.sections[0].paragraphs, ["房租是最大头。", "超市去了两次。"]);
  assert.equal(parsed.loose.length, 1);
  assert.deepEqual(parsed.disclosure, ["睡眠无数据，无法判断。"]);
});

test("清洗：剥掉 iOS sanitizer 会整段干掉的记号", () => {
  assert.equal(sanitizeParagraphText("**加粗** 和 __底线__ 去掉"), "加粗 和 底线 去掉");
  assert.equal(sanitizeParagraphText("- 列表项变段落"), "列表项变段落");
  assert.equal(sanitizeParagraphText("引用 finance.transactions 数据集"), "引用 数据 数据集");
  assert.equal(sanitizeParagraphText("value = 6.2 小时"), "value 是 6.2 小时");
  assert.equal(sanitizeParagraphText("sum(amount) 聚合"), "sum（amount) 聚合"); // iOS 只拦「xx(」，右括号无碍
  assert.equal(sanitizeParagraphText("per_day 换成空格"), "per day 换成空格");
});

test("映射：导语/claims/小节引用/证据/taskRange 必填", () => {
  const sheet = {
    window: resolveWindow(),
    text: "",
    entries: [
      { id: "F001", text: "本期支出合计 15321.96 元，共 68 笔。", values: [15321.96] },
      { id: "F002", text: "健身本期完成 6 天。", values: [6] },
    ],
    whitelist: [15321.96, 6],
  };
  const { result, empty } = mapReportToResult({
    reportText: "# 收入涨了\n\n导语：整体稳住了。\n\n支出合计 15322 元。\n\n健身完成了 6 天。\n\n数据说明：睡眠无数据。",
    sheet,
    window: sheet.window,
    snapshotCoverage: { "finance.transactions": { totalRows: 10, providedRows: 10, truncated: false, coveredFrom: null } },
  });
  assert.equal(empty, false);
  assert.equal(result.title, "收入涨了");
  assert.equal(result.narrativeSummary, "导语：整体稳住了。");
  assert.equal(result.claims.length, 2);
  assert.equal(result.claims[0].displayText, "支出合计 15322 元。");
  assert.deepEqual(result.claims[0].evidenceIDs, [], "引用走证据全集，不做逐条引用（防 iOS 双通道重复）");
  assert.ok(result.evidence.some((e) => e.metricKey === "F001"), "被引用的事实进证据全集");
  assert.equal(result.taskRange.label, "最近30天");
  assert.equal(typeof result.taskRange.start, "number");
  assert.equal(result.engine, "deep-report-v1");
  assert.equal(result.warnings.length, 0);
  assert.ok(result.evidence.length >= 1);
  assert.equal(result.evidence[0].kind, "rows");
});

test("映射：全部段落为空时报 empty，调用方失败处理", () => {
  const sheet = { window: resolveWindow(), entries: [], whitelist: [] };
  const { result, empty } = mapReportToResult({ reportText: "# 只有标题", sheet, window: sheet.window });
  assert.equal(empty, true);
  assert.equal(result, null);
});

test("小节映射：无 ## 时 reportStructure 为空（App 回退旧版式），有 ## 时引用 claim", () => {
  const sheet = { window: resolveWindow(), entries: [], whitelist: [] };
  const noSections = mapReportToResult({ reportText: "# 标题\n\n第一段。\n\n第二段。", sheet, window: sheet.window });
  assert.equal(noSections.result.reportStructure, null);
  assert.equal(noSections.result.claims.length, 1, "首段为导语，其余为 claims");

  const withSections = mapReportToResult({ reportText: "# 标题\n\n导语段。\n\n## 钱包\n\n房租 5000 元。\n\n## 身体\n\n健身少了。\n\n数据说明：无。", sheet, window: sheet.window });
  const rs = withSections.result.reportStructure;
  assert.equal(withSections.result.narrativeSummary, "导语段。", "首个松散段作导语");
  assert.equal(rs.sections.length, 2, "导语不占小节；两个 ## 各成节");
  assert.equal(rs.sections.find((s) => s.title === "钱包").paragraphClaimIDs.length, 1);
  assert.deepEqual(rs.disclosureNotes, ["无。"]);
});

function resolveWindow() {
  return {
    label: "最近30天",
    startMs: Date.parse("2026-10-08T00:00:00+08:00"),
    endMs: Date.parse("2026-11-07T12:00:00+08:00"),
    prevStartMs: Date.parse("2026-09-08T00:00:00+08:00"),
    hasPrev: true,
    genMs: Date.parse("2026-11-07T12:00:00+08:00"),
  };
}
