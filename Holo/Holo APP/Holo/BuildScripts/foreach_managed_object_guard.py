#!/usr/bin/python3
# ForEach ManagedObject Guard —— 删除后闪退族闸门（2026-11-16 随删主题真机崩溃根治设立）
#
# 病：@State/let/[计算属性] 数组直接装 NSManagedObject 做 ForEach 数据源，
#     删除+save 与页面 reload 之间存在时序窗口，body 重算时 ForEach 读死对象
#     \.id（非可选 UUID 底层 nil）→ UUID._unconditionallyBridgeFromObjectiveC →
#     EXC_BREAKPOINT。实锤：Holo-2026-11-16-215553.ips（1.1.9(57) 删主题），
#     历史同族复发 10+ 次（Thought.id / Attachment.id / reconcile 多案）。
#
# 规则：
#   1) ForEach 数据源被本文件证明为 NSManagedObject 子类数组（变量/属性/函数参数
#      三种声明形态建立类型映射），且表达式不含 .renderable/.isRenderable → 构建失败
#   2) 实体清单从 Models/ 的 `class Xxx: NSManagedObject` 动态收集（新增实体自动进闸门）
#   3) 白名单豁免=挂账（确属值类型/投影且映射误报的，注明原因，收口即移出）
#   4) Models 读不到/实体集合为空 → fail-closed 拦截（假闸门比没闸门更危险）
# 修法：数据源挂 .renderable（Utils/ManagedObjectRenderSafety.swift）；
# 红线真源：docs/standards/quality-redlines.md §3.3（项目标准防线，非可选）
#
# 已知边界（不拦，防误报）：元组投影深链 keypath（id: \.topic.id 形态）、
# 构造器注入的跨文件属性（init 参数透传，静态无类型信息）——review 时人工盯。

import os
import re
import sys

SRCROOT = os.environ.get("SRCROOT", "")
MODELS = os.path.join(SRCROOT, "Holo", "Models")
SCAN_DIRS = [os.path.join(SRCROOT, "Holo", "Views"), os.path.join(SRCROOT, "Holo", "Components")]

MIN_EXPECTED_ENTITIES = 5   # Models 下实体数十个；低于此值视为沙箱拦截读取
MIN_EXPECTED_FILES = 50     # Views 下 .swift 数百个；低于此值视为沙箱拦截读取

# 白名单（豁免+挂账，注明原因，收口即移出）：
# key = "相对路径:行号"（行号会漂移，匹配时按 文件+数据源变量名 双因子兜底）
WHITELIST = {
    # 示例："Views/Thoughts/Foo.swift:42": "frequentTags 是投影 struct 非实体，误报豁免",
}

entity_decl = re.compile(r"^(?:public |final |private )*(?:class|@objc class) +(\w+) *: *[^{]*NSManagedObject")
# 变量→实体数组 三种声明形态
decl_state = re.compile(r"@State\s+(?:private |public )?var +(\w+) *: *\[(\w+)\]")
decl_var = re.compile(r"^(?:private |public |internal )*(?:var|let) +(\w+) *: *\[(\w+)\]")
decl_param = re.compile(r"(?:_ *)?(\w+) *: *\[(\w+)\]")
# ForEach 调用行（数据源段取 ForEach( 后按括号深度切出的第一顶层逗号前段）
foreach_line = re.compile(r"\bForEach\(")


def collect_entities():
    """扫 Models/ 收集 NSManagedObject 子类名。"""
    entities = set()
    if not os.path.isdir(MODELS):
        return entities
    for root, _dirs, files in os.walk(MODELS):
        for fn in sorted(files):
            if not fn.endswith(".swift"):
                continue
            try:
                with open(os.path.join(root, fn), encoding="utf-8") as fp:
                    for line in fp:
                        m = entity_decl.match(line)
                        if m:
                            entities.add(m.group(1))
            except OSError:
                pass
    return entities


def first_argument_segment(code, start):
    """从 start（'ForEach(' 后）取第一顶层参数段（括号深度平衡内的首个顶层逗号前）。"""
    depth = 0
    seg = []
    for ch in code[start:]:
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                break
            depth -= 1
        elif ch == "," and depth == 0:
            break
        seg.append(ch)
    return "".join(seg)


