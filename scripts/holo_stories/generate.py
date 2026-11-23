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
# 季节事件刻度（相对注入日；注释为设计参照月份）
D_NEWYEAR_GOALS = 358   # 跨年夜，立三个目标
D_CNY_START, D_CNY_END = 285, 278   # 春节假期（年三十~初六）
D_JAPAN_START, D_JAPAN_END = 214, 209   # 日本关西 6 天
D_GYM = 165             # 健身卡（24 期分期）
D_618 = 158             # 618 剁手峰
D_RAISE = 105           # 8 月调薪（>105 的 10 日工资为 12800，之后 14200）
D_RUN_BREAK = 260       # 跑步断档开始（3 月，连续加班+雨季）
D_RUN_RESUME = 190      # 跑步重启（5 月中，对应健身卡办卡期）
D_HALFMARATHON = 36     # 杭州半马 2:41:33（此后休整，无跑步记录）
D_KEYBOARD = 152        # 买键盘（618 期间）
D_KEYBOARD_REFUND = 140 # 键盘退货
RUN_BREAK_NOTE = "重新开始 别再断了"

COFFEE_NOTES = ["瑞幸 生椰拿铁","manner 带走","又买咖啡 唉","续命","楼下新开的 试一次",
                "星巴克 用了券","9.9 的快乐","加班 咖啡因","manner 燕麦拿铁","库迪 5块8",
                "咖啡因续一条命","带电脑去 café 假装办公"]
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
FRUIT_NOTES = ["水果 库存","草莓 贵但好吃","阳光玫瑰 打折","榴莲 咬牙","香蕉 苹果 基础款",
               "西瓜 第一口夏天","橘子 有点酸"]
SHUIGUO = FRUIT_NOTES

# ─────────────────────────── 交易 ───────────────────────────
def gen_salary_and_fixed():
    tx, salary_count = [], 0
    for d in range(365, 0, -1):
        if month_day(d) == 10:  # 发薪日
            amount = 12800 if d > D_RAISE else 14200
            tag = "12月调薪后第一次" if d == D_RAISE - 30 else ""
            tx.append({"id": f"salary-{d}", "type": "income", "category": "工资",
                       "account": "储蓄卡", "amountCents": cents(amount),
                       "date": ts(d, 10, 5), "note": "工资" + (f" {tag}" if tag else "")})
            salary_count += 1
        if month_day(d) == 1:   # 房租 + 话费
            tx.append({"type": "expense", "category": "居住/房租", "account": "微信",
                       "amountCents": cents(1500), "date": ts(d, 9, 12), "note": "房租"})
        if month_day(d) == 6:
            tx.append({"type": "expense", "category": "居住/话费", "account": "支付宝",
                       "amountCents": cents(39), "date": ts(d, 10, 30), "note": "话费套餐"})
        if month_day(d) == 15:  # 水电燃气
            tx.append({"type": "expense", "category": "居住/电费", "account": "支付宝",
                       "amountCents": cents(R.choice([86.5, 94.2, 112.8, 133.5, 158, 77.6])),
                       "date": ts(d, 20, 15), "note": "水电燃气"})
    return tx, salary_count

def gen_savings_transfers():
    """旅行专款：最近 12 个「10 日」各转 3000，期初 0 → 余额精确 36000（72%）"""
    tx, made = [], 0
    d = 365
    while d > 0 and made < 12:
        if month_day(d) == 10:
            tx.append({"type": "income", "category": "转入", "account": "旅行专款",
                       "amountCents": cents(3000), "date": ts(d, 10, 22),
                       "note": "发薪日转存" if made % 3 == 0 else ""})
            made += 1
        d -= 1
    assert made == 12
    return tx

