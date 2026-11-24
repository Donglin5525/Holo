#!/usr/bin/python3
# Coupling Guard —— 模块耦合「只减不增」闸门（2026-11-24 随「全量技术优化一轮」设立）
#
# 病（2026-11-24 耦合度量实锤）：1449 个文件 41 万行全在一个 Swift 模块里，编译器拦不住互相引用——
#   非界面层反过来依赖功能界面、数据层依赖业务服务、各功能界面互相直接引用、视图直接拿全局数据库栈、
#   界面层新增全局单例。没有机器闸门时每加一个功能这些数字只会涨（173 个单例、财务仓库被 99 个文件直引）。
#
# 规则（存量基线冻结，只减不增；口径 = 每个文件对每个外部类型计 1 次「类型引用」）：
#   A 依赖方向：Utils / Components / Modifiers / Views/Components / Models / Data 不得引用 Views/<功能>/ 声明的类型
#   B 数据层纯净：Models / Data 不得引用 Services/ 声明的类型
#   C 功能界面横向耦合：Views/<功能A> → Views/<功能B>（A≠B）的类型引用数，按来源功能合计
#   D 视图直连数据库栈：Views/** 中 CoreDataStack.shared 的出现次数，按文件
#   E 界面层单例：Views/** 中 static let/var shared 的声明数，按文件
#   读不到文件 / 文件数异常 / 基线损坏 → fail-closed
# 用法：
#   提交时由 pre_commit_guard.py 自动调用（有 .swift 改动才跑）；手动：python3 coupling_guard.py
#   收缩基线：python3 coupling_guard.py --update-baseline            （每项只许 ≤ 基线，否则拒绝）
#   确需新增耦合：python3 coupling_guard.py --update-baseline --accept-growth   （把打印的增量写进提交说明）
# 分层规则真源：docs/standards/quality-redlines.md §9 机器守门清单 + 开发规范「模块边界与依赖规则」

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def srcroot():
    env = os.environ.get("SRCROOT")
    if env:
        return env
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    return os.path.join(top, "Holo", "Holo APP", "Holo")


SRCROOT = srcroot()
SCAN_ROOT = os.path.join(SRCROOT, "Holo")
BASELINE_PATH = os.path.join(HERE, "coupling_baseline.json")

MIN_EXPECTED_FILES = 1000

# 声明：class/struct/enum/protocol/actor + 名字（extension 不建新类型名，不索引）
DECL = re.compile(r"\b(class|struct|enum|protocol|actor)\s+([A-Za-z_]\w*)")
# 引用：标识符，排除 @包装器（@State 不是引用自定义 State 类型）与 成员访问（.xxx）
TOKEN = re.compile(r"(?<![@.\w])[A-Za-z_]\w*")
SHARED_DECL = re.compile(r"\bstatic\s+(?:let|var)\s+shared\b")
CORE_DATA_STACK = re.compile(r"\bCoreDataStack\s*\.\s*shared")
NOT_KEYWORD = {"class", "struct", "enum", "protocol", "actor", "func", "var", "let", "init", "self", "some", "any"}

# 规则 A：这些「非界面层」不得依赖功能界面
RULE_A_SOURCES = {"Utils", "Components", "Modifiers", "Views/Components", "Models", "Data"}
# 规则 B：这些「数据层」不得依赖业务服务
RULE_B_SOURCES = {"Models", "Data"}


def group_of(rel):
    """文件 → 模块组。Views/<功能>/ 是功能界面；Views 下的散文件是外壳（首页/内容容器）。"""
    parts = rel.split(os.sep)
    if parts[0] == "Views":
        if len(parts) == 2:
            return "Views(壳)"
        return "Views/" + parts[1]
    if len(parts) == 1:
        return "(App)"
    return parts[0]


def is_feature_ui(group):
    return group.startswith("Views/") and group != "Views/Components" or group == "Views(壳)"


def strip_comment(line):
    return line.split("//", 1)[0]


def collect():
    """返回 (counts, evidence, total_files)；任一文件读不到或文件数异常返回 (None, None, n)。
    counts[规则][键] = 数值；evidence[规则][键][(文件, 类型)] = 次数。"""
    files = {}
    total = 0
    for root, _dirs, names in os.walk(SCAN_ROOT):
        for fn in sorted(names):
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(root, fn)
            total += 1
            try:
                with open(path, encoding="utf-8") as fp:
                    files[os.path.relpath(path, SCAN_ROOT)] = fp.read()
            except OSError:
                return None, None, total
    if total < MIN_EXPECTED_FILES:
        return None, None, total

    # 类型名 → 声明所在模块组
    type_groups = {}
    for rel, text in files.items():
        for _kind, name in DECL.findall(text):
            if name not in NOT_KEYWORD:
                type_groups.setdefault(name, set()).add(group_of(rel))

    counts = {r: {} for r in "ABCDE"}
    evidence = {r: {} for r in "ABCDE"}

    def bump(rule, key, item):
        counts[rule][key] = counts[rule].get(key, 0) + 1
        evidence[rule].setdefault(key, {}).setdefault(item, 0)
        evidence[rule][key][item] += 1

    for rel, text in files.items():
        group = group_of(rel)
        code = "\n".join(strip_comment(ln) for ln in text.split("\n"))
        for token in set(TOKEN.findall(code)):
            for decl_group in type_groups.get(token, ()):
                if decl_group == group:
                    continue
                if group in RULE_A_SOURCES and is_feature_ui(decl_group):
                    bump("A", "%s→%s" % (group, decl_group), (rel, token))
                if group in RULE_B_SOURCES and decl_group == "Services":
                    bump("B", "%s→Services" % group, (rel, token))
                if (group.startswith("Views/") and group != "Views/Components"
                        and decl_group.startswith("Views/") and decl_group != "Views/Components"):
                    bump("C", group, (rel, token))
        if group.startswith("Views/") or group == "Views(壳)":
            cds = len(CORE_DATA_STACK.findall(code))
            if cds:
                counts["D"][rel] = cds
            shared = len(SHARED_DECL.findall(code))
            if shared:
                counts["E"][rel] = shared
    return counts, evidence, total


