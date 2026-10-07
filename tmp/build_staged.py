#!/usr/bin/env python3
"""外科手术暂存构造（干跑）：共享文件 = HEAD + 仅共创 hunks。
模式过滤：GoalWorkshop/goalWorkshop/GoalPlanRevision/一起想清楚/目标共创。
replace 块一律保留 HEAD 侧；insert 块只放行匹配共创模式的行。"""
import difflib, re, subprocess, sys

REPO = "/Users/tangyuxuan/Desktop/Claude/HOLO"
FILES = {
    "Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj": r"GoalWorkshop|GoalPlanRevision|GoalWorkshopJourney",
    "Holo/Holo APP/Holo/Holo/Models/AI/HoloAICapability.swift": r"Goal Workshop|goalWorkshop|GOAL_WORKSHOP_FORCE_ON|目标共创「一起想清楚」|关闸时旧 AI 规划",
    "Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift": r"goalWorkshopLaunch|GoalWorkshopFlowView",
    "Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift": r"goalWorkshopLaunch|HoloAIFeatureFlags\.goalWorkshopEnabled|目标共创开闸时|目标共创（一起想清楚）流程入口",
}

def head_lines(path):
    return subprocess.run(["git", "show", f"HEAD:{path}"], cwd=REPO,
                          capture_output=True, text=True, check=True).stdout.splitlines(keepends=True)

for path, pattern in FILES.items():
    rx = re.compile(pattern)
    hl = head_lines(path)
    with open(f"{REPO}/{path}", encoding="utf-8") as f:
        wl = f.readlines()
    sm = difflib.SequenceMatcher(None, hl, wl, autojunk=False)
    out, kept_ins, dropped_ins, suspicious = [], 0, 0, []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("equal",):
            out.extend(hl[i1:i2])
        elif tag == "delete":
            pass  # 保留 HEAD 侧（删减行是别人会话的搬动/改动，不跟进）
        elif tag == "replace":
            # 保留 HEAD 侧；但若 work 侧混有共创行则报警（需要人工判断）
            for line in wl[j1:j2]:
                if rx.search(line):
                    suspicious.append(line)
            out.extend(hl[i1:i2])
        elif tag == "insert":
            for line in wl[j1:j2]:
                if rx.search(line):
                    out.append(line)
                    kept_ins += 1
                else:
                    dropped_ins += 1
    print(f"== {path}")
    print(f"   HEAD {len(hl)} 行 / 工作区 {len(wl)} 行 / 构造 {len(out)} 行；insert放行 {kept_ins}，拦截 {dropped_ins}，replace可疑 {len(suspicious)}")
    for line in suspicious:
        print("   可疑:", line.rstrip())
    # 校验：放行的行必须与工作区中匹配模式的行一一对应（不丢共创行）
    work_match = [l for l in wl if rx.search(l)]
    out_match = [l for l in out if rx.search(l)]
    print(f"   工作区共创匹配行 {len(work_match)}，构造版 {len(out_match)}，一致={work_match == out_match}")
    with open(f"/tmp/staged_{abs(hash(path))}.swift" if path.endswith(".swift") else f"/tmp/staged_{abs(hash(path))}.pbxproj", "w", encoding="utf-8") as f:
        f.writelines(out)
