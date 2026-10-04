import assert from "node:assert/strict";
import { test } from "node:test";

import {
  createCloudAnalysisQueryEngine,
  buildCloudToolCatalog,
} from "../src/agent/cloudAnalysisQueryEngine.js";
import { getPrompt } from "../src/prompts/promptRegistry.js";

/**
 * 目录驱动字段原则（2026-10-04 v25）：字段能力标记随快照目录上云，
 * 引擎按声明字段无差别过滤/分组，提示词只教通用原则不逐字段枚举——
 * 「分析东京旅行花费」这类项目维度问句的整链回归网。
 */

const SNAPSHOT = {
  version: 1,
  datasets: {
    "finance.transactions": {
      fields: [
        { name: "date", type: "date", filterable: true, groupable: false },
        { name: "amount", type: "number", unit: "元", filterable: true, groupable: false },
        { name: "category", type: "text", filterable: true, groupable: true },
        {
          name: "project",
          type: "text",
          filterable: true,
          groupable: true,
          description: "所属财务项目（如东京旅行），未挂项目的交易无此字段",
        },
      ],
      rows: [
        { date: "2026-09-20", amount: -1200, category: "交通", project: "东京旅行" },
        { date: "2026-09-21", amount: -350, category: "餐饮", project: "东京旅行" },
        { date: "2026-09-22", amount: -89, category: "餐饮" },
        { date: "2026-09-23", amount: -4200, category: "购物", project: "装修" },
      ],
    },
  },
};

function execute(plan) {
  const engine = createCloudAnalysisQueryEngine();
  return engine.execute(plan, SNAPSHOT, { toolRequestID: "t", tool: "finance" });
}

function sumByComparison(result, metricId) {
  const byKey = {};
  for (const metric of result.metrics) {
    if (metric.metricKey.includes(`.${metricId}.`)) byKey[metric.comparison] = metric.value;
  }
  return byKey;
}

test("目录：能力标记 {可筛·可组} 随字段上目录，未声明能力的字段不冒充", () => {
  const catalog = buildCloudToolCatalog(SNAPSHOT);
  assert.match(catalog, /project:text\(所属财务项目（如东京旅行），未挂项目的交易无此字段\)\{可筛·可组\}/);
  assert.match(catalog, /category:text\{可筛·可组\}/);
  assert.match(catalog, /amount:number\[元\]\{可筛\}/);
  assert.doesNotMatch(catalog, /date:date\{[^}]*可组/);
});

test("引擎：按 project 字段 equal 过滤圈定（东京旅行两笔，别的不混入）", () => {
  const result = execute({
    source: "finance.transactions",
    filters: [{ field: "project", operation: "equal", value: { type: "text", text: "东京旅行" } }],
    groupBy: [{ type: "field", field: "category" }],
    aggregations: [{ id: "total", operation: "sum", field: "amount", unit: "元" }],
    derivations: [],
    limit: 50,
    evidenceLimit: 5,
  });
  assert.equal(result.status, "success");
  const byCategory = sumByComparison(result, "total");
  assert.equal(byCategory["交通"], -1200);
  assert.equal(byCategory["餐饮"], -350);
  assert.equal(byCategory["购物"], undefined);
});

test("引擎：groupBy type=field 按项目分组，桶名即全部项目取值（未挂落 unknown）", () => {
  const result = execute({
    source: "finance.transactions",
    filters: [],
    groupBy: [{ type: "field", field: "project" }],
    aggregations: [{ id: "total", operation: "sum", field: "amount", unit: "元" }],
    derivations: [],
    limit: 50,
    evidenceLimit: 5,
  });
  assert.equal(result.status, "success");
  const byProject = sumByComparison(result, "total");
  assert.equal(byProject["东京旅行"], -1550);
  assert.equal(byProject["装修"], -4200);
  assert.equal(byProject["unknown"], -89);
});

test("提示词：agent_loop v25 含目录驱动字段契约块（原则句不依赖具体字段名）", () => {
  const prompt = getPrompt("agent_loop");
  assert.ok(prompt, "agent_loop prompt 应存在");
  assert.equal(prompt.version, 25);
  assert.match(prompt.content, /\[HOLO_AGENT_CATALOG_DRIVEN_FIELDS_V25\]/);
  assert.match(prompt.content, /花括号标「可筛」的字段都可用于 filters 精确圈定、标「可组」的字段都可用于 groupBy type=field/);
  assert.match(prompt.content, /本条对目录今后新增的字段同样成立/);
});
