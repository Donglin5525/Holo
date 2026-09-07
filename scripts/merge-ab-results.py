#!/usr/bin/env python3
"""
merge-ab-results.py — 合并 4 个分片的 A/B 评测结果并产出总汇总。

用法：python3 scripts/merge-ab-results.py [日期，默认今天]
"""
import json, sys, glob
from pathlib import Path

OUT = Path(__file__).parent.parent / "docs/_common/eval/personal-context/ab"
date = sys.argv[1] if len(sys.argv) > 1 else __import__("datetime").date.today().isoformat()

merged, by_id = [], {}
for path in sorted(glob.glob(str(OUT / f"results-{date}-s*.json"))):
    for r in json.load(open(path)).get("results", []):
        gid = r["goalID"]
        # 同目标多份结果（接力重跑）：无 error 的优先覆盖
        if gid not in by_id or (by_id[gid].get("error") and not r.get("error")):
            by_id[gid] = r
merged = list(by_id.values())

done = [r for r in merged if not r.get("error")]

def tally(rows, pred):
    rows = list(rows)
    return {"pass": sum(1 for j in rows if pred(j)), "total": len(rows)}

judges = [r["judge"] for r in done if r.get("judge")]
arms_total = sum(len(r.get("arms", {})) for r in done)
calls = [c for r in done for a in r.get("arms", {}).values() for c in a.get("calls", [])]

# skipped-parse/empty/unparseable = 方案数据受损未判（生产截断/坏JSON），
# 不计入判分分母，单独报告受损量。
def judged(rows, key, pred):
    items = [j[key] for j in rows if j.get(key)]
    valid = [j for j in items if j.get("verdict") not in ("skipped-parse", "empty", "unparseable")]
    skipped = len(items) - len(valid)
    return {"pass": sum(1 for j in valid if pred(j)), "total": len(valid), "skippedDamaged": skipped}

summary = {
    "evaluatedAt": date,
    "goals": len(merged),
    "completed": len(done),
    "failed": len(merged) - len(done),
    "inputs": arms_total,
    "calls": len(calls),
    "tokens": {
        "prompt": sum(c.get("promptTokens") or 0 for c in calls),
        "completion": sum(c.get("completionTokens") or 0 for c in calls),
    },
    "models": sorted({c.get("model") for c in calls if c.get("model")}),
    "planEffectsPresentRate": tally(done, lambda r: r.get("structural", {}).get("planEffectsPresent", 0) > 0),
    "personalEffectRate": tally(done, lambda r: r.get("structural", {}).get("personalEffectRefsNonEmpty", 0) > 0),
    "forbiddenViolations": sum(len(r.get("structural", {}).get("forbiddenHit", [])) for r in done),
    "planParseRepaired": sum(
        1 for r in done for a in r.get("arms", {}).values() if (a.get("plan") or {}).get("parseRepaired")
    ),
    "judge": {
        # contextAppliedV0：X=情境方案（期望胜出）；counterfactualV1：Y=条件改变后方案；pairwiseAB：Y=情境方案
        "contextAppliedV0": judged(judges, "contextAppliedV0", lambda j: j["verdict"] == "X"),
        "counterfactualV1": judged(judges, "counterfactualV1", lambda j: j["verdict"] == "Y"),
        "irrelevantRobustV2": judged(judges, "irrelevantRobustV2", lambda j: j["verdict"] != "Y"),
        "pairwiseAB": judged(judges, "pairwiseAB", lambda j: j["verdict"] == "Y"),
    },
    "byCategory": {},
}

for r in done:
    cat = r["category"]
    summary["byCategory"].setdefault(cat, {"goals": 0})
    summary["byCategory"][cat]["goals"] += 1
    j = r.get("judge") or {}
    for key, want in [("contextAppliedV0", "X"), ("counterfactualV1", "Y"), ("pairwiseAB", "Y")]:
        if j.get(key):
            slot = summary["byCategory"][cat].setdefault(key, {"pass": 0, "total": 0})
            slot["total"] += 1
            if j[key].get("verdict") == want:
                slot["pass"] += 1
    if j.get("irrelevantRobustV2"):
        slot = summary["byCategory"][cat].setdefault("irrelevantRobustV2", {"pass": 0, "total": 0})
        slot["total"] += 1
        if j["irrelevantRobustV2"].get("verdict") != "Y":
            slot["pass"] += 1

json.dump({"summary": summary, "results": merged}, open(OUT / f"results-{date}.json", "w"), ensure_ascii=False, indent=2)
json.dump(summary, open(OUT / f"summary-{date}.json", "w"), ensure_ascii=False, indent=2)
print(json.dumps(summary, ensure_ascii=False, indent=1))