def gen_japan_project():
    """日本关西 6 天，23 笔硬凑 ¥11,208"""
    items = [  # (天数偏移, 时刻, 类目, 账户, 金额, 备注)
        (D_JAPAN_START, "07:15", "交通/机票", "旅行专款", 2380, "机票 去程 早班"),
        (D_JAPAN_START, "12:40", "餐饮/便利店没这分类先超市", "旅行专款", 68.5, "关空 便利店"),
    ]
    # ↑ 先占位，下面用干净表重写
    items = [
        (0, "07:15", "交通/机票", "旅行专款", 2380, "机票 去程 早班红眼"),
        (0, "13:05", "餐饮/超市", "旅行专款", 68.5, "关空 便利店补给"),
        (0, "15:30", "交通/渡轮", "旅行专款", 92, "机场快线"),
        (1, "09:20", "餐饮/早餐", "旅行专款", 46, "饭团 味增汤"),
        (1, "11:00", "门票", "旅行专款", 698, "环球影城 快速票"),
        (1, "12:40", "餐饮/午餐", "旅行专款", 158, "哈利波特园区 黄油啤酒套餐"),
        (1, "19:10", "餐饮/晚餐", "旅行专款", 96, "道顿堀 章鱼烧"),
        (2, "10:15", "门票", "旅行专款", 320, "海游馆"),
        (2, "18:30", "餐饮/晚餐", "旅行专款", 268, "和牛放题 心疼但值"),
        (3, "08:50", "交通/火车", "旅行专款", 118, "新大阪→京都"),
        (3, "14:20", "门票", "旅行专款", 72, "清水寺"),
        (3, "16:00", "购物/服饰", "旅行专款", 156, "抹茶伴手礼"),
        (4, "09:00", "住宿", "旅行专款", 880, "温泉旅馆 一泊二食"),
        (4, "13:30", "购物/美妆", "旅行专款", 460, "药妆 扫货"),
        (4, "17:40", "餐饮/夜宵", "旅行专款", 85, "居酒屋 一人"),
        (5, "10:50", "餐饮/茶饮", "旅行专款", 58, "宇治 抹茶冰淇淋"),
        (5, "12:10", "餐饮/午餐", "旅行专款", 124, "一兰 拉面"),
        (5, "15:20", "交通/公交", "旅行专款", 32, "市巴士一日券"),
        (5, "19:30", "餐饮/晚餐", "旅行专款", 142, "最后一天 吃顿好的"),
        (6, "08:00", "交通/机票", "旅行专款", 2160, "机票 回程"),
        (6, "11:20", "餐饮/超市", "旅行专款", 92, "机场 手信"),
        (5, "21:00", "娱乐/视频", "旅行专款", 45, "京都巴士歌 单曲循环"),
        (2, "20:15", "餐饮/啤酒", "旅行专款", 68, "超市啤酒 便利店蹲"),
        (0, "16:30", "住宿", "旅行专款", 380, "大阪 心斋桥民宿 D1"),
        (1, "18:00", "住宿", "旅行专款", 380, "大阪 心斋桥民宿 D2"),
        (2, "14:00", "住宿", "旅行专款", 380, "大阪 心斋桥民宿 D3"),
        (3, "15:00", "住宿", "旅行专款", 320, "京都 民宿"),
        (1, "08:30", "交通/火车", "旅行专款", 228, "JR 关西广域券 三日"),
        (3, "16:30", "购物/美妆", "旅行专款", 326.5, "药妆 第二波 退税"),
        (4, "10:00", "手续费", "旅行专款", 55, "京都站 行李寄存"),
        (2, "12:30", "餐饮/午餐", "旅行专款", 520, "黑门市场 海鲜丼和牛双人份的一半"),
    ]
    bad = [i for i in items if "没这分类" in i[2]]
    assert not bad, f"占位类目泄漏: {bad}"
    fixed = {  # 两笔交通类目改用预设存在的名字
        92: "交通/公交", 118: "交通/火车", 32: "交通/公交", 2160: "交通/机票",
    }
    tx = []
    for off, hhmm, cat, acct, amt, n in items:
        cat = fixed.get(amt, cat) if amt in fixed else cat
        d = D_JAPAN_START - off
        hh, mm = hhmm.split(":")
        tx.append({"type": "expense", "category": cat, "account": acct,
                   "amountCents": cents(amt), "date": ts(d, int(hh), int(mm)),
                   "note": n, "project": "日本旅行"})
    total = sum(t["amountCents"] for t in tx)
    assert total == cents(11208), f"日本旅行口径不平: {total/100}"
    return tx

