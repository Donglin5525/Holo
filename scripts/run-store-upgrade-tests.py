#!/usr/bin/env python3
"""使用生产模型工厂和生产装载门，验证真实 SQLite 63→65 升级及拒绝态。"""

import argparse
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1] / "Holo/Holo APP/Holo"
MODELS = ROOT / "Holo/Models"


def declaration(source, pattern):
    match = re.search(pattern, source)
    opening = source.index("{", match.end() - 1)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


def model_type_support(factories):
    text = "\n".join(p.read_text() for p in factories)
    all_sources = [p.read_text() for p in MODELS.rglob("*.swift")]
    support = "import Foundation\nimport CoreData\n"
    # 工厂只用 rawValue：从实际枚举提取 case 原文；不复制 UI 方法或自行编造默认值。
    for name in sorted(set(re.findall(r"\b([A-Z]\w+)\.\w+\.rawValue", text))):
        source = next(s for s in all_sources if re.search(r"\benum " + name + r"\b", s))
        definition = declaration(source, r"\benum " + name + r"\b[^\{]*\{")
        if name == "AnniversaryType":
            support += definition + "\n"  # 工厂还读取 defaultEmoji/defaultColor。
            continue
        cases = []
        for line in definition.splitlines():
            line = line.split("//")[0].strip()
            if re.match(r"^case\s+[A-Za-z]\w*(?:\s*=|\s*,|\s*$)", line):
                cases.append(line)
        assert cases, name
        support += f"nonisolated enum {name}: String {{\n" + "\n".join(cases) + "\n}\n"
    for name in ["MatterSchemaDefaults", "HoloTodayPlanSchemaDefaults"]:
        source = next(s for s in all_sources if re.search(r"\benum " + name + r"\b", s))
        support += declaration(source, r"\bnonisolated enum " + name + r"\b[^\{]*\{") + "\n"
    classes = set(re.findall(r"NSStringFromClass\((\w+)\.self\)", text))
    classes.update(re.findall(r'managedObjectClassName\s*=\s*"(\w+)"', text))
    defined = set(re.findall(r"\bclass\s+(\w+)\s*:", text))
    # 空壳只提供与生产一致的 ObjC 类名。实体、属性、索引和关系全部使用生产工厂原文。
    for name in sorted(classes - defined - {"NSManagedObject"}):
        support += f"@objc({name}) nonisolated class {name}: NSManagedObject {{}}\n"
    support += 'nonisolated enum CloudKitRuntimeAvailability { static let isAvailable = false; static let containerIdentifier = "unused" }\n'
    return support


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-output", type=Path, help="保留旧库合成夹具，供无窗口模拟器升级走查")
    args = parser.parse_args()
    factories = sorted(MODELS.glob("CoreDataStack+*.swift"))
    with tempfile.TemporaryDirectory(prefix="holo-store-upgrade-") as temporary:
        work = Path(temporary)
        types = work / "Types.swift"
        types.write_text(model_type_support(factories))
        executable = work / "upgrade-tests"
        subprocess.run([
            "swiftc", "-parse-as-library", "-module-cache-path", str(work / "modules"),
            "-module-name", "Holo", str(MODELS / "CoreDataStack.swift"),
            str(MODELS / "CoreDataStoreUpgrade.swift"), *map(str, factories), str(types),
            str(ROOT / "HoloTests/Models/CoreDataKnownUpgradeStandaloneTests.swift"),
            "-o", str(executable)
        ], check=True)

        def run(mode, directory):
            result = subprocess.run([str(executable), mode, str(directory)], capture_output=True, text=True, timeout=45)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            print(result.stdout.strip(), flush=True)

        legacy = work / "legacy"
        run("seed", legacy)
        # seed 进程已退出，复制封闭的合成 store 与外置 BLOB；不读写 AppGroup 或个人原库。
        def fixture(name, source=legacy):
            path = work / name
            path.mkdir()
            for item in source.iterdir():
                if item.name == "StoreUpgradeBackups" or item.name.endswith("-backup.txt"):
                    continue
                if item.is_dir():
                    shutil.copytree(item, path / item.name)
                else:
                    shutil.copy2(item, path / item.name)
            return path

        wal_backup = Path((legacy / "wal-backup.txt").read_text())
        (legacy / "backup-to-verify.txt").write_text(str(wal_backup))
        run("verify-backup", legacy)
        upgraded = fixture("upgrade")
        run("upgrade", upgraded)
        backups = list((upgraded / "StoreUpgradeBackups").glob("*/HoloDataModel.sqlite"))
        assert len(backups) == 1, backups
        (upgraded / "backup-to-verify.txt").write_text(str(backups[0]))
        run("verify-backup", upgraded)
        run("reopen", upgraded)
        assert len(list((upgraded / "StoreUpgradeBackups").glob("*/HoloDataModel.sqlite"))) == 1
        # 多跳纯加表升级（比白名单时代多出的第三张新表）也必须先备份后放行（2026-10-31 S1）
        run("wide-additive", fixture("wide-additive"))
        for mode in ["unknown", "backup-failure", "locked-wal"]:
            run(mode, fixture(mode))
        # 正常关闭可删除 WAL/SHM；系统 SQLite 的只读连接必须也能处理这个常见状态。
        closed = work / "closed-wal"
        closed.mkdir()
        source = sqlite3.connect(f"file:{legacy / 'HoloDataModel.sqlite'}?mode=ro", uri=True)
        target = sqlite3.connect(closed / "HoloDataModel.sqlite")
        source.backup(target)
        target.close()
        source.close()
        shutil.copytree(legacy / ".HoloDataModel_SUPPORT", closed / ".HoloDataModel_SUPPORT")
        shutil.copy2(legacy / "snapshot.json", closed / "snapshot.json")
        assert not (closed / "HoloDataModel.sqlite-wal").exists()
        run("upgrade", closed)
        print("PASS 无 WAL/SHM 的完整旧库也可安全备份并升级", flush=True)
        newer = work / "newer"
        run("seed-new", newer)
        run("downgrade", fixture("downgrade", newer))
        if args.fixture_output:
            assert not args.fixture_output.exists(), "夹具输出目录已存在，不覆盖"
            shutil.copytree(legacy, args.fixture_output)
            print(f"旧库合成夹具：{args.fixture_output}")
        print("PASS：真实 63→65 增量升级、全部旧字段/关系/对象 URI/外置附件、WAL 备份、重复打开、拒绝降级及备份失败保护")


if __name__ == "__main__":
    main()
