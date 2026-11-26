#!/usr/bin/python3
# Aesthetic Guard —— 反 AI 味审美底座闸门（2026-11-24 设立）
#
# 目的：防止后续 Agent 在新页面/组件中回退到「圆体数字 + sparkles + 满屏旧白卡 + 裸阴影」模板。
# 机制：与 banned_api_guard.py 同口径——存量冻结在 aesthetic_guard_baseline.json，只减不增；
#       任何新增违例在 Xcode 构建期与 git pre-commit 期直接报错，并给出标准底座替代件。
#
# 规则（全部基于基线冻结，新代码零容忍）：
#   R1 roundedFont  ：禁新增 `design: .rounded`
#                     → 主角数字用 `Font.holoHeroNumber(size:)`，常规数字用默认无衬线 + `.monospacedDigit()`
#   R2 sparklesIcon ：禁新增 `"*sparkles*"`（豁免用户自选图标目录 CategoryIconCatalog / UnifiedIconCatalog）
#                     → AI 统一用 `HoloAIBadge` 或 `"smallcircle.filled.circle"` + `Color.holoAI`
#   R3 legacyCard   ：禁新增 `.holoCard()` / `.holoNestedCard()`（豁免 DesignSystem.swift 定义）
#                     → 默认无卡用 `HoloCardlessRow` + `HoloHairlineDivider`；仅独立实体用 `.holoSurface(.independent)`
#   R4 rawShadow    ：Views/ 与 Components/ 禁新增裸 `.shadow(`
#                     → 默认无阴影；仅真正悬浮容器用 `.holoSurface(.floating)`
#
# 用法：
#   构建/CI：python3 aesthetic_guard.py
#   存量消化后收缩基线：python3 aesthetic_guard.py --update-baseline
# 真源：docs/standards/设计规范.md（2026-11-24 反 AI 味减法红线） & Holo/Components/HoloEditorialPrimitives.swift

import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SRCROOT = os.environ.get("SRCROOT") or os.path.dirname(SCRIPT_DIR)
SCAN_ROOT = os.path.join(SRCROOT, "Holo")
BASELINE_PATH = os.path.join(SCRIPT_DIR, "aesthetic_guard_baseline.json")

MIN_EXPECTED_FILES = 300

SPARKLES_EXEMPT_FILES = {
    "CategoryIconCatalog.swift",
    "UnifiedIconCatalog.swift",
}
LEGACY_CARD_EXEMPT_FILES = {
    "DesignSystem.swift",
}

RULES = {
    "roundedFont": {
        "pattern": re.compile(r"design\s*:\s*\.rounded\b"),
        "advice": "主角数字改用 Font.holoHeroNumber(size:)，常规数字改用默认无衬线 + .monospacedDigit()",
    },
    "sparklesIcon": {
        "pattern": re.compile(r'"[^"\n]*sparkles[^"\n]*"'),
        "advice": "AI 标识改用 HoloAIBadge 或 smallcircle.filled.circle + Color.holoAI（禁止 sparkles）",
    },
    "legacyCard": {
        "pattern": re.compile(r"\.holo(?:Nested)?Card\s*\("),
        "advice": "默认无卡改用 HoloCardlessRow + HoloHairlineDivider；仅独立实体用 .holoSurface(.independent)",
    },
    "rawShadow": {
        "pattern": re.compile(r"\.shadow\s*\("),
        "advice": "默认无阴影；仅真正悬浮容器使用 .holoSurface(.floating)",
    },
}


def strip_line_comment(line):
    """简单去掉 // 行尾注释（保留字符串字面量内的 //）。"""
    in_str = False
    escaped = False
    i = 0
    while i < len(line):
        ch = line[i]
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == '"':
            in_str = not in_str
        elif not in_str and ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
            return line[:i]
        i += 1
    return line


def collect_findings():
    findings = {k: {} for k in RULES}
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

            code_lines = [strip_line_comment(ln) for ln in lines]
            in_ui_dir = rel.startswith("Holo/Views/") or rel.startswith("Holo/Components/")

            for rule_name, cfg in RULES.items():
                if rule_name == "sparklesIcon" and fn in SPARKLES_EXEMPT_FILES:
                    continue
                if rule_name == "legacyCard" and fn in LEGACY_CARD_EXEMPT_FILES:
                    continue
                if rule_name == "rawShadow" and not in_ui_dir:
                    continue
                pat = cfg["pattern"]
                cnt = sum(len(pat.findall(ln)) for ln in code_lines)
                if cnt:
                    findings[rule_name][rel] = cnt

    if total < MIN_EXPECTED_FILES:
        return None
    return findings


def main():
    update_baseline = "--update-baseline" in sys.argv
    findings = collect_findings()
    if findings is None:
        print(
            "error: Aesthetic Guard 扫描异常（文件数过少或读取失败）——闸门失效按失败处理（fail-closed）",
            file=sys.stderr,
        )
        sys.exit(1)

    if update_baseline:
        with open(BASELINE_PATH, "w", encoding="utf-8") as fp:
            json.dump(findings, fp, ensure_ascii=False, indent=2, sort_keys=True)
            fp.write("\n")
        summary = ", ".join(
            f"{k}:{sum(v.values())}" for k, v in sorted(findings.items())
        )
        print(f"Aesthetic Guard: 基线已更新（{summary}）")
        return

    if not os.path.exists(BASELINE_PATH):
        print(
            "error: Aesthetic Guard 基线文件缺失，请先运行 --update-baseline 建立（fail-closed）",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        with open(BASELINE_PATH, encoding="utf-8") as fp:
            baseline = json.load(fp)
    except (OSError, ValueError):
        print("error: Aesthetic Guard 基线文件损坏（fail-closed）", file=sys.stderr)
        sys.exit(1)

    errors = []
    for rule_name, file_counts in findings.items():
        rule_base = baseline.get(rule_name, {})
        advice = RULES[rule_name]["advice"]
        for rel, count in sorted(file_counts.items()):
            allowed = rule_base.get(rel, 0)
            if count > allowed:
                errors.append(
                    f"error: {rel} 命中审美闸门 [{rule_name}] {count} 处（基线豁免 {allowed} 处）——新增违例。"
                    f"{advice}（真源：docs/standards/设计规范.md 2026-11-24 反 AI 味减法红线）"
                )

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)

    summary = ", ".join(
        f"{k}:{sum(v.values())}" for k, v in sorted(findings.items())
    )
    print(f"Aesthetic Guard: 0 新增违例（存量基线内：{summary}）")


if __name__ == "__main__":
    main()