def gen_daily_expenses():
    """日常 ~880 笔：工作日/周末双模式 + 月末爆发 + 深夜偶发"""
    tx = []
    for d in range(365, 1, -1):
        if D_CNY_END <= d <= D_CNY_START:
            continue  # 春节段单独生成
        if D_JAPAN_END <= d <= D_JAPAN_START:
            continue  # 旅行段项目内单独生成
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
        # 晚餐/外卖 55% / 周末 75%
        if R.random() < (0.55 if not is_weekend else 0.75):
            tx.append(mk(d, R.choice(["晚餐", "晚餐", "晚餐", "外卖", "夜宵"]),
                         R.choice(["微信", "支付宝"]),
                         R.choice([16.8, 19.9, 22.5, 25.8, 28, 32, 35.5, 41, 45]),
                         R.choice([(18, 40), (19, 10), (19, 50), (20, 30), (21, 15)]),
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
                                       "Steam 打折 买而不玩","switch 新游戏","演唱会抢票 没抢到 手续费"], 0.55)))
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
    """春节：红包双向 + 年货 + 高铁（写在小满回老家叙事里）"""
    tx = []
    # 高铁往返（假期首尾）
    tx.append(mk(D_CNY_START, "交通/火车", "支付宝", 263.5, (8, 40), "回家 高铁"))
    tx.append(mk(D_CNY_END, "交通/火车", "支付宝", 263.5, (16, 22), "回杭州"))
    # 年货（假期前一天）
    tx.append(mk(D_CNY_START + 2, "超市", "支付宝", 386.5, (19, 30), "年货 一车"))
    # 压岁红包：给 3 份，收 4 份（收入）
    for i, (d, amt, n) in enumerate([
        (D_CNY_START - 1, 200, "外婆 压岁钱必须给"),
        (D_CNY_START - 1, 100, "小侄女"),
        (D_CNY_START - 2, 200, "表弟家娃"),
    ]):
        tx.append({"type": "expense", "category": "红包礼金", "account": "微信",
                   "amountCents": cents(amt), "date": ts(d, 10 + i, R.randint(10, 50)), "note": n})
    for i, (d, amt, n) in enumerate([
        (D_CNY_START - 1, 600, "妈妈 硬塞的"),
        (D_CNY_START - 2, 200, "二姨"),
        (D_CNY_START - 2, 200, "舅舅"),
        (D_CNY_START - 3, 100, "邻居阿婆"),
    ]):
        tx.append({"type": "income", "category": "红包", "account": "微信",
                   "amountCents": cents(amt), "date": ts(d, R.choice([11, 12, 14]), R.randint(5, 55)), "note": n})
    # 假期里的日常：聚餐/零食
    for d in range(D_CNY_END, D_CNY_START):
        if R.random() < 0.8:
            tx.append(mk(d, R.choice(["请客", "零食", "水果", "晚餐"]),
                         "微信", R.choice([45, 68, 88.8, 120, 156, 25.8]),
                         (R.choice([11, 12, 17, 18]), R.randint(0, 59)),
                         note(["走亲戚 饭局","和表哥撸串","瓜子花生砂糖橘","奶茶 聚会必备",
                               "请爸妈吃饭 我买单"], 0.5)))
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
THOUGHTS_MONEY = ["这个月好像又超了","工资一到账就没了存在感","要不把健身卡转出去","想买kindle 但会吃灰吧",
    "记账之后才知道外卖花了这么多","咖啡自由 = 咖啡不自由","618 尾款人 清醒一点","双十一直接卸载APP好了",
    "凑满减凑了个寂寞","这笔真的需要吗 需要（不是）","又开始研究理财产品了 研究完不买","省钱省到抠 没必要",
    "转了3000去旅行专款 离5万又近一点","看了眼存款 睡了","外卖红包链得点五个App 太累","月底吃土 面包6块那种",
    "工资涨了1400 第一个月全吃了","双十一的策略是删购物车","这个月信用卡账单 假装没看见","红包随出去的和收回来的 打平了",
    "打车软件的优惠券越来越难用了","便利店关东煮涨价了 5毛 也是涨","记账App年度报告 比我自己懂我","想办签证 发现照片要重拍 又一笔",
    "健身房销售的话术我都背下来了","支付宝账单不敢点开","生活成本里 蛋糕是刺客","买贵了 同款第二天降价 气死",
    "开始记账之后 反而不焦虑了 奇怪","月底对账 竟然还剩300 意外","给自己设了个小金库 目标5万 走着瞧",
    "消费降级第一步 自己带饭 第二步 坚持不住"]
