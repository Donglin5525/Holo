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
BASELINE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_mount_baseline.json")


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

    for scan_dir, mode in SCAN:
        dirname = os.path.basename(scan_dir)
        total = 0
        seen_names = {}
        try:
            entries = os.walk(scan_dir)
        except OSError:
            errors.append("error: Test Mount Guard 读不到 %s（fail-closed）" % scan_dir)
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
                if fn not in pbx:
                    unmounted.append(os.path.relpath(path, SRCROOT))
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