def base_identifier(segment):
    """剥掉 Array(...) / xxx.enumerated() / 前缀调用等包装，取最内核的起始标识符。"""
    s = segment.strip()
    # Array(expr) → expr
    while True:
        m = re.match(r"^Array\s*\((.*)\)$", s)
        if not m:
            break
        s = m.group(1).strip()
    # expr.enumerated() / expr.sorted { } 等 .method 尾巴剥掉
    s = re.split(r"\.(enumerated|sorted|reversed)\s*\(", s)[0].strip()
    # 取首个标识符（可能带前缀路径 foo.bar → foo）
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)", s)
    return m.group(1) if m else None


def build_type_map(lines, entities):
    """本文件内 变量/属性/参数名 → 实体名 映射（只收实体数组）。"""
    tm = {}
    for line in lines:
        code = line.split("//", 1)[0]
        for m in decl_state.finditer(code):
            if m.group(2) in entities:
                tm[m.group(1)] = m.group(2)
        for m in decl_var.finditer(code):
            if m.group(2) in entities:
                tm[m.group(1)] = m.group(2)
        for m in decl_param.finditer(code):
            if m.group(2) in entities:
                tm[m.group(1)] = m.group(2)
    return tm


def main():
    errors = []
    entities = collect_entities()
    if len(entities) < MIN_EXPECTED_ENTITIES:
        print(
            "error: ForEach ManagedObject Guard 仅收集到 %d 个实体（预期数十），"
            "疑似沙箱拦截 Models 读取——闸门失效按失败处理（fail-closed）" % len(entities),
            file=sys.stderr,
        )
        sys.exit(1)

    checked = 0
    findings = 0
    for scan_dir in SCAN_DIRS:
        if not os.path.isdir(scan_dir):
            continue
        for root, _dirs, files in os.walk(scan_dir):
            for fn in sorted(files):
                if not fn.endswith(".swift") or fn.endswith("ViewModel.swift"):
                    continue
                path = os.path.join(root, fn)
                rel = os.path.relpath(path, SRCROOT)
                try:
                    with open(path, encoding="utf-8") as fp:
                        lines = fp.read().split("\n")
                except OSError:
                    errors.append(
                        "error: ForEach ManagedObject Guard 无法读取 %s（fail-closed 拦截）" % rel
                    )
                    continue
                checked += 1
                tm = build_type_map(lines, entities)
                if not tm:
                    continue
                for i, line in enumerate(lines):
                    code = line.split("//", 1)[0]
                    if not foreach_line.search(code):
                        continue
                    start = code.index("ForEach(") + len("ForEach(")
                    seg = first_argument_segment(code, start)
                    if ".renderable" in seg or ".isRenderable" in seg:
                        continue
                    ident = base_identifier(seg)
                    if ident and ident in tm:
                        wl_key = "%s:%d" % (rel, i + 1)
                        wl_key2 = "%s:*:%s" % (rel, ident)
                        if wl_key in WHITELIST or wl_key2 in WHITELIST:
                            continue
                        findings += 1
                        errors.append(
                            "error: %s:%d ForEach(%s, ...) 渲染实体数组 [%s] 未挂 .renderable ——"
                            "删除该实体后 body 重算会读到死对象 \\.id 直接崩（2026-11-16 删主题真机实锤，"
                            "红线 §3.3）。改为 ForEach(%s.renderable, ...)（Utils/ManagedObjectRenderSafety.swift）"
                            % (rel, i + 1, seg.strip()[:60], tm[ident], ident)
                        )

    if checked < MIN_EXPECTED_FILES:
        errors.append(
            "error: ForEach ManagedObject Guard 仅检查到 %d 个文件（预期数百），"
            "疑似沙箱拦截目录读取——闸门失效按失败处理（fail-closed）" % checked
        )

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)
    print(
        "ForEach ManagedObject Guard: %d 个文件 × %d 个实体类型，0 处违规（renderable 防线完好）"
        % (checked, len(entities))
    )


if __name__ == "__main__":
    main()
