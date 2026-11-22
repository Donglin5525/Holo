"""检查文档示例的自洽性；不是 Holo 实现，也不证明 Core Data/CloudKit 正确。"""

import json
import re
from datetime import date, datetime, time, timedelta, timezone
from itertools import permutations
from pathlib import Path
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parents[1]


def resolve_revision(case, revisions):
    # 包络不完整时不能把较旧选择当成确定赢家。
    if any(not row.get("envelopeComplete", True) for row in revisions):
        return {"state": "pending", "winner": None}
    operations = {}
    for row in revisions:
        previous = operations.get(row["operationID"])
        identity_fields = ("placementKey", "logicalClock", "writerID", "mutationID", "payloadHash")
        if previous is not None and any(previous.get(key) != row.get(key) for key in identity_fields):
            return {"state": "corrupt", "winner": None}
        operations[row["operationID"]] = row
    if not operations:
        return {"state": "none", "winner": None}
    winner = max(
        operations.values(),
        key=lambda row: (row["logicalClock"], row["writerID"], row["mutationID"]),
    )
    result = {"winner": winner["operationID"]}
    if winner["schemaVersion"] != 1:
        return dict(result, state="unsupported")
    if not winner.get("payloadValid", True):
        return dict(result, state="corrupt")
    if winner["action"] == "clear":
        return dict(result, state="none")
    if winner["assetID"] in case["tombstones"]:
        return dict(result, state="deleted")
    return dict(result, state=case["assets"].get(winner["assetID"], "pending"))


def choose_day(case, events):
    # 只计算有效原事件；这组样例不模拟真实 Provider 的全部业务过滤。
    visible = {
        event["key"]: event
        for event in events
        if event.get("visible", True) and not event.get("deleted", False)
    }
    count = len(visible)
    state = "partial" if not case["loadComplete"] else "loaded" if count else "loadedEmpty"
    manual = case["manual"]
    if manual and manual["availability"] == "pending":
        return {"featured": manual["key"], "count": count, "state": state}
    if manual and manual["availability"] == "active" and manual["key"] in visible:
        return {"featured": manual["key"], "count": count, "state": state}
    if not visible:
        return {"featured": None, "count": count, "state": state}
    ranks = {"hero": 0, "legacyPhoto": 1, "text": 2, "other": 3}
    featured = min(
        visible.values(),
        key=lambda event: (
            ranks[event["kind"]] if event["reliableTime"] or event["kind"] != "other" else 4,
            -event["occurredOrder"] if event["reliableTime"] or event["kind"] != "other" else 0,
            event["key"],
        ),
    )
    return {"featured": featured["key"], "count": count, "state": state}


def main():
    fixtures = json.loads((ROOT / "fixtures/contract-cases.json").read_text())
    checks = 0
    for case in fixtures["revisionCases"]:
        # 所有到达排列，以及重复到达，必须返回同一声明结果。
        for rows in permutations(case["revisions"]):
            assert resolve_revision(case, rows) == case["expected"], case["id"]
            checks += 1
        assert resolve_revision(case, case["revisions"] * 2) == case["expected"], case["id"]
        checks += 1
    for case in fixtures["galleryCases"]:
        for events in permutations(case["events"]):
            assert choose_day(case, events) == case["expected"], case["id"]
            checks += 1
    for case in fixtures["alphaCases"]:
        actual = case["A"] + case["R"] * (1 - case["A"])
        assert abs(actual - case["expected"]) < 1e-9, case["id"]
        checks += 1
    for case in fixtures["dayIntervalCases"]:
        zone = ZoneInfo(case["timezone"])
        day = date.fromisoformat(case["day"])
        start = datetime.combine(day, time(), zone).astimezone(timezone.utc)
        end = datetime.combine(day + timedelta(days=1), time(), zone).astimezone(timezone.utc)
        assert (end - start).total_seconds() == case["expectedSeconds"], case["id"]
        # 半开区间的两端：当天零点纳入，下一天零点排除。
        assert start <= start < end and not (start <= end < end), case["id"]
        checks += 1

    documents = sorted(ROOT.glob("*.md"))
    for document in documents:
        content = document.read_text()
        assert content.count("```") % 2 == 0, document.name
        assert "R2" in content, document.name
        for target in re.findall(r"\]\(([^)]+)\)", content):
            if not target.startswith(("https:", "http:", "#")):
                assert (document.parent / target).exists(), (document.name, target)
    acceptance = (ROOT / "03-排期与验收.md").read_text()
    scenario_ids = re.findall(r"^\| ([SFTDXGNR]\d{2}) \|", acceptance, re.MULTILINE)
    assert len(scenario_ids) == len(set(scenario_ids)), "验收编号重复"
    audit = (ROOT / "05-对抗审查与修订记录.md").read_text()
    referenced_ids = set(re.findall(r"\b([SFTDXGNR]\d{2})\b", audit))
    assert referenced_ids <= set(scenario_ids), referenced_ids - set(scenario_ids)
    print(json.dumps({
        "documentCount": len(documents),
        "fixtureGroups": sum(len(fixtures[key]) for key in (
            "revisionCases", "galleryCases", "alphaCases", "dayIntervalCases"
        )),
        "exampleAssertions": checks,
        "acceptanceScenarios": len(scenario_ids),
        "scope": "仅检查交接文档与示例，不是原生产品测试",
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
