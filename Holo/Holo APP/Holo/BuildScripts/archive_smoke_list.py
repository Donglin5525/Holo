#!/usr/bin/python3
# archive_smoke_list.py —— 归档冒烟清单机械导出（2026-11-16 随机器守门体系设立）
#
# 病（2026-11-12 每周回顾带病上架设立红线 §8）：「归档窗口内改过界面的页面，
#     归档前必须重跑开页冒烟；清单用 git diff 机械导出，不靠自觉」——
#     规矩立了但导出动作仍靠人手敲，等于半个摆设。本工具把它固化。
#
# 用法（BuildScripts 下）：
#   ./archive_smoke_list.py [base_ref]      # 默认 base_ref = 上一个 build 号提交
# 输出：本次范围改动的界面文件 → 按 §8 五大入口映射的「必须打开冒烟」清单
#       + 无映射的长尾页面文件列表（人工归置）。
# 红线真源：docs/standards/quality-redlines.md §8

import re
import subprocess
import sys
import os

# 界面目录 → 五大入口映射（§8：今日/看板、HoloAI、想法、任务、财务/设置）
ENTRY_MAP = [
    (r"Holo/Holo APP/Holo/Holo/Views/HomeView\.swift|Views/DailyKanban/", "今日 / 看板"),
    (r"Views/Chat/", "HoloAI（进页 + 停留 3 秒 + 发一条消息）"),
    (r"Views/Thoughts/|Views/MemoryGallery/", "想法（含长廊）"),
    (r"Views/Tasks/|Views/Matter/", "任务"),
    (r"Views/Finance/|Views/AddTransaction|Views/Settings/|Components/.*Picker", "财务 / 设置"),
    (r"Views/Habits/", "习惯"),
    (r"Views/Goals/", "目标"),
    (r"Views/Anniversary/", "周年纪念"),
    (r"HoloApp\.swift|ContentView\.swift", "全局启动"),
]


def main():
    srcroot = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(srcroot)
    base = sys.argv[1] if len(sys.argv) > 1 else None
    if not base:
        r = subprocess.run(
            ["git", "log", "--oneline", "-30", "--grep=build 号", "-E"],
            capture_output=True, text=True,
        )
        lines = [ln for ln in (r.stdout or "").split("\n") if ln.strip()]
        if len(lines) >= 2:
            base = lines[1].split()[0]  # 上一个 build 号提交（最近的是本次，取倒数第二个）
        else:
            base = "HEAD~10"
    r = subprocess.run(["git", "diff", "--name-only", base + "..HEAD"], capture_output=True, text=True)
    files = [f for f in (r.stdout or "").split("\n") if f.strip()]

    view_files = [f for f in files if "/Views/" in f or f.endswith("ContentView.swift") or f.endswith("HoloApp.swift") or "/Components/" in f]
    entries = {}
    tail = []
    for f in view_files:
        for pat, entry in ENTRY_MAP:
            if re.search(pat, f):
                entries.setdefault(entry, []).append(f)
                break
        else:
            tail.append(f)

    print("=== 归档冒烟清单（%s..HEAD，机械导出不靠自觉，红线 §8）===" % base)
    if not view_files:
        print("（本范围无界面文件改动——纯逻辑/后端变更，开页冒烟按常规抽一入口即可）")
        return
    for entry, fs in entries.items():
        print("\n[%s]  ←— 必须打开冒烟" % entry)
        for f in sorted(set(fs)):
            print("   " + f)
    if tail:
        print("\n[长尾：无入口映射，人工归置]")
        for f in tail:
            print("   " + f)
    print("\n规则：任一入口打不开/白屏/永久加载 = 禁止归档（11-12 每周回顾事故红线）")


if __name__ == "__main__":
    main()
