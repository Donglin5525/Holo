#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_taste.py — 剧本「人味儿」程序化审查（对抗审查第一轮）

机器能查的规律性穿帮先查掉，查不掉的交给只读代理（第二轮）和东林（第三轮）。
用法：python3 audit_taste.py [story.json]
输出：PASS/WARN 清单；有任何 FAIL 则退出码 1。
"""
import json
import sys
from collections import Counter
from datetime import date, timedelta

path = sys.argv[1] if len(sys.argv) > 1 else "story.json"
story = json.load(open(path, encoding="utf-8"))
today = date.today()
fails, warns = [], []

def fail(msg): fails.append(msg)
def warn(msg): warns.append(msg)

def day_num(s):
    head = s.split("T")[0]
    return int(head[2:]) if head.startswith("D-") else -int(head[2:])

def minute_of(s):
    if "T" not in s: return None
    hh, mm = s.split("T")[1].split(":")
    return int(hh) * 60 + int(mm)

tx = [t for t in story["transactions"] if t.get("type") == "expense" and "installment" not in t]

# 1. 节奏：工作日 vs 周末日均条数
daily = Counter()
for t in tx:
    daily[day_num(t["date"])] += 1
wk = [c for d, c in daily.items() if (today - timedelta(days=d)).weekday() < 5]
we = [c for d, c in daily.items() if (today - timedelta(days=d)).weekday() >= 5]
avg_wk, avg_we = (sum(wk) / len(wk) if wk else 0), (sum(we) / len(we) if we else 0)
print(f"[节奏] 工作日日均 {avg_wk:.2f} 笔 vs 周末日均 {avg_we:.2f} 笔")
if avg_we <= avg_wk * 1.15:
    fail(f"周末记账应明显多于工作日（现在 {avg_we:.2f} vs {avg_wk:.2f}）——匀速生活是 AI 味")
if max(daily.values()) < 4:
    warn(f"全年单日最多仅 {max(daily.values())} 笔，缺少爆发日（真人有单日 5-8 笔的周末/旅行日）")

# 2. 间隔规律性：同类型高频消费的间隔天数游程
coffee_days = sorted({day_num(t["date"]) for t in tx if t.get("category") == "咖啡"})
gaps = [b - a for a, b in zip(coffee_days, coffee_days[1:])]
run_same = sum(1 for a, b in zip(gaps, gaps[1:]) if a == b) / max(1, len(gaps) - 1)
print(f"[节奏] 咖啡间隔相等比例 {run_same:.0%}（连续等间隔=机器人）")
if run_same > 0.25:
    fail(f"咖啡出现等间隔连游程 {run_same:.0%}，超过 25% 穿帮线")

# 3. 金额：整元率 / 有分率 / 尾零率
cents_vals = [t["amountCents"] for t in tx]
with_fen = sum(1 for c in cents_vals if c % 100 != 0) / len(cents_vals)
tail_zero = sum(1 for c in cents_vals if (c // 10) % 10 == 0) / len(cents_vals)
print(f"[金额] 带分（非整元）占比 {with_fen:.0%}；尾数含 0 占比 {tail_zero:.0%}")
if with_fen < 0.18:
    fail(f"带分金额仅 {with_fen:.0%}，太整齐（真人外卖/超市价格带分）")
top_amt = Counter(cents_vals).most_common(1)[0]
if top_amt[1] > len(cents_vals) * 0.15:
    warn(f"最高频金额 {top_amt[0]/100} 元出现 {top_amt[1]} 次（{top_amt[1]/len(cents_vals):.0%}）"
         f"——固定票价/固定套餐属正常，超 15% 才报")

# 4. 备注：空备注率 / 高频重复
notes = [t.get("note", "") for t in tx]
empty = sum(1 for n in notes if not n) / len(notes)
top_note = Counter(n for n in notes if n).most_common(3)
print(f"[备注] 空备注率 {empty:.0%}；高频 top3: {top_note}")
if empty < 0.25:
    warn(f"空备注率仅 {empty:.0%}——真人大量不写备注")
for n, c in top_note:
    if c > 25:
        fail(f"备注「{n}」重复 {c} 次，同一句话写太多遍")

# 5. 类目集中度
cats = Counter(t["category"] for t in tx)
top3 = sum(c for _, c in cats.most_common(3)) / len(tx)
print(f"[类目] top3 集中度 {top3:.0%}（{cats.most_common(3)}）")
if top3 < 0.35:
    warn(f"类目 top3 仅 {top3:.0%}，分布过于均匀")

# 6. 想法：唯一率 / 长度 / mood
th = story["thoughts"]
dup_th = [c for c in Counter(t["content"] for t in th).values() if c > 1]
lens = [len(t["content"]) for t in th]
long_ratio = sum(1 for l in lens if l > 40) / len(lens)
print(f"[想法] 重复 {len(dup_th)} 条；超 40 字占比 {long_ratio:.0%}；均长 {sum(lens)/len(lens):.0f} 字")
if dup_th: fail(f"想法内容有重复 {len(dup_th)} 条")
if long_ratio > 0.10: fail(f"超 40 字想法占 {long_ratio:.0%}，小作文化")
moods = Counter(t.get("mood") for t in th)
if moods.get("happy", 0) / len(th) > 0.40:
    fail("开心情绪占比过高——正能量小作文味")

# 7. 时间戳：整分整点率
mins = [minute_of(t["date"]) for t in tx if "T" in t["date"]]
whole = sum(1 for m in mins if m is not None and m % 30 == 0) / len(mins)
print(f"[时间] 半点/整点时刻占比 {whole:.0%}")
if whole > 0.25:
    fail(f"整/半点时刻占 {whole:.0%}，超过 25%——人不是钟表")

# 8. 待办：title 唯一 + 完成时刻
tasks = story["tasks"]
dup_tk = len(tasks) - len({t["title"] for t in tasks})
if dup_tk: fail(f"待办 title 重复 {dup_tk} 条（Schema 硬约束）")
done = [t for t in tasks if t["status"] == "completed"]
done_weekend = sum(1 for t in done
                   if (today - timedelta(days=day_num(t["completedAt"]))).weekday() >= 5) / max(1, len(done))
print(f"[待办] 完成 {len(done)}/{len(tasks)}（{len(done)/len(tasks):.0%}）；周末完成占比 {done_weekend:.0%}")

# 9. 习惯：断档真实感
runs = [t for t in story["habitRecords"] if t["habit"] == "跑步"]
rd = sorted(day_num(t["date"]) for t in runs)
big_gap = max(b - a for a, b in zip(rd, rd[1:]))
print(f"[习惯] 跑步最大断档 {big_gap} 天；共 {len(runs)} 次")
if big_gap < 14:
    warn(f"跑步最大断档仅 {big_gap} 天——人设要求 41 天断档叙事")

print()
for w in warns: print("⚠ WARN:", w)
for f in fails: print("❌ FAIL:", f)
if not fails:
    print("✅ 程序化人味审查通过")
    sys.exit(0)
sys.exit(1)
