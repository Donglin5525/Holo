#!/usr/bin/python3
# Banned API Guard —— 硬禁令 API 闸门（2026-11-16 随机器守门体系设立）
#
# 病（红线陷阱清单实锤条目，每条都真崩过）：
#   - 陷阱8：Dictionary(uniqueKeysWithValues:) 在 iCloud 副本重复 id 上崩
#     （NSInvalidArgumentException 且 try? 拦不住 ObjC 异常）→ 全库禁新增
#   - 陷阱7：入口链路（ChatView 及其 .task 初始化路径）.first!/try!/as!
#     → 点开即崩族（2026-09-17 五连发）
#
# 规则：
#   R1 全库禁 uniqueKeysWithValues 新增（基线冻结法：存量 30 处冻结在
#      banned_api_baseline.json，只减不增；存量消化后跑 --update-baseline 收缩）
#   R2 Views/Chat/** 与 ContentView.swift 禁 .first! / try! / as!（存量 0）
#   R3 目录读不到 → fail-closed
# 用法：
#   构建/CI：python3 banned_api_guard.py
#   存量合法消化后收缩基线：python3 banned_api_guard.py --update-baseline
# 红线真源：docs/standards/quality-redlines.md §3.7/§3.8

import json
import os
import re
import sys

SRCROOT = os.environ.get("SRCROOT", "")
SCAN_ROOT = os.path.join(SRCROOT, "Holo")
ENTRY_DIRS = [os.path.join(SRCROOT, "Holo", "Views", "Chat")]
ENTRY_FILES = {"ContentView.swift"}
BASELINE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "banned_api_baseline.json")

MIN_EXPECTED_FILES = 300

unique_keys_pattern = re.compile(r"\buniqueKeysWithValues\s*:")
bang_patterns = [
    (re.compile(r"\.first!"), ".first!"),
    (re.compile(r"\btry!"), "try!"),
    (re.compile(r"\bas!\s"), "as! "),
]


def collect_findings():
    """返回 {规则: {文件相对路径: 次数}}；文件读不到返回 None（fail-closed）。"""
    findings = {"uniqueKeysWithValues": {}, "entryBang": {}}
    total = 0
    for root, _dirs, files in os.walk(SCAN_ROOT):
        for fn in sorted(files):
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, SRCROOT)
            total += 1
            try:
                with open(path, encoding="utf-8") as fp:
                    lines = fp.read().split("\n")
            except OSError:
                return None
            uk = sum(1 for ln in lines if unique_keys_pattern.search(ln.split("//", 1)[0]))
            if uk:
                findings["uniqueKeysWithValues"][rel] = uk
            if root in ENTRY_DIRS or fn in ENTRY_FILES:
                hits = []
                for i, ln in enumerate(lines):
                    code = ln.split("//", 1)[0]
                    for pat, name in bang_patterns:
                        if pat.search(code):
                            hits.append((i + 1, name))
                if hits:
                    findings["entryBang"][rel] = hits
    if total < MIN_EXPECTED_FILES:
        return None
    return findings


def main():
    update_baseline = "--update-baseline" in sys.argv
    findings = collect_findings()
    if findings is None:
        print(
            "error: Banned API Guard 扫描异常（文件数过少或读取失败）——闸门失效按失败处理（fail-closed）",
            file=sys.stderr,
        )
        sys.exit(1)

    errors = []

    # R2：入口 ! 家族零容忍（存量 0）
    for rel, hits in findings["entryBang"].items():
        for ln, name in hits:
            errors.append(
                "error: %s:%d 入口链路出现 %s ——红线陷阱 §3.7（点开即崩族，2026-09-17 五连发）。"
                "入口代码禁用强制解包/强转，改安全解包路径" % (rel, ln, name)
            )

    # R1：uniqueKeysWithValues 基线冻结（只减不增）
    baseline = {}
    if os.path.exists(BASELINE_PATH):
        try:
            with open(BASELINE_PATH, encoding="utf-8") as fp:
                baseline = json.load(fp).get("uniqueKeysWithValues", {})
        except (OSError, ValueError):
            print("error: 基线文件损坏，先跑 --update-baseline 重建（fail-closed）", file=sys.stderr)
            sys.exit(1)
    if update_baseline:
        with open(BASELINE_PATH, "w", encoding="utf-8") as fp:
            json.dump({"uniqueKeysWithValues": findings["uniqueKeysWithValues"]}, fp, ensure_ascii=False, indent=2, sort_keys=True)
        print("Banned API Guard: 基线已更新（uniqueKeysWithValues 存量 %d 文件冻结）" % len(findings["uniqueKeysWithValues"]))
        return
    for rel, count in findings["uniqueKeysWithValues"].items():
        allowed = baseline.get(rel, 0)
        if count > allowed:
            errors.append(
                "error: %s 出现 %d 处 uniqueKeysWithValues（基线豁免 %d）——新增违例。"
                "iCloud 副本天然重复 id，此 API 会抛 ObjC 异常且 try? 拦不住（红线陷阱 §3.8）；"
                "改用 uniquingKeysWith { a, _ in a }。存量消化后可跑 --update-baseline 收缩基线"
                % (rel, count, allowed)
            )

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)
    frozen = sum(findings["uniqueKeysWithValues"].values())
    print(
        "Banned API Guard: 0 新增违例（uniqueKeysWithValues 存量冻结 %d 处/基线内；入口 ! 家族 0）" % frozen
    )


if __name__ == "__main__":
    main()
