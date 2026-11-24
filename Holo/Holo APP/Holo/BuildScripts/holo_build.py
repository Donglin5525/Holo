#!/usr/bin/python3
# holo_build / holo_test 统一包装 —— 防构建假成功 + 测试计数强制 + 构建秩序
#（2026-11-16 随机器守门体系设立，复犯坑总档族2「测试假绿」根治件之一；
# 2026-11-24 随「全量技术优化一轮」增设构建秩序：排队锁 / 低优先级 / 产物目录固定复用 / 具体模拟器目标）
#
# 病：
#   - xcodebuild 输出管道 grep/tail 接 && 吃掉 exit code → 编译红也报绿（多次实锤）
#   - -only-testing 前缀写错 → 0 tests 仍 TEST SUCCEEDED（20+ 次假绿）
#   - 多会话同时跑 xcodebuild，15 核被叠加构建打满 → 东林的 Xcode / 整机卡顿（2026-11-24 摸底实锤）
#   - 每个任务新开一份 DerivedData → 每次全量重编，磁盘被几十份产物撑爆
#     （2026-11-24 实测：仓库内 15 份 + Xcode 目录下 40 份，合计约 100GB，硬盘用到 95%）
#   - build 默认 generic 模拟器目标 → 1779 个文件每个编两遍（arm64 + x86_64）
#     （2026-11-24 实测全量 152.6s，指定具体模拟器 103.5s）
#
# 用法（BuildScripts 目录下）：
#   ./holo_build.py build  [-scheme Holo] [-config Debug] [-dest 'platform=iOS Simulator,name=iPhone 17'] [-dd 路径]
#   ./holo_build.py test   [-only HoloTests/XXX] [-expect N] [--workers 4]   # N=预期用例数，不填则只要求 N>0
#   ./holo_build.py ls     # 列出各工程副本的产物目录（工程路径 / 大小 / 上次使用）
#   ./holo_build.py gc [--days 14]   # 回收这么多天没用过的产物目录
#   ./holo_build.py archive [--config Release] [--archive-path 路径.xcarchive]   # 出归档包（真机可装）
#     默认 Release / generic iOS 设备 / 存到 Xcode 归档目录（Organizer 里能看到）；
#     判定 = exit 0 + "** ARCHIVE SUCCEEDED **" + 无编译错误 + 包里真有 Holo.app
#   test 默认开并行（-parallel-testing-enabled YES + 4 个并发模拟器 worker），--workers 0 关闭
# 构建秩序：
#   - 排队：全机同一时间只跑一个构建/测试。别的 holo_build 在跑 → 排队等；别的裸 xcodebuild 在跑 →
#     也等它结束（最多等 30 分钟）。Xcode 界面构建不在此列——东林自己的 Run 永远不用排队。
#   - 让路：xcodebuild 以低优先级（nice 10）运行，东林本人点 Run / 用电脑时系统优先响应他。
#   - 产物目录：--dd 不填时按「工程所在路径」固定一份（/tmp/holo_dd/<路径哈希>），跨会话复用，
#     增量编译才生效；不同工程副本互不污染；闲置的由 gc 回收。
#   - 诊断用附加参数：环境变量 HOLO_XCODEBUILD_ARGS（如 "-resultBundlePath /tmp/x.xcresult"），
#     只给排查/实验用，日常不要设。
# 判定（三者缺一不可）：
#   build：exit code 0 + 输出含 "** BUILD SUCCEEDED **" + 无 "\.swift:.*: error"
#   test ：exit code 0 + "** TEST SUCCEEDED **" + 用例计数与预期相符（默认 N>0）
#   archive：exit code 0 + "** ARCHIVE SUCCEEDED **" + 无编译错误 + 包内存在 Holo.app
#          计数以逐用例行（Test Case '...' passed/failed/skipped）为准——并行模式下
#          "Executed N tests" 汇总被 clone 拆散、max() 会低估，逐用例行不重复最可靠
# 退出码：0=真绿；1=假绿/失败（stderr 摘要）。
# 以后所有会话跑构建/测试一律走本包装（写入工作区 AGENTS.md）。

