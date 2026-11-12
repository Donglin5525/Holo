#!/usr/bin/env node
// M1.6 自动判分：JSON 合法性 + D2 禁词扫描 + D4 引用存在性 + D6 op 合法性。
// 语义维度（D1 强度/D3 行动/D5 替代解释质量）输出候选列表供人工判读。

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIR = join(HERE, "results-round1");

const FORBIDDEN_PATTERNS = [
  [/导致|造成|引发|使得/, "因果断言词"],
  [/懒|自律差|缺乏毅力|拖延症|孤僻|社恐|上瘾|成瘾|自制力差|工作狂/, "人格/道德标签"],
  [/诊断|抑郁|焦虑症|建议就医/, "医疗化"],
  [/法定|负责一切|已经确认|一定是/, "强度越界"],
];
const LEGAL_OPS = new Set(["retrieveRelated", "checkOwnership", "comparePeriods", "compareConditions", "alignEvents", "searchCounterEvidence", "checkCoverage"]);

const files = readFileSync(join(HERE, "scenarios.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const oidsByCase = new Map();
for (const m of files) oidsByCase.set(`${m.id}--${m.variant}`, m.observations.map((o) => o.oid));

const rows = [];
for (const [key, oids] of oidsByCase) {
  let d;
  try {
    d = JSON.parse(readFileSync(join(DIR, `${key}.json`), "utf8"));
  } catch {
    rows.push({ key, fatal: "结果文件缺失" });
    continue;
  }
  if (!d.ok) { rows.push({ key, fatal: d.error }); continue; }
  let raw = d.raw.trim().replace(/^```(json)?|```$/g, "").trim();
  let obj = null, jsonOk = true;
  try { obj = JSON.parse(raw); } catch { jsonOk = false; }
  const row = { key, theme: d.theme, jsonOk, candidates: [] };
  if (!jsonOk) { rows.push(row); continue; }
  for (const c of obj.candidates ?? []) {
    const cand = { statement: c.statement, action: c.action, grade: c.evidenceGrade };
    const text = JSON.stringify(c);
    cand.d2Auto = [];
    for (const [pat, label] of FORBIDDEN_PATTERNS) {
      if (pat.test(text)) cand.d2Auto.push(`${label}:${pat.exec(text)[0]}`);
    }
    const refs = c.supportingRefs ?? [];
    cand.d4 = refs.length && refs.every((r) => oids.includes(r)) ? 1 : refs.some((r) => oids.includes(r)) ? 0.5 : 0;
    const plan = c.verificationPlan ?? [];
    cand.d6Auto = plan.length
      ? (plan.every((p) => LEGAL_OPS.has(p.op)) ? "op全合法" : `非法op:${plan.filter((p) => !LEGAL_OPS.has(p.op)).map((p) => p.op).join(",")}`)
      : "无查证计划";
    cand.alts = c.alternativeExplanations ?? [];
    cand.refs = refs;
    row.candidates.push(cand);
  }
  row.noValueReason = obj.noValueReason ?? null;
  rows.push(row);
}
writeFileSync(join(HERE, "auto-score-round1.json"), JSON.stringify(rows, null, 2));
const bad = rows.filter((r) => !r.jsonOk || r.fatal);
const d2Hits = rows.flatMap((r) => (r.candidates ?? []).flatMap((c) => (c.d2Auto ?? []).map((x) => `${r.key} ${x}`)));
const illegalOps = rows.flatMap((r) => (r.candidates ?? []).filter((c) => c.d6Auto?.startsWith("非法")).map((c) => `${r.key} ${c.d6Auto}`));
console.log(`JSON合法 ${rows.length - bad.length}/${rows.length}`);
console.log(`D2自动禁词命中: ${d2Hits.length}${d2Hits.length ? "\n  " + d2Hits.join("\n  ") : ""}`);
console.log(`非法op: ${illegalOps.length}${illegalOps.length ? "\n  " + illegalOps.join("\n  ") : ""}`);
