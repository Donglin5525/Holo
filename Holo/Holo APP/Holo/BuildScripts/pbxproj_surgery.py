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
#   ./pbxproj_surgery.py mount   --file HoloTests/Services/XTests.swift [--file …]   把源文件挂进所在目录对应的 target
#   ./pbxproj_surgery.py mount   --all-unmounted                              一次挂齐所有「该挂未挂」的测试文件
#     （挂载 = 构建文件 / 文件引用 / 分组 / Sources 相位四处登记一次到位；2026-11-24 随技术优化增设——
#       HoloTests 是手工组，新测试不挂就静默不跑，四处手工登记易漏；口径同 test_mount_guard.py）
# 以后所有 pbxproj 手术一律走本工具（写入工作区 AGENTS.md）；直接手编 = 违规。

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

SRCROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(SRCROOT, "Holo.xcodeproj", "project.pbxproj")
# 目录 → 该目录下源文件所属 target（手工组，文件不会自动进 target）
DIR_TARGETS = {"HoloTests": "HoloTests", "HoloUITests": "HoloUITests"}


def backup():
    """备份到 /tmp/pbxproj_surgery/<工程路径哈希>/ 下。按工程分目录：
    多会话、多副本共用同一个 /tmp 时，平铺的「时间戳.bak」会互相混淆——2026-11-24 实踩：
    从「最新一份备份」还原时拿到的是主工作区的工程文件，盖掉了隔离副本里自己的。"""
    tag = hashlib.sha1(SRCROOT.encode("utf-8")).hexdigest()[:12]
    folder = "/tmp/pbxproj_surgery/%s" % tag
    os.makedirs(folder, exist_ok=True)
    dst = os.path.join(folder, "%s.bak" % time.strftime("%Y%m%d_%H%M%S"))
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


def find_target(text, name):
    """返回 (Sources 相位 ID, path = <name> 的分组 ID)。"""
    m = re.search(
        r"\t\t[0-9A-Za-z]{24} /\* %s \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n(.*?)\n\t\t\};" % re.escape(name), text, re.S)
    phase = re.search(r"([0-9A-Za-z]{24}) /\* Sources \*/", m.group(1)) if m else None
    anchor = "\t\t\tpath = %s;\n" % name
    groups = re.findall(r"\t\t([0-9A-Za-z]{24}) /\* [^*\n]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n", text[:text.index(anchor)]) \
        if text.count(anchor) == 1 else []
    if not phase or not groups:
        raise RuntimeError("定位 target %s 的 Sources 相位/分组失败（相位=%s 分组=%s）" % (name, bool(phase), len(groups)))
    return phase.group(1), groups[-1]


def unmounted_test_files(text):
    """「该挂未挂」的测试文件，口径同 test_mount_guard.py：HoloTests 含 import XCTest 的必须挂；HoloUITests 全挂。"""
    jobs = {}
    for dirname, target in DIR_TARGETS.items():
        seen = {}
        for root, _dirs, names in os.walk(os.path.join(SRCROOT, dirname)):
            for fn in sorted(names):
                if not fn.endswith(".swift"):
                    continue
                path = os.path.join(root, fn)
                if fn in seen:
                    raise RuntimeError("%s 下存在同名文件：%s 与 %s——先改名保证唯一" % (dirname, seen[fn], path))
                seen[fn] = path
                if fn in text:
                    continue
                with open(path, encoding="utf-8") as fp:
                    if target == "HoloTests" and "import XCTest" not in fp.read():
                        continue  # 纯逻辑文件（独立脚本通道），无需挂载
                jobs.setdefault(target, []).append(os.path.relpath(path, SRCROOT))
    return jobs