import argparse
import fcntl
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRCROOT = os.path.dirname(HERE)  # BuildScripts 的上级 = xcodeproj 所在

DD_ROOT = "/tmp/holo_dd"                      # 所有工程副本的产物目录统一放这里（重启自动清空）
LOCK_PATH = os.path.join(DD_ROOT, ".build.lock")
NICE = shlex.split(os.environ.get("HOLO_BUILD_NICE", "nice -n 10"))   # 让路：低优先级跑，界面优先
                                                    # （HOLO_BUILD_NICE="nice -n 0" 可关闭，只给对照实验用）
DEFAULT_DEST = "platform=iOS Simulator,name=iPhone 17"   # 具体机型；generic 会把每个文件编两遍
FOREIGN_WAIT_SECONDS = 30 * 60                # 等别人裸跑的 xcodebuild 的上限
GC_DAYS_DEFAULT = 14                          # 产物目录闲置多少天后回收


DEFAULT_ARCHIVE_DEST = "generic/platform=iOS"


def default_archive_path(config):
    """归档包默认落点：Xcode 归档目录下按日期分目录（Organizer 里直接能看到）。"""
    day = time.strftime("%Y-%m-%d")
    name = "Holo-%s-%s.xcarchive" % (config, time.strftime("%Y%m%d-%H%M%S"))
    return os.path.expanduser("~/Library/Developer/Xcode/Archives/%s/%s" % (day, name))


def default_dd():
    """按工程路径哈希固定一份产物目录：同一工程副本的所有会话共用（增量生效），不同副本互不污染。"""
    key = hashlib.sha1(os.path.realpath(SRCROOT).encode("utf-8")).hexdigest()[:12]
    return os.path.join(DD_ROOT, key)


