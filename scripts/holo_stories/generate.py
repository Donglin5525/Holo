#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""小满剧本生成器（holo_stories 01 号档案）

产出 story.json，供 HoloStorySeeder（HOLO 工程注入通道）灌进模拟器。
字段真源：同目录 SCHEMA.md。人设真源：自媒体仓库 seed/xiaoman-人格设定.md。

设计原则（人味儿三律，见记忆 media-seed-human-taste-standard）：
1. 金额有零有整——从真实价格池采样，不整十整百
2. 节奏爆发式——工作日/周末双模式 + 月末小爆发 + 深夜偶发，不是匀速
3. 口径从明细算出——硬口径（旅行/存款/读书/半马）由固定构造保证，
   软口径（咖啡/全年支出/跑步）生成后统计、断言在区间，写进 lockedClaims

确定性：random.Random(42)，同一版本代码产出逐字节一致，可 diff 可复现。
"""
import json
import random
import sys
from datetime import date, timedelta

R = random.Random(42)
TODAY = date.today()  # 注入锚点：剧本全程用相对天数 D-N，季节事件用固定刻度

def cents(yuan): return int(round(yuan * 100))

def ts(d, hh=None, mm=None):
    """相对天数 → 剧本日期串。d=天数前（负数=未来）；不给时刻=12:00"""
    day = f"D+{-d}" if d < 0 else f"D-{d}"
    if hh is None: return day
    return f"{day}T{hh:02d}:{mm if mm is not None else 0:02d}"

def weekday(d):
    """D-d 是星期几（0=周一）。节奏按真实星期走，任何注入日生成的周末模式都对。"""
    return (TODAY - timedelta(days=d)).weekday()

def month_day(d):
    return (TODAY - timedelta(days=d)).day

def month_num(d):
    return (TODAY - timedelta(days=d)).month

def pick(pool):
    return R.choice(pool)

def note(pool, empty_rate=0.40):
    """备注：素材池抽样 + 空备注率（真人大面积不写备注）"""
    if R.random() < empty_rate: return ""
    return pick(pool)

def day_of(datestr):
    """"D-37T07:30" → 37；"D+38" → -38；非法 → None"""
    head = datestr.split("T")[0]
    if head.startswith("D-"): return int(head[2:])
    if head.startswith("D+"): return -int(head[2:])
    return None

# ─────────────────────────── 人格配置（小满） ───────────────────────────
# 季节事件刻度（相对注入日；注释为设计参照，锚定 2026-11-23 换算）
D_NEWYEAR_GOALS = 358   # 跨年夜，立三个目标（12/30）
D_CNY_START, D_CNY_END = 280, 274   # 春节（2/16 除夕 ~ 2/22 初六）
D_JAPAN_START, D_JAPAN_END = 214, 209   # 日本关西（4/23 出发 ~ 4/28 回程到杭州）
D_GYM = 165             # 健身卡（6/11 办卡，24 期分期）
D_618 = 158             # 618 剁手峰（6/18）
D_RAISE = 105           # 调薪（8/10）
D_RUN_BREAK = 260       # 跑步断档开始（3/4）
D_RUN_RESUME = 190      # 跑步重启（5/18）
D_HALFMARATHON = 36     # 杭州半马 2:41:33（10/18，此后休整无跑步）
D_KEYBOARD = 152        # 买键盘（6/23）
D_KEYBOARD_REFUND = 140 # 键盘退货（7/5）
RUN_BREAK_NOTE = "重新开始 别再断了"
def training_days():
    """训练期可选日：1-3月 + 5-10月（排除断档与半马后）"""
    return R.choice([R.randint(D_HALFMARATHON + 1, D_RUN_RESUME),
                     R.randint(D_RUN_BREAK + 1, D_NEWYEAR_GOALS - 1)])

COFFEE_NOTES = ["瑞幸 生椰拿铁","manner 带走","又买咖啡 唉","续命","楼下新开的 试一次",
                "瑞幸 券后 9.9","9.9 的快乐","加班 咖啡因","manner 燕麦拿铁","库迪 5块8",
                "咖啡因续一条命"]
LUNCH_NOTES = ["老娘舅","沙县 老三样","轻食 骗自己","外卖 满减凑单","公司楼下 麻辣烫",
               "食堂 改善伙食","全家 关东煮","黄焖鸡","又麻辣烫 辣的","面馆 加蛋",
               "兰州拉面 加肉","预制菜时代 唉","同事拼单 麻辣香锅","饺子 速冻的"]
DINNER_NOTES = ["外卖","煮面","加班餐","便利店的关东煮","想吃辣的","烤串 和同事",
                "自己做饭 惊呆室友","螺蛳粉 被投诉","火锅 一个人的","炒饭 加火腿",
                "减肥 吃草 没坚持住","夜宵 罪过"]
TAXI_NOTES = ["加班","下雨","起晚了","地铁停运了","跟师傅聊了一路","报销不了 痛",
              "搬家 师傅多要了","看展回来 太累"]
SUPERMARKET_NOTES = ["囤纸巾","洗衣液 酒精 拖把","超市大采购","卫生纸又没了","凑满减",
                     "牙膏 抽纸 肥皂三件套","打折 鸡蛋两板"]
FRUIT_NOTES = ["水果 库存","香蕉 苹果 梨","超市果切 打折","凑单水果","葡萄 洗了一碗",
               "提子 一串","果盘 拼的"]
SHUIGUO = FRUIT_NOTES

# ─────────────────────────── 交易 ───────────────────────────
def gen_salary_and_fixed():
    tx = []
    for d in range(365, 0, -1):
        if month_day(d) == 10:  # 发薪日（时刻带分钟抖动，避免全年秒级一致的模板味）
            amount = 12800 if d > D_RAISE else 14200
            tx.append({"id": f"salary-{d}", "type": "income", "category": "工资",
                       "account": "储蓄卡", "amountCents": cents(amount),
                       "date": ts(d, 10, 5 + R.randint(-3, 3)), "note": "工资"})
            if d == D_RAISE:  # 调薪日互证：想法说「喝了杯 19.5 的」
                tx.append({"type": "expense", "category": "咖啡", "account": "微信",
                           "amountCents": cents(19.5), "date": ts(d, 14, R.randint(10, 50)),
                           "note": "调薪 请自己的"})
        if month_day(d) == 1:   # 房租
            tx.append({"type": "expense", "category": "居住/房租", "account": "微信",
                       "amountCents": cents(1500), "date": ts(d, 9, 12 + R.randint(-5, 5)), "note": "房租"})
        if month_day(d) == 6:
            tx.append({"type": "expense", "category": "居住/话费", "account": "支付宝",
                       "amountCents": cents(39), "date": ts(d, 10, 30 + R.randint(-10, 10)), "note": "话费套餐"})
        if month_day(d) == 15:  # 水电燃气
            tx.append({"type": "expense", "category": "居住/电费", "account": "支付宝",
                       "amountCents": cents(R.choice([86.5, 94.2, 112.8, 133.5, 158, 77.6])),
                       "date": ts(d, 20, 15 + R.randint(-8, 8)), "note": "水电燃气"})
    # 半马报名费（1 月初，配「钱都交了」的想法）
    tx.append({"type": "expense", "category": "体育赛事", "account": "支付宝",
               "amountCents": cents(150), "date": ts(D_NEWYEAR_GOALS - 2, 21, R.randint(10, 50)),
               "note": "杭州半马 报名费"})
    return tx

def gen_savings_transfers():
    """旅行专款：最近 12 个「10 日」各转 3000，期初结转 11208 → 余额精确 36000（72%）"""
    tx, made = [], 0
    d = 365
    while d > 0 and made < 12:
        if month_day(d) == 10:
            tx.append({"type": "income", "category": "转入", "account": "旅行专款",
                       "amountCents": cents(3000), "date": ts(d, 10, 22 + R.randint(-4, 4)),
                       "note": "发薪日转存" if R.random() < 0.35 else ""})
            made += 1
        d -= 1
    assert made == 12
    return tx

def gen_japan_project():
    """日本关西 6 天，31 笔硬凑 ¥11,208。机票钱记在订票日（提前一个多月），
    回程日只留日本机场的手信——与杭州本地日常消费互斥（对抗审查 R2-02）。"""
    items = [  # (相对旅行出发日的偏移, 时刻, 类目, 账户, 金额, 备注)；off 负数=出发前
        (1, "08:30", "交通/火车", "旅行专款", 228, "JR 关西广域券 三日"),
        (0, "13:05", "餐饮/超市", "旅行专款", 68.5, "关空 便利店补给"),
        (0, "15:30", "交通/公交", "旅行专款", 92, "机场快线"),
        (1, "09:20", "餐饮/早餐", "旅行专款", 46, "饭团 味增汤"),
        (1, "11:00", "门票", "旅行专款", 698, "环球影城 快速票"),
        (1, "12:40", "餐饮/午餐", "旅行专款", 158, "哈利波特园区 黄油啤酒套餐"),
        (1, "19:10", "餐饮/晚餐", "旅行专款", 96, "道顿堀 章鱼烧"),
        (2, "10:15", "门票", "旅行专款", 320, "海游馆"),
        (2, "12:30", "餐饮/午餐", "旅行专款", 520, "黑门市场 海鲜丼和牛"),
        (2, "18:30", "餐饮/晚餐", "旅行专款", 268, "和牛放题 心疼但值"),
        (3, "08:50", "交通/火车", "旅行专款", 118, "新大阪→京都"),
        (3, "14:20", "门票", "旅行专款", 72, "清水寺"),
        (3, "15:00", "住宿", "旅行专款", 320, "京都 民宿"),
        (3, "16:00", "购物/服饰", "旅行专款", 156, "抹茶伴手礼"),
        (3, "16:30", "购物/美妆", "旅行专款", 326.5, "药妆 第二波 退税"),
        (4, "09:00", "住宿", "旅行专款", 880, "温泉旅馆 一泊二食"),
        (4, "13:30", "购物/美妆", "旅行专款", 460, "药妆 扫货"),
        (4, "10:00", "手续费", "旅行专款", 55, "京都站 行李寄存"),
        (4, "17:40", "餐饮/夜宵", "旅行专款", 85, "居酒屋 一人"),
        (5, "10:00", "餐饮/茶饮", "旅行专款", 58, "宇治 抹茶冰淇淋"),
        (5, "12:10", "餐饮/午餐", "旅行专款", 124, "一兰 拉面"),
        (5, "13:10", "交通/公交", "旅行专款", 32, "京都 巴士一日券"),
        (5, "14:00", "娱乐/音乐", "旅行专款", 45, "单曲循环了一路"),
        (5, "19:30", "餐饮/晚餐", "旅行专款", 142, "最后一天 吃顿好的"),
        (6, "10:30", "购物/礼物", "旅行专款", 92, "关西机场 手信"),
        (2, "14:00", "住宿", "旅行专款", 380, "大阪 心斋桥民宿 D3"),
        (1, "18:00", "住宿", "旅行专款", 380, "大阪 心斋桥民宿 D2"),
        (0, "16:30", "住宿", "旅行专款", 380, "大阪 心斋桥民宿 D1"),
        (2, "20:15", "餐饮/啤酒", "旅行专款", 68, "超市啤酒 便利店蹲"),
    ]
    bad = [i for i in items if "占位" in str(i[5]) or i[4] == 0]
    assert not bad, f"占位条目泄漏: {bad}"
    flights = [  # 机票记在订票日（出发前 ~40 天）
        (40, "20:45", 2380, "机票 去程 提前蹲的特价"),
        (38, "21:20", 2160, "机票 回程"),
    ]
    tx = []
    for off, hhmm, cat, acct, amt, n in items:
        d = D_JAPAN_START - off
        hh, mm = hhmm.split(":")
        tx.append({"type": "expense", "category": cat, "account": acct,
                   "amountCents": cents(amt), "date": ts(d, int(hh), int(mm)),
                   "note": n, "project": "日本旅行"})
    for back, hhmm, amt, n in flights:
        hh, mm = hhmm.split(":")
        tx.append({"type": "expense", "category": "交通/机票", "account": "旅行专款",
                   "amountCents": cents(amt), "date": ts(D_JAPAN_START + back, int(hh), int(mm)),
                   "note": n, "project": "日本旅行"})
    total = sum(t["amountCents"] for t in tx)
    assert total == cents(11208), f"日本旅行口径不平: {total/100}"
    # 回程日当晚到家的一笔外卖（21:35，不挂项目，与当天日本行程不冲突）
    tx.append(mk(D_JAPAN_START - 6, "外卖", "微信", 35.5, (21, 35), "到家 点个外卖"))
    return tx

def gen_daily_expenses():
    """日常 ~880 笔：工作日/周末双模式 + 月末爆发 + 深夜偶发"""
    tx = []
    for d in range(365, 1, -1):
        if D_CNY_END <= d <= D_CNY_START + 2:
            continue  # 春节段单独生成（含年前采买）
        if D_JAPAN_START - 7 <= d <= D_JAPAN_START:
            continue  # 旅行段（含出发前一晚与回程日）由项目单独生成，杜绝「分身术」
        is_weekend = weekday(d) >= 5
        monthend = month_day(d) >= 25

        # 工作日通勤地铁（双程 85%）
        if not is_weekend and R.random() < 0.85:
            tx.append(mk(d, "交通/地铁", "支付宝", R.choice([4, 4, 4, 5, 5, 7]),
                         R.choice([(8, 12), (8, 25), (8, 40), (9, 2)]), ""))
            if R.random() < 0.9:
                tx.append(mk(d, "交通/地铁", "支付宝", R.choice([4, 4, 5, 5, 7]),
                             R.choice([(18, 30), (19, 5), (19, 40), (21, 15)]), ""))
        # 打车 8%（加班晚归/周末）
        if R.random() < (0.11 if not is_weekend else 0.07):
            amt = round(R.gauss(32, 9), 1)
            amt = max(16.5, min(58, amt))
            tx.append(mk(d, "交通/打车", R.choice(["微信", "支付宝"]),
                         amt, (R.choice([22, 22, 23, 0]), R.randint(5, 55)),
                         note(TAXI_NOTES, 0.5)))
        # 工作日午餐 72%
        if not is_weekend and R.random() < 0.72:
            tx.append(mk(d, "午餐", "微信",
                         R.choice([18.5, 21, 23, 23, 26.8, 28, 31, 32, 19.9, 35]),
                         (12, R.randint(0, 55)), note(LUNCH_NOTES)))
        # 咖啡：工作日 45% / 周末 22%（≈130 杯/年，口径区间见对账）
        if R.random() < (0.45 if not is_weekend else 0.22):
            tx.append(mk(d, "咖啡", R.choice(["微信", "微信", "支付宝"]),
                         R.choice([9.9, 9.9, 9.9, 13.8, 13.8, 15.5, 19.5, 21]),
                         R.choice([(8, 35), (9, 10), (10, 20), (14, 30)]),
                         note(COFFEE_NOTES, 0.5)))
        # 晚餐/外卖 55% / 周末 75%（21 点后才允许「夜宵」标签）
        if R.random() < (0.55 if not is_weekend else 0.75):
            hh = R.choice([18, 19, 19, 20, 21, 22])
            cat = R.choice(["晚餐", "晚餐", "晚餐", "外卖", "夜宵"] if hh >= 21
                           else ["晚餐", "晚餐", "晚餐", "晚餐", "外卖"])
            tx.append(mk(d, cat, R.choice(["微信", "支付宝"]),
                         R.choice([16.8, 19.9, 22.5, 25.8, 28, 32, 35.5, 41, 45]),
                         (hh, R.randint(0, 59)),
                         note(DINNER_NOTES)))
        # 周末生活消费 2-4 笔 + 早餐/夜宵（周末在家点早餐是常态）
        if is_weekend:
            if R.random() < 0.55:
                tx.append(mk(d, R.choice(["早餐", "早餐", "外卖"]), R.choice(["微信", "支付宝"]),
                             R.choice([12.5, 15.8, 18, 22.5, 26]),
                             (R.choice([9, 10]), R.randint(0, 59)),
                             note(["睡醒点个早饭","豆浆油条送到楼下","早午餐 brunched","昨天剩的 热一下"], 0.6)))
            for _ in range(R.choice([2, 2, 3, 3, 4])):
                kind = R.random()
                if kind < 0.30:
                    tx.append(mk(d, "超市", "支付宝",
                                 R.choice([32.6, 45.8, 58, 76.5, 89, 112.4, 128]),
                                 (10 + R.randint(0, 8), R.randint(0, 59)),
                                 note(SUPERMARKET_NOTES, 0.5)))
                elif kind < 0.52:
                    tx.append(mk(d, "水果", "微信",
                                 R.choice([12.5, 18.8, 25, 33.9, 46, 58.8, 88]),
                                 (R.choice([10, 11, 15, 16]), R.randint(0, 59)),
                                 note(FRUIT_NOTES, 0.6)))
                elif kind < 0.68:
                    tx.append(mk(d, "饮品", R.choice(["微信", "支付宝"]),
                                 R.choice([13, 15.5, 18, 21.5, 26]),
                                 (14 + R.randint(0, 5), R.randint(0, 59)),
                                 note(["奶茶 三分糖","喜茶 新品","茶颜 没有了 点的别的","霸王茶姬",
                                       "一点点 波霸","又是奶茶 唉","请同事","椰子水 好贵"], 0.45)))
                elif kind < 0.82:
                    tx.append(mk(d, R.choice(["电影", "游戏", "视频"]),
                                 R.choice(["微信", "支付宝"]),
                                 R.choice([39.9, 45, 49.9, 68, 6, 30, 98, 25]),
                                 (R.choice([10, 13, 15, 19, 20]), R.randint(0, 59)),
                                 note(["电影 爆米花没买","续了视频会员","游戏 又氪了 停手",
                                       "Steam 打折 买而不玩","switch 新游戏","演出门票 手快有"], 0.55)))
                else:
                    tx.append(mk(d, R.choice(["日用", "书籍", "运动"]),
                                 R.choice(["支付宝", "储蓄卡"]),
                                 R.choice([15.9, 22, 39, 45.5, 56, 68, 89]),
                                 (R.choice([11, 14, 16, 19]), R.randint(0, 59)),
                                 note(["数据线 又坏一根","买了本书 拖延症自救失败",
                                       "跳绳 阻尼的","袜子 三双装","肥皂香薰 无用但快乐",
                                       " kindle 书 一本"], 0.5)))
        # 月末小爆发：+1~2 笔杂项
        if monthend and R.random() < 0.5:
            tx.append(mk(d, R.choice(["日用", "超市", "理发"]),
                         R.choice(["支付宝", "现金"]),
                         R.choice([20, 35, 58, 68, 88]),
                         (R.choice([12, 15, 17, 20]), R.randint(0, 59)),
                         note(["理发 老地方","月末清购物车","又买手机壳"], 0.5)))
        # 深夜冲动 23:00 后，全年 ~6 笔
        if R.random() < 6 / 363:
            tx.append(mk(d, R.choice(["夜宵", "游戏", "服饰"]),
                         "支付宝",
                         R.choice([25.8, 32, 6, 30, 98, 128, 156]),
                         (23, R.randint(10, 55)),
                         note(["半夜饿了 罪过","睡不者 下单 醒来后悔","深夜购物 克制失败",
                               "游戏充值 手滑"], 0.35)))
    return tx

def mk(d, cat, acct, amt, hm, n):
    hh, mm = hm
    return {"type": "expense", "category": cat, "account": acct,
            "amountCents": cents(amt), "date": ts(d, hh, mm), "note": n}

def gen_cny():
    """春节（D_CNY_START=2/16 除夕）：红包双向 + 年货 + 高铁。
    类目与时段强绑定：白天走亲戚/零食，晚饭点才记「请客/晚餐」。"""
    tx = []
    # 高铁往返（假期首尾）
    tx.append(mk(D_CNY_START, "交通/火车", "支付宝", 263.5, (8, 40), "回家 高铁"))
    tx.append(mk(D_CNY_END, "交通/火车", "支付宝", 263.5, (16, 22), "回杭州"))
    # 年货（除夕前两天）
    tx.append(mk(D_CNY_START + 2, "超市", "支付宝", 386.5, (19, 30), "年货 一车"))
    # 压岁红包：除夕/初一给出去，初一初二收回来
    for i, (d, amt, n) in enumerate([
        (D_CNY_START, 200, "外婆 压岁钱必须给"),
        (D_CNY_START, 100, "小侄女"),
        (D_CNY_START - 1, 200, "表弟家娃 年夜饭上"),
    ]):
        tx.append({"type": "expense", "category": "红包礼金", "account": "微信",
                   "amountCents": cents(amt), "date": ts(d, 10 + i * 2, R.randint(10, 50)), "note": n})
    for i, (d, amt, n) in enumerate([
        (D_CNY_START - 1, 600, "妈妈 硬塞的"),
        (D_CNY_START - 2, 200, "二姨 拜年"),
        (D_CNY_START - 2, 200, "舅舅 拜年"),
        (D_CNY_START - 3, 100, "邻居阿婆"),
    ]):
        tx.append({"type": "income", "category": "红包", "account": "微信",
                   "amountCents": cents(amt), "date": ts(d, R.choice([11, 12, 14]), R.randint(5, 55)), "note": n})
    # 假期日常：白天零食/水果，饭点请客晚餐
    for d in range(D_CNY_END, D_CNY_START):
        if R.random() < 0.55:  # 白天：走亲戚零食
            tx.append(mk(d, R.choice(["零食", "水果", "请客"]),
                         "微信", R.choice([25.8, 45, 68, 88.8]),
                         (R.choice([10, 11, 14]), R.randint(0, 59)),
                         note(["走亲戚","和表哥撸串","瓜子花生砂糖橘","奶茶 聚会必备"], 0.5)))
        if R.random() < 0.6:  # 饭点：聚餐/年夜饭
            tx.append(mk(d, R.choice(["请客", "晚餐"]),
                         "微信", R.choice([88.8, 120, 156, 200]),
                         (R.choice([17, 18, 19]), R.randint(0, 59)),
                         note(["年夜饭 我买单的那桌","请爸妈吃饭","亲戚饭局 轮流做东"], 0.4)))
    return tx

def gen_618_and_keyboard():
    tx = [
        {"id": "keyboard", "type": "expense", "category": "数码", "account": "储蓄卡",
         "amountCents": cents(799), "date": ts(D_KEYBOARD, 21, 10), "note": "键盘 客制化入门"},
        mk(D_618, "数码", "储蓄卡", 1299, (20, 45), "显示器 2K 升级"),
        mk(D_618 - 1, "购物/鞋包", "支付宝", 399, (19, 20), "相机包"),
        mk(D_618 - 2, "日用", "支付宝", 45.9, (12, 15), "凑单 插线板"),
        mk(D_618 + 1, "服饰", "微信", 156, (15, 40), "T恤 三件 618价"),
        mk(D_618 + 2, "零食", "支付宝", 68.5, (11, 25), "囤零食"),
        {"id": "keyboard-refund", "refundOf": "keyboard", "amountCents": cents(799),
         "date": ts(D_KEYBOARD_REFUND, 15, 20), "remark": "键程不喜欢 退了"},
    ]
    return tx

def gen_installment():
    return [{"id": "gym", "type": "expense", "category": "健身", "account": "储蓄卡",
             "amountCents": cents(6912), "note": "健身卡 两年卡",
             "installment": {"periods": 24, "startDate": ts(D_GYM, 11, 30)}}]

# ─────────────────────────── 想法 ───────────────────────────
THOUGHTS_WORK = ["会上那个方案不太行 算了不说","又开了一天会","需求文档改到第8版了","老板今天心情不好 少说话",
    "实习生都比我能卷","周报憋不出来","这个季度OKR悬了","面试了个候选人 比我强 有点慌","跨部门撕了一天 累",
    "通勤路上想通的 会上又糊涂了","PPT 美化大师（自封）","工位搬到窗边了 开心","午休刷手机 刷到焦虑",
    "老板说下季度加人 信一半","数据好看 但我知道为什么好看","又背了个新指标","上班摸鱼写周报 周报里全是鱼",
    "会议记录里一半是废话 另一半是重复的废话","灵光一现 提了个需求 被夸了","地铁上改方案 手抖差点发出",
    "下班前一小时最漫长","工作三年 学会最深的是已读乱回","年终评优 应该没我 佛了","新来的领导口音好重 聚精会神听",
    "复盘会开成表功会 也行吧","想在会议室白板上画小人","周五下午的效率是玄学","收到 HR 的节日邮件 删了",
    "带教新人 讲着讲着自己悟了","通勤耳机是上班的精神氧气","老板画的饼 我做成笔记了（字面）",
    "季度汇报 紧张程度堪比高考","离职同事的告别邮件写得好真诚","摸鱼的本质是心累不是闲"]
THOUGHTS_MONEY = ["这个月好像又超了","工资一到账就没了存在感","想买kindle新的 旧的太卡","记账之后才知道外卖花了这么多",
    "咖啡自由 = 咖啡不自由","凑满减凑了个寂寞","这笔真的需要吗 需要（不是）","又开始研究理财产品了 研究完不买","省钱省到抠 没必要",
    "外卖红包链得点五个App 太累","月底吃土 面包6块那种","红包随出去的和收回来的 打平了",
    "打车软件的优惠券越来越难用了","便利店关东煮涨价了 5毛 也是涨","支付宝账单不敢点开","生活成本里 蛋糕是刺客","买贵了 同款第二天降价 气死",
    "开始记账之后 反而不焦虑了 奇怪","月底对账 竟然还剩300 意外","给自己设了个小金库 目标5万 走着瞧",
    "消费降级第一步 自己带饭 第二步 坚持不住"]
# 时间敏感条目：必须落在指定窗口（对抗审查 R2 修复——随机撒日期会造成「赛后感想比比赛早」类穿帮）
THOUGHTS_ANCHORED = [
    # (内容, d_lo, d_hi, mood, tags)
    ("618 尾款人 清醒一点", D_618 - 2, D_618 + 1, "calm", ["消费"]),
    ("双十一的策略是删购物车", 10, 16, "calm", ["消费"]),
    ("双十一直接卸载APP好了", 10, 16, "angry", ["消费"]),
    ("工资涨了1400 第一个月全吃了", D_RAISE, D_RAISE + 3, "happy", ["工作"]),
    ("健身房销售的话术我都背下来了", D_GYM - 3, D_GYM, "thinking", ["生活"]),
    ("纠结半个月 还是把健身卡办了", D_GYM, D_GYM + 2, "calm", ["生活"]),
    ("路边的桂花开了 空气都是甜的", 55, 85, "happy", ["生活"]),
    ("地铁口的烤红薯 是冬天的信号", 0, 25, "happy", ["生活"]),
    ("被子晒过太阳的味道 是秋天", 40, 90, "calm", ["生活"]),
    ("赛后一周 腿终于原谅我了", D_HALFMARATHON + 5, D_HALFMARATHON + 9, "calm", ["跑步"]),
    ("赛前紧张 比面试还紧张", D_HALFMARATHON - 3, D_HALFMARATHON - 1, "thinking", ["跑步"]),
    ("跑完的腿是铁的", D_HALFMARATHON, D_HALFMARATHON + 4, "happy", ["跑步"]),
    ("研究跑鞋半天 最后啥也没买 好样的", 45, 120, "calm", ["跑步"]),
    ("配速掉了一点 但心率稳了 也是进步", 60, 180, "calm", ["跑步"]),
    ("跑前纠结一小时 跑完后悔没早出门", 45, 180, "thinking", ["跑步"]),
    ("给自己买了花 理由是配得上", 30, 330, "happy", ["生活"]),
    ("室友做的饭 香醒了", 30, 330, "happy", ["生活"]),
    ("地铁读书 效率意外的高", 30, 330, "calm", ["读书"]),
    ("下雨 跑不成了 先歇几天", D_RUN_BREAK, D_RUN_BREAK + 8, "calm", ["跑步"]),
    ("阳台的绿萝好像烂根了 买盆新的还是救一救", 20, 340, "thinking", ["生活"]),
]
# 跑步自由条目（全部训练期锚定：1-3月 ∪ 5-10月，排除断档与半马后）
THOUGHTS_RUN = ["跑步第一天 肺是别人的","连跑三周了 有点上瘾","重新开始 别再断了","配速终于进6了","今天不想跑 跑完了 真香",
    "晨跑的风 是城市没醒时的特权","夜跑遇到遛狗的狗 比我有劲",
    "拉伸不到位 第二天酸到怀疑人生","补给胶难吃 但真香（能量上的）","跑崩了 5公里就回来了 唉",
    "买了跑步袜 心理配速快了10秒","下雨天跑步机上凑合 好无聊","跑步APP的徽章 集齐一半了",
    "给自己定了规矩 下雨天改力量训练","今天空气好 值得多跑一公里","状态玄学 昨天轻松今天要死",
    "跑步时想通的工作问题 比开会多","跑完的早餐 比什么都香","群里大佬晒百公里 我安静点赞","冬天跑步的第一口冷空气 提神"]
THOUGHTS_READ = ["翻开书 五分钟睡着 催眠神器","kindle 泡面盖 重新启用",
    "读到一句：种一棵树最好的时间","纸质书的手感 电子书的价格 我反复横跳","读书笔记欠了一屁股","这本书有点读不下去 换",
    "通勤听书 听睡着了 倒是睡了个好觉","晚上关灯前读十页 是我的仪式感","今年读完的第一本 挑薄的先赢",
    "书架到头了 开始两排叠放","书店蹭读 最后一杯奶茶钱买了它","微信读书的书友划线 有时比书精彩",
    "读完半天缓不过来 好书后遗症","读书速度慢 但记住了 也行","借同事的书 三周了 才翻到第三章 惭愧",
    "小说和非小说 交替读 不腻","图书馆借的书 有上一个人的划线 像隔空聊天",
    "工具书读完就忘 但做笔记的这一本不会","地铁早高峰读不了书 改听书了","睡前那几页 是一天里最安静的时段",
    "这本封面好看 买回来发现内容一般 教训","看完一本厚书 成就感比发工资还实","书非借不能读也 古人诚不欺我"]
THOUGHTS_SELF = ["感觉自己最近有点空","今晚早睡（并没有）","想跑步 但床不让","拖延症 拖到把拖延都忘了",
    "三十岁了 还是没搞清楚要什么","又立flag了 这次的理由是想清楚了","羡慕能坚持的人","今天什么都没干 但很累",
    "想学个乐器 又怕三分钟热度","少刷手机 多睡觉 道理都懂","想到一个App点子 记下来再说",
    "今天情绪一般 但记录了一下 就还行","早上的自己和晚上的自己是两个物种","拖延到最后 反而效率最高 是天赋吧",
    "社交电量耗尽 需要独处充电","又冲动消费了 复盘 算了不复盘了","想通了一件事 大部分焦虑来自比较",
    "洗澡时灵感最多 可惜热水器时间有限","体检报告还行 就是让少熬夜","今天有点丧 吃顿好的解决一半",
    "立了个新规矩 手机不进卧室 坚持3天了","整理床铺的瞬间 觉得人生可控了",
    "周六早上自然醒 赚到了","体重秤的电池 该没就没吧","又开始写日记 第4天 历史最好成绩",
    "深夜的歌单品味比白天好","承认吧 你就是想被夸","遇到难题先睡一觉 是策略不是逃避",
    "记录这件事 快变成习惯了 好现象"]
THOUGHTS_LIFE = ["周末大扫除 只完成了大 扫除没动","快递盒攒了一堆 该卖了",
    "被楼下猫治愈了","插座又不够用了","冰箱里还有什么 答案是寂寞","想去看海 就查了下高铁票",
    "超市自由 修车不自由","伞 又丢了第三把","手机内存又满了 相片真难删",
    "楼下新开的面馆 好吃 但为什么没人","菜市场的烟火气 比商场治愈","晾衣杆的顺序也是有讲究的",
    "楼上的椅子又拖了 忍","收快递的取件码 背得比手机号熟","洗衣机排队 人类文明的默契","阳台的风 今晚很舒服",
    "周末最大的成就 出门吃了早饭","囤的方便面在过期前吃完了 刚好","便利店新品 报喝","超市试吃摊 吃出了一顿早茶",
    "攒了十个快递 一次取完 像发年终奖",
    "室友的猫 会自己开抽屉 服","楼下面包店八点后半价 蹲点成功","搬家时最舍不得的是这扇窗的日落",
    "窗帘该洗了 想到就累","新买的四件套 睡出了酒店感"]
THOUGHTS_SEASONAL = {  # 关键节点注入，保证故事弧线在想法池里可见
    D_NEWYEAR_GOALS: ["新年三件事：半马 存5万 读24本 写下来就算数了","跨年烟花好看 但明年想在海边看","半马报名了 钱都交了"],
    D_CNY_START - 1: ["到家了 妈妈第一句怎么又瘦了"],
    D_RUN_BREAK + 3: ["连着加班两周 跑步的事 先放放"],
    D_RUN_RESUME: ["复跑第一天 慢慢来"],
    D_GYM + 1: ["健身房第一天 跑步机比我先累"],
    D_JAPAN_START: ["出发！第一次去日本","环球影城 值回票价 哈利波特区哭了"],
    D_618: ["付尾款 手起刀落 一气呵成"],
    D_RAISE: ["调薪了 14200 请自己喝了杯 19.5 的"],
    D_HALFMARATHON: ["杭州半马 2:41:33 完赛了 累哭 但值"],
    1: ["年度总结：没有大成就 但一天没落下记录"],
    2: ["翻去年今天的想法 好傻 但很真"],
}

def gen_thoughts():
    """三层结构：季节锚点必出 → 时间敏感条目锚定窗口 → 自由池补足。
    池尽即止不硬凑（一年 180~210 条想法都真实），禁任何「（又想到）」类机械后缀。"""
    thoughts, used = [], set()
    MOODS = {  # 每池情绪权重（对抗审查 R2-18：随机 mood 与内容错位）
        "work":  (["thinking", "calm", "happy", "sad", "angry", "inspired"], [32, 20, 12, 16, 15, 5]),
        "money": (["thinking", "calm", "happy", "sad", "angry", "inspired"], [35, 20, 15, 22, 6, 2]),
        "self":  (["thinking", "calm", "happy", "sad", "angry", "inspired"], [30, 22, 28, 12, 3, 5]),
        "life":  (["thinking", "calm", "happy", "sad", "angry", "inspired"], [15, 28, 42, 8, 3, 4]),
        "run":   (["thinking", "calm", "happy", "sad", "angry", "inspired"], [20, 22, 38, 8, 2, 10]),
        "read":  (["thinking", "calm", "happy", "sad", "angry", "inspired"], [25, 35, 28, 5, 2, 5]),
    }
    TAGS = {"work": ["工作", "工作/吐槽"], "money": ["消费"], "life": ["生活"],
            "run": ["跑步"], "read": ["读书"], "self": []}

    def add(content, d, mood=None, tags=None, kind=None):
        assert content not in used, f"想法重复: {content}"
        used.add(content)
        if mood is None:
            vals, w = MOODS.get(kind, MOODS["self"])
            mood = R.choices(vals, weights=w)[0]
        if tags is None:
            pool_t = TAGS.get(kind, [])
            tags = [R.choice(pool_t)] if pool_t and R.random() < 0.30 else []
        thoughts.append({"content": content,
                         "createdAt": ts(d, R.choice([9, 10, 12, 14, 15, 16, 17, 22, 23]),
                                         R.randint(0, 59)),
                         "mood": mood, "tags": tags})

    # 1) 季节锚点（必出，故事弧线）
    for d, pool in THOUGHTS_SEASONAL.items():
        for c in pool:
            add(c, d)
    # 2) 时间敏感条目（锚定窗口，指定 mood/tags）
    for content, lo, hi, mood, tags in THOUGHTS_ANCHORED:
        add(content, R.randint(max(lo, 2), min(hi, 364)), mood=mood, tags=tags)
    # 3) 跑步池整池锚定训练期（1-3月 ∪ 5-10月，排除断档与半马后）
    for c in THOUGHTS_RUN:
        d = training_days()
        if "第一天" in c:
            d = D_NEWYEAR_GOALS + 3
        elif "重新开始" in c:
            d = D_RUN_RESUME
        add(c, d, kind="run")
    # 4) 自由池补足到 ~205；池尽即止
    pools = [("work", THOUGHTS_WORK), ("money", THOUGHTS_MONEY),
             ("self", THOUGHTS_SELF), ("life", THOUGHTS_LIFE), ("read", THOUGHTS_READ)]
    weights = {"work": 28, "money": 18, "self": 18, "life": 20, "read": 16}
    idx = {k: 0 for k, _ in pools}
    for _, pool in pools:
        R.shuffle(pool)
    n_target = max(0, 205 - len(thoughts))
    exhausted = set()
    while n_target > 0 and len(exhausted) < len(pools):
        kind = R.choices(list(weights), weights=list(weights.values()))[0]
        if kind in exhausted:
            continue
        pool = dict(pools)[kind]
        if idx[kind] >= len(pool):
            exhausted.add(kind)
            continue
        add(pool[idx[kind]], R.randint(2, 364), kind=kind)
        idx[kind] += 1
        n_target -= 1
    R.shuffle(thoughts)
    return thoughts

# ─────────────────────────── 待办 ───────────────────────────
TASK_POOL_LIFE = ["取快递", "拿一下丰巢的件", "取快递（大件 周末才能搬）", "缴房租 和室友对账", "交电费 余额不足",
    "买洗衣液", "囤纸巾 下单", "剪头发", "理发（托尼老师那家）", "给妈妈打电话", "给外婆打视频", "换手机壳",
    "卖纸箱", "旧衣服断舍离", "约牙医洗牙", "体检报告去取", "配眼镜 复查度数", "预约疫苗", "手机相册清理",
    "备份照片到硬盘", "整理收藏夹", "退货运费险看一下", "收拾阳台", "绿萝换盆",
    "冰箱除霜", "换被套", "晒被子", "买生日礼物给室友", "回消息 好友申请", "还充电宝", "预约九价 HPV 第二针",
    "给绿植浇水", "扔掉阳台的枯叶", "整理药箱", "补货洗手液", "修一下歪的置物架", "退宽带多收的费",
    "约保洁 深度打扫", "把冬装收进压缩袋", "凉席换成床垫", "买蚊香液", "通下水道（浴室）", "换灯泡",
    "处理闲置键盘 挂闲鱼", "闲鱼砍价的人回了吗", "给充电宝充满", "整理电脑桌面", "清空回收站",
    "退订视频会员自动续费", "查话费为什么多扣了", "换牙刷头", "买牙膏", "指甲刀丢了 买新的",
    "预约猫咪驱虫（室友的猫）", "猫砂下单", "给猫买罐头", "水电分摊转给室友", "修雨伞",
    "找秋裤", "冬被拿出来晒", "买速冻水饺囤着", "零食柜补货", "水果店会员卡充值",
    "眼药水快用完了", "感冒药备一点", "创可贴买防水款"]
TASK_POOL_WORK = ["整理用户访谈问题", "写周报", "周报 数据补齐", "画活动流程图", "对齐需求 排期会",
    "改需求文档 v8", "需求文档 终稿", "回复老板的消息 三个方案", "面试候选人 2 位", "准备月度汇报 PPT",
    "整理竞品动态", "数据周报 拉表", "复盘活动效果", "约跨部门对齐会", "改埋点需求", "验收设计稿",
    "给设计师提意见（委婉版）", "更新 OKR 进展", "整理需求池", "写双周报", "催运营给素材", "催设计终稿",
    "写季度总结", "整理会议纪要 发群", "预约会议室（大）", "改报名页文案", "核对活动库存奖品",
    "用户反馈分类打标", "回复应用商店评论", "申请预算 报销", "报销单贴发票", "续费设计工具席位",
    "给新人开权限", "带新人过一遍流程", "整理 SOP 文档", "上线前 checklist 过一遍", "灰度放量观察",
    "回滚预案确认", "值班交接", "统计月活口径差异", "和财务对账发票", "写年度规划初稿",
    "砍需求（最难的部分）", "给老板的一页纸汇报", "整理用户旅程图", "竞品价格表更新"]
TASK_POOL_TRIP = ["办签证", "办签证（加急 照片重拍）", "订机票", "订大阪酒店", "订京都温泉旅馆",
    "买转换插头", "换日元 现金", "下载离线地图", "买交通卡 ICOCA", "查环球影城快速票",
    "买防晒和小药包", "寄养猫 问室友", "请假条 OA 提交", "行程表 终版", "收拾行李箱", "买行李秤"]
TASK_POOL_HEALTH = ["跑 5 公里", "跑 8 公里", "长距离 LSD", "拉伸 15 分钟", "泡沫轴放松",
    "睡前不看手机（今天）", "体检 预约", "约康复拉伸", "买新跑鞋 试穿", "研究跑姿视频"]
TASK_POOL_GOAL = ["读完《置身事内》", "读完《置身事内》后半本", "还书给同事", "图书馆借书",
    "下单 6 月书单", "整理读书笔记", "Kindle 续航测试（划掉）", "读书角 台灯到位", "旅行专款 转 3000",
    "核对旅行专款余额", "设置存钱自动转账", "记账 补昨天的"]

def gen_tasks(run_days):
    """run_days：跑步记录日列表（由 gen_habit_records 先产出）——
    跑步类待办的完成日必须落在真实记录日上（对抗审查 R2-26）。"""
    tasks = []
    titles = set()
    def add(title, d_created, **kw):
        if title in titles:
            return False  # 池尽/重名即跳过，绝不加「（又一次）」类机械后缀
        titles.add(title)
        t = {"title": title, "createdAt": ts(d_created, R.choice([9, 10, 11, 14, 16, 20, 21]), R.randint(0, 59))}
        t.update(kw)
        tasks.append(t)
        return True
    # 旅行前准备（旅行前 3~55 天完成；d 值越大日期越早）
    for title in ["办签证", "订机票", "订大阪酒店", "买转换插头", "换日元 现金",
                  "下载离线地图", "买交通卡 ICOCA", "查环球影城快速票", "请假条 OA 提交", "收拾行李箱"]:
        d = D_JAPAN_START + R.randint(3, 55)
        add(title, d + R.randint(0, 3), status="completed",
            completedAt=ts(d, R.choice([15, 16, 20]), R.randint(0, 59)),
            importance="p2")
    # 生活/工作池：全年随机撒，周日批量完成的真实模式；重名跳过
    for _ in range(270):
        d = R.randint(2, 364)
        pool = TASK_POOL_LIFE if R.random() < 0.7 else TASK_POOL_WORK
        title = R.choice(pool)
        if title in titles and R.random() < 0.62:
            continue  # 高频重复事件（取快递/周报）少量保留，其余跳过
        kw = {}
        if R.random() < 0.75:
            kw["status"] = "completed"
            gap = 0 if R.random() < 0.55 else R.randint(1, 4)
            if weekday(d - gap) == 6 or R.random() < 0.4:  # 周日集中清理
                cd = d - gap
                while weekday(cd) != 6: cd -= 1
                gap = d - cd
            kw["completedAt"] = ts(d - gap, R.choice([10, 11, 15, 20, 21]), R.randint(0, 59))
            if R.random() < 0.6: kw["dueDate"] = ts(d - R.randint(0, 3), R.choice([18, 21]), 0)
        else:
            kw["status"] = R.choices(["todo", "inProgress"], weights=[85, 15])[0]
            if kw["status"] == "inProgress":
                kw["dueDate"] = ts(R.choice([0, 1, 2]), R.choice([18, 20]), 0)
            elif R.random() < 0.5:
                kw["dueDate"] = ts(-R.randint(0, 14), R.choice([18, 21]), 0)
        if R.random() < 0.5: kw["importance"] = R.choices(["p1", "p2", "p3"], weights=[15, 65, 20])[0]
        if R.random() < 0.3: kw["urgencyMode"] = "auto"
        add(title, d, **kw)
    # 健康/目标杂项：跑步条目绑真实记录日；断档期不生成跑步待办
    for _ in range(70):
        pool = R.choices([TASK_POOL_HEALTH, TASK_POOL_GOAL], weights=[55, 45])[0]
        title = R.choice(pool)
        if title.startswith(("跑", "长距离")):
            if not run_days:
                continue
            d = R.choice(run_days)
            add(title, d, status="completed",
                completedAt=ts(d, R.choice([8, 19, 20]), R.randint(0, 59)))
        else:
            d = R.randint(2, 364)
            add(title, d,
                **({"status": "completed",
                    "completedAt": ts(d - R.randint(0, 2), R.choice([8, 19]), R.randint(0, 59))}
                   if R.random() < 0.8 else {"status": "todo", "dueDate": ts(R.randint(0, 7), 20, 0)}))
    return tasks

# ─────────────────────────── 习惯与记录 ───────────────────────────
def gen_habits():
    return [
        {"name": "跑步", "type": "numeric", "icon": "figure.run", "color": "#EA794C",
         "unit": "公里", "targetValue": 5, "frequency": "weekly",
         "description": "今年跑一场半马", "createdAt": ts(366)},
        {"name": "阅读", "type": "numeric", "icon": "book.fill", "color": "#FF6B35",
         "unit": "分钟", "targetValue": 30,
         "description": "一天 30 分钟", "createdAt": ts(366)},
        {"name": "早起", "type": "checkIn", "icon": "sun.max.fill", "color": "#F59E0B",
         "targetCount": 1, "frequency": "weekly", "createdAt": ts(310), "archived": True},
    ]

def gen_habit_records():
    recs = []
    # 跑步：1 月-3 月中（17 条）→ 断 41 天 → 5 月中-10 月（34 条）→ 半马后休整（0 条）
    def run_session(d, long_run=False):
        dist = R.choice([5.2, 6.8, 8.4]) if long_run else R.choice(
            [3.1, 3.5, 3.8, 4.2, 4.5, 5.0, 5.4])
        note = None
        if d == D_HALFMARATHON:
            dist, note = 21.1, "杭州半马 2:41:33"
        elif d == D_RUN_RESUME:
            note = RUN_BREAK_NOTE
        elif long_run and R.random() < 0.4:
            note = R.choice(["LSD 长距离", "配速 6'15", "绕西湖 一圈", "江边 夜跑"])
        rec = {"habit": "跑步", "date": ts(d, R.choice([6, 7, 7, 19, 20]), R.randint(5, 55)),
               "value": round(dist, 1)}
        if note: rec["note"] = note
        recs.append(rec)
    # 注意 d 值越大日期越早：phase1 = 1月~3月中（d ∈ [261,358]），phase2 = 5月中~10月（d ∈ [37,190]，排除半马日本身）
    phase1 = sorted(R.sample(range(D_RUN_BREAK + 1, D_NEWYEAR_GOALS), 15))
    for d in phase1: run_session(d)
    phase2 = sorted(R.sample(range(D_HALFMARATHON + 1, D_RUN_RESUME), 28))
    for d in phase2:
        run_session(d, long_run=(R.random() < 0.2))
    run_session(D_HALFMARATHON)
    total_km = round(sum(r["value"] for r in recs), 1)
    latest_day = min(day_of(r["date"]) for r in recs)
    assert latest_day == D_HALFMARATHON, "半马后不得有跑步记录（达标型取最新）"
    return recs, total_km

def gen_reading_records():
    recs = []
    d = 363
    while d > 1:
        if R.random() < 0.78:
            mins = max(10, min(95, int(R.gauss(35, 15))))
            rec = {"habit": "阅读", "date": ts(d, R.choice([21, 22, 22, 23]), R.randint(0, 59)),
                   "value": mins}
            if R.random() < 0.06:
                rec["note"] = R.choice(["今晚这本很上头", "10页就困了", "地铁上读的",
                                        "读书角 台灯很配", "kindle 版"])
            recs.append(rec)
        d -= 1
    return recs

def gen_earlybird_records():
    recs, d = [], 300
    while d > 240:
        if R.random() < 0.55:
            rec = {"habit": "早起", "date": ts(d, R.choice([6, 7]), R.randint(20, 59))}
            if R.random() < 0.15:
                rec["completed"] = False
            recs.append(rec)
        d -= 1
    return recs

# ─────────────────────────── 目标 ───────────────────────────
def gen_goals():
    # 读书 metricLogs：19 本，间隔 8-30 天，附部分书名
    logs, d = [], 355
    book_pool = ["《置身事内》", "《被讨厌的勇气》", "《认知觉醒》", "《小王子》", "《夜晚的潜水艇》",
                 "《把自己作为方法》", "《精心时刻》", "《纳瓦尔宝典》", "《蛤蟆先生去看心理医生》",
                 "《香水》", "《人类群星闪耀时》", "《我与地坛》", "《秋园》", "《工作、消费主义和新穷人》",
                 "《亲密关系》", "《活着为了讲述》", "《我们生活在巨大的差距里》", "《一句顶一万句》",
                 "《献给阿尔吉侬的花束》"]
    R.shuffle(book_pool)
    for i in range(19):
        log = {"date": ts(d), "value": 1}
        if R.random() < 0.55: log["note"] = book_pool[i]
        logs.append(log)
        d -= R.randint(9, 22)
    goals = [
        {"title": "跑完一场半马", "domain": "health", "iconEmoji": "🏃",
         "summary": "今年完赛一场半程马拉松",
         "desiredOutcome": "完赛一场半程马拉松", "motivation": "三十而立 给自己一个交代",
         "createdAt": ts(D_NEWYEAR_GOALS, 23, 50), "deadline": ts(-38),
         "status": "completed", "completedAt": ts(D_HALFMARATHON, 11, 15),
         "goalKind": "target", "metricSource": "habit", "sourceHabit": "跑步",
         "metricUnit": "公里", "targetValue": 21.1, "baselineValue": 3,
         "habits": ["跑步"]},
        {"title": "年底存下 5 万", "domain": "finance", "iconEmoji": "💰",
         "summary": "旅行专款账户余额到 5 万",
         "desiredOutcome": "旅行专款账户余额到 5 万", "motivation": "明年辞职去南美 长旅行（想想）",
         "createdAt": ts(D_NEWYEAR_GOALS, 23, 50), "deadline": ts(-38),
         "goalKind": "cumulative", "metricSource": "ledger",
         "ledgerScope": "account_balance", "ledgerAccount": "旅行专款",
         "metricUnit": "元", "targetValue": 50000},
        {"title": "读完 24 本书", "domain": "learning", "iconEmoji": "📚",
         "summary": "今年读完 24 本（现在 19，还差 5 本）",
         "desiredOutcome": "全年读完 24 本书", "motivation": "对抗刷手机",
         "createdAt": ts(D_NEWYEAR_GOALS, 23, 50), "deadline": ts(-38),
         "goalKind": "cumulative", "metricSource": "manual", "metricUnit": "本",
         "targetValue": 24, "habits": ["阅读"], "metricLogs": logs,
         "startDate": ts(366)},  # 显式回溯起算日：立目标前读完的也算（累积口径稳定）
    ]
    return goals

# ─────────────────────────── 汇编 + 对账 ───────────────────────────
def build():
    tx = []
    tx += gen_salary_and_fixed()
    tx += gen_savings_transfers()
    tx += gen_japan_project()
    tx += gen_daily_expenses()
    tx += gen_cny()
    tx += gen_618_and_keyboard()
    tx += gen_installment()
    # 习惯记录先产出（跑步记录日供待办绑定），再生成想法/待办
    run_recs, total_km = gen_habit_records()
    run_days = sorted(day_of(r["date"]) for r in run_recs)
    story = {
        "meta": {"storyId": "xiaoman-v1", "persona": "小满", "lockedClaims": {}},
        "accounts": [{"name": "旅行专款", "type": "bank",
                      "initialBalanceCents": cents(11208),
                      "icon": "airplane", "color": "#0EA5E9",
                      "notes": "去年攒的旅行基金结转 + 每月发薪转存 3000"}],
        "budgets": [
            {"account": "微信", "amountCents": cents(3000), "period": "month"},
            {"account": "微信", "amountCents": cents(900), "period": "month", "category": "餐饮"},
        ],
        "financeProjects": [{"name": "日本旅行", "icon": "✈️", "color": "#F97316",
                             "startDate": ts(D_JAPAN_START), "endDate": ts(D_JAPAN_END),
                             "budgetAmountCents": cents(12000), "status": "completed",
                             "note": "大阪 + 京都 6 天"}],
        "transactions": tx,
        "thoughts": gen_thoughts(),
        "tasks": gen_tasks(run_days),
        "habits": gen_habits(),
        "habitRecords": run_recs + gen_reading_records() + gen_earlybird_records(),
        "goals": gen_goals(),
    }

    # ── 对账（软口径从明细统计，硬口径已由构造+断言保证）──
    coffee = [t for t in tx if t.get("category") == "咖啡" and t["type"] == "expense"]
    coffee_cents = sum(t["amountCents"] for t in coffee)
    # 退款无 type 字段，按负支出冲减；分期不计全额
    daily_expense_cents = sum(
        (-t["amountCents"] if "refundOf" in t else t["amountCents"])
        for t in tx
        if "installment" not in t and ("refundOf" in t or t.get("type") == "expense"))
    # App 端分期只计已发生期（每期 288，到今天为止 ~6 期），文案口径与界面一致
    per_period = cents(6912 / 24)
    periods_elapsed = 6  # D_GYM=165 起每月一期，注入日约为第 6 期
    app_annual_expense = daily_expense_cents + per_period * periods_elapsed
    savings = sum(t["amountCents"] for t in tx if t.get("category") == "转入")
    japan = sum(t["amountCents"] for t in tx if t.get("project") == "日本旅行")
    # 存款余额 = 期初结转 + 转存流水 − 旅行支出（App account_balance 同口径，应恰为 36000=72%）
    savings_balance = cents(11208) + savings - japan
    claims = {
        "daysRecorded": 365,
        "transactionCount": len(tx),
        "coffeeCups": len(coffee), "coffeeTotal": coffee_cents / 100,
        "runKm": total_km, "runSessions": len(run_recs),
        "japanTrip": japan / 100,
        "savingsBalance": savings_balance / 100, "savingsTarget": 50000,
        "booksRead": 19, "booksTarget": 24,
        "halfMarathon": "2:41:33",
        "annualExpense": app_annual_expense / 100,
        "thoughtCount": len(story["thoughts"]),
        "taskCount": len(story["tasks"]),
    }
    story["meta"]["lockedClaims"] = claims

    # ── Schema 自检（生成器侧，失败即退出：账不平不许出片）──
    errs = []
    def chk(cond, msg):
        if not cond: errs.append(msg)
    chk(len(coffee) >= 118 and len(coffee) <= 145, f"咖啡杯数 {len(coffee)} 超出人味区间 118-145")
    chk(6500000 <= daily_expense_cents <= 9000000,
        f"全年支出 {daily_expense_cents/100:.0f} 超出区间 65000-90000（不含分期全额）")
    chk(savings == cents(36000), f"旅行专款转存流水 {savings/100} ≠ 36000")
    chk(savings_balance == cents(36000), f"旅行专款余额 {savings_balance/100} ≠ 36000（期初+转存−旅行支出）")
    chk(japan == cents(11208), f"日本旅行 {japan/100} ≠ 11208")
    chk(200 <= total_km <= 235, f"跑步总量 {total_km} 超出 200-235")
    chk(185 <= len(story["thoughts"]) <= 215,
        f"想法 {len(story['thoughts'])} 超出 185-215（池尽即止的自然区间）")
    titles = [t["title"] for t in story["tasks"]]
    chk(len(titles) == len(set(titles)), "待办 title 有重复")
    chk(len(set(t["date"] for t in run_recs if t.get("note") == "杭州半马 2:41:33")) == 1,
        "半马记录应恰有 1 条（0=缺失，>1=phase 抽样撞上半马日）")
    latest_run = min(run_recs, key=lambda r: day_of(r["date"]))
    chk(latest_run["value"] == 21.1, f"最新跑步记录非 21.1（{latest_run}）——达标型口径会被覆盖")
    for t in tx:
        if "installment" in t:
            n = day_of(t["installment"]["startDate"])
        else:
            n = day_of(t["date"])
        chk(n is not None and n >= 1, f"交易时间太近/格式错: {t}")
    chk(all(day_of(t["date"]) >= D_HALFMARATHON for t in run_recs), "半马后有跑步记录")
    if errs:
        print("❌ 对账失败：", *errs, sep="\n  - ")
        sys.exit(1)
    return story, claims

def main():
    story, claims = build()
    out = "/Users/tangyuxuan/Desktop/Claude/HOLO/scripts/holo_stories/story.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(story, f, ensure_ascii=False, separators=(",", ":"))
    print(f"✅ {out}")
    print(f"   交易 {len(story['transactions'])} 笔 | 想法 {len(story['thoughts'])} | "
          f"待办 {len(story['tasks'])} | 习惯记录 {len(story['habitRecords'])}")
    print("   口径:", json.dumps(claims, ensure_ascii=False, indent=None))

if __name__ == "__main__":
    main()