THOUGHTS_SELF = ["感觉自己最近有点空","今晚早睡（并没有）","想跑步 但床不让","拖延症 拖到把拖延都忘了",
    "三十岁了 还是没搞清楚要什么","又立flag了 这次的理由是想清楚了","羡慕能坚持的人","今天什么都没干 但很累",
    "想学个乐器 又怕三分钟热度","朋友圈精装修 现实毛坯","少刷手机 多睡觉 道理都懂","想到一个App点子 记下来再说",
    "今天情绪一般 但记录了一下 就还行","早上的自己和晚上的自己是两个物种","拖延到最后 反而效率最高 是天赋吧",
    "社交电量耗尽 需要独处充电","又冲动消费了 复盘 算了不复盘了","想通了一件事 大部分焦虑来自比较",
    "洗澡时灵感最多 可惜热水器时间有限","体检报告还行 就是让少熬夜","今天有点丧 吃顿好的解决一半",
    "立了个新规矩 手机不进卧室 坚持3天了","给自己买了花 理由是配得上","整理床铺的瞬间 觉得人生可控了",
    "周六早上自然醒 赚到了","体重秤的电池 该没就没吧","又开始写日记 第4天 历史最好成绩",
    "深夜的歌单品味比白天好","承认吧 你就是想被夸","遇到难题先睡一觉 是策略不是逃避",
    "记录这件事 快变成习惯了 好现象"]
THOUGHTS_LIFE = ["要不要把阳台那盆绿萝换成龟背竹","周末大扫除 只完成了大 扫除没动","快递盒攒了一堆 该卖了",
    "被楼下猫治愈了","插座又不够用了","冰箱里还有什么 答案是寂寞","室友做的饭 香醒了","想去看海 就查了下高铁票",
    "被子晒过太阳的味道 是秋天","超市自由 修车不自由","伞 又丢了第三把","手机内存又满了 相片真难删",
    "楼下新开的面馆 好吃 但为什么没人","菜市场的烟火气 比商场治愈","晾衣杆的顺序也是有讲究的",
    "楼上的椅子又拖了 忍","收快递的取件码 背得比手机号熟","洗衣机排队 人类文明的默契","阳台的风 今晚很舒服",
    "周末最大的成就 出门吃了早饭","囤的方便面在过期前吃完了 刚好","便利店新品 报喝","超市试吃摊 吃出了一顿早茶",
    "路边的桂花开了 一秒回到十月","地铁口的烤红薯 是冬天的信号","攒了十个快递 一次取完 像发年终奖",
    "室友的猫 会自己开抽屉 服","楼下面包店八点后半价 蹲点成功","搬家时最舍不得的是这扇窗的日落",
    "窗帘该洗了 想到就累","新买的四件套 睡出了酒店感"]
THOUGHTS_RUN = ["跑步第一天 肺是别人的","连跑三周了 有点上瘾","下雨 断一天（变成断四十天的开始）",
    "重新开始 别再断了","配速终于进6了","今天不想跑 跑完了 真香","半马报名了 钱都交了 退不了",
    "长距离LSD 15km 人生新纪录","赛前紧张 比面试还紧张","2:41:33 完赛了 累哭 但值","跑完腿是铁的",
    "研究跑鞋半天 最后啥也没买 好样的","晨跑的风 是城市没醒时的特权","夜跑遇到遛狗的狗 比我有劲",
    "配速掉了一点 但心率稳了 也是进步","跑前纠结一小时 跑完后悔没早出门","第一次跑进西湖断桥 人少的时候",
    "拉伸不到位 第二天酸到怀疑人生","补给胶难吃 但真香（能量上的）","跑崩了 5公里就回来了 唉",
    "买了跑步袜 心理配速快了10秒","下雨天跑步机上凑合 好无聊","跑步APP的徽章 集齐一半了",
    "给自己定了规矩 下雨天改力量训练","今天空气好 值得多跑一公里","状态玄学 昨天轻松今天要死",
    "跑步时想通的工作问题 比开会多","跑完的早餐 比什么都香","赛后一周 腿终于原谅我了",
    "群里大佬晒百公里 我安静点赞","冬天跑步的第一口冷空气 提神"]
