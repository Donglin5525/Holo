#!/bin/bash
# 填充 Localizable.xcstrings 的 zh-Hant 列（OpenCC s2twp：简体 → 台湾繁体）
# 用法: bash docs/localization/fill-zh-hant.sh [词表路径] [--force]
#   --force  强制重新转换所有条目（会覆盖人工校对过的繁体译文，慎用）
# 依赖: pip3 install --user opencc-python-reimplemented
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../" && pwd)"
CATALOG="${1:-$ROOT/Holo/Holo APP/Holo/Holo/Localizable.xcstrings}"

if ! python3 -c "import opencc" 2>/dev/null; then
  echo "❌ 缺少依赖：请先执行  pip3 install --user opencc-python-reimplemented"
  exit 1
fi

python3 - "$CATALOG" "${2:-}" <<'PY'
import json, sys

catalog_path, force = sys.argv[1], sys.argv[2] == "--force"

with open(catalog_path) as f:
    catalog = json.load(f)

import opencc
cc = opencc.OpenCC("s2twp")  # 简体 → 繁体（台湾正体，含两岸词汇转换）

# OpenCC s2twp 已知偏差修正（规则来源：glossary-zh-hant.md 第三节陷阱字表）
# 字级：｢賬｣为香港写法，台湾资通讯产品惯例（Apple/Google 繁体界面）用「帳」
# 字级：｢專案｣仅指工程/计划义；App 内「项目」均为列表条目义（支出项目等），保留「項目」
# 词组级：「补签」为打卡语境须用「簽」（簽到）；OpenCC 按字面转成「籤」（抽签义）是错的；
#         注意「標籤」的籤是对的，故只修「補籤」词组，不可全局替换
POST_FIXES = {"賬": "帳", "專案": "項目", "補籤": "補簽"}

def convert(text):
    out = cc.convert(text)
    for wrong, right in POST_FIXES.items():
        out = out.replace(wrong, right)
    return out

strings = catalog.get("strings", {})
filled = skipped = 0
for key, entry in strings.items():
    localizations = entry.setdefault("localizations", {})
    zh_hant = localizations.get("zh-Hant")
    if zh_hant and zh_hant.get("stringUnit", {}).get("state") != "new" and not force:
        skipped += 1  # 已有译文（含人工校对），不覆盖
        continue
    converted = convert(key)  # key 即简体原文
    localizations["zh-Hant"] = {"stringUnit": {"state": "translated", "value": converted}}
    filled += 1

with open(catalog_path, "w") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"✅ 填充 {filled} 条，跳过已有译文 {skipped} 条")
print("⚠️  转换后请按 docs/localization/glossary-zh-hant.md 核对产品词与陷阱字（歷/曆、帳、裡、後）")
PY