def mount(text, jobs):
    """jobs: {target 名: [相对工程目录的文件路径]} → 四处登记后的新文本。"""
    used = set()

    def new_id(key):
        salt = 0
        while True:
            cand = hashlib.sha1(("holo-mount:%s:%d" % (key, salt)).encode("utf-8")).hexdigest()[:24].upper()
            if cand not in text and cand not in used:
                used.add(cand)
                return cand
            salt += 1

    build, refs, children, sources = [], [], {}, {}
    for target, paths in jobs.items():
        phase, group = find_target(text, target)
        for rel in sorted(paths):
            base = os.path.basename(rel)
            if base in text:
                raise RuntimeError("%s 已在工程里（或与已挂文件同名），先核对" % rel)
            sub = os.path.relpath(rel, target)
            fid, bid = new_id(rel + "#ref"), new_id(rel + "#build")
            path_txt = sub if re.match(r"^[A-Za-z0-9_./-]+$", sub) else '"%s"' % sub
            build.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };" % (bid, sub, fid, sub))
            refs.append("\t\t%s /* %s */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; "
                        "path = %s; sourceTree = \"<group>\"; };" % (fid, sub, path_txt))
            children.setdefault(group, []).append("\t\t\t\t%s /* %s */," % (fid, sub))
            sources.setdefault(phase, []).append("\t\t\t\t%s /* %s in Sources */," % (bid, sub))

    def insert_after(text, pattern, lines):
        """在 pattern（必须恰好匹配 1 次）之后插入若干行。"""
        if not lines:
            return text
            # 注：空列表直接返回，避免多出一个空行
        n = len(re.findall(pattern, text))
        if n != 1:
            raise RuntimeError("挂载锚点出现 %d 次 ≠ 1（防撞锚断言失败）：%s" % (n, pattern[:50]))
        end = re.search(pattern, text).end()
        if pattern.endswith(r"\n"):   # 锚点自带行尾：新行接在下一行开头，不产生空行
            return text[:end] + "\n".join(lines) + "\n" + text[end:]
        return text[:end] + "\n" + "\n".join(lines) + text[end:]

    text = insert_after(text, r"/\* Begin PBXBuildFile section \*/", build)
    text = insert_after(text, r"/\* Begin PBXFileReference section \*/", refs)
    for gid, lines in children.items():
        text = insert_after(text, r"\t\t%s /\* [^*\n]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n" % gid, lines)
    for pid, lines in sources.items():
        text = insert_after(text, r"\t\t%s /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n" % pid, lines)
    return text


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
    p_mnt = sub.add_parser("mount", help="把源文件挂进所在目录对应的 target（四处登记一次到位）")
    p_mnt.add_argument("--file", action="append", default=[], help="相对工程目录的路径，如 HoloTests/Services/XTests.swift；可重复")
    p_mnt.add_argument("--all-unmounted", action="store_true", help="挂载所有「该挂未挂」的测试文件")
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
        elif args.cmd == "insert":
            n = s.count(args.anchor)
            if n != 1:
                raise RuntimeError("锚点出现 %d 次 ≠ 1（防撞锚断言失败）" % n)
            s = s.replace(args.anchor, args.anchor + "\n" + args.lines.replace("\\n", "\n"))
        else:
            jobs = {}
            rels = list(args.file)
            if args.all_unmounted:
                for target, paths in unmounted_test_files(s).items():
                    rels.extend(paths)
            if not rels:
                print("没有需要挂载的文件")
                os.remove(bak)
                return
            for rel in rels:
                target = DIR_TARGETS.get(rel.split(os.sep)[0])
                if not target:
                    raise RuntimeError("%s 所在目录不是手工组（会自动进 target），无需挂载" % rel)
                if not os.path.isfile(os.path.join(SRCROOT, rel)):
                    raise RuntimeError("文件不存在：%s" % rel)
                jobs.setdefault(target, []).append(rel)
            s = mount(s, jobs)
            for rel in rels:  # 挂载核验：文件名至少出现在 4 行
                n = sum(1 for ln in s.split("\n") if os.path.basename(rel) in ln)
                if n < 4:
                    raise RuntimeError("%s 挂载后只出现在 %d 行（应 ≥4）" % (rel, n))
            print("已挂载 %d 个文件：%s" % (len(rels), "、".join(sorted(os.path.basename(r) for r in rels))), file=sys.stderr)
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
