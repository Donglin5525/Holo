"""记忆萃取降本 · 成本模型 v2（2026-11-10 第二轮审查后重写）

口径：qwen3.7-flash 牌价，输入 ¥0.2 / 缓存命中 ¥0.04 / 输出 ¥0.8（每百万 token）。
所有「现状」= 按代码设计频率推算（不含并发双跑等重复付费，那部分用实测单列，见 [表0]）。
所有「改造后」只计入「确定做」的改动；需评测才决定的（关联候选 12→8、一个发现不思考）单列为「可选」。

实测锚点（生产库 ai_call_logs，东林真机 F50B4915，北京时间 11-01~11-09）：
  萃取 X  343 次 输入 4828 / 输出 1370 / 缓存 18%
  核验 V  264 次 输入 6071 / 输出 163 / 缓存 4%
  关联单价 重度 ¥0.00162（东林 207 次）/ 轻度 ¥0.00059（真实用户 BCA59F42 234 次）
  领域萃取单价 ¥0.00138（东林 90 次）；一个发现单价 ¥0.0065（东林 13 次）
双源对账：同窗口生产预算账本实扣 ÷ 本口径按牌价折算 = 1.000（证据/prod_r2_checks.js ④）
"""
import math

P_IN, P_CACHE, P_OUT = 0.2, 0.04, 0.8


def price(tok_in, tok_out, cache):
    return (tok_in * ((1 - cache) * P_IN + cache * P_CACHE) + tok_out * P_OUT) / 1e6


# ---------- 单价与 token 拆解 ----------
X_UNIT = price(4828, 1370, 0.18)          # 现状萃取一次（满包 12 条来源）
V_UNIT = price(6071, 163, 0.04)           # 现状核验一次（整页 50 条原文重传）
V_PER_X = 264 / 343                       # 每次萃取跟一次核验的比例（实测）
PKG_NOW = X_UNIT + V_PER_X * V_UNIT       # 现状补历史每包

SYS_X = 1450        # 萃取系统提示词（2093 字符）
EXISTING = 2050     # 既有记忆清单（实测反推：4828 − 1450 − 12×110 ≈ 2058）
SRC_NOW = 110       # 每条来源进提示词 token（含 UUID/修订号/时间/业务态）
SRC_SHORT = 60      # B3 短编号 + 修订号由客户端回填后
OUT_CAND_NOW, OUT_CAND_SHORT = 350, 260   # 每个候选的输出 token（B3 后不回显修订号）
YIELD = 0.3         # 每条来源平均产出候选数（补历史实测：12 条/包 ≈ 3.6 个候选）
SYS_V = 300
RELATE_H, RELATE_L = 0.00162, 0.00059
DOMAIN_UNIT, DISC_UNIT = 0.00138, 0.0065
PKG_SIZE_AFTER = 24  # 改造后每包来源上限（不用 40：输出会顶到上限被截断，见审查记录 R2）


def x_cost(k, src_tok, out_cand, yield_=None):
    c = (YIELD if yield_ is None else yield_) * k
    return price(SYS_X + EXISTING + src_tok * k, 100 + out_cand * c, 0.18), c


def v_cost(c, n_src_in_prompt, src_tok):
    return price(SYS_V + 150 * c + src_tok * n_src_in_prompt, 60 + 30 * c, 0.04)


def pkg_after(k, yield_=None):
    """改造后一包：短编号 + 核验只带本包被引用的来源（B1）。"""
    xc, c = x_cost(k, SRC_SHORT, OUT_CAND_SHORT, yield_)
    return xc + v_cost(c, min(k, 2.7 * c), SRC_SHORT)


# ---------- 用户档案 ----------
# 每天新增（全部来源）与其中「有信息量」的部分（信息密度闸门：账单备注≥5字 23%、打卡有备注 0.07%、
# 聊天去掉≤4字 90%、想法/任务全过——比例取东林 Mac 同步库实测）
HEAVY = dict(new=dict(finance=5, habit=6, thought=2, task=2, chat=5),
             rich=dict(finance=1.15, habit=0.0, thought=2, task=2, chat=4.5),
             opens=12, thoughts=210, relate_unit=RELATE_H, relate_fail=0.30, relate_events=1,
             domain_day=10, disc_month=0.28, topic_month=0.04,
             hist=dict(thought=210, finance=776, task=188, habit=1434, chat=691),        # = 东林真实库
             rich_hist=dict(thought=210, finance=180, task=188, habit=10, chat=619))
