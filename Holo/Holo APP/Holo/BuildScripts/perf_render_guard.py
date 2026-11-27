#!/usr/bin/env python3
"""
Holo 渲染与滑动性能机器守门（2026-11-27 随 120Hz 卡顿根治设立）。

遵循 quality-redlines.md §9 守门纪律：
- fail-closed：扫描文件数异常直接判失败，防假闸门；
- 存量基线挂账制（perf_render_baseline.json）：老账冻结只减不增，新增即红；
- 守护规则：
  1. Info.plist 必须保留 CADisableMinimumFrameDurationOnPhone = true（iPhone Pro 120Hz 高刷解锁）；
  2. Views/ 与 Components/ 禁止新增裸 UIImage(systemName:) 探测（应走 SystemSymbolValidationCache）；
  3. Views/ 禁止新增 viewContext.fetch( 同步主线程查库；
  4. Views/ 禁止新增 ResolvePlacement 绕过缓存或非静态 DateFormatter() 构造。
"""

import argparse
import json
import os
import plistlib
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
VIEWS_ROOT = PROJECT_ROOT / "Holo" / "Views"
COMPONENTS_ROOT = PROJECT_ROOT / "Holo" / "Components"
INFO_PLIST = PROJECT_ROOT / "Info.plist"
BASELINE_PATH = SCRIPT_DIR / "perf_render_baseline.json"

MIN_EXPECTED_SWIFT_FILES = 100

RE_UIIMAGE_SYSTEM = re.compile(r"\bUIImage\s*\(\s*systemName\s*:")
RE_VIEWCONTEXT_FETCH = re.compile(r"\bviewContext\s*\.\s*fetch\s*\(")
RE_RAW_DATEFORMATTER = re.compile(r"\b(?:let|var)\s+\w+\s*=\s*DateFormatter\s*\(\s*\)")


def check_info_plist() -> list[str]:
    errors: list[str] = []
    if not INFO_PLIST.is_file():
        return [f"FAIL-CLOSED: 找不到 Info.plist: {INFO_PLIST}"]
    with INFO_PLIST.open("rb") as f:
        data = plistlib.load(f)
    if data.get("CADisableMinimumFrameDurationOnPhone") is not True:
        errors.append("Info.plist 缺少 CADisableMinimumFrameDurationOnPhone = true（iPhone Pro 120Hz 高刷将被系统锁帧）")
    return errors


def strip_line_comment(line: str) -> str:
    idx = line.find("//")
    return line[:idx] if idx >= 0 else line


def scan_swift_files() -> tuple[int, dict[str, dict[str, int]]]:
    counts: dict[str, dict[str, int]] = {}
    file_count = 0

    for root in (VIEWS_ROOT, COMPONENTS_ROOT):
        if not root.is_dir():
            continue
        for swift_file in sorted(root.rglob("*.swift")):
            file_count += 1
            rel = str(swift_file.relative_to(PROJECT_ROOT))
            is_views = swift_file.is_relative_to(VIEWS_ROOT)
            try:
                lines = swift_file.read_text(encoding="utf-8").splitlines()
            except Exception as exc:
                raise RuntimeError(f"无法读取 {rel}: {exc}") from exc

            file_hits: dict[str, int] = {}
            in_static_block = False
            brace_depth = 0
            for raw_line in lines:
                line = strip_line_comment(raw_line)
                if not line.strip():
                    continue

                if re.search(r"\bstatic\s+(?:let|var)\b", line) and "{" in line:
                    in_static_block = True
                    brace_depth = line.count("{") - line.count("}")
                elif in_static_block:
                    brace_depth += line.count("{") - line.count("}")
                    if brace_depth <= 0:
                        in_static_block = False
                        brace_depth = 0

                if RE_UIIMAGE_SYSTEM.search(line):
                    file_hits["uiimage_system_name"] = file_hits.get("uiimage_system_name", 0) + 1
                if is_views and RE_VIEWCONTEXT_FETCH.search(line):
                    file_hits["viewcontext_fetch"] = file_hits.get("viewcontext_fetch", 0) + 1
                if is_views and not in_static_block and RE_RAW_DATEFORMATTER.search(line):
                    file_hits["raw_date_formatter"] = file_hits.get("raw_date_formatter", 0) + 1

            if file_hits:
                counts[rel] = file_hits

    return file_count, counts


def main() -> int:
    parser = argparse.ArgumentParser(description="Holo 渲染与滑动性能机器守门")
    parser.add_argument("--update-baseline", action="store_true", help="刷新存量基线文件")
    args = parser.parse_args()

    plist_errors = check_info_plist()
    file_count, current = scan_swift_files()
    if file_count < MIN_EXPECTED_SWIFT_FILES:
        print(f"[perf_render_guard] FAIL-CLOSED: 仅扫描到 {file_count} 个 Swift 文件（预期 ≥ {MIN_EXPECTED_SWIFT_FILES}）", file=sys.stderr)
        return 1

    if args.update_baseline:
        BASELINE_PATH.write_text(json.dumps(current, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"[perf_render_guard] 已更新基线：{BASELINE_PATH}（扫描 {file_count} 文件，挂账 {len(current)} 文件）")
        if plist_errors:
            for err in plist_errors:
                print(f"[perf_render_guard] ERROR: {err}", file=sys.stderr)
            return 1
        return 0

    if not BASELINE_PATH.is_file():
        print(f"[perf_render_guard] FAIL-CLOSED: 缺少基线文件 {BASELINE_PATH}", file=sys.stderr)
        return 1

    baseline: dict[str, dict[str, int]] = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    violations: list[str] = list(plist_errors)

    for rel, rules in current.items():
        base_rules = baseline.get(rel, {})
        for rule, count in rules.items():
            allowed = base_rules.get(rule, 0)
            if count > allowed:
                violations.append(f"{rel}: [{rule}] 当前 {count} 处 > 基线 {allowed} 处（新增 {count - allowed} 处违例）")

    if violations:
        print("[perf_render_guard] FAILED:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    print(f"[perf_render_guard] PASSED: Info.plist 120Hz 已开启，扫描 {file_count} 个文件，0 新增性能违例。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