THOUGHTS_READ = ["翻开书 五分钟睡着 催眠神器","地铁读书 效率意外的高","今年第10本 稳的","kindle 泡面盖 重新启用",
    "读到一句：种一棵树最好的时间","纸质书的手感 电子书的价格 我反复横跳","读书笔记欠了一屁股","这本书有点读不下去 换",
    "通勤听书 听睡着了 倒是睡了个好觉","晚上关灯前读十页 是我的仪式感","今年读完的第一本 挑薄的先赢",
    "书架到头了 开始两排叠放","书店蹭读 最后一杯奶茶钱买了它","微信读书的书友划线 有时比书精彩",
    "读完半天缓不过来 好书后遗症","读书速度慢 但记住了 也行","借同事的书 三周了 才翻到第三章 惭愧",
    "小说和非小说 交替读 不腻","给读完的书包书皮 像给考试卷分数","读到一半去查了作者的八卦 正常吧",
    "图书馆借的书 有上一个人的划线 像隔空聊天","今年书单进度有点悬 加速","晚上读书代替刷手机 第一周成功",
    "工具书读完就忘 但做笔记的这一本不会","地铁早高峰读不了书 改听书了","睡前那几页 是一天里最安静的时段",
    "这本封面好看 买回来发现内容一般 教训","看完一本厚书 成就感比发工资还实","书非借不能读也 古人诚不欺我",
    "读到共鸣处 拍照发了个没人的朋友圈"]
THOUGHTS_SEASONAL = {  # 关键节点注入，保证故事弧线在想法池里可见
    D_NEWYEAR_GOALS: ["新年三件事：半马 存5万 读24本 写下来就算数了","跨年烟花好看 但明年想在海边看"],
    D_CNY_START - 1: ["到家了 妈妈第一句怎么又瘦了","抢红包手气最佳 转头全发回去了"],
    D_RUN_BREAK + 3: ["连着加班两周 跑步的事 先放放","梅雨 跑步计划湿了"],
    D_RUN_RESUME: ["健身房办卡了 钱花了 人就会去（希望）"],
    D_JAPAN_START: ["出发！第一次去日本 签证 photos 全套","环球影城 值回票价 哈利波特区哭了"],
    D_618: ["付尾款 手起刀落 一气呵成"],
    D_RAISE: ["调薪了 14200 请自己喝了杯 19.5 的"],
    D_HALFMARATHON: ["杭州半马 2:41:33 完赛 谢谢一直记录的自己"],
    1: ["年度总结：没有大成就 但一天没落下记录"],
    2: ["翻去年今天的想法 好傻 但很真"],
}

def gen_thoughts():
    thoughts, used = [], set()
    def add(content, d, mood=None, tags=None):
        if content in used: content = content + "（又想到）"
        used.add(content)
        thoughts.append({"content": content,
                         "createdAt": ts(d, R.choice([9, 10, 12, 14, 15, 16, 17, 22, 23]),
                                         R.randint(0, 59)),
                         "mood": mood or R.choices(
                             ["thinking", "calm", "happy", "sad", "angry", "inspired"],
                             weights=[30, 25, 20, 12, 8, 5])[0],
                         "tags": tags or []})
    # 季节锚点（必出，故事弧线）
    for d, pool in THOUGHTS_SEASONAL.items():
        for c in pool:
            add(c, d)
    # 跑步断档期：D_RUN_BREAK~D_RUN_RESUME 之间不出现跑步正面想法
    pools = [("work", THOUGHTS_WORK), ("money", THOUGHTS_MONEY), ("self", THOUGHTS_SELF),
             ("life", THOUGHTS_LIFE), ("run", THOUGHTS_RUN), ("read", THOUGHTS_READ)]
    weights = {"work": 26, "money": 18, "self": 16, "life": 18, "run": 12, "read": 10}
    idx = {k: 0 for k, _ in pools}
    for _, pool in pools:
        R.shuffle(pool)
    n_target = 210 - len(thoughts)
    exhausted = set()
    while n_target > 0:
        if len(exhausted) == len(pools):  # 全部池尽：重置计数，复用素材（变体后缀兜底）
            exhausted.clear()
            for k_, _ in pools:
                idx[k_] = 0
        kind = R.choices(list(weights), weights=list(weights.values()))[0]
        if kind in exhausted:
            continue
        pool = dict(pools)[kind]
        if idx[kind] >= len(pool):
            exhausted.add(kind)
            continue
        d = R.randint(2, 364)
        # 断档期内跳过跑步类正面想法（人味儿一致性）
        if kind == "run" and D_RUN_RESUME < d < D_RUN_BREAK:
            continue
        content = pool[idx[kind]]; idx[kind] += 1
        if kind == "run" and ("连跑三周" in content or "上瘾" in content):
            d = R.randint(D_RUN_BREAK, D_NEWYEAR_GOALS)  # 早期训练期
        if kind == "run" and "第一天" in content:
            d = D_NEWYEAR_GOALS + 3
        add(content, d)
        n_target -= 1
    R.shuffle(thoughts)
    return thoughts[:210]

