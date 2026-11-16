#!/usr/bin/python3
# Pre-Commit Guard —— 高危文件提交拦截（2026-11-16 随机器守门体系设立）
#
# 病（复犯坑总档族3/族4，40+ 次实锤）：
#   - xcstrings 被 json 工具全量重写 → diff 爆几万行 + 并行会话词条被抹
#   - CHANGELOG 被整文件覆盖 → 他线记录丢失
#   - pbxproj 大规模删除 → 并行挂载被脚本抹掉不可找回
#
# 规则（对 staged 内容判定，命中即拦，stderr 给出放行方式）：
#   R1 *.xcstrings：staged 删除行 > 原文件行数 25%，或词条 key 数减少 > 20
#   R2 CHANGELOG.md：staged 删除行 > 原文件行数 60%（整文件覆盖特征）
#   R3 *.pbxproj：staged 删除行 > 150（手术事故特征）
# 放行：确属有意的重写/清理 → git commit --no-verify（或 HOLO_ALLOW_RISKY=1），
#       且要求在提交说明里写明原因。
#
# 安装（一次性，装到本仓库 .git/hooks/，三宿主共用）：
#   ln -sf "../../Holo/Holo APP/Holo/BuildScripts/pre_commit_guard.py" .git/hooks/pre-commit && chmod +x <脚本>

import json
import os
import re
import subprocess
import sys

KEY_PATTERN = re.compile(r'^\s*"([^"]+)" : \{')


def staged_files():
    r = subprocess.run(["git", "diff", "--cached", "--name-only"], capture_output=True, text=True)
    return [f for f in (r.stdout or "").split("\n") if f.strip()]


def file_lines(path):
    try:
        with open(path, encoding="utf-8") as fp:
            return fp.read().split("\n")
    except OSError:
        return None


def staged_diff_stat(path):
    r = subprocess.run(
        ["git", "diff", "--cached", "--numstat", "--", path],
        capture_output=True, text=True,
    )
    parts = (r.stdout or "").strip().split("\t")
    if len(parts) < 2:
        return 0, 0
    try:
        return int(parts[0]) if parts[0] != "-" else 10**9, int(parts[1]) if parts[1] != "-" else 10**9
    except ValueError:
        return 0, 0


def xcstrings_keys(head_version, staged_version):
    def keys(text):
        out = set()
        if not text:
            return out
        for m in (KEY_PATTERN.match(ln) for ln in text.split("\n")):
            if m:
                out.add(m.group(1))
        return out
    return keys(head_version), keys(staged_version)


def main():
    if os.environ.get("HOLO_ALLOW_RISKY") == "1":
        print("Pre-Commit Guard: HOLO_ALLOW_RISKY=1 已放行（请在提交说明写明原因）")
        return
    problems = []
    for f in staged_files():
        base = os.path.basename(f)
        add, dele = staged_diff_stat(f)
        if base.endswith(".xcstrings"):
            head = subprocess.run(["git", "show", "HEAD:" + f], capture_output=True, text=True).stdout
            staged = file_lines(f)
            staged_text = "\n".join(staged) if staged else ""
            old_keys, new_keys = xcstrings_keys(head, staged_text)
            lost = len(old_keys - new_keys)
            total_lines = len(head.split("\n")) if head else 0
            if total_lines and dele > total_lines * 0.25:
                problems.append(
                    "%s：删除 %d 行 > 原文件 25%%（json 工具全量重写特征，会抹掉并行会话词条——"
                    "复犯坑族4）。词条级操作请走文本级手术；确属有意重写用 --no-verify 并写明原因" % (f, dele)
                )
            elif lost > 20:
                problems.append(
                    "%s：词条 key 减少 %d 个（>20）——确认这不是误删（复犯坑族4）。"
                    "确属有意删除用 --no-verify 并写明原因" % (f, lost)
                )
        elif base == "CHANGELOG.md":
            head = subprocess.run(["git", "show", "HEAD:" + f], capture_output=True, text=True).stdout or ""
            if head and dele > len(head.split("\n")) * 0.6:
                problems.append(
                    "%s：删除 %d 行 > 原文 60%%（整文件覆盖特征，他线记录会丢——复犯坑族3）。"
                    "追加式编辑；确属有意重写用 --no-verify 并写明原因" % (f, dele)
                )
        elif base == "project.pbxproj" and dele > 150:
            problems.append(
                "%s：删除 %d 行（>150，手术事故特征：脚本重放曾抹掉并行会话挂载不可找回——"
                "复犯坑族1）。pbxproj 手术请走 BuildScripts/pbxproj_surgery.py；"
                "确属大规模清理用 --no-verify 并写明原因" % (f, dele)
            )

    if problems:
        print("Pre-Commit Guard 拦截（高危提交特征）：", file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        sys.exit(1)
    print("Pre-Commit Guard: 通过")


if __name__ == "__main__":
    main()
