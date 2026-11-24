#!/usr/bin/python3
# Test Mount Guard —— 测试文件挂载闸门（2026-11-16 随机器守门体系设立）
#
# 病：HoloTests / HoloUITests / HoloWidgets 是手工 group（非文件系统同步组），
#     新测试文件不加挂载会静默不编译不执行——「测试全绿」报告里根本没有它
#     （复犯坑总档族1/族2，30+ 次实锤：0 tests 仍 TEST SUCCEEDED）。
#
# 规则：
#   1) HoloTests 下含 `import XCTest` 的 .swift 必须挂进 pbxproj（文件名出现≥1 次）；
#      纯逻辑文件（无 import XCTest）= standalone 脚本通道，豁免
#   2) HoloUITests 下所有 .swift 必须挂载（走查测试不挂=永远不会跑，比不写更危险）
#   3) 白名单=显式挂账（注明原因与收口动作）
#   4) 目录读不到/文件数异常 → fail-closed 拦截
#   5) 独立脚本式套件（带独立运行启动器）必须有执行入口：文件自带测试类，或在自动生成的桥接
#      Support/StandaloneExecutableBridgeTests.swift 里——否则挂了也只编译不执行
#      （2026-11-24 技术优化随 48 个漏桥接套件补齐设立，零容忍）
# 红线真源：docs/standards/quality-redlines.md §2；复犯坑总档族1

import json
import os
import re
import sys

SRCROOT = os.environ.get("SRCROOT", "")
PBXPROJ = os.path.join(SRCROOT, "Holo.xcodeproj", "project.pbxproj")
SCAN = [
    # (目录, 模式)  模式 xctest=仅含 import XCTest 的必须挂；all=全部必须挂
    (os.path.join(SRCROOT, "HoloTests"), "xctest"),
    (os.path.join(SRCROOT, "HoloUITests"), "all"),
]

MIN_EXPECTED = {"HoloTests": 200, "HoloUITests": 10}

# 基线（存量挂账）：2026-11-16 守门首跑发现 47 个含 XCTest 的测试文件从未挂载
# （含编辑器提交/Agent 契约等关键防线，从未进过测试报告）——冻结在
# test_mount_baseline.json，挂载专项收口后跑 --update-baseline 收缩。
# 2026-11-24 技术优化：这批已全部挂载，基线收缩为空（pbxproj_surgery.py mount --all-unmounted）。
BASELINE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_mount_baseline.json")

_TOKEN = re.compile(
    r'"(?:\\.|[^"\\])*"'      # 带引号字符串（含转义）
    r"|/\*.*?\*/"                 # /* 注释 */
    r"|//[^\n]*"                   # // 注释
    r"|[{}()=;,]"
    r'|[^/\s{}()=;,""][^\s{}()=;,""]*',   # 不带引号的字符串（可含 / ，如 Holo/Foo.swift；首字符不能是 / ，留给注释）
    re.S)


def parse_openstep(text):
    """pbxproj（OpenStep plist 文本）最小解析：字典 / 数组 / 字符串。
    不用正则去抠「某某 in Sources」——手写正则漏掉过含非十六进制字母的 ID、多行条目等多种写法（2026-11-24 自测抓到）；
    也不依赖 plutil（构建相位脚本沙箱里少一个外部依赖）。解析不了直接抛错，由调用方按 fail-closed 处理。"""
    tokens = []
    for m in _TOKEN.finditer(text):
        t = m.group(0)
        if t[0] in "({})=;," or t[0] != "/" and not t.startswith("//"):
            tokens.append(t)
    pos = 0

    def value():
        nonlocal pos
        t = tokens[pos]
        if t == "{":
            pos += 1
            d = {}
            while tokens[pos] != "}":
                k = value()
                if tokens[pos] != "=":
                    raise ValueError("pbxproj 解析失败：字典里缺 = （第 %d 个记号）" % pos)
                pos += 1
                d[k] = value()
                if tokens[pos] != ";":
                    raise ValueError("pbxproj 解析失败：字典里缺 ; （第 %d 个记号）" % pos)
                pos += 1
            pos += 1
            return d
        if t == "(":
            pos += 1
            a = []
            while tokens[pos] != ")":
                a.append(value())
                if tokens[pos] == ",":
                    pos += 1
            pos += 1
            return a
        pos += 1
        if t.startswith('"'):
            body = t[1:-1]
            return re.sub(r"\\(.)", lambda mm: {"n": "\n", "t": "\t", "r": "\r"}.get(mm.group(1), mm.group(1)), body)
        return t

    root = value()
    if pos != len(tokens):
        raise ValueError("pbxproj 解析失败：末尾有 %d 个多余记号" % (len(tokens) - pos))
    return root