# ─────────────────────────── 待办 ───────────────────────────
TASK_POOL_LIFE = ["取快递", "拿一下丰巢的件", "取快递（大件 周末才能搬）", "缴房租 和室友对账", "交电费 余额不足",
    "买洗衣液", "囤纸巾 下单", "剪头发", "理发（托尼老师那家）", "给妈妈打电话", "给外婆打视频", "换手机壳",
    "卖纸箱", "旧衣服断舍离", "约牙医洗牙", "体检报告去取", "配眼镜 复查度数", "预约疫苗", "手机相册清理",
    "备份照片到硬盘", "整理收藏夹", "退货运费险看一下", "收拾阳台", "绿萝换盆", "给龟背竹浇水",
    "冰箱除霜", "换被套", "晒被子", "买生日礼物给室友", "回消息 好友申请", "还充电宝", "预约九价 HPV 第二针"]
TASK_POOL_WORK = ["整理用户访谈问题", "写周报", "周报 数据补齐", "画活动流程图", "对齐需求 排期会",
    "改需求文档 v8", "需求文档 终稿", "回复老板的消息 三个方案", "面试候选人 2 位", "准备月度汇报 PPT",
    "整理竞品动态", "数据周报 拉表", "复盘活动效果", "约跨部门对齐会", "改埋点需求", "验收设计稿",
    "给设计师提意见（委婉版）", "更新 OKR 进展", "整理需求池", "写双周报", "催运营给素材", "催设计终稿"]
TASK_POOL_TRIP = ["办签证", "办签证（加急 照片重拍）", "订机票", "订大阪酒店", "订京都温泉旅馆",
    "买转换插头", "换日元 现金", "下载离线地图", "买交通卡 ICOCA", "查环球影城快速票",
    "买防晒和小药包", "寄养猫 问室友", "请假条 OA 提交", "行程表 终版", "收拾行李箱", "买行李秤"]
TASK_POOL_HEALTH = ["跑 5 公里", "跑 8 公里", "长距离 LSD", "拉伸 15 分钟", "泡沫轴放松",
    "睡前不看手机（今天）", "体检 预约", "约康复拉伸", "买新跑鞋 试穿", "研究跑姿视频"]
TASK_POOL_GOAL = ["读完《置身事内》", "读完《置身事内》后半本", "还书给同事", "图书馆借书",
    "下单 6 月书单", "整理读书笔记", "Kindle 续航测试（划掉）", "读书角 台灯到位", "旅行专款 转 3000",
    "核对旅行专款余额", "设置存钱自动转账", "记账 补昨天的"]

