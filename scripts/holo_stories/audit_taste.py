#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_taste.py — 剧本「活人感」审查（对抗审查第一轮，机器能查的先查掉）

每一组检查都对应一次真实踩过的坑（2026-11-23 两轮复审的结论），注释里写了病根。
用法：python3 audit_taste.py [story.json]
退出码：有 FAIL 为 1。FAIL=观众看得出/数据自相矛盾；WARN=偏模板味，建议看一眼。
日历表（节假日、调休、行程、断记录日）直接从 generate.py 导入，避免两处各写一份对不上。
"""
import json
import re
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta

import generate as G

path = sys.argv[1] if len(sys.argv) > 1 else "story.json"
S = json.load(open(path, encoding="utf-8"))
claims = S["meta"]["lockedClaims"]
NOW = datetime.strptime(claims["generatedAt"], "%Y-%m-%d %H:%M") + timedelta(minutes=5)


def dt(s):
    return datetime.strptime(s[:16], "%Y-%m-%dT%H:%M") if "T" in s else datetime.strptime(s[:10], "%Y-%m-%d")


issues = []
FAIL, WARN, INFO = "FAIL", "WARN", "INFO"


def add(level, group, msg):
    issues.append((level, group, msg))


TX = [t for t in S["transactions"] if "date" in t]
SPEND = [t for t in TX if t.get("type") == "expense" and "refundOf" not in t]   # 退款单不带 type 字段
TH = S["thoughts"]
TK = S["tasks"]
HR = [r for r in S["habitRecords"] if r["habit"] == "跑步"]
half = next(g for g in S["goals"] if g["title"].startswith("跑完"))
RACE = dt(half["completedAt"]).date()
JP = next(p for p in S["financeProjects"] if "日本" in p["name"])
JP_END = dt(JP["endDate"]).date()
JP_START = dt(JP["startDate"]).date()
fmt = lambda d: d.strftime("%Y-%m-%d")

# ═══════════════ A. 文本：机器签名 ═══════════════
# 病根 v1：775 条文字 67% 用空格当停顿（中文输入法打不出来）、只有 1 条带标点、长度全挤在 10~19 字
texts = [t["content"] for t in TH] + [t.get("note", "") for t in TX if t.get("note")]
CN_SPACE = re.compile(r"[\u4e00-\u9fff] +[\u4e00-\u9fff]")       # 中文之间夹空格
spaced = [t["content"] for t in TH if CN_SPACE.search(t["content"])]   # 想法是句子，不该拿空格当停顿
space_rate = len(spaced) / len(TH)
if spaced:
    add(FAIL, "A 文本", f"想法里拿空格当停顿的有 {len(spaced)} 条，这是机器签名：{spaced[:4]}")
notes_all = [t.get("note", "") for t in TX if t.get("note")]
pause = [n for n in notes_all if n.replace("M Stand", "MStand").count(" ") >= 2 or re.search(r" (她|他|我|也|还是|又|就|但|居然|真的|贵|排了|和|给|边)", n)]
if pause:
    add(FAIL, "A 文本", f"备注里拿空格当逗号：{pause[:4]}")
punct = sum(any(p in t["content"] for p in "，。！？…：；") for t in TH) / len(TH)
if punct < 0.30:
    add(WARN, "A 文本", f"带标点的想法只有 {punct:.0%}，全是无标点短句也偏机器")
L = [len(t["content"]) for t in TH]
tiny, mid, long_ = (sum(x <= 6 for x in L) / len(L), sum(7 <= x <= 15 for x in L) / len(L), sum(x >= 31 for x in L) / len(L))
if mid > 0.75:
    add(WARN, "A 文本", f"{mid:.0%} 的想法挤在 7~15 字，长度太齐")
if tiny < 0.02 or long_ < 0.04:
    add(WARN, "A 文本", f"句长缺两头：≤6 字的占 {tiny:.0%}，≥31 字的占 {long_:.0%}（真人两头都有）")
shapes = {"两段式 A，B": sum(t["content"].count("，") == 1 and "。" not in t["content"] for t in TH),
          "两句 A。B": sum(t["content"].count("。") == 1 and "，" not in t["content"] for t in TH),
          "无标点单句": sum(not any(p in t["content"] for p in "，。！？…：；") for t in TH)}
for name, n_ in shapes.items():
    if n_ / len(TH) > 0.40:
        add(WARN, "A 文本", f"「{name}」句式占 {n_ / len(TH):.0%}，超过四成就是一种节奏写到尾")
# 这台模拟器的运行时渲染不了 emoji（系统 Safari 里也是问号方框），会上屏的图标一律不用 emoji
EMOJI = re.compile(r"[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F]")
emo = [g_["title"] for g_ in S["goals"] if EMOJI.search(g_.get("iconEmoji") or "")] + \
      [p_["name"] for p_ in S["financeProjects"] if EMOJI.search(p_.get("icon") or "")]
if emo:
    add(FAIL, "A 图标", f"图标用了 emoji，在这台模拟器上会显示成问号方框：{emo}")
mech = [t["title"] for t in TK if re.search(r"（又|再再|\(\d+\)|#\d|副本", t["title"])]
if mech:
    add(FAIL, "A 文本", f"标题带机械去重后缀：{mech[:4]}")
cliche = [t["content"] for t in TH if re.search(r"不是.{1,8}[，,].{0,4}是|——|说白了|本质上|意味着", t["content"])]
if len(cliche) > 4:
    add(WARN, "A 文本", f"「不是X是Y」/破折号/书面连接词偏多：{cliche[:3]}")
dup_th = [c for c, n in Counter(t["content"] for t in TH).items() if n > 1]
if dup_th:
    add(FAIL, "A 文本", f"想法内容重复：{dup_th[:3]}")

# 情绪要跟内容一致（病根：随机抽情绪，「关掉，快乐」被标成难过）
SAD, ANGRY, HAPPY = ("哭|难受|焦虑|疼|心在滴血|后悔|丧"), ("气死|有点气|好烦|离谱|无语"), ("快乐|开心|真香|赚到了|真好|激动")
for t in TH:
    c, m = t["content"], t["mood"]
    if re.search(SAD, c) and m == "happy" and not re.search("累哭了|但开心|但值|但好吃|也还行", c):
        add(FAIL, "A 情绪", f"内容难过、标签开心：{c[:24]}")
    if re.search(ANGRY, c) and m == "happy":
        add(FAIL, "A 情绪", f"内容生气、标签开心：{c[:24]}")
    if re.search(HAPPY, c) and m in ("sad", "angry"):
        add(FAIL, "A 情绪", f"内容开心、标签负面：{c[:24]}（{m}）")
mood = Counter(t["mood"] for t in TH)
if mood["angry"] + mood["sad"] > 0.35 * len(TH):
    add(WARN, "A 情绪", f"负面情绪占 {(mood['angry'] + mood['sad']) / len(TH):.0%}，太丧")

# ═══════════════ B. 日历：节日、调休、先后 ═══════════════
# 病根 v1：用「几天前」整数运算日期，方向连错四次——跨年夜落在 11-30、赛后感想在赛前、机票买在旅行之后
def day_of(s):
    return dt(s).date()


night_before = TH and any(re.search("跨年|新年三件事", t["content"]) and day_of(t["createdAt"]) == date(2025, 12, 31) for t in TH)
if not night_before:
    add(FAIL, "B 日历", "跨年夜立志的想法不在 12 月 31 日")
rules_after = [("赛后|完赛|下楼梯|腿终于|奖牌|跑休", RACE), ("调薪|涨了一千四", date(2026, 8, 10)),
               ("出签", date(2026, 3, 2)), ("中签", date(2026, 9, 15)), ("办了一个半月", date(2026, 7, 27))]
rules_before = [("赛前", RACE), ("报名", RACE), ("出签", JP_START), ("办签证", JP_START)]
windows = {"618": (date(2026, 6, 10), date(2026, 6, 25)), "双十一": (date(2026, 10, 15), date(2026, 11, 30)),
           "桂花": (date(2026, 9, 20), date(2026, 10, 25)), "梅雨": (date(2026, 6, 10), date(2026, 7, 5)),
           "40度": (date(2026, 7, 1), date(2026, 8, 31)), "烤红薯": (date(2026, 11, 1), date(2026, 11, 30)),
           "年夜饭|拜年|压岁钱|同学聚会|返程": (date(2026, 2, 14), date(2026, 2, 24)),
           "空气是甜的|跑山": (date(2026, 10, 2), date(2026, 10, 4))}
for t in TH:
    d, c = day_of(t["createdAt"]), t["content"]
    for pat, ref in rules_after:
        if re.search(pat, c) and d < ref:
            add(FAIL, "B 先后", f"「{c[:20]}」在 {fmt(d)}，早于它该发生的时间 {fmt(ref)}")
    for pat, ref in rules_before:
        if re.search(pat, c) and d > ref:
            add(FAIL, "B 先后", f"「{c[:20]}」在 {fmt(d)}，晚于它该发生的时间 {fmt(ref)}")
    for pat, (a, b) in windows.items():
        if re.search(pat, c) and not a <= d <= b and not re.search("早知道|的时候|去年|上次|回忆", c):   # 回顾语气不算
            add(FAIL, "B 季节", f"「{c[:20]}」出现在 {fmt(d)}，不在它的时节 {fmt(a)}~{fmt(b)}")
if RACE.weekday() != 6:
    add(FAIL, "B 日历", "比赛不在周日")
# 放假日不该通勤（病根 v1：国庆节当天有地铁和工作午餐）
closed = {x.isoformat() for x in G.HOLIDAYS}
commute = [t for t in TX if t.get("category") == "交通/地铁" and t["date"][:10] in closed and not t.get("project")]
if commute:
    add(FAIL, "B 节假日", f"法定假日出现通勤：{[t['date'][:10] for t in commute][:4]}")
work_lunch = {m for m, _, _ in G.C.LUNCH}
hol_lunch = [t for t in TX if t["date"][:10] in closed and t.get("category") == "午餐" and t.get("note") in work_lunch]
if hol_lunch:
    add(FAIL, "B 节假日", f"法定假日吃工作午餐：{[t['date'][:10] for t in hol_lunch][:4]}")
makeup = [t for t in TX if t["date"][:10] in {x.isoformat() for x in G.MAKEUP_WORKDAYS} and t.get("category") == "交通/地铁"]
if len(makeup) < len(G.MAKEUP_WORKDAYS) - 1:
    add(WARN, "B 节假日", f"调休上班日只有 {len(makeup)} 天有通勤（共 {len(G.MAKEUP_WORKDAYS)} 个调休日），当天本该上班")
# 出门期间不该有本地日常；行程内消费不该晚于行程结束
for a, b in G.AWAY:
    stray = [t for t in TX if a <= day_of(t["date"]) <= b and t.get("category") in ("交通/地铁", "交通/单车")
             and t.get("note", "") in ("", "地铁", "上班", "下班", "早高峰", "加班回来", "哈啰单车", "美团单车")]
    if stray:
        add(FAIL, "B 行程", f"{fmt(a)}~{fmt(b)} 不在杭州，却有本地通勤：{[t['date'][:10] for t in stray][:3]}")
late = [t for t in TX if t.get("project") == JP["name"] and day_of(t["date"]) > JP_END]
if late:
    add(FAIL, "B 行程", f"行程结束后还有行程内消费：{[t['date'][:10] for t in late][:3]}")
prep = {"办签证", "订机票", "订大阪民宿", "收拾行李箱", "换日元", "请假条OA提交"}
for t in TK:
    if t["title"] in prep and t.get("completedAt") and dt(t["completedAt"]).date() >= JP_START:
        add(FAIL, "B 行程", f"行前准备「{t['title']}」完成于 {t['completedAt'][:10]}，晚于出发 {fmt(JP_START)}")
    if t["title"] == "办签证" and t.get("completedAt") and dt(t["completedAt"]).date() != date(2026, 3, 2):
        add(FAIL, "B 行程", f"「办签证」完成于 {t['completedAt'][:10]}，应该和签证代办付款同一天（03-02）")
# 断记录日里不能有任何记录
rec_days = ({t["date"][:10] for t in TX} | {t["createdAt"][:10] for t in TH} | {t["date"][:10] for t in S["habitRecords"]}
            | {t["createdAt"][:10] for t in TK})
leak = [fmt(d) for d in G.GAPS if fmt(d) in rec_days]
if leak:
    add(FAIL, "B 断档", f"断记录日里出现了记录：{leak[:4]}")
if not 5 <= len(G.GAPS) <= 20:
    add(WARN, "B 断档", f"全年完全没记录的日子 {len(G.GAPS)} 天——真人会有几天彻底没记")

# ═══════════════ C. 时间戳 ═══════════════
# 病根 v1：21 条待办完成早于创建；夜宵记在 18 点；「起晚了打车」发生在晚上十点
stamps = [t["date"] for t in TX] + [t["createdAt"] for t in TH] + [t["date"] for t in S["habitRecords"]] \
    + [t["createdAt"] for t in TK] + [t.get("completedAt", "") for t in TK]
future = [s for s in stamps if s and dt(s) >= NOW]
if future:
    add(FAIL, "C 时间戳", f"有记录的时间不早于生成时刻（注入后会被当成没发生）：{future[:3]}")
bad = [t for t in TK if t.get("completedAt") and dt(t["completedAt"]) <= dt(t["createdAt"])]
if bad:
    add(FAIL, "C 时间戳", f"待办完成不晚于创建 {len(bad)} 条：{[(t['title'], t['createdAt'], t['completedAt']) for t in bad[:3]]}")
hour_rules = {   # 类目 → (最早, 最晚) 小时
    "早餐": (5, 11), "午餐": (10.5, 14.5), "晚餐": (16.5, 21.5), "夜宵": (21, 27), "外卖": (7, 23.8), "咖啡": (6.5, 17),
    "地铁": (5.5, 23.9), "交通/地铁": (5.5, 23.9), "饮品": (9, 22.5)}
for t in TX:
    h = dt(t["date"]).hour + dt(t["date"]).minute / 60
    cat = t.get("category")
    if cat == "夜宵" and h < 3:          # 凌晨的夜宵
        h += 24
    rule = hour_rules.get(cat)
    if cat in ("交通/地铁", "地铁") and G.is_workday(day_of(t["date"])) and not (5.5 <= h <= 9.6 or 17 <= h <= 23.9):
        add(FAIL, "C 时段", f"通勤地铁记在 {t['date'][11:]}：{t.get('note') or ''}")
    elif rule and not rule[0] <= h <= rule[1]:
        add(FAIL, "C 时段", f"{cat} 记在 {t['date'][11:]}：{t.get('note') or ''}")
    note = t.get("note", "")
    if "起晚了" in note and h >= 10:
        add(FAIL, "C 时段", f"「起晚了打车」发生在 {t['date'][11:]}")
    if re.search("地铁没了|地铁停运", note) and h < 22.5:
        add(FAIL, "C 时段", f"「地铁没了打车」发生在 {t['date'][11:]}")
    if "疯狂星期四" in note and dt(t["date"]).weekday() != 3:
        add(FAIL, "C 时段", f"疯狂星期四记在周{dt(t['date']).weekday() + 1}")
    if cat == "午餐" and note in work_lunch and not G.is_workday(day_of(t["date"])):
        add(FAIL, "C 时段", f"休息日吃楼下工作午餐：{t['date'][:10]} {note}")
    if cat == "咖啡" and h >= 18:
        add(FAIL, "C 时段", f"晚上六点后喝咖啡：{t['date']}")
    for brand, hi in (("瑞幸", 18.5), ("库迪", 15.5), ("manner", 23), ("挪瓦", 16)):
        if cat == "咖啡" and note.startswith(brand) and t["amountCents"] / 100 > hi:
            add(FAIL, "C 咬合", f"{brand} 卖到 ¥{t['amountCents'] / 100}：{note}")
    if cat == "咖啡" and note.startswith("星巴克") and t["amountCents"] / 100 < 19:
        add(FAIL, "C 咬合", f"星巴克只花 ¥{t['amountCents'] / 100}：{note}")
# 想法的钟点要跟内容对得上
NIGHT = re.compile("早睡|睡前|关灯|深夜|凌晨|半夜|睡不着")
for t in TH:
    when, c = dt(t["createdAt"]), t["content"]
    d, h, wd = when.date(), when.hour + when.minute / 60, when.date().weekday()
    if re.search(r"^(今晚|睡前|早睡|深夜|关灯)|睡不着|洗完澡|今晚早睡", c) and not re.search("没|并没", c[:6]) and h < 21:
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在 {when.strftime('%H:%M')}")
    if re.search("晨跑|周六早上自然醒", c) and not 5 <= h <= 11:
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在 {when.strftime('%H:%M')}")
    if re.search(r"^地铁上|地铁上读书|地铁上闻到|早高峰", c) and not (G.is_workday(d) and (7 <= h <= 9.7 or 18 <= h <= 20)):
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在 {fmt(d)} {when.strftime('%H:%M')}")
    if re.search("午休", c) and not 11.5 <= h <= 14:
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在 {when.strftime('%H:%M')}")
    if "下班前" in c and not (G.is_workday(d) and 15 <= h <= 18.5):
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在 {fmt(d)} {when.strftime('%H:%M')}")
    if re.search("周五", c) and wd != (3 if "明天是周五" in c else 4):
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在周{wd + 1}")
    if re.search("周六", c) and wd != 5:
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在周{wd + 1}")
    if re.search("周日", c) and wd != 6:
        add(FAIL, "C 想法时段", f"「{c[:18]}」记在周{wd + 1}")
    if re.search("写周报|周报憋|周报里|需求文档|评审会|OKR|述职|灰度|值班|埋点|排期|催运营|验收设计稿", c) and not G.is_workday(d):
        add(FAIL, "C 想法时段", f"上班的事写在休息日：{fmt(d)}「{c[:18]}」")
    if c.startswith("今天一分钱没花") and any(x["date"][:10] == fmt(d) for x in TX):
        add(FAIL, "C 咬合", f"说「一分钱没花」的 {fmt(d)} 其实有消费")
    if re.search("调薪快乐|19块9", c) and not any(x["date"][:10] == fmt(d) and x["amountCents"] == 1990 for x in TX):
        add(FAIL, "C 咬合", f"想法说当天喝了杯 19 块 9 的，账上没有：{fmt(d)}")
# 比赛记录：七点半开跑 2:41:33，十点十一分之后才记
race_rec = max(HR, key=lambda r: r["date"])
if not (day_of(race_rec["date"]) == RACE and dt(race_rec["date"]) >= datetime(RACE.year, RACE.month, RACE.day, 10, 11)):
    add(FAIL, "C 比赛", f"比赛记录时刻 {race_rec['date']}，早于冲线时间")
for r in HR:
    h = dt(r["date"]).hour
    if not (5 <= h <= 11 or 17 <= h <= 23):
        add(FAIL, "C 跑步", f"跑步记录在 {r['date']}")

# ═══════════════ D. 数值与咬合 ═══════════════
# 病根 v1：184 顿午餐只有 9 种价格、44 次跑步只有 11 种距离、赛前最长 8.4 公里却跑了 21 公里
lunch = [t["amountCents"] for t in TX if t.get("category") == "午餐"]
if len(set(lunch)) / len(lunch) < 0.30:
    add(FAIL, "D 金额", f"{len(lunch)} 顿午餐只有 {len(set(lunch))} 种价格，模板池太小")
coffee = [t for t in TX if t.get("category") == "咖啡"]
if len(coffee) != claims["coffeeCups"] or abs(sum(t["amountCents"] for t in coffee) / 100 - claims["coffeeTotal"]) > 0.01:
    add(FAIL, "D 对账", "咖啡的杯数或金额与口径表不一致")
jp = [t for t in TX if t.get("project") == JP["name"]]
if abs(sum(t["amountCents"] for t in jp) / 100 - claims["japanTrip"]) > 0.01:
    add(FAIL, "D 对账", "日本行合计与口径表不一致")
fund = [t for t in TX if t.get("account") == "旅行专款"]
bal = next(a for a in S["accounts"] if a["name"] == "旅行专款")["initialBalanceCents"] \
    + sum(t["amountCents"] if t["type"] == "income" else -t["amountCents"] for t in fund)
if abs(bal / 100 - claims["fundBalance"]) > 0.01 or not 0.6 <= bal / 5_000_000 < 1:
    add(FAIL, "D 对账", f"旅行专款余额算出来 {bal / 100}，口径表 {claims['fundBalance']}；进度应在 60%~100% 之间（年底差一点）")
runs = sorted((day_of(r["date"]), r["value"]) for r in HR)
pre = [(d, v) for d, v in runs if d < RACE]
RACE_KM = G.RACE_KM
peak = max(v for d, v in pre if (RACE - d).days <= 35)
early = max(v for d, v in pre if (RACE - d).days > 70)
if peak < 18:
    add(FAIL, "D 训练", f"赛前最长一次只跑了 {peak} 公里，跑不完半马")
if early >= 10:
    add(FAIL, "D 训练", f"备赛期之前就跑过 {early} 公里，训练曲线不合理")
if max(runs, key=lambda x: x[0])[1] != RACE_KM or max(runs, key=lambda x: x[0])[0] != RACE:
    add(FAIL, "D 训练", "最新一条跑步不是比赛那次（目标达标型取最新）")
if len({round(r["value"], 2) for r in HR}) / len(HR) < 0.45:
    add(FAIL, "D 训练", f"{len(HR)} 次跑步只有 {len({r['value'] for r in HR})} 种距离")
rd = [d for d, _ in runs]
longest_break = max((b - a).days for a, b in zip(rd, rd[1:]))
if longest_break < 30:
    add(WARN, "D 训练", f"全年跑步最长只断 {longest_break} 天，太自律")
breaks = [(a, b) for a, b in zip(rd, rd[1:]) if (b - a).days >= 30]
for a, b in breaks:
    stray = [t for t in TH if a < day_of(t["createdAt"]) < b and re.search("今天不想跑，跑完了|连跑三周|配速进|被大爷超了|膝盖外侧", t["content"])]
    if stray:
        add(FAIL, "D 训练", f"断档期（{fmt(a)}~{fmt(b)}）里写了跑步的事：{[t['content'][:14] for t in stray][:2]}")
# 生病那几天不跑不读
for x in G.ILLNESS:
    if any(day_of(r["date"]) == x for r in HR):
        add(FAIL, "D 生活", f"肠胃炎期间还在跑步：{fmt(x)}")
med = [t for t in TX if t.get("category") in ("就医", "药品", "疫苗", "牙齿保健", "体检", "眼镜")]
if len(med) < 4:
    add(WARN, "D 生活", f"全年医疗相关支出只有 {len(med)} 笔，人一年总会头疼脑热")
monthly = defaultdict(float)
for t in TX:
    if "refundOf" not in t and t.get("type") != "expense":
        continue
    monthly[t["date"][:7]] += (-1 if "refundOf" in t else 1) * t["amountCents"] / 100
full = {k: v for k, v in monthly.items() if k not in (G.START.strftime("%Y-%m"), NOW.strftime("%Y-%m"))}
vals = list(full.values())
if vals and (max(vals) / min(vals) > 4.2 or max(vals) / min(vals) < 1.5):
    add(WARN, "D 节奏", f"月度支出最高/最低 = {max(vals) / min(vals):.1f} 倍，太均匀或太悬殊")
top = max(full, key=full.get)
prev = (JP_START.replace(day=1) - timedelta(days=1)).strftime("%Y-%m")
if top not in (JP_START.strftime("%Y-%m"), prev):
    add(WARN, "D 节奏", f"全年支出最高的月份是 {top}；机票住宿提前付，峰值应该在行前那个月或旅行当月")
sal = sorted((t for t in TX if t.get("category") == "工资"), key=lambda t: t["date"])
if any(not G.is_workday(day_of(t["date"])) or day_of(t["date"]).day > 10 for t in sal) or len(sal) != 12:
    add(FAIL, "D 工资", f"发薪日不对：{[t['date'][:10] for t in sal]}")
if [t["amountCents"] for t in sal] != sorted([t["amountCents"] for t in sal]) or sal[-1]["amountCents"] != 1420000 \
        or sum(t["amountCents"] == 1420000 for t in sal) != 4:
    add(FAIL, "D 工资", "工资 8 月 10 日起从 12800 涨到 14200，流水要能对上")
wx_food = defaultdict(float)
for t in SPEND:
    if t.get("account") == "微信" and t.get("category") in ("早餐", "午餐", "晚餐", "夜宵", "零食", "咖啡", "外卖", "饮品", "水果", "火锅", "烧烤", "甜品", "啤酒", "茶饮", "超市"):
        wx_food[t["date"][:7]] += t["amountCents"] / 100
wx_full = {k: v for k, v in wx_food.items() if k != NOW.strftime("%Y-%m")}
budget = next(b for b in S["budgets"] if b.get("category") == "餐饮")["amountCents"] / 100
over = sum(v > budget for v in wx_full.values()) / len(wx_full)
if not 0.15 <= over <= 0.75:
    add(WARN, "D 预算", f"餐饮预算 {budget:.0f}/月，超支的月份占 {over:.0%}（要么月月超、要么月月不超，都太整齐）")
by_id = {t["id"]: t for t in TX if "id" in t}
for t in TX:
    if "refundOf" in t:
        o = by_id.get(t["refundOf"])
        if not o or t["amountCents"] > o["amountCents"] or t["date"] <= o["date"]:
            add(FAIL, "D 退款", f"退款 {t['date']} 与原单对不上")
run_days = {day_of(r["date"]): r["value"] for r in HR}
for t in TK:
    m = re.match(r"长距离 (\d+)公里", t["title"])
    if m and t.get("completedAt"):
        v = run_days.get(dt(t["completedAt"]).date())
        if not v or v < int(m.group(1)):
            add(FAIL, "D 咬合", f"待办「{t['title']}」完成那天没有对应的跑步记录")
titles = Counter(t["title"] for t in TK)
for g in S["goals"]:
    for tt in g.get("tasks", []):
        if titles[tt] != 1:
            add(FAIL, "D 目标", f"目标挂靠的任务「{tt}」在剧本里有 {titles[tt]} 条同名")

# ═══════════════ E. 节律 ═══════════════
# 病根 v1：136 条待办每条只出现一次（「写周报」一年一次）；完成率不是 97% 就是全删光
done = sum(t["status"] == "completed" for t in TK) / len(TK)
if not 0.80 <= done <= 0.93:
    add(FAIL, "E 待办", f"完成率 {done:.0%}，不在真人的 80%~93%")
weekly = sum(bool(re.search("周报", t["title"])) for t in TK)
if weekly < 22:
    add(FAIL, "E 待办", f"「周报」类全年只有 {weekly} 条，没有生活节律")
for kw, lo in (("快递", 10), ("房租", 9), ("电话", 8), ("电费|水费|燃气", 8)):
    n = sum(bool(re.search(kw, t["title"])) for t in TK)
    if n < lo:
        add(FAIL, "E 待办", f"「{kw}」类待办全年只有 {n} 条")
overdue = [t for t in TK if t["status"] == "todo" and t.get("dueDate") and dt(t["dueDate"]) < NOW - timedelta(days=3)
           and not t.get("archived")]
ancient = [t["title"] for t in overdue if dt(t["dueDate"]) < NOW - timedelta(days=150)]
if ancient:
    add(FAIL, "E 待办", f"逾期超过五个月还挂着的待办（像随手写的旧日期）：{ancient[:3]}")
if not 3 <= len(overdue) <= 14:
    add(WARN, "E 待办", f"逾期没做的待办 {len(overdue)} 条（真人会有几条一直挂着）")
today_blocks = [t for t in TK if t.get("plannedStart", "")[:10] == fmt(NOW.date())]
if len(today_blocks) < 2:
    add(FAIL, "E 待办", f"今天的时间块只有 {len(today_blocks)} 个，「今天」的看板是空的")
per_day = Counter(t["date"][:10] for t in TX)
def _spread(nums):
    m = sum(nums) / max(1, len(nums))
    return (sum((x - m) ** 2 for x in nums) / max(1, len(nums))) ** 0.5


per_day_all = Counter(t["date"][:10] for t in TX)
for x in G.span(G.START, NOW.date() - timedelta(days=1)):
    per_day_all.setdefault(x.isoformat(), 0)
wk = [n for d, n in per_day_all.items() if G.is_workday(date.fromisoformat(d))]
we = [n for d, n in per_day_all.items() if not G.is_workday(date.fromisoformat(d))]
avg_wk, avg_we = sum(wk) / max(1, len(wk)), sum(we) / max(1, len(we))
off_metro = [t for t in TX if t.get("category") == "交通/地铁" and not G.is_workday(day_of(t["date"]))]
if len(off_metro) > 0.02 * sum(t.get("category") == "交通/地铁" for t in TX):
    add(FAIL, "E 节律", f"休息日坐通勤地铁 {len(off_metro)} 次：{[t['date'][:10] for t in off_metro][:4]}")
if _spread(we) < _spread(wk) * 1.15:
    add(WARN, "E 节律", f"休息日笔数的波动（{_spread(we):.2f}）没有明显大于工作日（{_spread(wk):.2f}），生活太匀速")
note_c = Counter(t.get("note", "") for t in TX if t.get("note"))
for n, c in note_c.most_common(12):
    if c > 20 and n not in ("地铁", "上班", "下班", "早高峰", "加班回来", "工资", "房租", "话费", "电费", "iCloud自动续费", "微信读书", "网易云黑胶", "外卖", "午饭", "水果", "水果店", "超市", "滴滴"):
        add(WARN, "E 节律", f"备注「{n}」重复 {c} 次，同一句话写得太多")
blank = sum(not t.get("note") for t in TX) / len(TX)
if blank < 0.12:
    add(WARN, "E 节律", f"空备注只有 {blank:.0%}，真人很多笔不写备注")

# ═══════════════ F. 想法与账本互证（2026-11-23 第三轮：病根是「想法在表演、账本在拆台」）═══════════════
on_away = [t["content"][:18] for t in TH if any(a <= day_of(t["createdAt"]) <= b for a, b in G.AWAY)
           and not any(t["content"].startswith(x[1].split("{")[0]) for x in G.C.THOUGHTS_ANCHORED)]
if on_away:
    add(FAIL, "F 互证", f"人不在杭州，却有当天在杭州才可能发生的想法：{on_away[:3]}")
by_day = defaultdict(list)
for t in TH:
    by_day[t["createdAt"][:10]].append(t["content"])
for day, items in by_day.items():
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a_, b_ = {items[i][k:k + 2] for k in range(len(items[i]) - 1)}, {items[j][k:k + 2] for k in range(len(items[j]) - 1)}
            if len(a_ | b_) and len(a_ & b_) / len(a_ | b_) >= 0.45:
                add(FAIL, "F 互证", f"{day} 有两条几乎一样的想法：{items[i][:14]} ／ {items[j][:14]}")
# 现金：没有取现就只能花收到的现金，余额不能变负
cash = 0
for t in sorted((t for t in TX if t.get("account") == "现金" and "date" in t), key=lambda t: t["date"]):
    cash += t["amountCents"] if t["type"] == "income" else -t["amountCents"]
    if cash < 0:
        add(FAIL, "F 互证", f"现金账户在 {t['date'][:10]} 变成负数（有现金支出却没有现金来源）")
        break
# 想法里的数字要和账/跑步记录对得上
fund_max = 0
bal = next(a for a in S["accounts"] if a["name"] == "旅行专款")["initialBalanceCents"]
for t in sorted((t for t in TX if t.get("account") == "旅行专款" and "date" in t), key=lambda t: t["date"]):
    bal += t["amountCents"] if t["type"] == "income" else -t["amountCents"]
    fund_max = max(fund_max, bal)
for t in TH:
    m = re.search(r"过了(\d+)万", t["content"])
    if m and int(m.group(1)) * 1000000 > fund_max:
        add(FAIL, "F 互证", f"想法说「过了{m.group(1)}万」，但旅行专款全年最高只有 ¥{fund_max / 100:.0f}：{t['content'][:18]}")
    d = day_of(t["createdAt"])
    run_km = next((r["value"] for r in HR if day_of(r["date"]) == d), None)
    if "十五公里以后" in t["content"] and (run_km is None or run_km < 15):
        add(FAIL, "F 互证", f"「十五公里以后是真香」那天跑了 {run_km} 公里：{fmt(d)}")
    if "五公里就回家了" in t["content"] and (run_km is None or run_km >= 5):
        add(FAIL, "F 互证", f"「五公里就回家了」那天跑了 {run_km} 公里：{fmt(d)}")
    if "我买的单" in t["content"] and not any(x["date"][:10] == fmt(d) and x.get("category") == "请客" for x in TX):
        add(FAIL, "F 互证", f"想法说「我买的单」，当天账上没有请客：{fmt(d)}")
    cny = [x for x in TX if "2026-02-15" <= x["date"][:10] <= "2026-02-23"]          # 只算过年那几天
    if t["content"].startswith("红包出去") and (sum(x["amountCents"] for x in cny if x.get("category") == "红包礼金") // 100,
                                                 sum(x["amountCents"] for x in cny if x.get("category") == "红包") // 100) != \
            (int(re.search(r"出去(\d+)", t["content"]).group(1)), int(re.search(r"回来(\d+)", t["content"]).group(1))):
        add(FAIL, "F 互证", "想法里的红包进出金额与账上不符")
# 事件与日常互斥：一晚上不会吃两顿正餐；看话剧/电影的晚上不会同时在健身房
dinner_like = defaultdict(list)
for t in TX:
    if t.get("category") in ("晚餐", "外卖", "请客") and 17 <= dt(t["date"]).hour <= 22:
        dinner_like[t["date"][:10]].append(t)
double = {d: [x.get("note") for x in v] for d, v in dinner_like.items() if len(v) >= 2}
if double:
    add(FAIL, "F 互证", f"一晚上两顿正餐：{list(double.items())[:2]}")
for r in S["habitRecords"]:
    if r["habit"] == "健身":
        clash = [x for x in TX if x["date"][:10] == r["date"][:10] and x.get("category") in ("门票", "电影", "KTV", "演唱会")
                 and abs(dt(x["date"]).hour - dt(r["date"]).hour) <= 3]
        if clash:
            add(FAIL, "F 互证", f"{r['date'][:10]} 晚上既在看演出又在健身房")
# 待办：带季节的要在季节里，有截止的不能过期才出现
for t in TK:
    for title, (lo, hi) in G.C.TASK_SEASON.items():
        if t["title"] == title and not (lo <= dt(t["createdAt"]).month <= hi if lo <= hi else dt(t["createdAt"]).month >= lo or dt(t["createdAt"]).month <= hi):
            add(FAIL, "F 待办", f"「{title}」创建于 {t['createdAt'][:10]}，不在它的季节")
    for title, until in G.C.TASK_UNTIL.items():
        if t["title"] == title and dt(t["createdAt"]).date() > dt(until + "T00:00").date():
            add(FAIL, "F 待办", f"「{title}」创建于 {t['createdAt'][:10]}，已经过了它该出现的日期 {until}")
# 十二个月都得有水电费；七点前起床的打卡得在七点前
bills = {t["date"][:7] for t in TX if t.get("category") == "居住/电费" and t["date"] >= "2025-12"}
missing = [f"2026-{m:02d}" for m in range(1, 12) if f"2026-{m:02d}" not in bills]
if missing:
    add(FAIL, "F 生活", f"这些月份没有缴电费：{missing}")
late = [r["date"] for r in S["habitRecords"] if r["habit"] == "早起" and r.get("completed", True) and r["date"][11:13] >= "07"]
if late:
    add(FAIL, "F 生活", f"习惯写的是七点前起床，却有 {len(late)} 次完成打卡在七点后")
spaces = [t.get("note") for t in TX if CN_SPACE.search(t.get("note", ""))]
if spaces:
    add(FAIL, "A 文本", f"备注里中文之间夹着空格：{spaces[:4]}")

# ═══════════════ G. 想法与「当天的事实」对不对（2026-11-23 第四轮：自由想法随机落点、不看那天发生了什么）═══════════════
run_by_day = {day_of(r["date"]): r for r in HR}
tx_by_day = defaultdict(list)
for t in TX:
    if "date" in t:
        tx_by_day[day_of(t["date"])].append(t)
CN_HOUR = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12}
RUN_TALK = re.compile(r"跑完|夜跑|配速|跑崩|被遛狗|大爷超|不想跑|脚趾发麻|出门跑|跑过|犹豫了十分钟|能量胶")
for t in TH:
    c, d, w = t["content"], day_of(t["createdAt"]), dt(t["createdAt"])
    m = re.search(r"(上午|下午|晚上|凌晨)([一二三四五六七八九十两]+|\d+)点", c)
    if m and not re.search("一晚上|昨晚|那天|上次|小时候|去年|前天", c):      # 回顾过去的事不算
        base = CN_HOUR.get(m.group(2)) or int(m.group(2))
        expect = base + 12 if m.group(1) in ("下午", "晚上") else base % 12
        if w.hour != expect:
            add(FAIL, "G 当天事实", f"「{c[:16]}」写着{m.group(0)}，记在 {w.strftime('%H:%M')}")
    if G.STAY_WORDS.search(c):        # 声称「没出门/没花钱」：说的是哪几天（上周末 / 周末两天 / 当天），那几天必须真没有消费和跑步
        wrong = [fmt(x) for x in G.days_claimed_home(c, d) if tx_by_day[x] or x in run_by_day]
        if wrong:
            add(FAIL, "G 当天事实", f"「{c[:16]}」记在 {fmt(d)}，但它声称没出门的日子里有消费/跑步：{wrong}")
    if c == "起床" and not 5 <= w.hour <= 9:
        add(FAIL, "G 当天事实", f"「起床」记在 {w.strftime('%H:%M')}")
    if c == "下班" and not (G.is_workday(d) and 17 <= w.hour <= 20):
        add(FAIL, "G 当天事实", f"「下班」记在 {fmt(d)} {w.strftime('%H:%M')}")
    if "通勤" in c and not G.is_workday(d):
        add(FAIL, "G 当天事实", f"「{c[:16]}」记在休息日 {fmt(d)}")
    if "力量训练" in c and d in run_by_day:
        add(FAIL, "G 当天事实", f"「{c[:16]}」记在 {fmt(d)}，那天跑了 {run_by_day[d]['value']} 公里")
    if d in run_by_day and RUN_TALK.search(c) and w < dt(run_by_day[d]["date"]):
        add(FAIL, "G 当天事实", f"「{c[:16]}」记在 {w.strftime('%H:%M')}，跑步记录是 {run_by_day[d]['date'][11:]}——事情还没发生感想先发了")
    first_tx = min((x["date"] for x in tx_by_day[d]), default=None)
    if c.startswith(("起床了", "出门了")) and first_tx and w > dt(first_tx):
        add(FAIL, "G 当天事实", f"「{c[:16]}」记在 {w.strftime('%H:%M')}，但当天第一笔消费在 {first_tx[11:]}——人还没起床就出门了")
    m2 = re.search(r"外卖上个月([一二三四五六七八九十]+)多", c)
    if m2:
        prev = (d.replace(day=1) - timedelta(days=1)).strftime("%Y-%m")
        total = sum(x["amountCents"] for x in TX if x.get("date", "")[:7] == prev and x.get("category") == "外卖" and x["type"] == "expense") / 100
        h_ = CN_HOUR.get(m2.group(1)[0], 0) if len(m2.group(1)) == 2 else 10 * CN_HOUR.get(m2.group(1)[0], 1)
        if not h_ * 100 - 1 <= total < h_ * 100 + 100:
            add(FAIL, "G 当天事实", f"想法说上个月外卖{m2.group(1)}多，账上是 {total:.0f} 元（{prev}）")
# 上班日一早跑长距离：跑完之前不可能在通勤
for d, r in run_by_day.items():
    end = dt(r["date"])
    if G.is_workday(d) and r["value"] >= 10 and end.hour < 10:
        early = [x for x in tx_by_day[d] if x.get("category") in ("交通/地铁", "交通/打车", "交通/单车", "咖啡") and dt(x["date"]) < end]
        if early:
            add(FAIL, "G 当天事实", f"{fmt(d)} 早上 {end.strftime('%H:%M')} 才跑完 {r['value']} 公里，之前却有通勤/咖啡：{[x['date'][11:] for x in early]}")

# ═══════════════ 输出 ═══════════════
groups = ["A 文本", "A 情绪", "B 日历", "B 先后", "B 季节", "B 节假日", "B 行程", "B 断档", "C 时间戳", "C 时段", "C 想法时段",
          "C 咬合", "C 比赛", "C 跑步", "D 金额", "D 对账", "D 训练", "D 生活", "D 节奏", "D 工资", "D 预算", "D 退款",
          "D 目标", "E 待办", "E 节律", "F 互证", "F 待办", "F 生活", "G 当天事实"]
fails = [i for i in issues if i[0] == FAIL]
warns = [i for i in issues if i[0] == WARN]
print(f"文本 {len(texts)} 条｜中文间空格 {space_rate:.1%}｜带标点想法 {punct:.0%}｜句长 ≤6字 {tiny:.0%} / 7~15字 {mid:.0%} / ≥31字 {long_:.0%}")
print(f"情绪分布 {dict(mood.most_common())}")
print(f"月度支出 " + " ".join(f"{k[2:]}:{int(v / 100)}百" for k, v in sorted(monthly.items())))
print(f"餐饮(微信)月度 " + " ".join(f"{k[5:]}:{int(v)}" for k, v in sorted(wx_full.items())) + f"｜预算 {budget:.0f}，超支 {over:.0%} 的月份")
print(f"工作日日均 {avg_wk:.2f} 笔 / 休息日 {avg_we:.2f} 笔｜空备注 {blank:.0%}｜跑步 {len(HR)} 次，最长断档 {longest_break} 天，赛前峰值 {peak} 公里")
print(f"待办 {len(TK)} 条，完成 {done:.0%}，周报类 {weekly} 条，逾期未做 {len(overdue)} 条，今日时间块 {len(today_blocks)} 个")
covered = set()
for level, group, msg in issues:
    covered.add(group)
    if level != INFO:
        print(f"  {'❌' if level == FAIL else '⚠️ '} [{group}] {msg}")
print()
for g in groups:
    if g not in covered:
        print(f"  ✅ [{g}] 无异常")
print()
if fails:
    print(f"❌ 未通过：{len(fails)} 项 FAIL，{len(warns)} 项 WARN")
    sys.exit(1)
print(f"✅ 程序化活人感审查通过（{len(warns)} 项 WARN）")