LIGHT = dict(new=dict(finance=1, habit=0.5, thought=0.3, task=0.2, chat=0.5),
             rich=dict(finance=0.25, habit=0.0, thought=0.3, task=0.2, chat=0.45),
             opens=2, thoughts=55, relate_unit=RELATE_L, relate_fail=0.15, relate_events=0.5,
             domain_day=1.5, disc_month=0.10, topic_month=0.01,
             hist={d: r * 180 for d, r in dict(finance=1, habit=0.5, thought=0.3, task=0.2, chat=0.5).items()},
             rich_hist={d: r * 180 for d, r in dict(finance=0.25, habit=0.0, thought=0.3, task=0.2, chat=0.45).items()})


def pc_daily_now(p):
    """现状：每次打开（间隔≥30分钟）一轮；上一轮后有新记录的域各开一包（小包）。"""
    total = pkgs = 0.0
    for r in p["new"].values():
        lam = r / p["opens"]
        pr = 1 - math.exp(-lam)
        k = lam / pr if pr else 0
        xc, c = x_cost(k, SRC_NOW, OUT_CAND_NOW)
        pv = 1 - math.exp(-c)                       # 有候选才核验
        vc = v_cost(c / pv if pv else 0, k, SRC_NOW)  # 稳态时页里只有这几条新记录
        total += p["opens"] * pr * (xc + pv * vc)
        pkgs += p["opens"] * pr
    return total * 30, pkgs


def pc_daily_after(p):
    """A3：每域攒够 15 条或最晚 24 小时开一包；只有「有信息量」的记录进模型。"""
    total = pkgs = 0.0
    for r in p["rich"].values():
        if r <= 0:
            continue
        n_pkg = r / 15 if r >= 15 else 1 - math.exp(-r)
        k = r / n_pkg
        xc, c = x_cost(k, SRC_SHORT, OUT_CAND_SHORT)
        pv = 1 - math.exp(-c)
        vc = v_cost(c / pv if pv else 0, min(k, 2.7 * c), SRC_SHORT)
        total += n_pkg * (xc + pv * vc)
        pkgs += n_pkg
    return total * 30, pkgs


def relate_month(p, after, b5=False, step1=False):
    n, new_t = p["thoughts"], p["new"]["thought"] * 30
    if step1:
        calls = (new_t + n * p["relate_events"]) / (1 - 0.1)                              # 第一步：去掉 14 天过期重算 + 重试封顶（目录变化仍全量）
        return calls * p["relate_unit"], calls
    if not after:
        calls = (new_t + n * 30 / 14 + n * p["relate_events"]) / (1 - p["relate_fail"])  # 新想法 + 14天过期全量 + 目录/说明变化全量，失败无上限重试
    else:
        calls = (new_t + min(n, 30) * p["relate_events"]) * 1.1                          # C6 只重评相关 30 条、不再过期重评；C1 重试封顶
    return calls * p["relate_unit"] * (0.73 if b5 else 1), calls


def steady(p, after, optional=False, step1=False):
    pc, pkgs = pc_daily_after(p) if (after and not step1) else pc_daily_now(p)
    rel, rel_calls = relate_month(p, after, b5=optional, step1=step1)
    dom = p["domain_day"] * 30 * DOMAIN_UNIT * (0.62 if (after or step1) else 1)   # C8：解析失败也计入每日上限+重试封顶（实测 38% 是同输入重复）
    disc = p["disc_month"] * (0.3 if optional else 1)                    # C3 一个发现不思考（需 A/B）
    return dict(total=pc + rel + dom + disc + p["topic_month"], pc=pc, pkgs=pkgs, rel=rel, rel_calls=rel_calls, dom=dom, disc=disc)


def backfill(p, after, yield_=None):
    rel = p["thoughts"] * p["relate_unit"]                 # 每条想法建一次主题关联（老用户补历史必有）
    if not after:
        n_pkg = sum(math.ceil(n / 12) for n in p["hist"].values())
        return dict(total=n_pkg * PKG_NOW + rel, pc=n_pkg * PKG_NOW, pkgs=n_pkg, rel=rel)
    n_pkg = sum(math.ceil(n / PKG_SIZE_AFTER) for n in p["rich_hist"].values() if n > 0)
    n_src = sum(p["rich_hist"].values())
    pc = n_src * pkg_after(PKG_SIZE_AFTER, yield_) / PKG_SIZE_AFTER
    return dict(total=pc + rel, pc=pc, pkgs=n_pkg, rel=rel)