def wait_foreign_xcodebuild():
    """别的会话绕过本包装直接跑的 xcodebuild：等它结束，不叠加抢核。"""
    waited = 0
    while subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0:
        if waited == 0:
            print("holo_build: 检测到另一个 xcodebuild 正在运行（别的会话），等它结束再开始…", file=sys.stderr)
        time.sleep(10)
        waited += 10
        if waited >= FOREIGN_WAIT_SECONDS:
            print("holo_build: 已等满 %d 分钟，不再等，开始构建" % (FOREIGN_WAIT_SECONDS // 60), file=sys.stderr)
            break


def acquire_lock():
    """全机排队锁。进程退出即自动释放，不会留死锁；拿到锁的句柄必须持有到进程结束。"""
    os.makedirs(DD_ROOT, exist_ok=True)
    fp = open(LOCK_PATH, "w")
    try:
        fcntl.flock(fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("holo_build: 另一个 Holo 构建/测试正在进行，排队等待（同一时间只跑一个）…", file=sys.stderr)
        fcntl.flock(fp, fcntl.LOCK_EX)
    return fp


def mark_used(dd):
    """记下这份产物目录的归属工程与最近使用时间（ls 展示用、gc 判定用）。"""
    os.makedirs(dd, exist_ok=True)
    with open(os.path.join(dd, ".holo_srcroot"), "w") as f:
        f.write(SRCROOT + "\n")
    open(os.path.join(dd, ".holo_last_used"), "w").close()


def dd_dirs():
    if not os.path.isdir(DD_ROOT):
        return []
    return sorted(
        os.path.join(DD_ROOT, n) for n in os.listdir(DD_ROOT)
        if not n.startswith(".") and os.path.isdir(os.path.join(DD_ROOT, n))
    )


def days_idle(dd):
    marker = os.path.join(dd, ".holo_last_used")
    try:
        return (time.time() - os.stat(marker).st_mtime) / 86400
    except OSError:
        # 旧目录没有标记：按目录自身修改时间算
        return (time.time() - os.stat(dd).st_mtime) / 86400


def srcroot_of(dd):
    try:
        with open(os.path.join(dd, ".holo_srcroot")) as f:
            return f.read().strip()
    except OSError:
        return "（未知工程）"


def size_gb(path):
    r = subprocess.run(["du", "-sk", path], capture_output=True, text=True)
    try:
        return int(r.stdout.split()[0]) / 1048576
    except (IndexError, ValueError):
        return 0.0


def cmd_ls():
    dirs = dd_dirs()
    if not dirs:
        print("还没有产物目录（%s）" % DD_ROOT)
        return
    print("%-14s %8s  %-10s %s" % ("目录", "大小GB", "闲置天数", "工程路径"))
    total = 0.0
    for d in dirs:
        gb = size_gb(d)
        total += gb
        print("%-14s %8.1f  %-10.1f %s" % (os.path.basename(d), gb, days_idle(d), srcroot_of(d)))
    print("合计 %.1f GB；gc 回收 %d 天没用过的目录" % (total, GC_DAYS_DEFAULT))


def cmd_gc(days):
    freed = 0.0
    for d in dd_dirs():
        idle = days_idle(d)
        if idle < days:
            continue
        freed += size_gb(d)
        shutil.rmtree(d, ignore_errors=True)
        print("已回收 %s（闲置 %.0f 天）" % (d, idle))
    print("holo_gc: 回收 %.1f GB；保留 %d 份在用目录" % (freed, len(dd_dirs())))


ERROR_RE = re.compile(r"\.swift:\d+:\d+: error: ")
# 用例结果行有两种控制台格式（Xcode 26.3 起控制台只输出第二种；旧格式继续兼容）：
#   Test Case '-[HoloTests.Xxx testYyy]' passed (1.2 seconds)
#   Test case 'Xxx.testYyy()' passed on 'Clone 1 of iPhone 17 - Holo (92944)' (0.034 seconds)
# 只认旧格式的话，升级后每次测试都会被误判成「实际执行 0 个用例」（2026-11-24 技术优化实锤并修正）
CASE_RE = re.compile(r"Test [Cc]ase '.*?' (passed|failed|skipped)")
EXECUTED_RE = re.compile(r"Executed (\d+) tests?, with (\d+) failure")


def run(cmd, live_log):
    """流式执行：输出直接写进 live_log（长测试随时能看进度，不把整份输出攒在内存里），返回退出码。"""
    print("+ " + " ".join(cmd), file=sys.stderr)
    print("实时输出: %s" % live_log, file=sys.stderr)
    with open(live_log, "w") as log:
        proc = subprocess.run(NICE + cmd, stdout=log, stderr=subprocess.STDOUT)
    return proc.returncode


def scan_log(path):
    """跑完后逐行扫描 xcodebuild 输出，得到判定所需的全部事实。"""
    facts = {"build_succeeded": False, "test_succeeded": False, "archive_succeeded": False,
             "errors": [], "cases": [], "executed": []}
    with open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            if "** BUILD SUCCEEDED **" in line:
                facts["build_succeeded"] = True
            elif "** TEST SUCCEEDED **" in line:
                facts["test_succeeded"] = True
            elif "** ARCHIVE SUCCEEDED **" in line:
                facts["archive_succeeded"] = True
            if ERROR_RE.search(line):
                facts["errors"].append(line.strip())
            if line.startswith(("Test Case '", "Test case '")):
                m = CASE_RE.search(line)
                if m:
                    facts["cases"].append(m.group(1))
            m = EXECUTED_RE.search(line)
            if m:
                facts["executed"].append((int(m.group(1)), int(m.group(2))))
    return facts


def main():
    global GC_DAYS_DEFAULT
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["build", "test", "archive", "ls", "gc"])
    ap.add_argument("--scheme", default="Holo")
    ap.add_argument("--config", default=None, help="默认：build/test 用 Debug，archive 用 Release")
    ap.add_argument("--dest", default=None,
                    help="默认：具体模拟器 iPhone 17（generic 目标会把每个文件编两遍，不要用于日常构建）")
    ap.add_argument("--dd", default=None,
                    help="默认：/tmp/holo_dd/<工程路径哈希>（同一工程副本的会话共用，增量生效）")
    ap.add_argument("--only", help="-only-testing 过滤，如 HoloTests/TopicRepositoryDeleteTests")
    ap.add_argument("--expect", type=int, default=0, help="预期执行用例数（0=只要求>0）")
    ap.add_argument("--workers", type=int, default=4,
                    help="并行测试 worker 数（默认 4；0=串行）")
    ap.add_argument("--days", type=int, default=14, help="gc：回收多少天没用过的产物目录")
    ap.add_argument("--log", help="把 xcodebuild 完整输出落盘到该路径（诊断用）")
    ap.add_argument("--archive-path", default=None, help="archive：归档包路径（默认存到 Xcode 归档目录）")
    args = ap.parse_args()

    GC_DAYS_DEFAULT = args.days
    if args.mode == "ls":
        cmd_ls()
        return
    if args.mode == "gc":
        cmd_gc(args.days)
        return

    is_archive = args.mode == "archive"
    args.config = args.config or ("Release" if is_archive else "Debug")
    args.dest = args.dest or (DEFAULT_ARCHIVE_DEST if is_archive else DEFAULT_DEST)
    args.dd = args.dd or default_dd()
    args.archive_path = args.archive_path or default_archive_path(args.config)
    started = time.time()

    wait_foreign_xcodebuild()
    lock = acquire_lock()  # noqa: F841  持有到进程结束
    mark_used(args.dd)

    project = os.path.join(SRCROOT, "Holo.xcodeproj")
    base = ["xcodebuild", "-project", project, "-scheme", args.scheme,
            "-configuration", args.config, "-destination", args.dest,
            "-derivedDataPath", args.dd, "-showBuildTimingSummary"]
    extra = shlex.split(os.environ.get("HOLO_XCODEBUILD_ARGS", ""))
    if args.mode == "build":
        cmd = base + ["build"] + extra
    elif is_archive:
        cmd = base + ["archive", "-archivePath", args.archive_path] + extra
    else:
        cmd = base + ["test"]
        if args.workers > 0:
            cmd += ["-parallel-testing-enabled", "YES",
                    "-parallel-testing-worker-count", str(args.workers)]
        if args.only:
            cmd += ["-only-testing:" + args.only]
        cmd += extra

    # 输出边跑边落盘；没给 --log 时用一份临时日志，判定完即删
    live_log = args.log or os.path.join(DD_ROOT, "holo_build_live.log")
    os.makedirs(DD_ROOT, exist_ok=True)
    rc = run(cmd, live_log)
    facts = scan_log(live_log)
    if not args.log:
        os.remove(live_log)
    print("holo_build: 用时 %.1fs（产物目录 %s）" % (time.time() - started, args.dd), file=sys.stderr)

    fail = []
    if rc != 0:
        fail.append("xcodebuild 退出码 %d" % rc)
    is_test = args.mode == "test"
    mark = {"test": "** TEST SUCCEEDED **", "archive": "** ARCHIVE SUCCEEDED **"}.get(args.mode, "** BUILD SUCCEEDED **")
    succeeded = facts["test_succeeded"] if is_test else facts["archive_succeeded"] if is_archive else facts["build_succeeded"]
    if not succeeded:
        fail.append("输出缺少 %s 标记" % mark)
    if is_archive and succeeded:
        app_in_archive = os.path.join(args.archive_path, "Products", "Applications", "Holo.app")
        if not os.path.isdir(app_in_archive):
            fail.append("归档包里没有 Holo.app（%s）——包不完整" % app_in_archive)
        else:
            print("holo_archive: 包内应用 %s" % app_in_archive, file=sys.stderr)
            print("holo_archive: 归档路径 %s" % args.archive_path, file=sys.stderr)
    errors = facts["errors"]
    if errors:
        fail.append("存在 %d 条编译错误" % len(errors))
        for e in errors[:5]:
            print("  " + e, file=sys.stderr)

    if is_test:
        # 逐用例计数：每条用例恰好一行 ended 行（passed/failed/skipped），并行下也不重复
        cases = facts["cases"]
        executed = facts["executed"]
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
        args.mode, "用例数符合预期" if is_test else "包内有 Holo.app" if is_archive else "无编译错误"))


if __name__ == "__main__":
    main()
