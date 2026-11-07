import { test } from "node:test";
import assert from "node:assert/strict";
import { ProfileCompiler } from "../src/agent/deepReport/profileCompiler.js";

const ROUTE = { provider: "fake", model: "m" };

function compilerWith(fn) {
  return new ProfileCompiler(fn, { route: ROUTE, log: () => {} });
}

test("编译：模板字段档案 → 逐条指令（含资料型字段）", async () => {
  const c = compilerWith(async () => JSON.stringify({
    directives: ["行文中称呼用户为阿杰", "建议避免跑步、跳绳等伤膝运动", "先给结论再说理由，建议最多三条"],
  }));
  const out = await c.compile("# 关于我\n- 昵称：阿杰\n- 膝盖有旧伤");
  assert.equal(out.source, "compiled");
  assert.equal(out.directives.length, 3);
  assert.match(out.directives[0], /阿杰/);
});

test("回退：转写抛错 → 原文单条，不阻塞任务", async () => {
  const c = compilerWith(async () => { throw new Error("UPSTREAM_TIMEOUT"); });
  const out = await c.compile("叫我东林。别绕弯子。");
  assert.equal(out.source, "fallback");
  assert.deepEqual(out.directives, ["叫我东林。别绕弯子。"]);
});

test("回退：输出非数组/空数组 → 原文单条", async () => {
  for (const bad of ["不是JSON", JSON.stringify({ foo: 1 }), JSON.stringify({ directives: [] }), JSON.stringify({ directives: ["", null, "  "] }), ""]) {
    const c = compilerWith(async () => bad);
    const out = await c.compile("称呼：老王");
    assert.equal(out.source, "fallback", `输入 ${JSON.stringify(bad)} 应回退`);
    assert.deepEqual(out.directives, ["称呼：老王"]);
  }
});

test("空档案：directives 为空且不产生任何块", async () => {
  const c = compilerWith(async () => { throw new Error("should not call"); });
  const out = await c.compile("   ");
  assert.deepEqual(out.directives, []);
  assert.equal(ProfileCompiler.checkerBlock(out), "");
});

test("writerBlock：编译态附原文，回退态不重复", () => {
  const compiled = { source: "compiled", directives: ["称呼我为东林"] };
  assert.match(ProfileCompiler.writerBlock(compiled, "叫我东林"), /档案原文/);
  const fallback = { source: "fallback", directives: ["叫我东林"] };
  assert.ok(!ProfileCompiler.writerBlock(fallback, "叫我东林").includes("档案原文"), "回退态原文即指令，不再重复");
});

test("非字符串条目被字符串化保留（42 → 42）", async () => {
  const c = compilerWith(async () => JSON.stringify({ directives: [42, "叫我东林"] }));
  const out = await c.compile("x");
  assert.equal(out.source, "compiled");
  assert.deepEqual(out.directives, ["42", "叫我东林"]);
});

test("指令条数上限 30，防超长档案撑爆输入", async () => {
  const c = compilerWith(async () => JSON.stringify({ directives: Array.from({ length: 99 }, (_, i) => `要求${i}`) }));
  const out = await c.compile("x");
  assert.equal(out.directives.length, 30);
});
