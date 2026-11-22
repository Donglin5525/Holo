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
#   ./holo_build.py test   [-only HoloTests/XXX] [-expect N] [--workers 4]   # N=预期用例数，不填则只要求 N>0
#   test 默认开并行（-parallel-testing-enabled YES + 4 个并发模拟器 worker），--workers 0 关闭
# 判定（三者缺一不可）：
#   build：exit code 0 + 输出含 "** BUILD SUCCEEDED **" + 无 "\.swift:.*: error"
#   test ：exit code 0 + "** TEST SUCCEEDED **" + 用例计数与预期相符（默认 N>0）
#          计数以逐用例行（Test Case '...' passed/failed/skipped）为准——并行模式下
#          "Executed N tests" 汇总被 clone 拆散、max() 会低估，逐用例行不重复最可靠
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


def maybe_log(path, out):
    if path:
        with open(path, "w") as f:
            f.write(out)
        print("完整输出已落盘: %s" % path, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["build", "test"])
    ap.add_argument("--scheme", default="Holo")
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--dest", default=None,
                    help="默认：build=generic 模拟器；test=具体模拟器 iPhone 17（generic 跑不了测试）")
    ap.add_argument("--dd", default="/tmp/holo_dd_wrap")
    ap.add_argument("--only", help="-only-testing 过滤，如 HoloTests/TopicRepositoryDeleteTests")
    ap.add_argument("--expect", type=int, default=0, help="预期执行用例数（0=只要求>0）")
    ap.add_argument("--workers", type=int, default=4,
                    help="并行测试 worker 数（默认 4；0=串行）")
    ap.add_argument("--log", help="把 xcodebuild 完整输出落盘到该路径（诊断用）")
    args = ap.parse_args()
    if args.dest is None:
        args.dest = ("generic/platform=iOS Simulator" if args.mode == "build"
                     else "platform=iOS Simulator,name=iPhone 17")

    project = os.path.join(SRCROOT, "Holo.xcodeproj")
    base = ["xcodebuild", "-project", project, "-scheme", args.scheme,
            "-configuration", args.config, "-destination", args.dest,
            "-derivedDataPath", args.dd]
    if args.mode == "build":
        rc, out = run(base + ["build"])
    else:
        cmd = base + ["test"]
        if args.workers > 0:
            cmd += ["-parallel-testing-enabled", "YES",
                    "-parallel-testing-worker-count", str(args.workers)]
        if args.only:
            cmd += ["-only-testing:" + args.only]
        rc, out = run(cmd)

    maybe_log(args.log, out)

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
        # 逐用例计数：每条用例恰好一行 ended 行（passed/failed/skipped），并行下也不重复
        cases = re.findall(r"Test Case '.*?' (passed|failed|skipped)", out)
        executed = re.findall(r"Executed (\d+) tests?, with (\d+) failure", out)
        if cases:
            total = len(cases)
            failures = cases.count("failed")
            summary_src = "逐用例行"
        elif executed:
            # 兜底：老式汇总（串行模式；suite 级/bundle 级多行取最大值）
            total = max((int(n) for n, _ in executed), default=0)
            failures = max((int(f) for _, f in executed), default=0)
            summary_src = "Executed 汇总"
        else:
            total, failures, summary_src = 0, 0, ""
            fail.append("输出中找不到任何用例结果行 —— 用例可能静默没跑（假绿判据）")
        if failures > 0:
            fail.append("Executed tests with %d failures" % failures)
        if total == 0:
            fail.append("实际执行 0 个用例（-only-testing 前缀错？假绿）")
        elif args.expect > 0 and total != args.expect:
            fail.append("实际执行 %d 个用例 ≠ 预期 %d（用例静默消失=假绿）" % (total, args.expect))
        print("Executed %d tests，失败 %d（%s）" % (total, failures, summary_src), file=sys.stderr)

    if fail:
        print("holo_%s: 假绿/失败 —— %s" % (args.mode, "; ".join(fail)), file=sys.stderr)
        sys.exit(1)
    print("holo_%s: 真绿（exit0 + 成功标记 + 错误零 + %s）" % (
        args.mode, ("用例数符合预期" if args.mode == "test" else "无编译错误")))


if __name__ == "__main__":
    main()