def upgrade(p, after, months_hist=6):
    if not after:
        hist = p["hist"] if p is HEAVY else {d: r * 30 * months_hist for d, r in p["new"].items()}
        n_pkg = sum(math.ceil(n / 12) for n in hist.values())
        return n_pkg * PKG_NOW + p["thoughts"] * p["relate_unit"]
    n_src = sum(r * 90 for r in p["rich"].values())       # 确需回看时：近 90 天有信息量的记录
    return n_src * pkg_after(PKG_SIZE_AFTER) / PKG_SIZE_AFTER + min(p["thoughts"], 30) * p["relate_unit"]


if __name__ == "__main__":
    print("[校验1] 单价复现实测")
    print(f"  萃取 ¥{X_UNIT:.6f}（实测 0.001918） 核验 ¥{V_UNIT:.6f}（实测 0.001310） 现状每包 ¥{PKG_NOW:.5f}")
    print(f"  拆解自洽：{SYS_X} 提示词 + {EXISTING} 既有记忆 + 12×{SRC_NOW} 来源 = {SYS_X + EXISTING + 12 * SRC_NOW}（实测 4828）")
    print(f"  改造后每包({PKG_SIZE_AFTER}条) ¥{pkg_after(PKG_SIZE_AFTER):.5f} → 每条来源 ¥{pkg_after(PKG_SIZE_AFTER) / PKG_SIZE_AFTER:.6f}；现状每条 ¥{PKG_NOW / 12:.6f}"
          f"（−{100 * (1 - pkg_after(PKG_SIZE_AFTER) / PKG_SIZE_AFTER / (PKG_NOW / 12)):.0f}%）")
    xa, ca = x_cost(PKG_SIZE_AFTER, SRC_SHORT, OUT_CAND_SHORT)
    print(f"  改造后一包平均输出 ≈ {100 + OUT_CAND_SHORT * ca:.0f} token（候选 {ca:.1f} 个）；产出偏多(每条0.5个候选)时 ≈ {100 + OUT_CAND_SHORT * 0.5 * PKG_SIZE_AFTER:.0f} → 萃取输出上限需 4000→6000")
    print(f"  核验只带本包被引用来源(B1)：一次核验 ¥{V_UNIT:.5f} → ¥{v_cost(YIELD * 12, min(12, 2.7 * YIELD * 12), SRC_NOW):.5f}（12 条包、来源未缩短时）")

    print("\n[表1] 过日子（每月）  现状 → 改造后（确定做）→ 再加可选项")
    rows = {}
    for name, p in (("轻度", LIGHT), ("重度", HEAVY)):
        b, a, o = steady(p, False), steady(p, True), steady(p, True, optional=True)
        rows[name] = (b, a, o)
        print(f"  {name}: ¥{b['total']:.2f} → ¥{a['total']:.2f} → ¥{o['total']:.2f}")
        print(f"     现状拆分：档案 ¥{b['pc']:.2f}（{b['pkgs']:.1f}包/天）关联 ¥{b['rel']:.2f}（{b['rel_calls']:.0f}次/月）领域 ¥{b['dom']:.2f} 发现 ¥{b['disc']:.2f} 主题 ¥{p['topic_month']:.2f}")
        print(f"     改造后：  档案 ¥{a['pc']:.2f}（{a['pkgs']:.1f}包/天）关联 ¥{a['rel']:.2f}（{a['rel_calls']:.0f}次/月）领域 ¥{a['dom']:.2f} 发现 ¥{a['disc']:.2f} 主题 ¥{p['topic_month']:.2f}")

    print("\n[表1b] 只做第一步（只付一次钱 + 主题不再定期重算 + 领域萃取失败计数）")
    for name, p in (("轻度", LIGHT), ("重度", HEAVY)):
        s1 = steady(p, False, step1=True)
        print(f"  {name}: ¥{steady(p, False)['total']:.2f} → ¥{s1['total']:.2f}（关联 {s1['rel_calls']:.0f}次/月 ¥{s1['rel']:.2f}；另有并发双跑的实测浪费不在模型内）")

    print("\n[表2] 补历史（老用户一次性）")
    for name, p in (("轻度老用户(6个月)", LIGHT), ("重度老用户(=东林库)", HEAVY)):
        b, a = backfill(p, False), backfill(p, True)
        print(f"  {name}: ¥{b['total']:.2f}（档案 {b['pkgs']} 包 ¥{b['pc']:.2f} + 关联 ¥{b['rel']:.2f}）→ ¥{a['total']:.2f}（档案 {a['pkgs']} 包 ¥{a['pc']:.2f} + 关联 ¥{a['rel']:.2f}）")
    moze_now = math.ceil(12442 / 12) * PKG_NOW
    in_window = 12442 * 12 / 120
    lo = in_window * 0.25 * pkg_after(PKG_SIZE_AFTER) / PKG_SIZE_AFTER
    hi = in_window * 1.00 * pkg_after(PKG_SIZE_AFTER) / PKG_SIZE_AFTER
    print(f"  大批量导入 12,442 笔: ¥{moze_now:.2f}（{math.ceil(12442 / 12)} 包，导入时间=当天，全按新数据）"
          f" → ¥{lo:.2f}~{hi:.2f}（只读近 12 个月≈{in_window:.0f} 笔里有备注的 25%~100%；其余交给本地挖矿 ¥0）")

    print("\n[表3] 每升级一次")
    for name, p in (("轻度", LIGHT), ("重度", HEAVY)):
        print(f"  {name}: ¥{upgrade(p, False):.2f} → 默认 ¥0（确需回看近 90 天 ¥{upgrade(p, True):.3f}）")
    fleet_now = 0.4 * upgrade(LIGHT, False) + 0.4 * backfill(LIGHT, False)["total"] + 0.1 * upgrade(HEAVY, False) + 0.1 * backfill(HEAVY, False)["total"]
    fleet_rev = 0.8 * upgrade(LIGHT, True) + 0.2 * upgrade(HEAVY, True)
    print(f"  全员（轻80%/重20%）人均 ¥{fleet_now:.3f} → 1 万人 ¥{fleet_now * 1e4:,.0f}/次；改造后默认 ¥0，需回看 ¥{fleet_rev * 1e4:,.0f}/次")

    print("\n[表4] 占 Plus 到手（每月，重度用户过日子）")
    nets = [("月付·30%抽成", 12 * 0.7), ("月付·15%", 12 * 0.85), ("年付·30%", 128 * 0.7 / 12), ("早鸟·30%", 98 * 0.7 / 12)]
    b, a, o = rows["重度"]
    for label, net in nets:
        print(f"  {label} ¥{net:.2f}: {100 * b['total'] / net:.0f}% → {100 * a['total'] / net:.0f}% → {100 * o['total'] / net:.0f}%")

    print("\n[表5] 额度墙检查（改造后）")
    for name, p in (("轻度老用户", LIGHT), ("重度老用户", HEAVY)):
        s, bf = steady(p, True)["total"], backfill(p, True)["total"]
        print(f"  {name}: 第一个月 过日子 ¥{s:.2f} + 补历史 ¥{bf:.2f} = ¥{s + bf:.2f}（单设备月额度 ¥2）；补历史按每天 ≤¥0.12 匀速跑约 {math.ceil(bf / 0.12)} 天")
    for users in (1000, 10000):
        m = users * (0.8 * steady(LIGHT, True)["total"] + 0.2 * steady(HEAVY, True)["total"])
        d1 = users * (0.8 * backfill(LIGHT, True)["total"] + 0.2 * backfill(HEAVY, True)["total"])
        print(f"  {users} 人：每月全局 ≈ ¥{m:,.0f}（现全局月闸 ¥60）；放量首周补历史 ≈ ¥{d1:,.0f}（现全局日闸 ¥3）→ 放量前必须先调全局闸")

    print("\n[敏感度] 重度用户·改造后过日子（确定做）在不同假设下")
    base = steady(HEAVY, True)["total"]
    YIELD = 0.6
    v1 = steady(HEAVY, True)["total"]; bf1 = backfill(HEAVY, True)["total"]
    YIELD = 0.3
    v2 = steady(dict(HEAVY, rich={k: v * 2 for k, v in HEAVY["rich"].items()}), True)["total"]
    v3 = steady(dict(HEAVY, relate_events=3), True)["total"]
    v4 = base + HEAVY["domain_day"] * 30 * DOMAIN_UNIT * 0.38
    print(f"  基准 ¥{base:.2f}；候选产出翻倍(每条0.6个) ¥{v1:.2f}（补历史 ¥{backfill(HEAVY, True)['total']:.2f}→¥{bf1:.2f}）；有信息量的记录多一倍 ¥{v2:.2f}；目录变化每月3次 ¥{v3:.2f}；领域萃取没省下来 ¥{v4:.2f}")
    no_expiry_now = steady(HEAVY, False)["total"] - relate_month(HEAVY, False)[0] + (60 + 210) / 0.7 * RELATE_H
    print(f"  现状侧：若 14 天过期并不触发全量重算（只算新想法+目录变化），重度现状 ¥{no_expiry_now:.2f}（基准 ¥{steady(HEAVY, False)['total']:.2f}）")
