#!/usr/bin/env python3
"""用 DeepSeek 批量把词表简体词条翻译成英文，写回 en 列。

约束：术语表定名、占位符必须原样保留、品牌词不翻。
校验：每批返回必须覆盖全部 key；%lld/%@/%d/%.1f 等占位符出现次数与原文一致，
不一致的词条拒绝写入并汇报。已翻译词条自动跳过（断点续跑）。

用法: python3 translate-catalog-en.py <词表路径> [--dry-run]
依赖: HoloBackend/.env 里的 DEEPSEEK_API_KEY
"""
import json
import os
import re
import sys
import time
import urllib.request

BATCH = 120
MAX_RETRY = 3

GLOSSARY = {
    "洞察": "Insight", "洞察胶囊": "Insight Capsule", "日回放": "Daily Replay",
    "周期回放": "Period Replay", "回放": "Replay", "想法": "Thought",
    "想法群落": "Thought Clusters", "记忆长廊": "Memory Gallery", "长廊": "Gallery",
    "今日看板": "Today Dashboard", "看板": "Dashboard", "深度分析": "Deep Analysis",
    "周规划": "Weekly Plan", "萃取": "Extraction", "知识树": "Knowledge Tree",
    "徽章": "Badge", "额度": "Quota", "权益": "Benefits", "付费墙": "Paywall",
    "账本": "Ledger", "记账": "track expenses", "记一笔": "Add Expense",
    "对账": "Reconciliation", "账户": "Account", "账单": "Bill",
    "账单导入": "Bill Import", "严格预算模式": "Strict Budget Mode",
    "补签": "Retroactive Check-in", "回收站": "Recycle Bin", "应用锁": "App Lock",
    "纪念日": "Anniversary", "目标": "Goal", "习惯": "Habit", "任务": "Task",
    "待办": "To-do", "记忆": "Memory", "标签": "Tag",
}

SYSTEM = f"""你是 iOS App「Holo」的本地化翻译员（简体中文→English）。这是一款个人生活管理 App：任务、习惯、记账、健康、AI 洞察、想法笔记、记忆长廊。

硬性规则：
1. 格式占位符必须原样保留且次数不变：%lld、%@、%d、%.1f、%.2f 等
2. 品牌词不翻译：Holo、HoloAI、Holo Plus、Plus、AI
3. 货币符号 ¥ 原样保留
4. 术语表（必须遵循）：{json.dumps(GLOSSARY, ensure_ascii=False)}
5. 「主题」在想法归类语境译 Topic，在外观语境译 Theme，按句意判断
6. UI 风格：按钮用动词短语首词大写（Delete、Save、Add Habit）；标题 Title Case；句子正常大小写；简洁自然，不要逐字直译，不要花哨
7. 空字符串、纯符号、纯占位符的条目原样返回
8. 输出 JSON 对象，key 是原文，value 是英文译文，不要输出其他任何内容"""


def placeholders(s):
    return sorted(re.findall(r'%(?:lld|@|d|\.?\d?f|%)', s))


def call_deepseek(keys, api_key):
    import subprocess
    body = json.dumps({
        "model": "deepseek-chat",
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": "翻译以下词条，返回 JSON：\n" +
             json.dumps({k: k for k in keys}, ensure_ascii=False)},
        ],
        "temperature": 0.3,
        "max_tokens": 8000,
        "response_format": {"type": "json_object"},
    })
    url = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/") + "/chat/completions"
    out = subprocess.run(
        ["curl", "-s", "--max-time", "180", url,
         "-H", "Content-Type: application/json",
         "-H", f"Authorization: Bearer {api_key}",
         "-d", body], capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    return json.loads(d["choices"][0]["message"]["content"])


def main(catalog_path, dry=False):
    env = {}
    with open(os.path.expanduser("~/Desktop/Claude/HOLO/HoloBackend/.env")) as f:
        for line in f:
            m = re.match(r'(DEEPSEEK_[A-Z_]+)=(.*)', line.strip())
            if m:
                env[m.group(1)] = m.group(2).strip().strip('"\'')
    api_key = env["DEEPSEEK_API_KEY"]

    catalog = json.load(open(catalog_path))
    pending = [k for k, v in catalog["strings"].items()
               if not v.get("localizations", {}).get("en", {})
               .get("stringUnit", {}).get("value")]
    print(f"待翻译 {len(pending)} 条，批量大小 {BATCH}")

    done = rejected = 0
    for i in range(0, len(pending), BATCH):
        batch = pending[i:i + BATCH]
        result = None
        for attempt in range(MAX_RETRY):
            try:
                result = call_deepseek(batch, api_key)
                if all(k in result for k in batch):
                    break
                missing = [k for k in batch if k not in result]
                print(f"  批 {i//BATCH+1} 尝试 {attempt+1}：缺 {len(missing)} 条，重试")
                result = None
            except Exception as e:
                print(f"  批 {i//BATCH+1} 尝试 {attempt+1} 失败：{e}")
                time.sleep(3)
        if result is None:
            print(f"  批 {i//BATCH+1} 放弃（下次续跑会重试）")
            continue

        for k in batch:
            en = str(result.get(k, "")).strip()
            if not en or placeholders(en) != placeholders(k):
                rejected += 1
                if rejected <= 10:
                    print(f"  ✗ 拒绝：{k[:30]} → {en[:40]}"
                          f"（占位符 {'原文'+str(placeholders(k)) if placeholders(en)!=placeholders(k) else '空译文'}）")
                continue
            catalog["strings"][k].setdefault("localizations", {})["en"] = {
                "stringUnit": {"state": "translated", "value": en}}
            done += 1
        print(f"批 {i//BATCH+1}/{(len(pending)+BATCH-1)//BATCH} 完成，累计 {done} 条")

    if not dry:
        json.dump(catalog, open(catalog_path, "w"), ensure_ascii=False, indent=2)
        with open(catalog_path, "a") as f:
            f.write("\n")
    print(f"✅ 翻译 {done} 条，拒绝 {rejected} 条"
          + ("（dry-run 未写回）" if dry else "，已写回"))


if __name__ == "__main__":
    main(sys.argv[1], "--dry-run" in sys.argv)
