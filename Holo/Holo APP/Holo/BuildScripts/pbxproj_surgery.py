#!/usr/bin/python3
# pbxproj 手术工具 —— 四连固化（2026-11-16 随机器守门体系设立）
#
# 病（复犯坑总档族1，30+ 次实锤）：手改 Holo.xcodeproj/project.pbxproj 翻车谱——
#   锚点 replace 静默空转、手写 ID 漂移/撞号、plutil 过了但 Xcode 读不了、
   # 脚本重放丢并行会话挂载不可找回。
#
# 固化流程（本工具强制，任何一步失败自动回滚）：
#   1) 备份到 /tmp（带时间戳）并 ls 验证备份存在
#   2) 锚点替换必须 count==期望值（防静默空转）
#   3) plutil -lint 语法验证
#   4) xcodebuild -list 工程可读验证（plutil 过 ≠ Xcode 能读）
#
# 用法：
#   ./pbxproj_surgery.py replace --old 'CURRENT_PROJECT_VERSION = 57;' --new 'CURRENT_PROJECT_VERSION = 58;' --count 4
#   ./pbxproj_surgery.py insert  --anchor '锚点整行' --lines '要插入的行\n第二行' --expect-count 1
# 以后所有 pbxproj 手术一律走本工具（写入工作区 AGENTS.md）；直接手编 = 违规。

import argparse
import os
import shutil
import subprocess
import sys
import time

SRCROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(SRCROOT, "Holo.xcodeproj", "project.pbxproj")


def backup():
    stamp = time.strftime("%Y%m%d_%H%M%S")
    dst = "/tmp/pbxproj_surgery_%s.bak" % stamp
    shutil.copy2(PBXPROJ, dst)
    if not os.path.exists(dst) or os.path.getsize(dst) == 0:
        print("error: 备份失败（%s 不存在或为空），手术中止" % dst, file=sys.stderr)
        sys.exit(1)
    print("备份 OK: %s (%d bytes)" % (dst, os.path.getsize(dst)), file=sys.stderr)
    return dst


def verify():
    r = subprocess.run(["plutil", "-lint", PBXPROJ], capture_output=True, text=True)
    if r.returncode != 0:
        return "plutil -lint 失败: %s" % r.stdout.strip()
    r = subprocess.run(
        ["xcodebuild", "-project", os.path.dirname(PBXPROJ), "-list"],
        capture_output=True, text=True, cwd=SRCROOT,
    )
    if r.returncode != 0 or "Schemes:" not in (r.stdout or ""):
        return "xcodebuild -list 读不了工程（plutil 过 ≠ Xcode 能读）: %s" % (r.stderr or "")[:200]
    return None


def rollback(bak):
    shutil.copy2(bak, PBXPROJ)
    print("已回滚到备份 %s" % bak, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_rep = sub.add_parser("replace")
    p_rep.add_argument("--old", required=True)
    p_rep.add_argument("--new", required=True)
    p_rep.add_argument("--count", type=int, default=1)
    p_ins = sub.add_parser("insert")
    p_ins.add_argument("--anchor", required=True, help="锚点整行（必须唯一出现）")
    p_ins.add_argument("--lines", required=True, help="要插入的行（\\n 分隔），插在锚点行之后")
    args = ap.parse_args()

    bak = backup()
    with open(PBXPROJ, encoding="utf-8") as fp:
        s = fp.read()

    try:
        if args.cmd == "replace":
            n = s.count(args.old)
            if n != args.count:
                raise RuntimeError("锚点出现 %d 次 ≠ 期望 %d（防静默空转断言失败）" % (n, args.count))
            s = s.replace(args.old, args.new)
        else:
            n = s.count(args.anchor)
            if n != 1:
                raise RuntimeError("锚点出现 %d 次 ≠ 1（防撞锚断言失败）" % n)
            s = s.replace(args.anchor, args.anchor + "\n" + args.lines.replace("\\n", "\n"))
        with open(PBXPROJ, "w", encoding="utf-8") as fp:
            fp.write(s)
        err = verify()
        if err:
            raise RuntimeError(err)
    except Exception as e:
        rollback(bak)
        print("error: 手术失败已回滚 —— %s" % e, file=sys.stderr)
        sys.exit(1)

    print("pbxproj 手术成功（备份/断言/lint/xcodebuild 四连全过）")


if __name__ == "__main__":
    main()
