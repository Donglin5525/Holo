#!/usr/bin/env python3
"""将财务图标 v3 压缩包导入 Xcode Asset Catalog 矢量资源。"""

import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("用法: import_finance_v3.py <zip> <assets-category-icons-dir>")
        return 2

    archive = Path(sys.argv[1]).expanduser()
    target = Path(sys.argv[2]).expanduser()
    target.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="holo-finance-v3-") as temp_dir:
        extracted = Path(temp_dir)
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(extracted)

        manifest_path = next(
            (extracted / name for name in ("icon_matches_v4.json", "icon_matches.json")
             if (extracted / name).is_file()),
            None,
        )
        if manifest_path is None:
            raise FileNotFoundError("找不到 icon_matches_v4.json 或 icon_matches.json")
        manifest = json.loads(manifest_path.read_text())
        keys = [item["key"] for item in manifest]
        if len(keys) != len(set(keys)):
            raise ValueError("icon_matches.json 含重复 key")

        for key in keys:
            source = next(
                (extracted / folder / f"{key}.svg" for folder in ("icons_v4", "icons_output")
                 if (extracted / folder / f"{key}.svg").is_file()),
                None,
            )
            if source is None:
                raise FileNotFoundError(key)

            imageset = target / f"{key}.imageset"
            imageset.mkdir(exist_ok=True)
            shutil.copyfile(source, imageset / f"{key}.svg")
            contents = {
                "images": [{"filename": f"{key}.svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                "properties": {
                    "preserves-vector-representation": True,
                    "template-rendering-intent": "template",
                },
            }
            (imageset / "Contents.json").write_text(
                json.dumps(contents, ensure_ascii=False, indent=2) + "\n"
            )

    print(f"已导入 {len(keys)} 个财务图标资源")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
