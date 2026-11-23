#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""小满剧本生成器 v2（真实日历驱动）

产出 story.json，由 HoloStorySeeder（HOLO 工程里的 DEBUG 注入口）灌进模拟器。
字段真源：SCHEMA.md。语料真源：xiaoman_corpus.py。人设真源：
~/Desktop/Claude/商业化/自媒体/Holo小红书/seed/xiaoman-人格设定.md

为什么是 v2（2026-11-23 复审的结论）：
v1 用「几天前」的整数运算日期，正负方向连着错了四次（赛后感想落在赛前、
机票付款落在旅行之后、旅行准备待办排在旅行结束后、跨年夜差了一个月），
而且随机撒日期的时间敏感内容会互相打架。v2 的三条规矩：
1. 全程用真实日期生成，输出也写真实日期，不做任何「相对天数」换算；
2. 节日、调休、赛事、行程钉在 2026 年真实日历上；今天超出有效期直接退出——
   宁可不出数据，也不出一份数据自相矛盾的剧本；
3. 金额、时段、类目、备注跟商家绑定；想法按内容绑定时段；一件事在各个模块
   之间要有涟漪（办卡→去了几次、比赛→训练曲线→买鞋→报名费）。

确定性：random.Random(42)，同一天生成结果逐字节一致。
用法：python3 generate.py [--claims-md 口径表的输出路径]
"""
import json
import random
import re
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta

import xiaoman_corpus as C

# ───────────────────────── 日历表 ─────────────────────────
VALID_FROM, VALID_TO = date(2026, 11, 23), date(2026, 12, 30)
TODAY = date.today()
if not (VALID_FROM <= TODAY <= VALID_TO):
    sys.exit(
        f"剧本日历锚点只保证 {VALID_FROM}~{VALID_TO} 期间自洽，今天是 {TODAY}。\n"
        "节日、调休、赛事都钉在 2026 年真实日历上，过了年底请给小满重排事件表再生成。")
NOW = datetime.now()
START = date(2025, 11, 24)          # 小满开始用 Holo 的那天（周一）
RACE = date(2026, 11, 1)            # 杭州半马（周日）
RACE_KM = 21.17                      # 跑表记出来的距离总会比 21.1 多一点点
R = random.Random(42)


def D(s):
    y, m, d = map(int, s.split("-"))
    return date(y, m, d)


def span(a, b):
    out = []
    while a <= b:
        out.append(a)
        a += timedelta(days=1)
    return out


def next_month(d):
    return (d.replace(day=28) + timedelta(days=4)).replace(day=1)


# 2026 年放假安排（国办 2025-11-04 通知）与调休上班日
HOLIDAYS = set(
    span(D("2026-01-01"), D("2026-01-03")) + span(D("2026-02-15"), D("2026-02-23"))
    + span(D("2026-04-04"), D("2026-04-06")) + span(D("2026-05-01"), D("2026-05-05"))
    + span(D("2026-06-19"), D("2026-06-21")) + span(D("2026-09-25"), D("2026-09-27"))
    + span(D("2026-10-01"), D("2026-10-07")))
MAKEUP_WORKDAYS = {D("2026-01-04"), D("2026-02-14"), D("2026-02-28"),
                   D("2026-05-09"), D("2026-09-20"), D("2026-10-10")}
assert START.weekday() == 0 and RACE.weekday() == 6 and D("2026-11-23").weekday() == 0
assert D("2026-02-16").weekday() == 0 and D("2026-10-01").weekday() == 3   # 除夕周一、国庆周四

# 不在杭州的日子：只写明确发生的事，不出通勤、工作午餐这类日常
AWAY = [(D("2026-02-15"), D("2026-02-22")),   # 回南通过年
        (D("2026-04-23"), D("2026-04-28")),   # 日本关西
        (D("2026-08-26"), D("2026-08-28")),   # 深圳出差
        (D("2026-10-02"), D("2026-10-04")),   # 莫干山
        (D("2026-03-19"), D("2026-03-19"))]   # 上海出差
# 完全没记录的日子：真人不会 365 天一天不落
GAPS = set(span(D("2025-11-28"), D("2025-11-30")) + span(D("2026-04-04"), D("2026-04-05"))
           + span(D("2026-06-26"), D("2026-06-28")) + span(D("2026-08-14"), D("2026-08-16")))
ILLNESS = span(D("2026-07-08"), D("2026-07-10"))   # 急性肠胃炎，躺着
# 一年中哪儿都没去的周末：有想法、有读书，但一分钱没花（「周末两天没下楼」得有真实落点）
STAY_HOME = {D("2025-12-13"), D("2025-12-14")}
# 这些天晚饭有安排（生日局、年会、同学聚会、婚宴、平安夜、跑团聚餐），日常不再点外卖
NO_DINNER = {D("2025-12-24"), D("2026-01-23"), D("2026-02-18"), D("2026-03-13"), D("2026-07-25"), RACE}


def is_workday(d):
    if d in MAKEUP_WORKDAYS:
        return True
    if d in HOLIDAYS:
        return False
    return d.weekday() < 5


# 现金只有过年我妈塞在包里的一千：从那以后才偶尔用现金，之前钱包里没钱
CASH_FROM = D("2026-02-22")


def recordable(d):
    return START <= d < TODAY and d not in GAPS


def at_home(d):
    return not any(a <= d <= b for a, b in AWAY)


def recordable_days(a, b):
    return [d for d in span(a, min(b, TODAY - timedelta(days=1))) if recordable(d)]


def cents(y):
    return int(round(y * 100))


def hm(total):
    return total // 60, total % 60


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M")


def at(d, hour=0, minute=0):
    return datetime(d.year, d.month, d.day, hour, minute)


def price(lo, hi):
    """区间内取价：整元 / 半元 / 带角 三种尾数混合，外卖与超市的价格就长这样"""
    v = lo + (hi - lo) * R.random()
    r = R.random()
    p = round(v) if r < 0.35 else (round(v * 2) / 2 if r < 0.50 else round(v, 1))
    return min(hi, max(lo, p))


WX, ZFB, CARD, CASH, BANK = "微信", "支付宝", "信用卡", "现金", "储蓄卡"
TX, THOUGHTS, TASKS, HABIT_RECORDS, RUNS, BOOK_DATES = [], [], [], [], [], []
BOOKS_BY_DATE = {}

# ───────────────────────── 记账 ─────────────────────────


def expense(day, hmt, category, account, amount, note="", **extra):
    h, m = hmt if isinstance(hmt, tuple) else (hmt, R.randint(0, 59))
    t = {"type": "expense", "category": category, "account": account,
         "amountCents": cents(amount), "date": iso(at(day, h, m))}
    if note:
        t["note"] = note
    t.update(extra)
    TX.append(t)
    return t


def income(day, hmt, category, account, amount, note="", **extra):
    t = expense(day, hmt, category, account, amount, note, **extra)
    t["type"] = "income"
    return t


def metro_fare():
    return R.choices([4, 5, 3, 7], weights=[52, 30, 10, 8])[0]


def coffee(month, day):
    """(金额, 备注)：券后价跟品牌绑定，冷热跟季节绑定"""
    brand = R.choices(list(C.COFFEE), weights=[C.COFFEE[b][0] for b in C.COFFEE])[0]
    _, coupon, normal = C.COFFEE[brand]
    amount = coupon if coupon and R.random() < (0.55 if brand == "瑞幸" else 0.45) else price(*normal)
    product = R.choice(C.COFFEE_COLD if 5 <= month <= 10 else C.COFFEE_HOT)
    r = R.random()
    if r < 0.45:
        note = f"{brand} {product}" if brand.isascii() else f"{brand}{product}"
    elif r < 0.75:
        note = brand
    else:
        note = ""
    if note and R.random() < 0.08:
        remark = R.choice(C.COFFEE_REMARK)
        if remark == "今天第二杯" and not any(t.get("category") == "咖啡" and t.get("date", "")[:10] == day.isoformat() for t in TX):
            remark = "续命"             # 说「今天第二杯」之前，得真有第一杯
        note = f"{note}，{remark}"
    return amount, note


def lunch_note(merchant):
    if merchant == "兰州拉面" and R.random() < 0.08:
        merchant = "兰洲拉面"          # 偶尔打错字，一年一两次
    r = R.random()
    if r < 0.16:
        return R.choice(C.LUNCH_PLAIN)
    if r < 0.28:
        return ""
    if r < 0.40:
        return f"{merchant}（{R.choice(C.LUNCH_REMARK)}）"
    return merchant


REMARK_USE = Counter()


def dinner(day, work):
    if work and day.weekday() == 3 and R.random() < 0.30:      # 疯狂星期四
        note, lo, hi, cat = C.KFC_THU[0], C.KFC_THU[1], C.KFC_THU[2], "外卖"
    else:
        note, lo, hi, cat = R.choice(C.DINNER)
        while not work and note == "食堂":            # 食堂只在工作日
            note, lo, hi, cat = R.choice(C.DINNER)
        if cat == "外卖" and R.random() < 0.25:
            note = R.choice(["外卖", "外卖", "", "晚饭外卖"])
        elif R.random() < 0.22:
            remark = R.choice(C.DINNER_REMARK)
            if REMARK_USE[remark] >= 2:                # 同一句俏皮话一年最多说两次
                remark = next((x for x in ("懒得做", "下雨不想出门", "一个人吃") if REMARK_USE[x] < 2), "懒得做")
            REMARK_USE[remark] += 1
            note = f"{note}，{remark}"
    expense(day, hm(1070 + R.randint(0, 170)), cat, R.choice([WX, ZFB]), price(lo, hi), note)


DAY_NOTES = defaultdict(set)


def fresh_note(day, pool):
    """同一天不重复买同一样东西（一天买两次鲈鱼就露馅）"""
    opts = [n for n in pool if n not in DAY_NOTES[day]]
    if not opts:
        return ""
    n = R.choice(opts + [""])
    if n:
        DAY_NOTES[day].add(n)
    return n


def leisure(day):
    """休息日的一笔生活消费"""
    summer = day.month in (6, 7, 8)
    kind = R.choices(["超市", "水果", "饮品", "购物", "买菜", "电影", "门票", "咖啡"],
                     weights=[26, 20, 22 if summer else 13, 17, 12, 5, 5, 4])[0]
    daytime = hm(600 + R.randint(0, 540))   # 10:00–19:00
    if kind == "超市":
        note, lo, hi = R.choice(C.SUPERMARKET)
        if R.random() < 0.22:
            note = f"{note}，{R.choice(C.SUPERMARKET_REMARK)}"
        expense(day, daytime, "超市", ZFB, price(lo, hi), note)
    elif kind == "水果":
        fruit = R.choice(C.FRUIT_BY_MONTH[day.month])
        if fruit in DAY_NOTES[day]:
            fruit = ""                                  # 同一天不重复买同一种水果
        else:
            DAY_NOTES[day].add(fruit)
        expense(day, daytime, "水果", R.choice([WX, ZFB]), price(12, 62),
                R.choice([fruit, fruit, "水果店", "水果", ""] if fruit else ["水果店", "水果", ""]))
    elif kind == "饮品":
        note, lo, hi = R.choice(C.DRINKS)
        expense(day, hm(600 + R.randint(0, 600)), "饮品", WX, price(lo, hi), note)
    elif kind == "购物":
        cat, shop, lo, hi, items = R.choice(C.SHOPPING)
        note = f"{shop}{R.choice(items)}" if R.random() < 0.55 else shop
        expense(day, daytime, cat, R.choice([WX, ZFB, CARD]), price(lo, hi), note)
    elif kind == "买菜":
        expense(day, hm(600 + R.randint(0, 420)), "买菜", (R.choice([WX, ZFB, CASH, CASH]) if day >= CASH_FROM else R.choice([WX, ZFB])), price(18, 68),
                fresh_note(day, ["两天的菜", "买了排骨", "鲈鱼", "番茄鸡蛋", "菜市场", "明天带饭"]))
    elif kind == "电影":
        expense(day, hm(780 + R.randint(0, 300)), "电影", WX, price(36, 59.9),
                R.choice(["电影票", "电影", "IMAX场", "和露露看电影", "周二没赶上半价"]))
    elif kind == "门票":
        expense(day, daytime, "展览" if R.random() < 0.6 else "门票", WX, price(38, 120),
                R.choice(["看展", "美术馆特展", "博物馆 讲解", "密室，和同事"]))
    else:
        expense(day, hm(600 + R.randint(0, 390)), "咖啡", WX, price(28, 46), R.choice(["咖啡店，坐了一下午", "手冲", "和露露喝咖啡"]))


def routine(day):
    """一个普通日子：工作日有通勤和工作餐，休息日有生活消费"""
    work = is_workday(day)
    month = day.month
    summer = month in (6, 7, 8)
    first_day = day == START

    if work:
        # 早高峰：偶尔打车（起晚了/下雨），多数地铁
        r = R.random()
        if r < 0.035:
            note, lo, hi = R.choice(C.TAXI_AM[:2])
            expense(day, hm(470 + R.randint(0, 90)), "交通/打车", R.choice([WX, ZFB]), price(lo, hi), note)
        elif r < 0.915:
            expense(day, hm(455 + R.randint(0, 90)), "交通/地铁", ZFB, metro_fare(),
                    R.choice(["", "", "", "地铁", "上班", "早高峰"]))
        if R.random() < 0.74:
            merchant, lo, hi = R.choice(C.LUNCH)
            expense(day, hm(695 + R.randint(0, 85)), "午餐", WX, price(lo, hi), lunch_note(merchant))
        if not first_day and R.random() < (0.36 if summer else 0.44):
            amt, note = coffee(month, day)
            base = 465 if R.random() < 0.6 else 800
            expense(day, hm(base + R.randint(0, 105 if base == 465 else 140)), "咖啡",
                    WX if R.random() < 0.7 else ZFB, amt, note)
        if R.random() < 0.06:
            expense(day, hm(490 + R.randint(0, 60)), "交通/单车", ZFB, 1.5, R.choice(["哈啰单车", "美团单车", ""]))
        # 晚高峰：加班到深夜打车，或者地铁
        r = R.random()
        if r < 0.08:
            note, lo, hi = R.choice(C.TAXI_PM)
            total = 1285 + R.randint(0, 140)
            if "地铁没了" in note and total < 23 * 60 + 10:
                note = "加班打车"            # 地铁十一点后才停，更早的加班打车不能赖地铁
            expense(day, hm(total), "交通/打车", R.choice([WX, ZFB]), price(lo, hi), note)
        elif r < 0.93:
            base = R.choices([1085, 1265], weights=[85, 15])[0]
            expense(day, hm(base + R.randint(0, 70)), "交通/地铁", ZFB, metro_fare(),
                    R.choice(["", "", "", "地铁", "下班", "加班回来"]))
        if R.random() < 0.56 and day not in NO_DINNER:
            dinner(day, work)
        elif R.random() < 0.10:
            expense(day, hm(1170 + R.randint(0, 90)), "外卖", WX, price(18, 36), "加班餐")
    else:
        if R.random() < 0.07:          # 躺了一天，一分钱没花
            return
        if R.random() < 0.35:
            note, lo, hi = R.choice(C.BREAKFAST)
            expense(day, hm(540 + R.randint(0, 100)), "外卖", WX, price(lo, hi), note)
        if not first_day and R.random() < 0.22:
            amt, note = coffee(month, day)
            expense(day, hm(600 + R.randint(0, 360)), "咖啡", WX, amt, note)
        if R.random() < 0.35:
            expense(day, hm(690 + R.randint(0, 60)), "午餐", WX, price(28, 86),
                    R.choice(["和露露吃brunch", "早午餐", "面馆", "酸汤牛肉", "湘湖边吃饭", "日料放题", "云南菜"]))
        for _ in range(R.choice([1, 2, 2, 3, 3])):
            leisure(day)
        if R.random() < 0.70 and day not in NO_DINNER:
            dinner(day, work)

    if day.day >= 25 and R.random() < 0.30:     # 月末囤货
        expense(day, hm(600 + R.randint(0, 540)), "日用", ZFB, price(19, 88),
                R.choice(["月末清购物车", "囤货", "纸巾", "洗漱用品补货", ""]))
    # 深夜冲动消费：一年五六次，可能落在第二天凌晨
    nxt = day + timedelta(days=1)
    if R.random() < (5.5 / 330) and recordable(nxt) and at_home(nxt) and nxt not in STAY_HOME:
        cat, note, lo, hi = R.choice(C.NIGHT_SNACK)
        total = 1385 + R.randint(0, 95)
        expense(nxt if total >= 1440 else day, hm(total % 1440), cat, R.choice([WX, ZFB]), price(lo, hi), note)


# 上班日一早先跑了长距离（九点前跑不完）：那天早上没有通勤和咖啡
MORNING_BUSY = {D("2026-09-20")}
NOT_BEFORE = {START: "T09:30", RACE: "T24:00", D("2026-10-01"): "T11:30"}      # 这天此刻之前的日常流水不算


def skip_routine_tx(t):
    """日常流水里不该出现的那几笔"""
    ds = t.get("date", "")
    if ds[:10] in {x.isoformat() for x in MORNING_BUSY} and "T05" <= ds[10:13] < "T10" \
            and t.get("category") in ("交通/地铁", "交通/打车", "交通/单车", "咖啡"):
        return True
    return any(ds[:10] == day.isoformat() and ds[10:16] < lim for day, lim in NOT_BEFORE.items())


def gen_today():
    """今天只记此刻之前已经发生的：先生成全天，再把还没到点的丢掉（咖啡由 gen_events 写）"""
    if TODAY in GAPS or not at_home(TODAY):
        return
    before = len(TX)
    routine(TODAY)
    cutoff = NOW - timedelta(minutes=25)
    keep = []
    for t in TX[before:]:
        if t["date"] < cutoff.strftime("%Y-%m-%dT%H:%M") and t.get("category") != "咖啡":
            keep.append(t)
    TX[before:] = keep


def payday(year, month):
    """发薪日是 10 号；撞上周末就提前到上一个工作日"""
    d = date(year, month, 10)
    while not is_workday(d):
        d -= timedelta(days=1)
    return d


def utility_amount(month):
    lo, hi = {12: (92, 148), 1: (96, 156), 2: (80, 128), 7: (128, 212), 8: (135, 218)}.get(month, (56, 98))
    return round(R.uniform(lo, hi), 2)


def gen_fixed():
    """自动扣款的固定流水：话费与三个订阅。房租、水电跟着对应的待办走（见待办部分）"""
    d = D("2025-12-01")
    while d < TODAY:
        y, m = d.year, d.month
        pay = payday(y, m)
        if recordable(pay) and at_home(pay):
            amount = 12800 if pay < D("2026-08-01") else 14200
            income(pay, (10, 5 + R.randint(-3, 3)), "工资", BANK, amount, "工资")
            # 发工资先存后花：到账一两分钟后转三千进旅行专款
            tr = at(pay, 10, 7 + R.randint(0, 6))
            income(pay, (tr.hour, tr.minute), "转入", "旅行专款", 3000,
                   R.choice(["发工资先存", "", "", "转3000", "旅行专款"]))
            add_task(R.choices(["转3000去旅行专款", "存钱3000", "发工资先存", "转钱去旅行基金", "固定存款3000"],
                               weights=[4, 3, 3, 1, 1])[0],
                     at(pay, 9, 41), comp=tr + timedelta(minutes=3))
        for day_no, cat, amt, note in ((6, "居住/话费", 39, "话费"), (3, "学习/订阅", 6, "iCloud自动续费"),
                                       (12, "学习/订阅", 19, "微信读书"), (18, "娱乐/音乐", 15, "网易云黑胶")):
            x = date(y, m, day_no)
            if x < TODAY and x not in GAPS:        # 自动续费不看人在哪（在南通过年也照扣）
                expense(x, (R.choice([8, 9, 10, 13, 14, 15, 20, 21]), R.randint(0, 59)), cat, ZFB, amt,
                        note)
        d = next_month(d)
    # 年终奖与转存
    income(D("2026-01-30"), (11, 2), "奖金", BANK, 11520, "年终奖")
    income(D("2026-01-30"), (11, 24), "转入", "旅行专款", 5000, "年终奖先存五千")
    add_task("年终奖转旅行专款", datetime(2026, 1, 29, 21, 12), comp=datetime(2026, 1, 30, 11, 24))
    # 健身卡：24 期分期，六月十一日办的
    TX.append({"id": "gym", "type": "expense", "category": "健身", "account": CARD,
               "amountCents": cents(6912), "note": "健身卡两年卡",
               "installment": {"periods": 24, "startDate": "2026-06-11T11:30"}})


JAPAN = "日本关西6天"


def gen_events():
    E = expense
    # 开始用 Holo 的第一天
    E(START, (8, 58), "咖啡", WX, 9.9, "瑞幸生椰拿铁")      # 她记的第一笔
    # 年底、年会
    E(D("2025-12-24"), (19, 12), "请客", WX, 128, "平安夜和露露吃饭AA")
    E(D("2025-12-24"), (19, 48), "饮品", WX, 18, "热红酒，现煮的")
    E(D("2026-01-10"), (10, 26), "疫苗", ZFB, 1319, "九价第二针")
    E(D("2026-01-22"), (19, 40), "服饰", CARD, 299, "年会裙子，穿一次")
    E(D("2026-01-23"), (21, 5), "交通/打车", WX, 38.5, "年会结束打车回")
    E(D("2026-01-27"), (19, 12), "药品", ZFB, 26.8, "感冒药，嗓子疼")
    # 回南通过年：票是提前抢的
    E(D("2026-01-31"), (14, 3), "交通/火车", ZFB, 236.5, "回家高铁，候补到的")
    E(D("2026-01-31"), (14, 5), "交通/火车", ZFB, 236.5, "返程高铁")
    E(D("2026-02-08"), (15, 22), "礼物", CARD, 568, "给我妈买的羽绒服，她肯定说贵")
    E(D("2026-02-12"), (20, 41), "礼物", WX, 288, "我爸的茶叶")
    E(D("2026-02-13"), (19, 30), "超市", ZFB, 386.5, "带给亲戚的年货，一车")
    E(D("2026-02-15"), (8, 12), "早餐", WX, 18, "高铁站 早饭")
    E(D("2026-02-16"), (10, 20), "红包礼金", WX, 200, "表姐家的小侄女")
    E(D("2026-02-16"), (20, 12), "红包礼金", WX, 600, "给外婆的红包")
    E(D("2026-02-17"), (11, 20), "红包礼金", WX, 1000, "给我爸妈的")
    income(D("2026-02-17"), (11, 5), "红包", WX, 600, "外婆，非说没结婚都有压岁钱")
    E(D("2026-02-18"), (19, 30), "请客", WX, 128, "初中同学聚会AA")
    E(D("2026-02-18"), (21, 40), "KTV", WX, 66, "KTV，唱到十二点")
    E(D("2026-02-19"), (12, 0), "请客", WX, 68, "抢着给表哥买了单")
    E(D("2026-02-20"), (15, 30), "超市", ZFB, 186.5, "陪我妈超市，她非要用现金")
    E(D("2026-02-20"), (17, 40), "玩具", WX, 89, "给表弟家娃买的玩具")
    E(D("2026-02-21"), (16, 22), "交通/打车", ZFB, 23.5, "南通打车，比杭州便宜")
    E(D("2026-02-22"), (15, 10), "水果", WX, 38, "路上吃的")
    income(D("2026-02-22"), (15, 40), "红包", CASH, 1000, "我妈偷偷塞在包里的")
    # 生日
    E(D("2026-03-10"), (20, 15), "甜品", WX, 168, "生日蛋糕，订的")
    E(D("2026-03-13"), (20, 30), "请客", WX, 288, "生日局，我买单")
    E(D("2026-03-21"), (11, 40), "牙齿保健", ZFB, 298, "洗牙，半年一次")
    # 上海出差
    E(D("2026-03-19"), (7, 45), "交通/火车", BANK, 73, "去上海虹桥")
    E(D("2026-03-19"), (9, 30), "交通/地铁", ZFB, 5, "上海地铁")
    E(D("2026-03-19"), (12, 20), "午餐", WX, 38, "客户楼下 面馆")
    E(D("2026-03-19"), (18, 10), "交通/火车", BANK, 73, "回杭州")
    E(D("2026-03-25"), (12, 40), "保险", CARD, 68, "境外旅行险 六天")
    income(D("2026-03-31"), (11, 5), "报销", BANK, 189, "上海出差报销")
    # 日本：签证、机票、住宿、门票都是提前一个多月付的
    E(D("2026-03-02"), (20, 41), "旅游", CARD, 328, "日本签证，单次，淘宝代办", project=JAPAN)
    E(D("2026-03-14"), (10, 52), "交通/机票", "旅行专款", 1480, "去程机票，吉祥直飞", project=JAPAN)
    E(D("2026-03-14"), (10, 54), "交通/机票", "旅行专款", 1320, "回程机票", project=JAPAN)
    E(D("2026-03-16"), (21, 18), "住宿", "旅行专款", 1140, "大阪民宿 三晚", project=JAPAN)
    E(D("2026-03-18"), (21, 30), "住宿", "旅行专款", 320, "京都民宿 一晚", project=JAPAN)
    E(D("2026-03-20"), (12, 46), "住宿", "旅行专款", 880, "温泉旅馆 一泊二食", project=JAPAN)
    E(D("2026-04-02"), (20, 12), "旅行", ZFB, 128, "ICOCA卡，淘宝", project=JAPAN)
    E(D("2026-04-10"), (13, 20), "门票", "旅行专款", 698, "环球影城 门票加快速4项", project=JAPAN)
    trip = [  # 行程内（按当地时间）：(月-日, 时刻, 类目, 1=现金, 金额, 备注)
        ("04-23", "06:48", "早餐", 0, 32, "机场星巴克，贵但认了"), ("04-23", "14:05", "超市", 1, 68.5, "关空便利店 饭团加咖啡"),
        ("04-23", "15:30", "火车", 0, 48, "南海电空港急行"), ("04-23", "17:20", "美妆", 0, 186.5, "药妆店，第一天就没忍住"),
        ("04-23", "19:10", "晚餐", 1, 96, "道顿堀 章鱼烧加串炸"), ("04-23", "20:15", "超市", 1, 58, "超市，八点后半价"),
        ("04-24", "08:20", "早餐", 1, 42, "便利店 饭团加咖啡"), ("04-24", "12:40", "午餐", 0, 158, "USJ园区午餐，哈利波特主题"),
        ("04-24", "15:30", "饮品", 0, 58, "黄油啤酒，无酒精的"), ("04-24", "19:40", "晚餐", 1, 76, "难波，随便吃了点"),
        ("04-25", "10:30", "午餐", 1, 186, "黑门市场海鲜丼"), ("04-25", "10:40", "门票", 0, 138, "海游馆"),
        ("04-25", "13:30", "门票", 0, 68, "天保山摩天轮"), ("04-25", "18:30", "晚餐", 0, 288, "烧肉放题晚市"),
        ("04-25", "20:30", "日用", 0, 215, "唐吉诃德 战利品"), ("04-26", "08:50", "火车", 1, 28, "大阪到京都 JR"),
        ("04-26", "11:30", "门票", 1, 45, "清水寺 加御守"), ("04-26", "13:00", "午餐", 1, 78, "抹茶荞麦面"),
        ("04-26", "15:00", "零食", 1, 66, "锦市场，边走边吃"), ("04-26", "16:00", "礼物", 0, 156, "抹茶伴手礼，给同事带的"),
        ("04-26", "18:40", "晚餐", 1, 142, "先斗町居酒屋，一个人"), ("04-27", "09:30", "火车", 1, 15, "JR去岚山"),
        ("04-27", "11:00", "午餐", 1, 128, "汤豆腐 午市"), ("04-27", "21:00", "饮品", 1, 12, "贩卖机 牛奶"),
        ("04-28", "09:50", "手续费", 1, 22, "京都站 行李寄存"), ("04-28", "10:40", "甜品", 0, 58, "宇治中村藤吉，排了一小时"),
        ("04-28", "12:30", "午餐", 1, 92, "京都站 拉面小路"), ("04-28", "14:00", "火车", 0, 148, "HARUKA 京都到关空"),
        ("04-28", "17:20", "美妆", 0, 460, "关空免税店，最后冲刺"),
    ]
    for md, hhmm, cat, cash, amt, note in trip:
        h, m = map(int, hhmm.split(":"))
        E(D(f"2026-{md}"), (h, m), cat, CARD if cash else ZFB, amt, note, project=JAPAN)
    E(D("2026-04-28"), (21, 40), "交通/公交", ZFB, 20, "机场大巴回滨江")
    E(D("2026-04-23"), (21, 30), "水果", CASH, 38, "草莓一盒 八百日元", project=JAPAN)
    E(D("2026-04-28"), (23, 5), "超市", WX, 21.5, "全家关东煮，落地第一顿")
    E(D("2026-04-29"), (9, 5), "咖啡", WX, 15.5, "manner 倒时差…只有一小时")
    # 五一、演唱会、室友生日
    E(D("2026-05-01"), (15, 22), "服饰", CARD, 298, "优衣库两件T，人山人海")
    E(D("2026-05-30"), (20, 5), "演唱会", CARD, 680, "演唱会看台，边上也认了")
    E(D("2026-06-06"), (15, 10), "礼物", WX, 128, "室友生日，香薰")
    # 618
    E(D("2026-06-17"), (20, 15), "鞋包", CARD, 399, "相机包")
    E(D("2026-06-18"), (0, 8), "数码", CARD, 1299, "显示器2K，618价")
    E(D("2026-06-18"), (0, 11), "数码", CARD, 799, "键盘", id="keyboard")
    E(D("2026-06-18"), (20, 30), "服饰", CARD, 156, "T恤三件，618价")
    E(D("2026-06-19"), (11, 25), "零食", ZFB, 68.5, "囤零食")
    E(D("2026-06-19"), (15, 2), "日用", ZFB, 45.9, "插线板 凑单")
    E(D("2026-06-30"), (21, 10), "游戏", ZFB, 62, "Steam夏促，喜加三")
    TX.append({"id": "keyboard-refund", "refundOf": "keyboard", "amountCents": cents(799),
               "date": "2026-07-06T15:20", "remark": "键程不喜欢，退了"})
    # 肠胃炎、同事婚礼
    E(D("2026-07-08"), (21, 35), "药品", ZFB, 38.5, "蒙脱石散 口服补液盐")
    E(D("2026-07-09"), (9, 12), "就医", ZFB, 30, "社区医院 挂号")
    E(D("2026-07-09"), (9, 46), "药品", ZFB, 42.6, "医生开的药")
    E(D("2026-07-14"), (10, 20), "疫苗", ZFB, 1319, "九价第三针")
    E(D("2026-07-25"), (11, 28), "红包礼金", WX, 600, "同事婚礼 份子钱")
    # 调薪、深圳出差
    E(D("2026-08-10"), (15, 20), "咖啡", WX, 19.9, "调薪快乐水")
    E(D("2026-08-26"), (8, 12), "早餐", WX, 24, "机场 早饭")
    E(D("2026-08-26"), (8, 20), "交通/机票", BANK, 1080, "去深圳，出差")
    E(D("2026-08-26"), (19, 40), "晚餐", WX, 68, "和供应商晚饭，自己先垫")
    E(D("2026-08-26"), (21, 30), "住宿", CARD, 856, "酒店两晚，协议价")
    E(D("2026-08-27"), (12, 30), "午餐", WX, 45, "客户园区 食堂")
    E(D("2026-08-27"), (21, 10), "交通/打车", WX, 32.5, "深圳打车")
    E(D("2026-08-28"), (18, 40), "交通/机票", BANK, 990, "回杭州")
    E(D("2026-08-28"), (17, 50), "晚餐", WX, 56, "机场晚饭")
    income(D("2026-09-11"), (15, 22), "报销", BANK, 3071.5, "八月深圳出差报销")
    # 备赛：报名、装备、比赛日
    E(D("2026-09-03"), (10, 12), "体育赛事", ZFB, 150, "杭马报名费")
    E(D("2026-09-08"), (20, 45), "运动", CARD, 469, "特步260，618没买现在原价")
    E(D("2026-09-12"), (19, 35), "门票", WX, 198, "话剧，朋友圈别人推荐的")
    E(D("2026-09-15"), (20, 20), "运动", ZFB, 49.9, "盐丸 能量胶")
    E(D("2026-09-22"), (12, 8), "运动", ZFB, 59, "跑步腰包")
    E(D("2026-10-05"), (16, 12), "运动", ZFB, 89, "压缩腿套")
    E(D("2026-10-08"), (12, 20), "红包礼金", WX, 600, "给我爸的 补个生日")
    E(D("2026-10-16"), (15, 40), "眼镜", CARD, 680, "配眼镜，换镜片")
    E(RACE, (5, 50), "交通/打车", WX, 28, "凌晨打去起点")
    E(RACE, (12, 48), "午餐", WX, 48, "完赛餐，牛肉面双份牛肉")
    E(RACE, (13, 30), "交通/地铁", ZFB, 4, "挂着奖牌坐地铁")
    E(RACE, (19, 10), "请客", WX, 88, "跑团吃饭AA")
    E(D("2026-11-03"), (20, 12), "药品", ZFB, 29.9, "肌肉贴")
    # 莫干山
    mg = [("10-02", "09:10", "火车", 12, "杭州东到德清"), ("10-02", "09:45", "打车", 45, "德清站打车上山，和室友拼"),
          ("10-02", "10:30", "住宿", 760, "民宿两晚，我先付的"), ("10-02", "12:30", "午餐", 98, "农家菜 土鸡煲"),
          ("10-02", "15:00", "户外运动", 68, "骑行半天"), ("10-02", "19:10", "晚餐", 156, "晚餐，加了瓶啤酒"),
          ("10-03", "11:30", "午餐", 88, "笋干烧肉面"), ("10-03", "16:00", "日用", 46, "竹编杯垫"),
          ("10-03", "19:00", "晚餐", 128, "山里的晚上只有吃饭"), ("10-04", "09:30", "早餐", 36, "民宿早餐"),
          ("10-04", "14:00", "打车", 38, "下山打车"), ("10-04", "15:32", "火车", 12, "德清到杭州东")]
    for md, hhmm, cat, amt, note in mg:
        h, m = map(int, hhmm.split(":"))
        E(D(f"2026-{md}"), (h, m), cat, CARD if cat == "住宿" else ZFB, amt, note, project="莫干山两天")
    # 双十一
    E(D("2026-10-21"), (20, 15), "美妆", ZFB, 50, "面膜 预售定金")
    E(D("2026-10-24"), (0, 12), "美妆", ZFB, 100, "面膜 尾款")
    E(D("2026-10-24"), (0, 6), "服饰", CARD, 689, "羽绒服尾款", id="down-jacket")
    E(D("2026-10-24"), (0, 9), "日用", ZFB, 59.9, "抽纸12包，囤一年的")
    E(D("2026-10-26"), (21, 30), "礼物", CARD, 359, "给我妈买的按摩仪")
    E(D("2026-11-02"), (20, 40), "服饰", CARD, 129, "摇粒绒，顺便凑的")
    TX.append({"id": "jacket-refund", "refundOf": "down-jacket", "amountCents": cents(689),
               "date": "2026-11-09T15:10", "remark": "版型不对，退了"})
    E(D("2026-11-15"), (18, 20), "零食", CASH, 12, "地铁口 烤红薯")
    E(D("2026-11-17"), (21, 20), "日用", ZFB, 29, "数据线，被猫咬断的")
    # 今天的咖啡：这笔是有的（九点前写就是瑞幸），其余日常由 build() 按此刻之前的时刻补齐
    if (NOW.hour, NOW.minute) >= (8, 55):
        E(TODAY, (8, 41), "咖啡", WX, 13.8, "瑞幸厚乳拿铁")


# ───────────────────────── 跑步与习惯 ─────────────────────────


def km_str(km):
    """跑步 App 同步过来的距离：多数带两位小数，有时一位，偶尔整数"""
    r = R.random()
    return round(km, 2) if r < 0.55 else (round(km, 1) if r < 0.8 else round(km))


def run_day(d, km, start_min, pace_s, note=None):
    """记录时间 = 开跑 + 用时 + 歇几分钟。pace_s 是每公里秒数。"""
    end = start_min + int(km * pace_s) // 60 + R.randint(2, 9)
    RUNS.append((d, km_str(km), end // 60, end % 60, note))


def gen_runs():
    # 第一阶段：新年立志后到三月初，每周两三次，三四公里（配速七分半到八分半，新手）
    run_day(D("2026-01-05"), 3.1, 19 * 60 + 30, 418, "第一次，跑走结合")
    for d in span(D("2026-01-06"), D("2026-03-05")):
        if d.weekday() in (1, 3, 5, 6) and recordable(d) and at_home(d):
            p = 0.72 if d < D("2026-02-15") else (0.6 if d.month == 2 else 0.5)
            if R.random() < p:
                weekend = d.weekday() >= 5
                km = R.uniform(4.0, 6.0) if weekend else R.uniform(3.0, 5.2)
                start = 6 * 60 + R.randint(20, 110) if weekend else 19 * 60 + R.randint(10, 60)
                run_day(d, km, start, R.uniform(478, 522), None if R.random() < 0.75 else R.choice(C.RUN_NOTES[:3]))
    # 断档七十天，五月十八日复跑
    resume = D("2026-05-18")
    run_day(resume, 3.2, 19 * 60 + 30, 432, "重新开始，别再断了")
    for d in span(D("2026-05-19"), D("2026-08-23")):
        if not (recordable(d) and at_home(d)) or D("2026-07-08") <= d <= D("2026-07-20"):
            continue
        hot = d >= D("2026-07-01")
        wd = d.weekday()
        if wd == 3 and R.random() < (0.5 if hot else 0.72):
            run_day(d, R.uniform(4.0, 6.4), 19 * 60 + R.randint(10, 50), R.uniform(468, 505))
        elif wd == 5 and R.random() < 0.55:
            run_day(d, R.uniform(4.0, 5.6), 7 * 60 + R.randint(0, 70), R.uniform(470, 515))
        elif wd == 6 and R.random() < (0.35 if hot else 0.5):
            run_day(d, R.uniform(5.0, 7.2), 6 * 60 + R.randint(20, 90), R.uniform(470, 515),
                    None if R.random() < 0.7 else R.choice(C.RUN_NOTES))
    # 第三阶段：八月底开始九周备赛，周日拉长距离，周中两次
    long_runs = [(D("2026-08-30"), 10.2), (D("2026-09-06"), 12.4), (D("2026-09-13"), 14.8), (D("2026-09-20"), 16.5),
                 (D("2026-09-26"), 18.6), (D("2026-10-03"), 12.0), (D("2026-10-11"), 20.1), (D("2026-10-18"), 14.2),
                 (D("2026-10-25"), 10.5)]
    long_days = {d for d, _ in long_runs}
    for d, km in long_runs:
        if d.month == 8:
            start = 6 * 60 + R.randint(0, 20)
        elif d.month == 9:
            start = 6 * 60 + R.randint(10, 40)
        else:
            start = 6 * 60 + R.randint(40, 70)
        if d == D("2026-10-03"):
            start, note = 7 * 60 + 30, "莫干山跑山"
        elif d == D("2026-09-20"):
            note = "调休上班前跑完"
        elif d == D("2026-10-11"):
            note = "赛前最长的一次"
        else:
            note = R.choice(["长距离", "LSD", "绕湘湖两圈", None, "长距离"])
        run_day(d, km, start, R.uniform(482, 528), note)
    for d in span(D("2026-08-31"), D("2026-10-25")):
        wd = d.weekday()
        if not (recordable(d) and at_home(d)) or d in long_days:
            continue
        if wd == 1 and R.random() < 0.85:
            run_day(d, R.uniform(6.0, 8.0), 19 * 60 + R.randint(10, 40), R.uniform(455, 495))
        elif wd == 3 and R.random() < 0.8:
            run_day(d, R.uniform(5.0, 7.0), 19 * 60 + R.randint(10, 40), R.uniform(452, 492),
                    None if R.random() < 0.8 else "节奏跑")
        elif wd == 5 and R.random() < 0.6:
            run_day(d, R.uniform(4.0, 5.2), 7 * 60 + R.randint(0, 60), R.uniform(475, 520))
    # 比赛：七点半开跑，2:41:33 冲线，挂着奖牌歇了半小时才想起来记一笔
    RUNS.append((RACE, RACE_KM, 10, 41, "杭州半马 2:41:33"))


def gen_habits_and_records():
    global BOOKS_BY_DATE
    # 读书：一年读完 19 本，从一月第二周开始
    d = D("2026-01-08")
    for _ in range(19):
        while not (recordable(d) and at_home(d)):
            d += timedelta(days=1)
        BOOK_DATES.append(d)
        d += timedelta(days=R.randint(8, 22))
    books = C.BOOKS[:]
    R.shuffle(books)
    BOOKS_BY_DATE = dict(zip(BOOK_DATES, books))
    for x in recordable_days(START, TODAY):
        p = 0.60 if x < START + timedelta(days=14) else 0.80
        if not at_home(x):
            p = 0.30
        if x in ILLNESS or any(t.get("category") == "KTV" and t.get("date", "")[:10] == x.isoformat() for t in TX):
            p = 0
        if x in BOOK_DATES or R.random() < p:
            mins = R.choice([10, 15, 20, 20, 30, 30, 30, 40, 45, 60, 60, 90]) if R.random() < 0.55 \
                else int(R.uniform(12, 76))
            h, m = hm(21 * 60 + R.randint(0, 179))
            HABIT_RECORDS.append({"habit": "阅读", "date": iso(at(x, h, m)), "value": mins})
    for month in {r["date"][:7] for r in HABIT_RECORDS if r["habit"] == "阅读"}:
        recs = [r for r in HABIT_RECORDS if r["habit"] == "阅读" and r["date"][:7] == month]
        if sum(r["value"] for r in recs) % 10 == 0:
            recs[0]["value"] += 7
    # 早起：一月尾试了七周，三月放弃
    for x in recordable_days(D("2026-01-20"), D("2026-03-10")):
        if any("起晚了" in t.get("note", "") and t.get("date", "")[:10] == x.isoformat() for t in TX):
            continue
        if R.random() < 0.55:
            ok = R.random() >= 0.15
            HABIT_RECORDS.append({"habit": "早起", "completed": ok,
                                  "date": iso(at(x, 6 if ok else R.randint(7, 10), R.randint(0, 59)))})
    # 健身房：办卡后一个半月去了五次，之后三次
    for x in ("2026-06-13", "2026-06-16", "2026-06-20", "2026-06-24", "2026-07-05",
              "2026-08-02", "2026-09-15", "2026-10-24"):
        HABIT_RECORDS.append({"habit": "健身", "date": f"{x}T{R.choice([19, 20, 20, 21]):02d}:{R.randint(10, 55):02d}"})
    for d, km, h, m, note in RUNS:
        rec = {"habit": "跑步", "date": iso(at(d, h, m)), "value": km}
        if note:
            rec["note"] = note
        HABIT_RECORDS.append(rec)


# ───────────────────────── 待办 ─────────────────────────


def add_task(title, cdt, comp=None, due=None, block=None, importance=None, note=None, status=None, archived=False):
    t = {"title": title, "createdAt": iso(cdt)}
    if status is None:
        status = "completed" if comp else R.choices(["todo", "inProgress"], weights=[88, 12])[0]
    t["status"] = status
    if status == "completed":
        assert comp > cdt, f"完成早于创建：{title} {cdt} → {comp}"
        t["completedAt"] = iso(comp)
    if due:
        t["dueDate"], t["isAllDay"] = iso(due), False
    if block:
        t["plannedStart"], t["plannedEnd"] = iso(block[0]), iso(block[1])
    if importance:
        t["importance"] = importance
    if note:
        t["note"] = note
    if archived:
        t["archived"] = True
    TASKS.append(t)
    return t


def later_same_day(cdt, latest=22 * 60 + 30):
    lo = cdt.hour * 60 + cdt.minute + 20
    if lo > latest:
        return None
    return cdt.replace(hour=0, minute=0) + timedelta(minutes=R.randint(lo, latest))


def finish_time(cdt, horizon=4):
    """完成时刻：多数当天晚些时候，有的拖到之后几天；落不出合法时刻返回 None"""
    same = later_same_day(cdt)
    if same and R.random() < 0.62:
        return same
    for _ in range(8):
        d = cdt.date() + timedelta(days=R.randint(1, horizon))
        if recordable(d) and at_home(d) and d not in STAY_HOME:
            return at(d, R.randint(9, 21), R.randint(0, 59))
    return same


def align(t, rule):
    d = t
    if rule == "fri":
        while not (d.weekday() == 4 and is_workday(d)):
            d += timedelta(days=1)
    elif rule == "weekend":
        while is_workday(d):
            d += timedelta(days=1)
    elif rule == "work":
        while not is_workday(d):
            d += timedelta(days=1)
    elif rule and rule.startswith("monthday:"):
        d = d.replace(day=int(rule.split(":")[1]))
        if d < t:
            d = next_month(d).replace(day=int(rule.split(":")[1]))
    return d


def gen_family_tasks():
    restock = C.TASK_FAMILIES[5]["variants"]
    haircut = ("剪头发", "理发", "头发长了该剪了", "剪刘海", "补染发根", "剪短一点", "洗剪吹", "理发（托尼老师那家）")
    for fam in C.TASK_FAMILIES:
        weights = [4, 4] + [1] * (len(fam["variants"]) - 2)

        def one(d_align, fam=fam, weights=weights):
            """在 d_align 这天发生一次；那天不在杭州或没记录就顺延到回来以后（二月的水电费就是这么晚交的）"""
            if d_align >= TODAY:
                return
            d0 = d_align
            while d0 < TODAY and not (recordable(d0) and at_home(d0)) and (d0 - d_align).days < 12:
                d0 += timedelta(days=1)
            if not (recordable(d0) and at_home(d0)) or d0 in STAY_HOME:
                return
            title = R.choices(fam["variants"], weights=weights)[0]
            lo, hi = fam["hours"]
            cdt = at(d0, R.randint(lo, hi - 1), R.randint(0, 59))
            comp = finish_time(cdt) if R.random() < fam["done"] else None
            if comp and (comp >= NOW or comp.date() in STAY_HOME):     # 宅家周末不上街：这次不做了
                comp = None
            stale = None
            if comp is None and d0 < TODAY - timedelta(days=60):
                # 没做又放了很久的：近一半被她清掉了，四成多归了档，只有少数一直挂着（逾期）
                r = R.random()
                if r < 0.10 and d0 >= TODAY - timedelta(days=150):      # 逾期太久的不会一直挂着
                    stale = "todo"
                elif r < 0.58:
                    stale = "archived"
                else:
                    return
            due = cdt.replace(hour=18 if fam["kind"] == "work" else 21, minute=0) + timedelta(days=R.choice([0, 0, 1]))
            add_task(title, cdt, comp, due if (comp is None or R.random() < 0.3) else None,
                     importance=R.choices(["p2", "p3", None], weights=[5, 4, 3])[0] if fam["kind"] == "life"
                     else R.choices(["p2", "p1", None], weights=[6, 2, 3])[0],
                     status="todo" if stale else None, archived=stale == "archived")
            when = (comp.hour, comp.minute) if comp else None
            if comp and fam["day"] == "monthday:1":
                expense(comp.date(), when, "居住/房租", WX, 1500, R.choice(["房租", "房租", "这个月房租", ""]))
            elif comp and fam["day"] == "monthday:16":
                expense(comp.date(), when, "居住/电费", ZFB, utility_amount(comp.month),
                        R.choice(["电费", "水电燃气", "电费单", "电费", "电费 这个月开空调了" if comp.month in (7, 8) else "电费"]))
            elif comp and fam["day"] == "weekend" and title in haircut:
                expense(comp.date(), when, "理发", WX, price(48, 98), R.choice(["理发", "", "剪头发", "托尼老师"]))
            elif comp and title in restock:
                expense(comp.date(), when, "日用", ZFB, price(28, 88), R.choice(["洗衣液", "纸巾", "日用品补货", "", "洗漱用品"]))

        if fam["day"] and fam["day"].startswith("monthday:"):     # 按月的：一个月一次，不靠步进去撞
            n_day = int(fam["day"].split(":")[1])
            cursor = D("2025-11-01")
            while True:
                cursor = next_month(cursor)
                if cursor >= TODAY:
                    break
                one(cursor.replace(day=n_day))
        else:
            t = START + timedelta(days=R.randint(0, fam["step"]))
            while True:
                d_align = align(t, fam["day"])
                if d_align >= TODAY:
                    break
                one(d_align)
                t = d_align + timedelta(days=max(3, int(fam["step"] * R.uniform(0.7, 1.3))))


SEQUENCES = [  # (标题, 创建, 完成)：一件件事有先后
    ("续租和房东谈", "2025-12-10T21:05", "2025-12-15T20:40"), ("把今年的书单整理一下", "2026-01-02T21:10", "2026-01-04T15:20"),
    ("订生日蛋糕", "2026-03-08T11:20", "2026-03-10T20:15"), ("预约洗牙", "2026-03-02T09:40", "2026-03-05T10:12"),
    ("上海出差申请", "2026-03-16T10:20", "2026-03-17T11:05"), ("上海出差的发票贴了", "2026-03-23T09:30", "2026-03-25T17:20"),
    ("抢回家的票", "2026-01-25T20:30", "2026-01-31T14:06"), ("给我妈买羽绒服", "2026-02-05T21:10", "2026-02-08T15:22"),
    ("收拾回家的行李", "2026-02-13T21:20", "2026-02-14T22:10"),
    ("办签证", "2026-02-27T21:10", "2026-03-02T20:45"), ("订机票", "2026-03-10T12:20", "2026-03-14T10:55"),
    ("订大阪民宿", "2026-03-15T21:00", "2026-03-16T21:20"), ("订京都的住宿", "2026-03-17T21:05", "2026-03-20T12:50"),
    ("买交通卡", "2026-04-01T20:15", "2026-04-02T20:15"), ("查环球影城快速票", "2026-04-08T13:00", "2026-04-10T13:25"),
    ("买旅行保险", "2026-03-24T20:30", "2026-03-25T12:40"), ("预约九价第三针", "2026-07-10T10:00", "2026-07-13T09:25"), ("打九价第三针", "2026-07-13T09:20", "2026-07-14T10:40"), ("开通境外流量包", "2026-04-15T20:00", "2026-04-17T08:40"),
    ("下载离线地图", "2026-04-18T09:20", "2026-04-18T09:26"), ("请假条OA提交", "2026-04-14T10:30", "2026-04-20T11:05"),
    ("行程表终版", "2026-04-18T21:00", "2026-04-21T22:40"), ("收拾行李箱", "2026-04-19T21:20", "2026-04-22T22:15"),
    ("买行李秤", "2026-04-19T21:25", "2026-04-20T12:42"), ("买防晒", "2026-04-18T09:40", "2026-04-21T20:18"),
    ("把伴手礼带给同事", "2026-04-29T08:50", "2026-04-29T10:05"), ("整理日本的照片", "2026-04-29T21:10", "2026-05-03T16:40"),
    ("办健身卡", "2026-06-03T19:20", "2026-06-11T11:30"), ("试一节私教体验课", "2026-06-12T12:10", "2026-06-16T20:40"),
    ("出差申请OA", "2026-08-20T10:20", "2026-08-21T11:05"), ("订出差的机票", "2026-08-21T14:00", "2026-08-22T15:30"),
    ("贴发票报销", "2026-08-31T09:30", "2026-09-03T17:20"), ("报名杭州半马", "2026-09-01T09:40", "2026-09-03T10:12"),
    ("买跑鞋", "2026-09-06T10:30", "2026-09-08T20:45"), ("买盐丸和能量胶", "2026-09-13T21:00", "2026-09-15T20:20"),
    ("跑前热身别偷懒", "2026-10-31T22:00", "2026-11-01T06:50"), ("莫干山订民宿", "2026-09-21T20:40", "2026-09-23T21:15"),
    ("体检报告去取", "2026-11-09T10:10", "2026-11-11T17:30"), ("双十一预热方案", "2026-09-28T14:20", "2026-10-09T18:10"),
    ("双十一复盘", "2026-11-16T10:05", "2026-11-20T15:28"),
]


def task_allowed(title, d):
    if d in STAY_HOME:
        return False
    season = C.TASK_SEASON.get(title)
    if season:
        lo, hi = season
        if not (lo <= d.month <= hi if lo <= hi else d.month >= lo or d.month <= hi):
            return False
    until = C.TASK_UNTIL.get(title)
    start = C.TASK_FROM.get(title)
    return not (until and d > D(until)) and not (start and d < D(start))


def gen_oneoff_tasks():
    seq_titles = {s[0] for s in SEQUENCES}
    pool = [(t, "life") for t in C.TASK_ONEOFFS_LIFE if t not in seq_titles] + \
           [(t, "work") for t in C.TASK_ONEOFFS_WORK if t not in seq_titles]
    R.shuffle(pool)
    base = [d for d in recordable_days(START + timedelta(days=2), TODAY) if at_home(d)]
    for title, kind in pool:
        d = None
        for _ in range(25):
            x = R.choice(base)
            if (kind == "work") == is_workday(x) and task_allowed(title, x):
                d = x
                break
        if d is None:
            continue
        cdt = at(d, R.randint(9, 16) if kind == "work" else R.randint(9, 20), R.randint(0, 59))
        comp = finish_time(cdt, 5) if R.random() < (0.86 if kind == "work" else 0.74) else None
        if comp and comp >= NOW:
            comp = None
        stale = None
        if comp is None and d < TODAY - timedelta(days=60):
            r = R.random()
            if r < 0.10 and d >= TODAY - timedelta(days=150):
                stale = "todo"
            elif r < 0.58:
                stale = "archived"
            else:
                continue
        due = (cdt + timedelta(days=R.randint(0, 3), hours=R.randint(2, 8))) if (comp is None or R.random() < 0.25) else None
        add_task(title, cdt, comp, due, importance=R.choices(["p1", "p2", "p3", None], weights=[2, 5, 2, 4])[0],
                 note=R.choice([None, None, None, "周一前", "老板要的", "别忘", "回来再说"]) if kind == "work" else None,
                 status="todo" if stale else None, archived=stale == "archived")


def gen_sequences_and_blocks():
    for title, c, f in SEQUENCES:
        add_task(title, datetime.fromisoformat(c), datetime.fromisoformat(f))
    for ds, a, b, title, st in C.PLANNED_BLOCKS:
        s, e = datetime.fromisoformat(f"{ds}T{a}"), datetime.fromisoformat(f"{ds}T{b}")
        if st == "auto":        # 今天的安排：过了就已完成，进行中就是进行中
            st = "completed" if NOW >= e + timedelta(minutes=5) else ("inProgress" if s <= NOW < e else "todo")
        created = min(s - timedelta(days=R.randint(1, 4), hours=R.randint(0, 3)), NOW - timedelta(hours=1))
        add_task(title, created, e + timedelta(minutes=R.randint(3, 12)) if st == "completed" else None,
                 due=e, block=(s, e), importance="p1" if "复盘" in title else "p2", status=st)
    # 长距离当天顺手记一条
    for d, km, h, m, note in RUNS:
        if km >= 10 and d != RACE:
            add_task(f"长距离 {int(km)}公里", at(d, max(h - 2, 6), R.randint(0, 59)), at(d, h, m), importance="p2")


# ───────────────────────── 想法 ─────────────────────────
MOODS = {
    "work": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [32, 20, 12, 16, 15, 5]),
    "money": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [35, 20, 15, 22, 6, 2]),
    "self": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [30, 22, 28, 12, 3, 5]),
    "life": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [15, 28, 42, 8, 3, 4]),
    "run": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [20, 22, 38, 8, 2, 10]),
    "read": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [25, 35, 28, 5, 2, 5]),
}
TAGS = {"work": ["工作", "工作/吐槽"], "money": ["消费"], "life": ["生活"], "run": ["跑步"], "read": ["读书"], "self": []}
WINDOW = {   # 内容带时间语义的自由想法：只能落在窗口内
    "实习生小徐": ("2026-11-02", "2026-11-21"),
    "连跑三周了": ("2026-01-19", "2026-02-15"), "冬天跑步的第一口冷空气": ("2026-01-06", "2026-03-05"),
    "杭州的夏天跑步": ("2026-06-15", "2026-08-23"), "能量胶": ("2026-09-10", "2026-10-25"),
    "下次报全马": ("2026-10-01", "2026-10-25"), "秋雨": ("2026-09-20", "2026-10-25"),
    "日用品这些不起眼的": ("2026-10-01", "2026-11-22"), "今年学会了说不": ("2026-09-25", "2026-11-22"),
    "三十岁了还是没搞清楚": ("2026-03-15", "2026-11-22"), "收入没涨多少": ("2026-08-15", "2026-11-22"),
    "这个月破例多花了": ("2026-01-26", "2026-11-22"), "记账快一年": ("2026-11-10", "2026-11-22"),
    "花呗还清了": ("2026-02-01", "2026-11-22"),
    "和我妈视频了四十分钟": ("2026-03-01", "2026-11-22"), "健身房私教第三次": ("2026-07-01", "2026-08-31"),
    "双十一的满减规则": ("2026-10-18", "2026-10-24"), "年终述职": ("2025-12-15", "2026-01-30"),
    "面膜过敏": ("2026-10-26", "2026-11-22"), "体重秤没电了半年": ("2026-09-05", "2026-11-22"),
    "突然意识到我来杭州": ("2026-11-08", "2026-11-22"), "楼下的桂花今年": ("2026-10-05", "2026-10-20"),
    "把去年刚开始记的": ("2026-11-06", "2026-11-22"),
}
ANY_HOURS = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]
ANY_W = [3, 5, 8, 6, 8, 5, 8, 8, 7, 6, 6, 6, 7, 9, 10, 6]


MOOD_WORDS = [   # 情绪跟内容走，不随机抽。顺序：先看负面的，再看正面的
    ("angry", ("气得", "有点气", "气笑", "气死", "，气", "生气", "烦", "无语", "离谱", "有病", "服了", "讨厌", "白做", "不想开会")),
    ("sad", ("哭", "丧", "焦虑", "疼", "累", "想家", "没劲", "失落", "难受", "慌", "孤单", "后悔", "心在滴血", "崩",
             "吐", "泻", "困", "跑不掉", "有点酸", "酸到", "放弃", "挣扎", "有点空", "发麻", "睡一觉再说", "没钱")),
    ("happy", ("快乐", "开心", "赚", "真好", "真香", "值了", "值得", "太值", "成功", "好吃", "很甜", "爽", "喜欢",
               "舒服", "激动", "治愈", "精彩", "好看", "笑死", "中签", "香")),
    ("inspired", ("灵感", "flag", "计划", "写下来", "记下来", "目标", "明年", "下次")),
    ("thinking", ("想", "算", "要不要", "是不是", "为什么", "研究", "口径", "发现", "原来", "纠结", "意识到", "感觉")),
]
MOOD_OVERRIDE = {   # 几句正负情绪混在一起、机器判不准的，手工定
    "2:41:33，累哭了，挂着奖牌坐地铁回家": "happy",
    "健身房第一天，跑步机比我先累": "calm",
    "31了，没什么感觉，蛋糕有点甜": "calm",
    "工位搬到窗边了，下午晒得眼睛疼，但开心": "happy",
    "跑步的时候想，下次报全马是不是有病": "thinking",
    "被楼下的猫尾行了一路，它只是想要吃的": "happy",
    "这本封面好看，内容一般": "calm",
    "起飞了，第一次一个人出国": "thinking",
    "能量胶真难吃。十五公里以后倒是不挑了": "calm",
    "好烦": "angry", "累": "sad", "困": "sad", "想家": "sad",
}
USED_MINUTES = set()


def mood_for(text):
    if text in MOOD_OVERRIDE:
        return MOOD_OVERRIDE[text]
    for mood, words in MOOD_WORDS:
        if any(w in text for w in words):
            return mood
    return "calm"


def add_thought(text, when, kind):
    while when.strftime("%Y-%m-%dT%H:%M") in USED_MINUTES:      # 同一分钟不发两条
        when += timedelta(minutes=1)
    USED_MINUTES.add(when.strftime("%Y-%m-%dT%H:%M"))
    THOUGHTS.append({"content": text, "createdAt": iso(when), "mood": mood_for(text),
                     "tags": [R.choice(TAGS[kind])] if TAGS.get(kind) and R.random() < 0.30 else []})


PLACES = ("良渚", "湘湖", "滨江天街", "西湖", "莫干山")
OVERTIME = re.compile("加班|开到七点半|九点半|回来的地铁上")
NOT_OVERTIME = re.compile("借口|不想加班|明天|以前|上次|去年|报销不了")     # 「借口加班溜了」不算真加班


def ensure_late_commute(d, when):
    """她写了今晚加班到几点：账上回家那趟通勤就得在那之后"""
    evening = [t for t in TX if t.get("date", "")[:10] == d.isoformat() and t.get("category") == "交通/地铁"
               and dt_of(t["date"]).hour >= 17]
    target = when - timedelta(minutes=R.randint(15, 40))
    if target.date() != d or target.hour < 20:
        target = at(d, 23, R.randint(0, 30))
    if evening:
        if dt_of(evening[0]["date"]) < target:
            evening[0]["date"], evening[0]["note"] = iso(target), "加班回来"
    else:
        expense(d, (target.hour, target.minute), "交通/打车", ZFB, price(28, 52), "加班打车")


def bindings(text, d, when):
    """想法里提到的消费，当天账上要真有这一笔"""
    if text.startswith("打车三十多"):
        expense(d, (when.hour, when.minute - 18 if when.minute >= 18 else 59), "交通/打车", ZFB, price(28, 46), "加班打车")
        return
    if text.startswith("周末最大的成就"):
        expense(d, (R.choice([9, 9, 10]), R.randint(5, 55)), "早餐", WX, price(9, 19), R.choice(["生煎", "小笼包", "肠粉", ""]))
        return
    if text.startswith("第一次跑过十公里"):
        expense(d, (when.hour - 1, when.minute), "超市", ZFB, price(10, 22), "全家 关东煮")
        return
    if text.startswith("离职的同事今天最后一天"):
        nxt = d + timedelta(days=1)
        if recordable(nxt) and at_home(nxt):
            add_thought("同事离职了，她工位上的绿植没人要，我搬回来了。一盆绿萝一盆不知道是什么，希望别在我手里死掉，上一盆就是浇水浇死的",
                        at(nxt, 20, R.randint(0, 59)), "life")
        return
    if text.startswith("今天加班到九点半"):
        expense(d, (when.hour, when.minute - 12 if when.minute >= 12 else 59), "超市", WX, price(12, 24), "全家 关东煮")
        return
    if text.startswith("给自己买了花"):
        expense(d, (when.hour, when.minute - 10 if when.minute >= 10 else 59), "植物花卉", CASH if d >= CASH_FROM else WX, price(19.9, 39.9), "花摊 一小束")
    elif text.startswith("买了跑步袜"):
        expense(d, (20, R.randint(5, 50)), "运动", ZFB, price(25, 49), "跑步袜")
    elif text.startswith("书店蹭读"):
        expense(d, (16, R.randint(5, 50)), "书籍", WX, price(39, 69), "书店，蹭了半天买了一本")
    elif text.startswith("外卖备注不要香菜"):
        existing = [x for x in TX if x.get("date", "")[:10] == d.isoformat() and x.get("category") in ("晚餐", "外卖")]
        if existing:        # 当天本来就有外卖：改成这一笔，不再多吃一顿
            existing[0]["category"], existing[0]["note"] = "外卖", "麻辣烫 不要香菜"
        else:
            expense(d, (19, R.randint(5, 55)), "外卖", WX, price(20, 38), "麻辣烫 不要香菜")
    elif text.startswith("把洋葱当大蒜"):
        expense(d, (18, R.randint(5, 50)), "买菜", WX, price(18, 46), "菜市场，买了一圈")
    elif text.startswith("楼下面包店"):
        expense(d, (20, R.randint(31, 59)), "零食", WX, price(9.9, 22), "面包店 半价")
    elif text.startswith("良渚那边的草坪"):
        expense(d, (R.choice([9, 10]), R.randint(0, 59)), "交通/地铁", ZFB, 7, "去良渚")
    elif text.startswith("湘湖骑了一圈"):
        expense(d, (R.choice([9, 10]), R.randint(0, 59)), "交通/地铁", ZFB, 5, "去湘湖")
    elif text.startswith("滨江天街周末"):
        expense(d, (when.hour, when.minute - R.randint(20, 55) if when.minute >= 55 else 59), "日用", ZFB, price(15, 69), "滨江天街名创优品")
    elif text.startswith(("今天真是服了，需求评审", "今天加班到九点半")):
        ensure_late_commute(d, when)


def slot_time(slot, d):
    """按内容挑钟点：早上通勤、午休、加班、睡前，各归各位"""
    pick = lambda h: at(d, h, R.randint(0, 59))
    mins = lambda a, b: at(d) + timedelta(minutes=a + R.randint(0, b - a))
    if slot == "commute_am":
        return mins(470, 550)
    if slot == "commute_pm":
        return mins(1085, 1180)
    if slot == "noon":
        return mins(720, 810)
    if slot == "night":
        return mins(1320, 1430)
    if slot == "morning":
        return mins(380, 540)
    if slot == "work":
        return pick(R.choice([10, 11, 14, 15, 16, 17]))
    if slot == "overtime":
        return pick(R.choice([20, 21, 22]))
    if slot == "evening":
        return pick(R.choice([19, 20, 21]))
    if slot == "weekend":
        return pick(R.choice([10, 11, 12, 13, 14, 15, 16, 17, 20, 21]))
    if slot == "weekend_am":
        return mins(540, 720)
    if slot == "sunday_night":
        return mins(1260, 1420)
    if slot == "friday_pm":
        return mins(900, 1070)
    if slot == "before_off":
        return mins(990, 1075)
    if slot == "sat_am":
        return mins(510, 660)
    if slot == "three_pm":
        return mins(900, 940)
    if slot == "work_night":
        return mins(1320, 1430)
    if slot == "off_work":
        return mins(1080, 1200)
    if slot == "wed_evening":
        return mins(1140, 1260)
    if slot == "weekend_evening":
        return mins(1020, 1260)
    if slot == "rest_day":
        return mins(540, 1380)
    if slot == "thursday_night":
        return mins(1320, 1420)
    if slot == "payday":
        return mins(606 if is_workday(d) else 660, 1260)
    return pick(R.choices(ANY_HOURS, weights=ANY_W)[0])


def slot_days(slot):
    """想法可以落在哪些天：一律要求「有记录、人在杭州」（出门的日子只写明确发生的事），
    再按时段叠加工作日/休息日约束。"""
    home_ = [d for d in recordable_days(START + timedelta(days=1), TODAY) if at_home(d)]
    work_ = [d for d in home_ if is_workday(d)]
    off_ = [d for d in home_ if not is_workday(d)]
    if slot in ("commute_am", "commute_pm", "noon", "work", "overtime", "before_off", "three_pm", "work_night", "off_work"):
        return work_
    if slot == "wed_evening":
        return [d for d in home_ if d.weekday() == 2]
    if slot == "friday_pm":
        return [d for d in home_ if d.weekday() == 4 and is_workday(d)]
    if slot == "thursday_night":
        return [d for d in home_ if d.weekday() == 3]
    if slot in ("weekend", "weekend_am", "weekend_evening"):
        return off_
    if slot == "sat_am":        # 放假日不等于周六
        return [d for d in home_ if d.weekday() == 5]
    if slot == "sunday_night":
        return [d for d in home_ if d.weekday() == 6]
    if slot == "wed":
        return [d for d in home_ if d.weekday() == 2]
    if slot == "monthend":
        return [d for d in home_ if d.day >= 26]
    if slot == "payday":
        return [d for d in [payday(2025, 12)] + [payday(2026, m) for m in range(1, 12)] if recordable(d) and at_home(d)]
    return home_


def fund_balance_on(day):
    """到某天为止旅行专款的余额（想法里说的数字从这里取，不写死）"""
    bal = 300000
    for t in TX:
        if t.get("account") == "旅行专款" and "date" in t and t["date"][:10] <= day.isoformat():
            bal += t["amountCents"] if t["type"] == "income" else -t["amountCents"]
    return bal


def cny_red_packets():
    """过年红包：给出去多少、收回来多少（元）"""
    feb = [t for t in TX if t.get("date", "")[:7] == "2026-02"]
    return (sum(t["amountCents"] for t in feb if t.get("category") == "红包礼金") // 100,
            sum(t["amountCents"] for t in feb if t.get("category") == "红包") // 100)


CN_DIG = "零一二三四五六七八九"


def cn_amount(yuan, floor=False):
    """把金额说成人话：约到百，「七百」「一千五」「两千二」"""
    h = int(yuan // 100) if floor else int(round(yuan / 100))
    q, r = divmod(h, 10)
    if q == 0:
        return CN_DIG[r] + "百"
    head = ("一千" if q == 1 else "两" + "千") if q <= 2 else CN_DIG[q] + "千"
    return head + (CN_DIG[r] if r else "")


def spend_of(categories=None, lo="0000", hi="9999"):
    """一段时间内某些类目的支出合计（元），退款按负数计"""
    return sum(t["amountCents"] * (-1 if "refundOf" in t else 1) for t in TX
               if lo <= t.get("date", "")[:10] <= hi and (categories is None or t.get("category") in categories)
               and t.get("type") == "expense") / 100


DOUBLE11 = ("面膜", "羽绒服", "抽纸", "给我妈买的按摩仪", "摇粒绒")     # 她双十一买的东西（按备注开头认）


def facts():
    """想法里会提到的金额，都从账上取（写死的数字落哪个月都错）"""
    bought = sum(t["amountCents"] for t in TX if "2026-10-21" <= t.get("date", "")[:10] <= "2026-11-12"
                 and t.get("type") == "expense" and t.get("note", "").startswith(DOUBLE11)) / 100
    refunded = sum(t["amountCents"] for t in TX if t.get("refundOf") == "down-jacket") / 100
    return {"coffee_spend": cn_amount(spend_of(("咖啡",))) + "块",
            "daily_spend": cn_amount(spend_of(("日用",))),
            "double11": cn_amount(bought - refunded)}


CLOCK = re.compile(r"(上午|下午|晚上|凌晨)([一二三四五六七八九十两]+|\d+)点")
CN_HOUR = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12}
run_days = set()


def tx_on(d):
    """某天到目前为止账上有几笔（想法会边落边带来消费，所以要实时数）"""
    return sum(1 for t in TX if t.get("date", "")[:10] == d.isoformat())


STAY_WORDS = re.compile("没下楼|躺了一天|在家躺|一分钱没花")


def days_claimed_home(text, d):
    """这条想法声称「没出门/没花钱」的是哪几天：「上周末」= 上个周六日，「周末两天」= 本周六日，其余=当天"""
    if "上周末" in text:
        back = d.weekday() + 2
        return [d - timedelta(days=back), d - timedelta(days=back - 1)]
    if "周末两天" in text:
        return [d - timedelta(days=1), d]
    return [d]


def fact_ok(text, d, when):
    """这条想法放在这一天这个钟点，和当天的事实对不对得上。对不上就换一天。"""
    h = when.hour
    m = CLOCK.search(text)
    if m and not re.search("一晚上|昨晚|那天|上次|小时候|去年|前天", text):      # 回顾过去的事不算
        base = CN_HOUR.get(m.group(2)) or int(m.group(2))
        expect = base + 12 if m.group(1) in ("下午", "晚上") else base % 12
        if h != expect:
            return False
    if STAY_WORDS.search(text):
        if "周末两天" in text and d.weekday() != 6:
            return False
        if "上周末" in text and d.weekday() > 4:
            return False
        if any(tx_on(x) or x in run_days for x in days_claimed_home(text, d)):
            return False
        if "上周末" not in text and any(d.isoformat() == t.get("completedAt", "")[:10] and "T09" <= t["completedAt"][10:13] < "T19"
                                         for t in TASKS):
            return False         # 白天还完成过待办，算不上「躺了一天」
    if re.search("通勤|开会|工位|公司楼下|去上班|调休上班|在也不想开会", text) and not is_workday(d):
        return False                   # 写的是今天上班的事
    if "周末" in text and is_workday(d) and "上周末" not in text:
        return False
    if "力量训练" in text and d in run_days:
        return False
    if text == "起床" and not 5 <= h <= 9:
        return False
    if text == "下班" and not (is_workday(d) and 17 <= h <= 20):
        return False
    todays = [t for t in TX if t.get("date", "")[:10] == d.isoformat()]
    first_tx = min((t["date"] for t in todays), default=None)
    if re.search("^起床|睡到|自然醒", text) and first_tx and when >= dt_of(first_tx):
        return False                 # 人还没起床，怎么已经有消费了
    mine = [p for p in PLACES if p in text]
    if mine and any(p in t.get("note", "") for t in todays for p in PLACES if p not in mine):
        return False                 # 想法里说在良渚，账上却在湘湖吃饭
    if text == "下班" and not any(t.get("category") == "交通/地铁" and abs((dt_of(t["date"]) - when).total_seconds()) <= 45 * 60
                                 for t in todays):
        return False                 # 「下班」要和回家那趟地铁对得上
    if d in STAY_HOME and re.search("买了|打车|出门|通勤|上班|开会|外卖|超市|便利店|跑了|跑完|花摊|面包店|菜市场|加班", text):
        return False                     # 那个周末她没出门
    return True


def gen_thoughts():
    global run_days, tx_count
    packets = dict(zip(("cny_out", "cny_in"), cny_red_packets()))
    packets["double11"] = facts()["double11"]
    for row in C.THOUGHTS_ANCHORED:
        ds, text, kind, lo, hi = row[:5]
        when = datetime.fromisoformat(f"{ds}T{lo:02d}:{row[5] if len(row) > 5 else R.randint(0, 59):02d}")
        if when >= NOW:                 # 锚点在今天的，还没到点就还没发生（凌晨/早晨生成时）
            continue
        add_thought(text.format(fund_w=fund_balance_on(when.date()) // 1_000_000, **packets), when, kind)
        if OVERTIME.search(text) and not NOT_OVERTIME.search(text):
            ensure_late_commute(when.date(), when)        # 她写了今晚加班：回家那趟通勤得在那之后
    b = BOOK_DATES
    add_thought("今年读完的第一本，一月八号，不算晚吧", at(b[0], 22, 31), "read")
    add_thought("第十本。比去年一整年都多", at(b[9], 22, 18), "read")
    for x, title in BOOKS_BY_DATE.items():
        if title in C.BOOK_NOTES:
            add_thought(C.BOOK_NOTES[title], at(x, 22, R.randint(5, 50)), "read")

    free = [(text, slot, kind) for kind, items in C.THOUGHTS_FREE.items()
            for text, slot in [(it if isinstance(it, tuple) else (it, "any")) for it in items]]
    R.shuffle(free)
    # 「没出门」类的想法最后落：等别的想法带来的消费都进了账，再看哪天真的没出门
    free.sort(key=lambda x: bool(re.search("没下楼|躺了一天|在家躺|一分钱没花", x[0])))
    per_day = Counter()
    run_by_day = {d: (km, h, m) for d, km, h, m, _ in RUNS}
    run_days = set(run_by_day)
    tx_count = Counter(t["date"][:10] for t in TX if "date" in t)
    long_after = [d + timedelta(days=1) for d, km, h, m, _ in RUNS if km >= 10] + [D("2026-01-06"), D("2026-05-19")]
    num = facts()
    for text, slot, kind in free:
        window = next(((D(a), D(z)) for key, (a, z) in WINDOW.items() if key in text), (START, TODAY))
        lo_d, hi_d = window[0], min(window[1], TODAY - timedelta(days=1))

        def in_window(d, lo_d=lo_d, hi_d=hi_d):
            return lo_d <= d <= hi_d and at_home(d)

        if slot == "run":
            cands = [d for d in run_by_day if in_window(d)]
        elif slot == "run_am":
            cands = [d for d, (km, h, m) in run_by_day.items() if h < 10 and in_window(d)]
        elif slot == "run_pm":          # 晚跑的日子：想法写在跑完之后（之前写在跑之前，事情没发生感想先发）
            cands = [d for d, (km, h, m) in run_by_day.items() if h >= 17 and in_window(d)]
        elif slot == "run_long":       # 「十五公里以后」只能落在真跑了十五公里以上的那天
            cands = [d for d, (km, h, m) in run_by_day.items() if km >= 15 and in_window(d)]
        elif slot == "run_short":      # 「五公里就回家了」只能落在没跑满五公里的那天
            cands = [d for d, (km, h, m) in run_by_day.items() if km < 5 and in_window(d)]
        elif slot == "after_run":         # 「第二天腿酸」这类：长距离之后的休息日
            cands = [d for d in long_after if in_window(d) and d not in run_by_day and per_day[d] < 2]
        elif slot == "after_last_book":    # 「读了十九本」只能在第十九本读完之后说
            cands = [d for d in slot_days("any") if max(BOOK_DATES) <= d <= hi_d and at_home(d)]
        elif slot == "on_book_done":
            cands = [d for d in BOOK_DATES if in_window(d)]
        elif slot == "rest_day":       # 「改力量训练」只能落在没跑步的那天
            cands = [d for d in slot_days("rest_day") if in_window(d) and d not in run_by_day and per_day[d] < 2]
        else:
            cands = [d for d in slot_days(slot) if in_window(d) and per_day[d] < 2]
            if kind == "work":
                cands = [d for d in cands if is_workday(d)]      # 上班的事只发生在上班的日子
            if text == "今天一分钱没花":
                cands = [d for d in cands if tx_on(d) == 0]
        d = when = None
        for _ in range(80):            # 当天事实校验：对不上就换一天
            if not cands:
                break
            d_ = R.choice(cands)
            if slot in ("run", "run_am", "run_pm", "run_long", "run_short"):
                km_, h_, m_ = run_by_day[d_]
                w_ = at(d_, h_, m_) + timedelta(minutes=R.randint(5, 110))
            else:
                w_ = slot_time(slot, d_)
            if w_ >= NOW:
                w_ = min(NOW - timedelta(minutes=60), at(d_, 20, R.randint(0, 59)))
            if fact_ok(text, d_, w_):
                d, when = d_, w_
                break
            cands.remove(d_)
        if d is None:
            sys.exit(f"想法找不到和当天事实对得上的日子：{text}（时段 {slot}）")
        assert when < NOW
        per_day[d] += 1
        if "{" in text:
            prev = (d.replace(day=1) - timedelta(days=1)).strftime("%Y-%m")
            text = text.format(wm=cn_amount(spend_of(("外卖",), lo=prev + "-01", hi=prev + "-31"), floor=True), **num)
        add_thought(text, when, kind)
        bindings(text, d, when)
        if OVERTIME.search(text) and not NOT_OVERTIME.search(text):
            ensure_late_commute(d, when)
    tx_count = Counter(t["date"][:10] for t in TX if "date" in t)
    for th_ in THOUGHTS:                 # 兜底：后落的想法可能带来新的消费，把「那天没出门」的结论推翻
        if STAY_WORDS.search(th_["content"]):
            spent = [fmt_(x) for x in days_claimed_home(th_["content"], dt_of(th_["createdAt"]).date()) if tx_on(x)]
            if spent:
                sys.exit(f"想法「{th_['content'][:16]}」说没出门，但 {spent} 有消费")


# ───────────────────────── 汇编与对账 ─────────────────────────


def fmt_(d):
    return d.isoformat()


def dt_of(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M")


def bigrams(text):
    return {text[i:i + 2] for i in range(len(text) - 1)}


FOOD = ("早餐", "午餐", "晚餐", "夜宵", "零食", "咖啡", "外卖", "饮品", "水果", "酒水", "超市", "火锅", "烧烤", "甜品", "啤酒", "茶饮")


def food_budget_cents():
    """餐饮预算：定在她微信上每月餐饮花销的中位数附近（定高了月月不超，定低了月月超，都不像真人）"""
    by_month = defaultdict(int)
    for t in TX:
        if t.get("type") == "expense" and t.get("account") == WX and t.get("category") in FOOD and "date" in t \
                and t["date"][:7] != NOW.strftime("%Y-%m"):
            by_month[t["date"][:7]] += t["amountCents"]
    vals = sorted(by_month.values())
    return int(round(vals[len(vals) // 2] / 10000.0)) * 10000


def build():
    for d in recordable_days(START, TODAY):
        if at_home(d) and d not in STAY_HOME:
            routine(d)
    gen_today()
    TX[:] = [t for t in TX if not skip_routine_tx(t)]
    gen_fixed()
    gen_events()
    gen_runs()
    gen_habits_and_records()
    gen_family_tasks()
    gen_oneoff_tasks()
    gen_sequences_and_blocks()
    gen_thoughts()

    for t in TX + HABIT_RECORDS + TASKS:        # 备注里中文之间不留空格（「全家 关东煮」→「全家关东煮」）
        if t.get("note"):
            t["note"] = re.sub(r"(?<=[\u4e00-\u9fff]) (?=[\u4e00-\u9fff])", "", t["note"])
    tx_normal = [t for t in TX if "installment" not in t]
    k = (NOW.year - 2026) * 12 + (NOW.month - 6)
    periods_elapsed = k + (1 if NOW.day >= 11 else 0)       # 健身卡分期到今天为止已经扣了几期
    spent = sum((-t["amountCents"] if "refundOf" in t else t["amountCents"])
                for t in tx_normal if "refundOf" in t or t["type"] == "expense")
    fund = [t for t in tx_normal if t.get("account") == "旅行专款"]
    fund_balance = 300000 + sum((t["amountCents"] if t["type"] == "income" else -t["amountCents"]) for t in fund)
    coffee_ = [t for t in tx_normal if t.get("category") == "咖啡"]
    japan = [t for t in tx_normal if t.get("project") == JAPAN]
    runs = [r for r in HABIT_RECORDS if r["habit"] == "跑步"]
    recorded = ({t["date"][:10] for t in TX if "date" in t} | {t["createdAt"][:10] for t in THOUGHTS}
                | {t["date"][:10] for t in HABIT_RECORDS} | {t["createdAt"][:10] for t in TASKS})
    done = [t for t in TASKS if t["status"] == "completed"]
    gaps_days = sorted(GAPS)
    run_dates = sorted(date.fromisoformat(r["date"][:10]) for r in runs)
    longest_break = max((b - a).days for a, b in zip(run_dates, run_dates[1:]))
    claims = {
        "generatedAt": NOW.strftime("%Y-%m-%d %H:%M"), "spanDays": (TODAY - START).days,
        "recordedDays": len(recorded), "gapDays": len(gaps_days), "longestRunBreakDays": longest_break,
        "transactions": len(tx_normal), "transactionsInApp": len(tx_normal) + 24,
        "annualExpense": round((spent + 28800 * periods_elapsed) / 100, 2),
        "coffeeCups": len(coffee_), "coffeeTotal": round(sum(t["amountCents"] for t in coffee_) / 100, 2),
        "runKm": round(sum(r["value"] for r in runs), 1), "runSessions": len(runs),
        "longestTrainingRun": max(r["value"] for r in runs if r["value"] != RACE_KM),
        "japanTrip": round(sum(t["amountCents"] for t in japan) / 100, 2), "japanTripCount": len(japan),
        "fundBalance": round(fund_balance / 100, 2), "fundTarget": 50000,
        "fundProgress": f"{fund_balance / 5000000:.1%}", "booksRead": len(BOOK_DATES), "booksTarget": 24,
        "halfMarathon": "2:41:33", "raceDate": RACE.isoformat(),
        "thoughts": len(THOUGHTS), "tasks": len(TASKS), "tasksDone": f"{len(done) / len(TASKS):.0%}",
        "habitRecords": len(HABIT_RECORDS),
        "expense2026": round((spent - sum(t["amountCents"] for t in tx_normal if t["date"][:4] == "2025" and t.get("type") == "expense")
                              + 28800 * periods_elapsed) / 100, 2),
        "booksPct": f"{len(BOOK_DATES) / 24:.1%}",
    }
    story = {
        "meta": {"storyId": "xiaoman-v2", "persona": "小满", "lockedClaims": claims},
        "accounts": [{"name": "旅行专款", "type": "bank", "initialBalanceCents": 300000, "icon": "airplane",
                      "color": "#0EA5E9", "notes": "明年去南美的钱，每月发工资先转三千"}],
        "budgets": [{"account": WX, "amountCents": cents(3000), "period": "month"},
                    {"account": ZFB, "amountCents": cents(1000), "period": "month"},
                    {"account": CARD, "amountCents": cents(1500), "period": "month"},
                    {"account": CASH, "amountCents": cents(200), "period": "month"},
                    {"account": WX, "amountCents": food_budget_cents(), "period": "month", "category": "餐饮"}],
        "financeProjects": [
            {"name": JAPAN, "icon": "airplane", "color": "#F97316", "startDate": "2026-04-23", "endDate": "2026-04-28",
             "budgetAmountCents": cents(12000), "status": "completed", "createdAt": "2026-02-26T22:40",
             "note": "大阪三天京都两天，一个人去的"},
            {"name": "莫干山两天", "icon": "mountain.2.fill", "color": "#10B981", "startDate": "2026-10-02", "endDate": "2026-10-04",
             "budgetAmountCents": cents(1500), "status": "completed", "createdAt": "2026-09-21T20:35",
             "note": "和室友，躺了两天"}],
        "transactions": TX,
        "thoughts": sorted(THOUGHTS, key=lambda t: t["createdAt"]),
        "tasks": sorted(TASKS, key=lambda t: t["createdAt"]),
        "habits": [
            {"name": "跑步", "type": "numeric", "icon": "figure.run", "color": "#EA794C", "unit": "公里",
             "targetValue": 5, "frequency": "weekly", "description": "今年跑一场半马", "createdAt": "2026-01-04T21:10"},
            {"name": "阅读", "type": "numeric", "icon": "book.fill", "color": "#FF6B35", "unit": "分钟",
             "targetValue": 30, "description": "睡前读一会儿", "createdAt": "2025-11-24T21:30"},
            {"name": "健身", "type": "checkIn", "icon": "dumbbell.fill", "color": "#10B981", "targetCount": 1,
             "description": "办了卡就去", "createdAt": "2026-06-10T11:25"},
            {"name": "早起", "type": "checkIn", "icon": "sun.max.fill", "color": "#F59E0B", "targetCount": 1,
             "description": "七点前起床", "createdAt": "2026-01-19T22:05", "archived": True}],
        "habitRecords": HABIT_RECORDS,
        "goals": [
            {"title": "跑完一场半马", "domain": "health", "summary": "今年跑完一场半马",
             "desiredOutcome": "完赛一场半程马拉松", "motivation": "三十而立，给自己一个交代",
             "createdAt": "2025-12-31T23:52", "deadline": "2026-12-31", "status": "completed",
             "completedAt": "2026-11-01T10:41", "goalKind": "target", "metricSource": "habit", "sourceHabit": "跑步",
             "metricUnit": "公里", "targetValue": 21.1, "habits": ["跑步"],
             "tasks": ["报名杭州半马", "买跑鞋", "买盐丸和能量胶"]},
            {"title": "年底存下5万", "domain": "finance", "summary": "旅行专款到五万",
             "desiredOutcome": "12月31日前旅行专款到5万", "motivation": "明年辞职去南美，想想的那种",
             "createdAt": "2025-12-31T23:54", "deadline": "2026-12-31", "goalKind": "cumulative",
             "metricSource": "ledger", "ledgerScope": "account_balance", "ledgerAccount": "旅行专款",
             "metricUnit": "元", "targetValue": 50000},
            {"title": "读完24本书", "domain": "learning", "summary": "一年读完24本",
             "desiredOutcome": "12月31日前读完24本", "motivation": "少刷手机", "createdAt": "2025-12-31T23:57",
             "deadline": "2026-12-31", "goalKind": "cumulative", "metricSource": "manual", "metricUnit": "本",
             "targetValue": 24, "startDate": "2025-11-24", "habits": ["阅读"], "tasks": ["把今年的书单整理一下"],
             "metricLogs": [{"date": iso(at(x, R.choice([21, 22, 23]), R.randint(0, 59))), "value": 1,
                             "note": BOOKS_BY_DATE[x]} for x in BOOK_DATES]}],
        "conversations": [], "insights": [], "memoryRecords": [],
    }

    # ── 对账：任何一条不过就不出文件 ──
    errs = []
    def chk(cond, msg):
        if not cond:
            errs.append(msg)
    now_s = NOW.strftime("%Y-%m-%dT%H:%M")
    stamps = ([t["date"] for t in TX if "date" in t] + [t["createdAt"] for t in THOUGHTS]
              + [t["date"] for t in HABIT_RECORDS] + [t["createdAt"] for t in TASKS]
              + [t.get("completedAt", "") for t in TASKS])
    chk(all(s < now_s for s in stamps), "有记录的时间不早于现在（注入时会被当成没发生）")
    chk(all(t["completedAt"] > t["createdAt"] for t in done), "有待办完成早于创建")
    chk(max(runs, key=lambda r: r["date"])["value"] == RACE_KM, "最新一条跑步不是半马（达标型取最新）")
    chk(1000000 < fund_balance < 5000000, f"旅行专款余额 {fund_balance / 100} 不在「存了一大半、年底差一点」的区间")
    chk(len(BOOK_DATES) == 19 and BOOK_DATES[-1] < TODAY, "读书 19 本的日期不对")
    titles = Counter(t["title"] for t in TASKS)
    for g in story["goals"]:
        for tt in g.get("tasks", []):
            chk(titles[tt] == 1, f"目标「{g['title']}」挂靠的任务「{tt}」在剧本里不是恰好一条（{titles[tt]} 条）")
    for t in TASKS:
        if "plannedStart" in t:
            chk(t["plannedStart"][:10] == t["plannedEnd"][:10] and t["plannedStart"] < t["plannedEnd"],
                f"时间块不合法：{t['title']}")
    for d in gaps_days:
        chk(d.isoformat() not in recorded, f"断记录日 {d} 里出现了记录")
    closed = {x.isoformat() for x in HOLIDAYS | GAPS}
    on_holiday = [t for t in TX if t.get("date", "")[:10] in closed and not t.get("project")
                  and ((t.get("category") == "交通/地铁" and t.get("note", "") in ("", "地铁", "上班", "下班", "早高峰", "加班回来"))
                       or t.get("note", "").startswith("起晚了"))]     # 放假日不该通勤（出门玩的地铁不算）
    chk(not on_holiday, f"法定假日/断记录日出现了通勤或工作午餐：{[t['date'] for t in on_holiday][:5]}")
    cash, cash_day = 0, ""
    for t in sorted((t for t in TX if t.get("account") == CASH and "date" in t), key=lambda t: t["date"]):
        cash += t["amountCents"] if t["type"] == "income" else -t["amountCents"]
        cash_day = t["date"][:10]
        if cash < 0:
            break
    chk(cash >= 0, f"现金账户在 {cash_day} 变成负数：没有取现/收现金却有现金支出")
    anchored = {t[1].split("{")[0] for t in C.THOUGHTS_ANCHORED}
    stray = [t["content"][:16] for t in THOUGHTS
             if any(a <= dt_of(t["createdAt"]).date() <= b for a, b in AWAY)
             and not any(t["content"].startswith(x) for x in anchored)]
    chk(not stray, f"人不在杭州，却有当天在杭州才可能发生的想法：{stray[:3]}")
    by_day = defaultdict(list)
    for t in THOUGHTS:
        by_day[t["createdAt"][:10]].append(t["content"])
    twins = []
    for day, items in by_day.items():
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                a_, b_ = set(bigrams(items[i])), set(bigrams(items[j]))
                if len(a_ | b_) and len(a_ & b_) / len(a_ | b_) >= 0.45:
                    twins.append((day, items[i][:14], items[j][:14]))
    chk(not twins, f"同一天有两条几乎一样的想法：{twins[:2]}")
    if errs:
        sys.exit("❌ 对账失败：\n  - " + "\n  - ".join(errs))
    return story, claims


def write_claims_md(path, claims):
    head = ["<!-- 由 generate.py 自动生成，不要手改；要改数据请改 generate.py / xiaoman_corpus.py 后重新生成 -->",
            "# 小满 · 口径锁定表（自动生成）", "",
            f"- 生成时间：{claims['generatedAt']}；剧本版本：xiaoman-v2，日历钉在 2025-11-24 起的一年",
            "- 引用原则：文案里的数字以本表为准；**App 界面上显示的数字以界面为准**（个别口径 App 算法不同，见备注列）", "",
            "| 口径 | 数值 | 备注 |", "|---|---|---|"]
    rows = [
        ("使用跨度", f"{claims['spanDays']} 天（2025-11-24 起）", "「已记录 N 天」App 按有记录的日子算，个人页实测会比下面这个数少 1 天，以界面为准"),
        ("有记录的天数", f"{claims['recordedDays']} 天", f"另有 {claims['gapDays']} 天完全没记——真人不会一天不落"),
        ("记账笔数", f"{claims['transactionsInApp']} 笔", "含健身卡分期展开的 24 期；明细 " + str(claims["transactions"]) + " 条"),
        ("全年支出", f"¥{claims['annualExpense']:,.0f}", "2025-11-24 起算；脚本口径 = 明细 + 分期已发生期数 − 退款。已在 App「统计」里逐月读数加总核对一致"),
        ("2026 年支出", f"¥{claims['expense2026']:,.0f}", "1 月 1 日起算到生成时刻；App 按季度显示：一季度 + 二季度 + 三季度 + 四季度至今"),
        ("咖啡", f"{claims['coffeeCups']} 杯 / ¥{claims['coffeeTotal']:,.0f}", "= 咖啡类目加总"),
        ("跑步", f"{claims['runKm']} 公里 / {claims['runSessions']} 次", "最长断档 " + str(claims["longestRunBreakDays"])
         + " 天；赛前最长一次 " + str(claims["longestTrainingRun"]) + " 公里"),
        ("日本关西", f"¥{claims['japanTrip']:,.0f} / {claims['japanTripCount']} 笔", "预算 12,000；机票住宿门票提前一个多月付，所以三月的账单最高"),
        ("半马", f"2:41:33（{claims['raceDate']}）", "七点半开跑，十点十一分冲线；目标卡片显示 21.1 / 21.1 公里（界面实测）；之后跑休，无跑步记录"),
        ("存钱进度", f"{claims['fundProgress']}（¥{claims['fundBalance']:,.0f} / 50,000）",
         "期初 3,000 + 12 个月 ×3,000 + 年终奖 5,000 − 日本行的机票住宿门票；目标页界面实测一致"),
        ("读书", f"{claims['booksRead']} / {claims['booksTarget']} 本（{claims['booksPct']}）", "手动记录；目标页界面实测一致；最后一本十月上旬读完，之后在备赛"),
        ("想法", f"{claims['thoughts']} 条", "无重复；同一句不会出现两次"),
        ("待办", f"{claims['tasks']} 条（完成 {claims['tasksDone']}）", "含重复出现的周报、取快递、缴房租等"),
        ("习惯记录", f"{claims['habitRecords']} 条", "阅读/跑步/健身/早起（已归档）"),
    ]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(head + [f"| {a} | {b} | {c} |" for a, b, c in rows]) + "\n")


def main():
    story, claims = build()
    with open("story.json", "w", encoding="utf-8") as f:
        json.dump(story, f, ensure_ascii=False, separators=(",", ":"))
    print(f"✅ story.json｜交易 {claims['transactions']} 条（App 内 {claims['transactionsInApp']} 笔）｜想法 {claims['thoughts']}"
          f"｜待办 {claims['tasks']}（完成 {claims['tasksDone']}）｜习惯记录 {claims['habitRecords']}")
    print("   口径：", json.dumps(claims, ensure_ascii=False))
    if "--claims-md" in sys.argv:
        write_claims_md(sys.argv[sys.argv.index("--claims-md") + 1], claims)
    return 0


if __name__ == "__main__":
    sys.exit(main())
