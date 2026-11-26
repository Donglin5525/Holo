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
#   R4 模块耦合只减不增：有 App 源码（.swift）改动时调用 coupling_guard.py（规则/基线见该脚本）
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


def coupling_guard(staged):
    """模块耦合「只减不增」（2026-11-24 随技术优化增设）。
    有 App 源码改动才跑（全量正则扫描约 2 秒）；规则与基线见 coupling_guard.py。
    本钩子是软链、被各工程副本共用，脚本按真实路径找——本树里没有这个脚本就不跑。"""
    if not any(f.endswith(".swift") and f.startswith("Holo/Holo APP/Holo/Holo/") for f in staged):
        return
    script = os.path.join(os.path.dirname(os.path.realpath(__file__)), "coupling_guard.py")
    if not os.path.exists(script):
        return
    if subprocess.run([sys.executable, script]).returncode != 0:
        print(
            "Pre-Commit Guard：模块耦合闸门未过。规则见 coupling_guard.py 头注释；"
            "确属必须的新耦合：python3 coupling_guard.py --update-baseline --accept-growth，并把打印的增量写进提交说明",
            file=sys.stderr,
        )
        sys.exit(1)


def main():
    if os.environ.get("HOLO_ALLOW_RISKY") == "1":
        print("Pre-Commit Guard: HOLO_ALLOW_RISKY=1 已放行（请在提交说明写明原因）")
        return
    problems = []
    staged = staged_files()
    coupling_guard(staged)
    for f in staged:
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

    # R4 审美底座闸门：只要暂存了 App Swift 文件，同步跑 aesthetic_guard.py，防止回退到圆体/sparkles/旧白卡/裸阴影
    staged_app_swift = [
        f for f in staged_files()
        if f.startswith("Holo/Holo APP/Holo/Holo/") and f.endswith(".swift")
    ]
    if staged_app_swift:
        guard_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "aesthetic_guard.py")
        if os.path.exists(guard_script):
            r = subprocess.run([sys.executable, guard_script], capture_output=True, text=True)
            if r.returncode != 0:
                print("Pre-Commit Guard 拦截（审美底座闸门未通过）：", file=sys.stderr)
                if r.stderr:
                    print(r.stderr.strip(), file=sys.stderr)
                sys.exit(1)

    # R5 CoreData 实体模型变更守门（2026-11-26：防止给实体加字段漏登记/漏跑模型绊线）
    current_staged = staged_files()
    schema_files = [
        f for f in current_staged
        if f.startswith("Holo/Holo APP/Holo/Holo/Models/CoreDataStack+")
        and (f.endswith("Entities.swift") or f.endswith("Entity.swift"))
    ]
    core_stack_file = "Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift"
    if core_stack_file in current_staged:
        stack_diff = subprocess.run(
            ["git", "diff", "--cached", "--", core_stack_file],
            capture_output=True, text=True,
        ).stdout or ""
        if any(
            kw in stack_diff
            for kw in ("makeDataModel", "NSEntityDescription", "NSAttributeDescription", "NSRelationshipDescription", "makeSoftDeleteAttributes")
        ):
            schema_files.append(core_stack_file)
    if schema_files:
        snapshot_test = "Holo/Holo APP/Holo/HoloTests/Models/CoreDataStoreRecoveryTests.swift"
        snapshot_updated = False
        if snapshot_test in current_staged:
            test_diff = subprocess.run(
                ["git", "diff", "--cached", "--", snapshot_test],
                capture_output=True, text=True,
            ).stdout or ""
            snapshot_updated = "currentEntityHashes" in test_diff or re.search(r'^\+\s*"[A-Za-z0-9_]+":\s*"[A-Za-z0-9+/=]{20,}"', test_diff, re.M) is not None
        if not snapshot_updated:
            print("Pre-Commit Guard 拦截（CoreData 模型文件改动未同步更新模型快照）：", file=sys.stderr)
            print("  涉及文件：" + ", ".join(schema_files), file=sys.stderr)
            print(
                "  若新增了实体/属性/关系：必须同步登记 CoreDataStoreUpgrade.propertyHistory、"
                "更新 CoreDataStoreRecoveryTests.swift 的 currentEntityHashes 快照，"
                "并实跑 CoreDataSchemaHistoryTests 全绿。",
                file=sys.stderr,
            )
            print(
                "  若纯注释/代码整理未改变模型结构：用 HOLO_ALLOW_RISKY=1 git commit 并在提交说明写明原因。",
                file=sys.stderr,
            )
            sys.exit(1)

    print("Pre-Commit Guard: 通过")


if __name__ == "__main__":
    main()
