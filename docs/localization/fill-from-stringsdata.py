#!/usr/bin/env python3
"""把构建中间产物 .stringsdata 里的词条汇总写回 String Catalog 词表。

背景：命令行 xcodebuild 会为每个源文件产出 .stringsdata（编译器提取的文案），
但不会写回工程内词表（该行为只在 Xcode GUI 构建发生）。本脚本补齐这一环，
使整条流水线不依赖 GUI：

  xcodebuild build → fill-from-stringsdata.py → fill-zh-hant.sh

多 target 分流：stringsdata 的路径含 /<Target>.build/，按 target 写进各自的词表。
已有词条的翻译（zh-Hant 等）不会被覆盖；新词条以「未翻译」状态进入词表。

用法: python3 fill-from-stringsdata.py <derivedDataPath> <主App词表> [小组件词表 ...]
      词表参数按 target 名匹配：Holo.build → 第一个词表，HoloWidgets.build → 含 Widgets 的词表
"""
import glob
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, catalog):
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    with open(path, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main(derived_data, main_catalog_path, *extra_catalog_paths):
    catalogs = {"main": load(main_catalog_path)}
    for p in extra_catalog_paths:
        if "Widget" in p:
            catalogs["widgets"] = load(p)
        else:
            catalogs["main"] = load(p)  # 多主表场景合并目标

    stats = {k: [0, 0, 0] for k in catalogs}  # added, merged, skipped
    for sd in glob.glob(f"{derived_data}/Build/Intermediates.noindex/**/*.stringsdata",
                        recursive=True):
        if "/HoloWidgets.build/" in sd:
            bucket, catalog = "widgets", catalogs.get("widgets")
        elif "/HoloTests" in sd or "/HoloUITests" in sd:
            continue
        else:
            bucket, catalog = "main", catalogs["main"]
        if catalog is None:
            continue
        try:
            data = json.load(open(sd))
        except (json.JSONDecodeError, OSError):
            continue
        for e in data.get("tables", {}).get("Localizable", []):
            key = e["key"]
            strings = catalog.setdefault("strings", {})
            if key not in strings:
                strings[key] = {}
                stats[bucket][0] += 1
            else:
                stats[bucket][1] += 1

    for name, catalog, path in (
        [("main", catalogs["main"], main_catalog_path)] +
        [("widgets", v, p) for p, v in
         ((p, catalogs["widgets"]) for p in extra_catalog_paths if "Widget" in p)]
    ):
        save(path, catalog)
        a, m, _ = stats[name]
        print(f"✅ [{path.rsplit('/', 1)[-1]}] 新增 {a} 条，已有 {m} 条保持不动，共 {len(catalog['strings'])} 条")


if __name__ == "__main__":
    main(*sys.argv[1:])
