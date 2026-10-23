import test from "node:test";
import assert from "node:assert/strict";
import { seedGoalReviewEvidence, goalReviewReferenceSets } from "../src/agent/goalScopeContract.js";

const pools = () => ({ metricEvidence: new Map(), validEvidenceIDs: new Set(), evidenceTexts: new Map() });
test("mixed requirements preserve units, actual zero, and unknown", () => {
  const target = pools();
  seedGoalReviewEvidence({ requirements: [
    { title: "旅行专款", state: "unmet", value: 6000, unit: "元", requirement: { target: 18000 } },
    { title: "跑步次数", state: "unmet", value: 2, unit: "次", requirement: { target: 3 } },
    { title: "宵夜", state: "observing", value: 0, unit: "次", requirement: { target: 0 } },
    { title: "尚未记录", state: "missing", value: null, unit: "分钟", requirement: { target: 120 } },
    { title: "来源不可用", state: "unavailable", value: 999, unit: "杯", requirement: { target: 2 } },
  ] }, target);
  assert.equal(target.metricEvidence.get("goal.requirement.1.observed|all").value, 6000);
  assert.equal(target.metricEvidence.get("goal.requirement.2.observed|all").unit, "次");
  assert.equal(target.metricEvidence.get("goal.requirement.3.observed|all").value, 0);
  assert.equal(target.metricEvidence.has("goal.requirement.4.observed|all"), false);
  assert.equal(target.metricEvidence.has("goal.requirement.5.observed|all"), false);
  assert.equal(target.metricEvidence.get("goal.requirement.4.target|all").value, 120);
});
test("requirement source IDs join the existing adjustment whitelist", () => {
  const id = "10000000-0000-0000-0000-000000000001";
  const source = "20000000-0000-0000-0000-000000000001";
  const refs = goalReviewReferenceSets({ requirements: [{ id, entityID: source }] });
  assert.equal(refs.bindingIDs.has(id), true);
  assert.equal(refs.entityIDs.has(source), true);
});
