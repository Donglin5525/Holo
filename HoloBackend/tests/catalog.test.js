import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { flattenFinanceCategoryCatalog } from "../src/catalog/financeCategoryCatalog.js";

function createTestApp() {
  return createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    routes: {
      chat: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.2,
        maxTokens: 512,
      },
    },
  });
}

test("GET /v1/catalog/finance-categories returns complete finance category catalog", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/catalog/finance-categories");

  assert.equal(response.status, 200);
  const json = await response.json();

  assert.equal(json.version, 1);
  assert.ok(json.expense.some((group) => group.name === "餐饮"));
  assert.ok(json.expense.some((group) => group.name === "交通"));
  assert.ok(json.income.some((group) => group.name === "工资收入"));

  const transport = json.expense.find((group) => group.name === "交通");
  const taxi = transport.children.find((child) => child.name === "打车");
  assert.ok(taxi.aliases.includes("滴滴"));
  assert.ok(taxi.tags.includes("taxi"));

  const salaryGroup = json.income.find((group) => group.name === "工资收入");
  const salary = salaryGroup.children.find((child) => child.name === "工资");
  assert.ok(salary.aliases.includes("薪水"));
  assert.ok(salary.tags.includes("stableIncome"));
});

test("finance category catalog covers the default category tree", () => {
  const rows = flattenFinanceCategoryCatalog();
  const keySet = new Set(rows.map((row) => `${row.type}|${row.primaryCategory}|${row.subCategory}`));

  for (const key of [
    "expense|餐饮|午餐",
    "expense|交通|打车",
    "expense|购物|日用",
    "expense|娱乐|KTV",
    "expense|居住|房租",
    "expense|医疗|药品",
    "expense|学习|订阅",
    "expense|人情|红包礼金",
    "expense|其他|捐赠",
    "income|投资理财|利息",
    "income|工资收入|工资",
    "income|人情来往|转入",
    "income|其他收入|出闲置",
  ]) {
    assert.ok(keySet.has(key), `missing catalog row: ${key}`);
  }

  for (const row of rows) {
    assert.ok(row.primaryCategory, "primaryCategory is required");
    assert.ok(row.subCategory, "subCategory is required");
    assert.ok(Array.isArray(row.aliases), `${row.subCategory} aliases should be an array`);
    assert.ok(Array.isArray(row.tags), `${row.subCategory} tags should be an array`);
  }
});
