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
#   5) body 多顶层视图劫持修饰链 → 构建失败（2026-11-12 随每周回顾翻车设立：
#      View 协议 body 要求自带 @ViewBuilder，body 里裸写兄弟视图会静默变 TupleView，
#      编译零警告；其后跟的点修饰全部挂到兄弟视图上。实锤：d9ce7ecd0 把 .task 挂到
#      空板块上 → 页面永久加载态，随 1.1.7(52) 上架。签名=根深度第 2+ 条语句是裸标识
#      符且下一行以点开头）
# 修法范本：Views/Settings/SettingsICloudSyncSection.swift（叶子拆出去、层级不增加）；
# 红线真源：docs/standards/quality-redlines.md §3/§6/§8

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
    # 10-22 拆分（1946→1399）滞留工作区未提交且与「一个发现」入口改动交织（2026-10-24 实测
    # HEAD 仍 1946 行）；待该线收口提交后移出白名单（工作区态 1399 行已过线）
    "ChatView.swift",
}

top_level_decl = re.compile(r"^(private |final |public )*(struct|class|enum|extension|actor) ")
view_struct_decl = re.compile(r"^(private |final |public )*struct \w+")

# —— body 多顶层视图劫持检测（规则 5）——
body_decl = re.compile(r"^\s*(?:@\w+\s+)*(?:private |public )?var body\b.*\{")
bare_identifier_line = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s*$")
dot_line = re.compile(r"^\s*\.")
# 根深度上这些开头视为上一条语句的续行，不算新语句
continuation_line = re.compile(r"^\s*[)}?:,&|+]")


def _code(line):
    """去掉行注释后的代码部分（brace 计数与判定都用它）。"""
    return line.split("//", 1)[0].rstrip()


def body_root_hijack_spans(lines):
    """返回 [(行号1based, 裸标识符)]：body 根深度上第 2+ 条语句为裸标识符且下一行以点开头。

    这是「修饰链被兄弟视图截断」的精确签名（TupleView + 修饰符挂错对象）。
    第一条语句的裸标识符后跟点是合法链式修饰，不算；容器闭包内部的裸子视图
    深度更高，也不算——深度追踪只盯 body 自己的根。
    """
    spans = []
    i, n = 0, len(lines)
    while i < n:
        if not body_decl.match(lines[i]):
            i += 1
            continue
        code = _code(lines[i])
        depth = code.count("{") - code.count("}")
        root_depth = depth
        stmt_count = 0
        j = i + 1
        while j < n and depth >= root_depth:
            raw = lines[j]
            c = _code(raw)
            if not c.strip():
                j += 1
                continue
            delta = c.count("{") - c.count("}")
            stripped = c.strip()
            if (
                depth == root_depth
                and not stripped.startswith("}")
                and not dot_line.match(c)
                and not continuation_line.match(c)
            ):
                stmt_count += 1
                if stmt_count >= 2 and bare_identifier_line.match(raw):
                    k = j + 1
                    while k < n and not _code(lines[k]).strip():
                        k += 1
                    if k < n and dot_line.match(_code(lines[k])):
                        spans.append((j + 1, stripped))
            depth += delta
            j += 1
        i = j
    return spans


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
            path = os.path.join(root, fn)
            try:
                with open(path, encoding="utf-8") as fp:
                    lines = fp.read().split("\n")
            except OSError:
                errors.append(
                    "error: View Weight Guard 无法读取 %s（脚本沙箱或文件异常，fail-closed 拦截）" % path
                )
                continue
            rel = os.path.relpath(path, SRCROOT)
            # 规则 5 对白名单文件同样生效（劫持检查与体量豁免无关）
            for ln, ident in body_root_hijack_spans(lines):
                errors.append(
                    "error: %s:%d 「%s」是 body 里第 2+ 个顶层视图（TupleView）——其后跟着的点修饰会挂到它身上"
                    "而不是你以为的整页（2026-11-12 每周回顾永久卡加载实锤，quality-redlines.md §8）。"
                    "把它移进容器/滚动内容流，让修饰链挂回唯一根视图" % (rel, ln, ident)
                )
            if fn in WHITELIST:
                continue
            checked += 1
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
