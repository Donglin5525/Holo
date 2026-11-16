#!/usr/bin/python3
# holo_build / holo_test 统一包装 —— 防构建假成功 + 测试计数强制
#（2026-11-16 随机器守门体系设立，复犯坑总档族2「测试假绿」根治件之一）
#
# 病：
#   - xcodebuild 输出管道 grep/tail 接 && 吃掉 exit code → 编译红也报绿（多次实锤）
#   - -only-testing 前缀写错 → 0 tests 仍 TEST SUCCEEDED（20+ 次假绿）
#
# 用法（BuildScripts 目录下）：
#   ./holo_build.py build  [-scheme Holo] [-config Debug] [-dest 'generic/platform=iOS Simulator'] [-dd 路径]
#   ./holo_build.py test   [-only HoloTests/XXX] [-expect N]   # N=预期用例数，不填则只要求 N>0
# 判定（三者缺一不可）：
#   build：exit code 0 + 输出含 "** BUILD SUCCEEDED **" + 无 "\.swift:.*: error"
#   test ：exit code 0 + "** TEST SUCCEEDED **" + 每个 "Executed N tests" 的 N 与预期相符（默认 N>0）
# 退出码：0=真绿；1=假绿/失败（stderr 摘要）。
# 以后所有会话跑构建/测试一律走本包装（写入工作区 AGENTS.md）。

import argparse
import re
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRCROOT = os.path.dirname(HERE)  # BuildScripts 的上级 = xcodeproj 所在


def run(cmd):
    print("+ " + " ".join(cmd), file=sys.stderr)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["build", "test"])
    ap.add_argument("--scheme", default="Holo")
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--dest", default="generic/platform=iOS Simulator")
    ap.add_argument("--dd", default="/tmp/holo_dd_wrap")
    ap.add_argument("--only", help="-only-testing 过滤，如 HoloTests/TopicRepositoryDeleteTests")
    ap.add_argument("--expect", type=int, default=0, help="预期执行用例数（0=只要求>0）")
    args = ap.parse_args()

    project = os.path.join(SRCROOT, "Holo.xcodeproj")
    base = ["xcodebuild", "-project", project, "-scheme", args.scheme,
            "-configuration", args.config, "-destination", args.dest,
            "-derivedDataPath", args.dd]
    if args.mode == "build":
        rc, out = run(base + ["build"])
    else:
        cmd = base + ["test"]
        if args.only:
            cmd += ["-only-testing:" + args.only]
        rc, out = run(cmd)

    fail = []
    if rc != 0:
        fail.append("xcodebuild 退出码 %d" % rc)
    succeeded_mark = "** BUILD SUCCEEDED **" if args.mode == "build" else "** TEST SUCCEEDED **"
    if succeeded_mark not in out:
        fail.append("输出缺少 %s 标记" % succeeded_mark)
    errors = re.findall(r"[^\s]+\.swift:\d+:\d+: error: .*", out)
    if errors:
        fail.append("存在 %d 条编译错误" % len(errors))
        for e in errors[:5]:
            print("  " + e, file=sys.stderr)

    if args.mode == "test":
        executed = re.findall(r"Executed (\d+) tests?, with (\d+) failure", out)
        if not executed:
            fail.append("输出中找不到任何 'Executed N tests' —— 用例可能静默没跑（假绿判据）")
        # xcodebuild 对同一批用例输出多级 summary（suite 级/bundle 级），
        # 取最大值 = bundle 级真实总数（sum 会重复计数，实测同批 6 用例输出 2~3 行）
        total = max((int(n) for n, _ in executed), default=0)
        failures = max((int(f) for _, f in executed), default=0)
        if failures > 0:
            fail.append("Executed tests with %d failures" % failures)
        if executed:
            if args.expect > 0 and total != args.expect:
                fail.append("实际执行 %d 个用例 ≠ 预期 %d（用例静默消失=假绿）" % (total, args.expect))
            if total == 0:
                fail.append("实际执行 0 个用例（-only-testing 前缀错？假绿）")
        print("Executed %d tests（bundle 级汇总，失败 %d）" % (total, failures), file=sys.stderr)

    if fail:
        print("holo_%s: 假绿/失败 —— %s" % (args.mode, "; ".join(fail)), file=sys.stderr)
        sys.exit(1)
    print("holo_%s: 真绿（exit0 + 成功标记 + 错误零 + %s）" % (
        args.mode, ("用例数符合预期" if args.mode == "test" else "无编译错误")))


if __name__ == "__main__":
    main()