def compiled_sources(pbx):
    """{target 名: {Sources 编译相位里的文件名}}。
    只认真正进了编译相位的文件：pbxproj 里「名字出现过」不等于会被编译——
    只登记了文件引用/分组、没进 Sources 相位的文件（半挂载）同样静默不编译（2026-11-24 技术优化加严）。"""
    objects = parse_openstep(pbx)["objects"]
    result = {}
    for obj in objects.values():
        if obj.get("isa") != "PBXNativeTarget":
            continue
        names = set()
        for pid in obj.get("buildPhases", []):
            phase = objects.get(pid, {})
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for bid in phase.get("files", []):
                ref = objects.get(objects.get(bid, {}).get("fileRef"), {})
                if ref:
                    names.add(os.path.basename(ref.get("path") or ref.get("name") or ""))
        result[obj["name"]] = names
    return result


def main():
    update_baseline = "--update-baseline" in sys.argv
    errors = []
    unmounted = []
    try:
        with open(PBXPROJ, encoding="utf-8") as fp:
            pbx = fp.read()
    except OSError:
        print("error: Test Mount Guard 读不到 pbxproj（fail-closed）", file=sys.stderr)
        sys.exit(1)
    try:
        compiled = compiled_sources(pbx)
    except (ValueError, IndexError, KeyError) as e:
        print("error: Test Mount Guard 解析不了 pbxproj（%s）——闸门失效按失败处理（fail-closed）" % e, file=sys.stderr)
        sys.exit(1)
    for dirname, minimum in MIN_EXPECTED.items():
        if len(compiled.get(dirname, ())) < minimum:
            print("error: Test Mount Guard 在 %s 的 Sources 编译相位里只见到 %d 个文件（预期不少于 %d）——"
                  "闸门失效按失败处理（fail-closed）" % (dirname, len(compiled.get(dirname, ())), minimum), file=sys.stderr)
            sys.exit(1)

    for scan_dir, mode in SCAN:
        dirname = os.path.basename(scan_dir)
        total = 0
        seen_names = {}
        bridge_path = os.path.join(scan_dir, "Support", "StandaloneExecutableBridgeTests.swift")
        try:
            with open(bridge_path, encoding="utf-8") as fp:
                bridge_source = fp.read()
        except OSError:
            bridge_source = ""   # HoloUITests 没有桥接文件；HoloTests 读不到时下面按未进桥报错（fail-closed）
        try:
            entries = os.walk(scan_dir)
        except OSError:
            errors.append("error: Test Mount Guard 读不到 %s（fail-closed）" % scan_dir)
            continue
        compiled_names = compiled.get(dirname)
        if compiled_names is None:
            errors.append("error: Test Mount Guard 定位不到 %s 的 Sources 编译相位（fail-closed）" % dirname)
            continue
        for root, _dirs, files in entries:
            for fn in sorted(files):
                if not fn.endswith(".swift"):
                    continue
                total += 1
                # 同名文件会让「文件名在 pbxproj 出现」互相掩护（2026-11-16 对抗自审加固：
                # 挂载判定按 basename，两个同名文件一个挂了一个没挂=漏网）。重名直接拦，要求改名。
                seen_names.setdefault(fn, []).append(os.path.join(root, fn))
                path = os.path.join(root, fn)
                try:
                    with open(path, encoding="utf-8") as fp:
                        content = fp.read()
                except OSError:
                    errors.append("error: 无法读取 %s（fail-closed）" % path)
                    continue
                if mode == "xctest" and "import XCTest" not in content:
                    continue  # standalone 脚本通道（无 XCTest，走 swift 脚本跑，无需挂载）
                # 5) 独立脚本式套件（带独立运行启动器）必须有执行入口，否则挂进工程也只编译不执行：
                #    要么文件自带测试类，要么在自动生成的桥接里（Support/StandaloneExecutableBridgeTests.swift）。
                #    2026-11-24 技术优化实锤：生成桥接后新提交的 48 个套件没人重新生成，一直没进自动测试。
                #    新增套件的三步见 HoloTests/Support/StandaloneSuiteBridge.swift 头注释。
                if ("@main" in content and "XCTestCase" not in content and "@Test" not in content
                        and "@Suite" not in content and fn in compiled_names and fn not in bridge_source):
                    errors.append(
                        "error: %s 是独立脚本式套件，但没有执行入口（挂进工程也只编译不执行）——"
                        "在 scripts/xctest-bridge-allowlist.txt 登记文件名后重跑 "
                        "ruby scripts/generate-standalone-xctest-bridge.rb 重新生成桥接"
                        % os.path.relpath(path, SRCROOT)
                    )
                if fn not in compiled_names:
                    unmounted.append(os.path.relpath(path, SRCROOT))
                    if fn in pbx:
                        errors.append(
                            "error: %s 在 pbxproj 里出现过，却不在 %s 的 Sources 编译相位里（半挂载，静默不编译）——"
                            "用 python3 BuildScripts/pbxproj_surgery.py mount --file %s 重新挂载"
                            % (os.path.relpath(path, SRCROOT), dirname, os.path.relpath(path, SRCROOT))
                        )
        if total < MIN_EXPECTED.get(dirname, 0):
            errors.append(
                "error: Test Mount Guard 在 %s 只见到 %d 个 .swift（预期数百），"
                "疑似沙箱拦截读取——闸门失效按失败处理（fail-closed）" % (dirname, total)
            )
        for fn, paths in seen_names.items():
            if len(paths) > 1:
                errors.append(
                    "error: %s 下存在同名文件 %s ×%d：%s —— 挂载判定按文件名匹配，"
                    "同名会互相掩护漏挂。请改名保证唯一（fail-closed）"
                    % (dirname, fn, len(paths), "; ".join(paths))
                )

    if update_baseline:
        with open(BASELINE_PATH, "w", encoding="utf-8") as fp:
            json.dump({"unmounted": sorted(unmounted)}, fp, ensure_ascii=False, indent=2)
        print("Test Mount Guard: 基线已更新（存量未挂载 %d 个冻结，挂载专项收口后再收缩）" % len(unmounted))
        return

    baseline = set()
    if os.path.exists(BASELINE_PATH):
        try:
            with open(BASELINE_PATH, encoding="utf-8") as fp:
                baseline = set(json.load(fp).get("unmounted", []))
        except (OSError, ValueError):
            print("error: 基线文件损坏，先跑 --update-baseline 重建（fail-closed）", file=sys.stderr)
            sys.exit(1)

    for rel in unmounted:
        if rel in baseline:
            continue
        errors.append(
            "error: %s 未挂进工程（手工组，新文件必须挂 pbxproj 才会编译执行，"
            "否则测试静默消失、报告假绿——复犯坑族1/族2）。挂载验证：grep -c 文件名 Holo.xcodeproj/project.pbxproj ≥1；"
            "挂完 plutil -lint + xcodebuild -list 双验；存量挂载走专项批次" % rel
        )

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)
    print(
        "Test Mount Guard: 新文件挂载完好（存量挂账 %d 个在基线内，挂载专项收口后收缩）" % len(
            [r for r in unmounted if r in baseline]
        )
    )


if __name__ == "__main__":
    main()