def diff_growth(current, baseline):
    """返回 [(规则, 键, 现值, 基线值)]：现值 > 基线值的项。"""
    out = []
    for rule in sorted(current):
        base = baseline.get(rule, {})
        for key, val in sorted(current[rule].items()):
            if val > base.get(key, 0):
                out.append((rule, key, val, base.get(key, 0)))
    return out


def load_baseline():
    if not os.path.exists(BASELINE_PATH):
        return {}
    try:
        with open(BASELINE_PATH, encoding="utf-8") as fp:
            return json.load(fp)
    except (OSError, ValueError):
        print("error: Coupling Guard 基线文件损坏（%s）——先跑 --update-baseline 重建（fail-closed）" % BASELINE_PATH,
              file=sys.stderr)
        sys.exit(1)


def changed_files():
    """相对 HEAD 有改动（已暂存/未暂存/未跟踪）的 App 源码文件，路径相对 SCAN_ROOT。"""
    r = subprocess.run(["git", "-C", SRCROOT, "status", "--porcelain", "-z", "--untracked-files=all", "--", "Holo"],
                       capture_output=True, text=True)
    prefix = os.path.join(SRCROOT, "Holo") + os.sep
    return {entry[len(prefix):] for entry in r.stdout.split("\0")
            if entry.startswith(prefix) and entry.endswith(".swift")}


def main():
    update = "--update-baseline" in sys.argv
    accept_growth = "--accept-growth" in sys.argv
    counts, evidence, total = collect()
    if counts is None:
        print("error: Coupling Guard 扫描异常（只扫到 %d 个 swift 文件，或读取失败）——闸门失效按失败处理（fail-closed）"
              % total, file=sys.stderr)
        sys.exit(1)

    first_time = not os.path.exists(BASELINE_PATH)
    baseline = load_baseline()
    growth = diff_growth(counts, baseline)

    if update:
        if growth and not first_time and not accept_growth:
            print("error: Coupling Guard 拒绝更新基线——下列项比基线涨了（只减不增）。确属必须的新耦合，"
                  "加 --accept-growth 并把这份清单写进提交说明：", file=sys.stderr)
            for rule, key, val, base in growth:
                print("  [%s] %s：%d（基线 %d）" % (rule, key, val, base), file=sys.stderr)
            sys.exit(1)
        with open(BASELINE_PATH, "w", encoding="utf-8") as fp:
            json.dump(counts, fp, ensure_ascii=False, indent=2, sort_keys=True)
        print("Coupling Guard: 基线已更新（A %d 项 / B %d 项 / C %d 项 / D %d 文件 / E %d 文件%s）" % (
            len(counts["A"]), len(counts["B"]), len(counts["C"]), len(counts["D"]), len(counts["E"]),
            "；本次接受新增耦合 %d 项" % len(growth) if growth else ""))
        for rule, key, val, base in growth:
            print("  新增 [%s] %s：%d（原基线 %d）" % (rule, key, val, base))
        return

    if not baseline:
        print("error: Coupling Guard 找不到基线（%s）——先跑 --update-baseline（fail-closed）" % BASELINE_PATH,
              file=sys.stderr)
        sys.exit(1)

    errors = []
    names = {"A": "依赖方向（非界面层不得依赖功能界面）", "B": "数据层不得依赖业务服务",
             "C": "功能界面横向耦合", "D": "视图直连数据库栈", "E": "界面层单例"}
    hints = {
        "A": "把界面需要的通用能力下沉到被依赖方，或用闭包/协议注入；非界面层不许 import 功能界面的类型",
        "B": "数据层不该认识业务服务：把这段逻辑上移到服务层，或把需要的能力作为参数传入",
        "C": "功能界面之间不要直接引用对方界面的类型：跳转走 DeepLinkState / 回调注入，共用件放 Views/Components",
        "D": "视图不要直接拿 CoreDataStack.shared：数据读写走对应 Repository",
        "E": "界面层不许新增全局单例：状态放 @State/@StateObject，共享能力放服务层",
    }
    changed = changed_files()
    for rule, key, val, base in growth:
        errors.append("error: [Coupling %s·%s] %s：%d（基线 %d）——新增耦合。%s" % (
            rule, key, names[rule], val, base, hints[rule]))
        items = sorted(evidence[rule].get(key, {}).items())
        # 相对 HEAD 有改动的文件排前面：新增的那一处几乎总在其中
        items.sort(key=lambda kv: (kv[0][0] not in changed, kv[0]))
        for (rel, token), _n in items[:6]:
            errors.append("    %s涉及：%s 引用 %s" % ("★本次改动 " if rel in changed else "", rel, token))

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)

    totals = {r: sum(counts[r].values()) for r in "ABCDE"}
    print("Coupling Guard: 0 新增耦合（存量 A %d / B %d / C %d / D %d / E %d，基线内只减不增）" % (
        totals["A"], totals["B"], totals["C"], totals["D"], totals["E"]))


if __name__ == "__main__":
    main()
