#!/usr/bin/python3
# View Weight Guard —— 全库 View 文件体量闸门（2026-10-24 随设置页真机栈溢出必崩设立）
#
# 病：单个 View struct 无边界内联巨型视图树 → SwiftUI 元数据实例化递归 →
#     真机 1MB 主线程栈溢出（模拟器 8MB 栈测不出，模拟器绿灯无证明力）。
# 实锤基线：ChatView 1946~1993 行四次崩溃（0917/0923/1022）；SettingsView 1740 行
#           2026-10-24 必崩（.ips: closure in SettingsView.iCloudSyncSection.getter）。
# 安全基线：主 struct 内联 ≤1400 行未见崩（ChatView 拆后 1399 存活）。
#
# 规则：
#   1) Views 下单文件总行数 > 2000 → 构建失败
#   2) 首个 View struct 内联体量 > 1400 → 构建失败（把大 section 拆同目录独立 struct）
#   3) 白名单豁免=挂账（在途/冻结占用），收口后拆分并移出白名单
#   4) 读不到文件/文件数异常 → fail-closed 拦截（假闸门比没闸门更危险）
# 修法范本：Views/Settings/SettingsICloudSyncSection.swift（叶子拆出去、层级不增加）；
# 红线真源：docs/standards/quality-redlines.md §3/§6

import os
import re
import sys

SRCROOT = os.environ.get("SRCROOT", "")
VIEWS = os.path.join(SRCROOT, "Holo", "Views")

FILE_LIMIT = 2000
MAIN_STRUCT_LIMIT = 1400
MIN_EXPECTED_FILES = 50  # Views 下 .swift 数百个；低于此值视为沙箱拦截读取

# 白名单（豁免+挂账，注明原因与体量，收口即拆）：
WHITELIST = {
    # 想法模块主线在途改造占用，拆分挂账待其收口（2026-10-24 记）
    "ThoughtEditorView.swift",  # 主 struct ~2115 行
    "ThoughtListView.swift",    # 主 struct ~1838 行
    # 首页布局冻结令（2026-10-12 东林明令不许动），纯结构拆分待东林专门批准
    "HomeView.swift",           # 主 struct ~1540 行
    # 非排除对象而是「非 SwiftUI 视图树」：UIKit 桥接逻辑文件，不参与 AttributeGraph 下钻
    "MarkdownTextView.swift",
}

top_level_decl = re.compile(r"^(private |final |public )*(struct|class|enum|extension|actor) ")
view_struct_decl = re.compile(r"^(private |final |public )*struct \w+")


def first_view_struct_span(lines):
    """首个 View struct 到下一个顶层声明之间的行数（主 struct 内联体量近似）。"""
    first = None
    for i, line in enumerate(lines):
        if view_struct_decl.match(line) and ("View" in line):
            first = i
            break
    if first is None:
        return 0
    for i in range(first + 1, len(lines)):
        if top_level_decl.match(lines[i]):
            return i - first
    return len(lines) - first


def main():
    errors = []
    checked = 0
    for root, _dirs, files in os.walk(VIEWS):
        for fn in sorted(files):
            if not fn.endswith(".swift") or "ViewModel" in fn:
                continue
            if fn in WHITELIST:
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, encoding="utf-8") as fp:
                    lines = fp.read().split("\n")
            except OSError:
                errors.append(
                    "error: View Weight Guard 无法读取 %s（脚本沙箱或文件异常，fail-closed 拦截）" % path
                )
                continue
            checked += 1
            rel = os.path.relpath(path, SRCROOT)
            total = len(lines)
            if total > FILE_LIMIT:
                errors.append(
                    "error: %s 已达 %d 行，超过 View 文件上限 %d（巨型视图=真机主线程栈溢出风险，"
                    "见 docs/standards/quality-redlines.md §6）。先把存量拆到独立 struct 文件再加代码" % (rel, total, FILE_LIMIT)
                )
                continue
            span = first_view_struct_span(lines)
            if span > MAIN_STRUCT_LIMIT:
                errors.append(
                    "error: %s 首个 View struct 内联 %d 行，超过警戒线 %d（单 struct 无边界视图树="
                    "真机主线程栈溢出，2026-10-24 设置页实锤）。把大 section 拆成同目录独立 struct 文件"
                    "（范本 Views/Settings/SettingsICloudSyncSection.swift）" % (rel, span, MAIN_STRUCT_LIMIT)
                )

    if checked < MIN_EXPECTED_FILES:
        errors.append(
            "error: View Weight Guard 仅检查到 %d 个文件（预期数百），疑似脚本沙箱拦截目录读取——"
            "闸门失效按失败处理（fail-closed）" % checked
        )

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)
    print("View Weight Guard: %d 个 View 文件全部在警戒线内" % checked)


if __name__ == "__main__":
    main()