def gen_tasks():
    tasks = []
    titles = set()
    def add(title, d_created, **kw):
        suffix = ""
        while title + suffix in titles:
            suffix = "（" + "再" * (suffix.count("再") + 1) + "一次）" if suffix else "（又一次）"
        title = title + suffix
        titles.add(title)
        t = {"title": title, "createdAt": ts(d_created, R.choice([9, 10, 11, 14, 16, 20, 21]), R.randint(0, 59))}
        t.update(kw)
        tasks.append(t)
    # 旅行前准备（2 月-4 月中，锚定日本行）
    for i, title in enumerate(["办签证", "订机票", "订大阪酒店", "买转换插头", "换日元 现金",
                               "下载离线地图", "买交通卡 ICOCA", "查环球影城快速票", "请假条 OA 提交", "收拾行李箱"]):
        d = D_JAPAN_START - R.randint(3, 50)
        add(title, d, status="completed",
            completedAt=ts(d - R.randint(0, 2), R.choice([15, 16, 20]), R.randint(0, 59)),
            importance="p2")
    # 生活池：全年随机撒 ~170 条，周日批量完成的真实模式
    for _ in range(170):
        d = R.randint(2, 364)
        pool = TASK_POOL_LIFE if R.random() < 0.7 else TASK_POOL_WORK
        title = R.choice(pool)
        due = R.random()
        kw = {}
        if due < 0.75:
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
            else:
                if R.random() < 0.5:
                    dd = R.randint(0, 14)
                    kw["dueDate"] = ts(-dd if dd else 0, R.choice([18, 21]), 0) if dd else ts(0, 18, 0)
                    if dd == 0: kw["dueDate"] = ts(0, 18, 0)
        if R.random() < 0.5: kw["importance"] = R.choices(["p1", "p2", "p3"], weights=[15, 65, 20])[0]
        if R.random() < 0.3: kw["urgencyMode"] = "auto"
        add(title, d, **kw)
    # 健康/目标杂项 ~60 条
    for _ in range(60):
        d = R.randint(2, 364)
        if D_RUN_RESUME < d < D_RUN_BREAK: d = R.choice([R.randint(2, 30), R.randint(D_RUN_BREAK, 364) if D_RUN_BREAK < 364 else 300])
        pool = R.choices([TASK_POOL_HEALTH, TASK_POOL_GOAL], weights=[55, 45])[0]
        add(R.choice(pool), d,
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
         "desiredOutcome": "完赛一场半程马拉松", "motivation": "30 岁前给自己一个交代",
         "createdAt": ts(D_NEWYEAR_GOALS, 23, 50), "deadline": ts(-38),  # 相对：38 天后的赛事季
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
         "targetValue": 24, "habits": ["阅读"], "metricLogs": logs},
    ]
    return goals

# ─────────────────────────── 汇编 + 对账 ───────────────────────────
def build():
    fixed_tx, salary_count = gen_salary_and_fixed()
    tx = []
    tx += fixed_tx
    tx += gen_savings_transfers()
    tx += gen_japan_project()
    tx += gen_daily_expenses()
    tx += gen_cny()
    tx += gen_618_and_keyboard()
    tx += gen_installment()
    # 分类去重声明（健身不在常用预设？在：娱乐/健身。健身卡分期类目用「健身」）
    story = {
        "meta": {"storyId": "xiaoman-v1", "persona": "小满", "lockedClaims": {}},
        "accounts": [{"name": "旅行专款", "type": "bank",
                      "initialBalanceCents": cents(11208),
                      "icon": "airplane", "color": "#0EA5E9",
                      "notes": "去年攒的旅行基金结转 + 每月发薪转存 3000"}],
        "budgets": [
            {"account": "微信", "amountCents": cents(3000), "period": "month"},
            {"account": "微信", "amountCents": cents(600), "period": "month", "category": "餐饮"},
        ],
        "financeProjects": [{"name": "日本旅行", "icon": "✈️", "color": "#F97316",
                             "startDate": ts(D_JAPAN_START), "endDate": ts(D_JAPAN_END),
                             "budgetAmountCents": cents(12000), "status": "completed",
                             "note": "大阪 + 京都 6 天"}],
        "transactions": tx,
        "thoughts": gen_thoughts(),
        "tasks": gen_tasks(),
        "habits": gen_habits(),
        "habitRecords": [],
        "goals": gen_goals(),
    }
    run_recs, total_km = gen_habit_records()
    story["habitRecords"] = run_recs + gen_reading_records() + gen_earlybird_records()

    # ── 对账（软口径从明细统计，硬口径已由构造+断言保证）──
    coffee = [t for t in tx if t.get("category") == "咖啡" and t["type"] == "expense"]
    coffee_cents = sum(t["amountCents"] for t in coffee)
    # 退款无 type 字段，按负支出冲减；分期不计全额
    daily_expense_cents = sum(
        (-t["amountCents"] if "refundOf" in t else t["amountCents"])
        for t in tx
        if "installment" not in t and ("refundOf" in t or t.get("type") == "expense"))
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
        "annualExpense": daily_expense_cents / 100,
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
    chk(len(story["thoughts"]) == 210, f"想法 {len(story['thoughts'])} ≠ 210")
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
