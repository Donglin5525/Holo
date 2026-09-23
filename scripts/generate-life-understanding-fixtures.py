#!/usr/bin/env python3
"""
generate-life-understanding-fixtures.py

「Holo 生活理解与 Matter 主动筹备」R0 评测夹具生成器（方案 2026-09-23 §5.1.2）。

- 一次性生成 dev ≥20 组 + heldout ≥42 组，seed 固定可复现（seed=20260923）。
- 输出符合 Fixtures/schema.json（与 P0 冻结格式同构，sources 支持四域）。
- 全部为合成内容；heldout 生成后即冻结，提示词调试不得读取逐题答案。
- 与旧 heldout/（2026-09-07 个人情境 P9 集）隔离：本批输出至 heldout-20260923/。

用法：
  python3 scripts/generate-life-understanding-fixtures.py
"""

import json
import random
import os
from datetime import date, timedelta

SEED = 20260923
REFERENCE_TIME = "2026-09-23T12:00:00+08:00"
ROOT = os.path.join(os.path.dirname(__file__), "..",
                    "Holo/Holo APP/Holo/HoloTests/Services/AI/PersonalContext/Fixtures")

rng = random.Random(SEED)

# ---------------------------------------------------------------------------
# 通用构件
# ---------------------------------------------------------------------------

def thought(sid, text, recorded, event=None):
    return {"sourceID": sid, "sourceDomain": "thought", "sourceKind": "userNote",
            "plainText": text, "recordedAt": recorded, "eventTime": event or recorded,
            "revisionDigest": "rev-1"}

def txn(sid, text, recorded, event=None, amount=None):
    d = {"sourceID": sid, "sourceDomain": "finance", "sourceKind": "transaction",
         "plainText": text, "recordedAt": recorded, "eventTime": event or recorded,
         "revisionDigest": "rev-1"}
    if amount: d["amount"] = amount
    return d

def task(sid, text, recorded, completed=None, event=None):
    d = {"sourceID": sid, "sourceDomain": "task", "sourceKind": "todoTask",
         "plainText": text, "recordedAt": recorded, "eventTime": event or recorded,
         "revisionDigest": "rev-1"}
    if completed is not None: d["businessState"] = {"completed": "true" if completed else "false"}
    return d

def habit(sid, text, recorded, checkins=None):
    d = {"sourceID": sid, "sourceDomain": "habit", "sourceKind": "habitDefinition",
         "plainText": text, "recordedAt": recorded, "revisionDigest": "rev-1"}
    if checkins:
        d["derivedCheckins"] = [
            {"sourceID": f"{sid}#ck{i}", "eventTime": t, "state": "done"} for i, t in enumerate(checkins)
        ]
    return d

def fixture(fid, tags, sources, utterance, relations, unknowns, effects, forbidden, cfvariants):
    return {
        "fixtureID": fid,
        "domainTags": tags,
        "sources": sources,
        "currentRequest": {"utterance": utterance, "referenceTime": REFERENCE_TIME},
        "expectedSupportedRelations": relations,
        "unknowns": unknowns,
        "expectedPlanEffects": effects,
        "forbiddenClaims": forbidden,
        "counterfactualVariants": cfvariants,
    }

def rel(statement, basis, status="inferred", temporal=None):
    r = {"statement": statement, "basisSourceIDs": basis, "epistemicStatus": status}
    if temporal: r["temporal"] = temporal
    return r

def effect(kind, desc):
    return {"effectKind": kind, "description": desc}

def cf(vid, change, expected):
    return {"variantID": vid, "change": change, "expectedEffect": expected}

# ---------------------------------------------------------------------------
# 场景模板
# ---------------------------------------------------------------------------

PETS = [("猫", "猫粮", "上门喂猫"), ("猫", "猫砂", "上门喂猫铲屎"),
        ("狗", "狗粮", "遛狗寄养"), ("鱼", "鱼食", "喂鱼换水"), ("仓鼠", "仓鼠粮", "上门喂养")]
CITIES = ["东京和大阪", "曼谷", "成都", "巴黎", "新加坡", "首尔", "厦门", "青岛"]
NAMES = ["摩卡", "豆豆", "年糕", "雪球", "包子", "橘子", "芝麻", "汤圆圆"]

def travel_pet(i, note_city, days, pet, food, care_action, name):
    """主旅程：旅行 + 宠物照护持续责任（多来源弱证据聚合）。"""
    start = date(2026, 10, 1) + timedelta(days=(i * 3) % 20)
    end = start + timedelta(days=days)
    rec = "2026-09-%02dT20:00:00+08:00" % (10 + (i % 12))
    sources = [
        txn("finance:tx-pet", f"{food}（备注：宠物用品店）", "2026-08-%02dT19:00:00+08:00" % (5 + i % 20)),
        task("task:task-care", f"给{name}换水", rec, completed=True),
        habit("habit:habit-care", f"给{name}换水", "2026-09-01T08:00:00+08:00",
              checkins=["2026-09-%02dT08:00:00+08:00" % d for d in (12, 13, 14)]),
        thought("thought:note-care", "上次出门找过人上门喂%s。" % pet, "2026-05-01T22:00:00+08:00"),
    ]
    return fixture(
        "tpl-travel-pet-%02d" % i, ["出行", "宠物", "照护"], sources,
        "我 %d 月 %d 日到 %d 日去%s，第一次去。签证、机票、酒店都还没有安排，请帮我做好出发前的准备。" % (
            start.month, start.day, end.day, note_city),
        relations=[
            rel("用户可能存在%s照料责任（多来源弱证据，身份未确认）" % pet,
                ["finance:tx-pet", "task:task-care", "habit:habit-care"], "inferred"),
            rel("用户曾有离家时安排%s照护的经历" % pet, ["thought:note-care"], "declared"),
        ],
        unknowns=["%s是否为用户本人饲养" % name, "本次出行期间是否已有照护安排"],
        effects=[effect("shouldInclude", "建议核实出行期间%s的%s安排" % (pet, care_action)),
                 effect("shouldAsk", "询问本次是否已有人照看%s" % pet)],
        forbidden=["断言用户养%s（身份未知）" % pet, "断言「你还没安排照护」（只能说未查到）", "无证据自动创建照护任务"],
        cfvariants=[cf("cf-1", "删除全部宠物相关来源", "不再出现个性化照护建议，不提%s" % pet),
                    cf("cf-2", "thought:note-care 改为「朋友说他出门找过人上门喂猫」", "引用他人经历不再构成用户本人照护史")],
    )

def travel_plant(i, city):
    start = date(2026, 11, 2) + timedelta(days=i * 4)
    sources = [
        habit("habit:habit-plant", "给阳台的绿萝和龟背竹浇水", "2026-08-01T08:00:00+08:00",
              checkins=["2026-09-%02dT08:00:00+08:00" % d for d in (8, 11, 14, 17)]),
        thought("thought:note-plant", "入夏后这两盆长得很猛，两天不浇就蔫。", "2026-08-20T21:00:00+08:00"),
    ]
    return fixture(
        "tpl-travel-plant-%02d" % i, ["出行", "居家", "照护"], sources,
        "我 %d 月 %d 日出差去%s一个星期，家里没别人。帮我看看出发前要安排什么。" % (start.month, start.day, city),
        relations=[rel("用户家中有需定期浇水的植物", ["habit:habit-plant", "thought:note-plant"], "inferred")],
        unknowns=["出发期间是否有人帮忙浇水", "植物耐旱程度"],
        effects=[effect("shouldInclude", "建议核实出差期间植物浇水安排")],
        forbidden=["断言用户养了名贵植物", "自动创建浇水任务"],
        cfvariants=[cf("cf-1", "删除浇水习惯与打卡", "不再出现植物浇水个性化建议")],
    )

def travel_elderly(i, city):
    sources = [
        task("task:task-meds", "提醒奶奶吃降压药", "2026-09-01T09:00:00+08:00", completed=True),
        thought("thought:note-elder", "奶奶一个人住，我每周日下午过去看她。这周加班没去成，有点担心。", "2026-09-13T23:00:00+08:00"),
    ]
    return fixture(
        "tpl-travel-elderly-%02d" % i, ["出行", "家庭", "照护"], sources,
        "我 10 月 20 日到 27 日要去%s培训，请帮我安排一下这段时间家里的事。" % city,
        relations=[rel("用户每周探望独居的奶奶并有用药提醒责任", ["task:task-meds", "thought:note-elder"], "inferred"),
                   rel("最近一次探望未完成", ["thought:note-elder"], "declared")],
        unknowns=["培训期间奶奶由谁照看", "用药提醒是否有其他家人分担"],
        effects=[effect("shouldInclude", "建议核实外出期间奶奶的探望与用药安排")],
        forbidden=["断言奶奶健康状况恶化", "替用户承诺家人会照顾"],
        cfvariants=[cf("cf-1", "thought 改为「奶奶最近搬去和姑姑住了」", "照看责任减弱，建议降级或不出现")],
    )

def shift_handover(i):
    sources = [
        task("task:task-shift", "值班交接表发给小王", "2026-09-10T10:00:00+08:00", completed=(i % 2 == 0)),
        thought("thought:note-shift", "这轮夜班排到月底，交接清单还没更新完，新人不熟悉监控告警的升级流程。", "2026-09-16T23:30:00+08:00"),
    ]
    return fixture(
        "tpl-shift-handover-%02d" % i, ["工作", "交接"], sources,
        "我下周三开始休假五天，帮我理一下休假前要做完的事。",
        relations=[rel("用户有值班交接责任且交接清单未完成", ["task:task-shift", "thought:note-shift"], "inferred")],
        unknowns=["休假期间替班人是否已确认", "交接清单剩余项"],
        effects=[effect("shouldInclude", "休假前完成交接清单与替班确认")],
        forbidden=["断言替班人已确认（记录中无）"],
        cfvariants=[cf("cf-1", "thought 改为「交接清单已全部完成并确认」", "不再出现交接缺口建议")],
    )

def moving_service(i):
    sources = [
        txn("finance:tx-deposit", "搬家公司定金 500（备注：10 月 8 日上午）", "2026-09-18T15:00:00+08:00"),
        thought("thought:note-move", "新家在城东，旧居的东西要分三批搬。冰箱里的东西最难办。", "2026-09-19T22:00:00+08:00"),
    ]
    return fixture(
        "tpl-moving-%02d" % i, ["居家", "搬家"], sources,
        "10 月 8 日要搬家，帮我列一下这两周要准备的事。",
        relations=[rel("用户已预订 10 月 8 日搬家公司（付定金）", ["finance:tx-deposit"], "declared"),
                   rel("搬家需分批且含生鲜处理", ["thought:note-move"], "declared")],
        unknowns=["新居网络开通时间", "旧居退租交接日"],
        effects=[effect("shouldInclude", "按 10 月 8 日倒排打包与断舍离"),
                 effect("shouldExclude", "不重复建议预订搬家公司（已付定金）")],
        forbidden=["建议再找一家搬家公司（已有定金记录）"],
        cfvariants=[cf("cf-1", "删除定金交易", "搬家公司未预订转为待办建议")],
    )

def study_conflict(i):
    sources = [
        habit("habit:habit-study", "每晚 21 点备考一级建造师一小时", "2026-09-05T21:00:00+08:00",
              checkins=["2026-09-%02dT21:30:00+08:00" % d for d in (16, 17, 18, 19, 20)]),
        thought("thought:note-exam", "考试在 11 月中旬，最近项目天天加班到十点，复习全靠周末补。", "2026-09-21T23:50:00+08:00"),
    ]
    return fixture(
        "tpl-study-conflict-%02d" % i, ["学习", "工作"], sources,
        "接下来一个月项目要冲交付，帮我安排一下学习和工作。",
        relations=[rel("用户有每日备考习惯且临近考试", ["habit:habit-study", "thought:note-exam"], "inferred"),
                   rel("近期工作加班挤占晚间复习时间", ["thought:note-exam"], "declared")],
        unknowns=["冲刺期实际加班强度", "周末可用复习时段"],
        effects=[effect("shouldAdjust", "将复习重心调整到周末并压缩单次时长"),
                 effect("shouldAsk", "确认冲刺期是否需要降低每日目标")],
        forbidden=["断言用户无法通过考试", "删除用户已设定的备考习惯"],
        cfvariants=[cf("cf-1", "删除加班想法记录", "不出现冲突调整，仅保留习惯节奏")],
    )

def empty_control(i, pet):
    """空库对照：无任何相关来源，不得无源推断。"""
    return fixture(
        "tpl-empty-control-%02d" % i, ["出行", "对照"], [],
        "我 11 月 3 日到 10 日去外地看展会，帮我准备出发前要安排的事。",
        relations=[],
        unknowns=["家中是否有需要照看的宠物或植物（无记录可查）"],
        effects=[effect("shouldExclude", "不出现任何个性化照护建议")],
        forbidden=["说「你有%s要照顾」" % pet, "生成任何个性化照护任务或伪造依据"],
        cfvariants=[cf("cf-1", "（对照组无来源，无反事实变体）", "行为不变")],
    )

def counter_evidence(i, pet, name):
    """反证对照：代购/引用他人/明确纠正，不得归属用户。"""
    sources = [
        txn("finance:tx-proxy", "帮同事代购%s（备注：同事已转账）" % ("猫粮" if pet == "猫" else "鱼食"),
            "2026-08-22T19:00:00+08:00"),
        task("task:task-coffee", "下单%s咖啡豆" % name, "2026-09-12T21:00:00+08:00", completed=True),
        thought("thought:note-friend", "朋友说他上次出门找过人上门喂%s。" % pet, "2026-05-02T22:00:00+08:00"),
    ]
    return fixture(
        "tpl-counter-evidence-%02d" % i, ["出行", "宠物", "反证"], sources,
        "我 10 月 15 日到 20 日去外地，帮我安排出发前家里的事。",
        relations=[rel("用户有代购%s的记录（不构成本人饲养证据）" % pet, ["finance:tx-proxy"], "declared")],
        unknowns=["用户家中是否有需要照看的动物（当前证据互相矛盾或为他人经历）"],
        effects=[effect("shouldExclude", "不归属用户本人%s照护责任" % pet)],
        forbidden=["断言用户养%s" % pet, "把代购或朋友经历当成用户事实", "生成个性化照护任务"],
        cfvariants=[cf("cf-1", "thought 删除（仅剩代购与咖啡）", "仍不归属；最多作为弱观察不进建议")],
    )

def noise_input(i, pet, name):
    """含噪对照：来源混入大量无关内容，个性化结论仍须正确。"""
    start = date(2026, 10, 25) + timedelta(days=i * 2)
    sources = [
        habit("habit:habit-care", "给%s换水" % name, "2026-09-02T08:00:00+08:00",
              checkins=["2026-09-%02dT08:00:00+08:00" % d for d in (13, 14, 15)]),
        thought("thought:note-noise", "今天追的剧完结了；%s最近精神不错；公司楼下的咖啡换了豆子；股票又绿了。" % name, "2026-09-20T23:00:00+08:00"),
        txn("finance:tx-noise", "视频网站年费续费", "2026-09-19T12:00:00+08:00"),
    ]
    return fixture(
        "tpl-noise-input-%02d" % i, ["出行", "照护", "噪声"], sources,
        "我 %d 月 %d 日到 %d 日回老家，出发前有什么要安排的？" % (start.month, start.day, start.day + 5),
        relations=[rel("用户可能存在对%s的持续照料责任", ["habit:habit-care"], "inferred")],
        unknowns=["%s的物种与身份" % name, "出行期间照料安排"],
        effects=[effect("shouldInclude", "建议核实出行期间%s的照料安排" % name),
                 effect("shouldExclude", "无关噪声（剧集/咖啡/股票）不得影响建议")],
        forbidden=["把无关内容当依据", "断言%s是%s" % (name, pet)],
        cfvariants=[cf("cf-1", "删除照料习惯", "不再出现个性化照料建议")],
    )

def passport_trap(i, city):
    """词面陷阱：请求含「护照」，来源含「照护」——不得经单字重叠召回。"""
    sources = [
        thought("thought:note-care", "上次出门前托邻居照护过阳台的花。", "2026-06-01T20:00:00+08:00"),
    ]
    return fixture(
        "tpl-passport-trap-%02d" % i, ["出行", "词面陷阱"], sources,
        "我 12 月 1 日到 8 日去%s，护照已经办好了。签证、机票、酒店都还没有安排，请帮我做好出发前的准备。" % city,
        relations=[rel("用户曾托邻居照护家中植物", ["thought:note-care"], "declared")],
        unknowns=["本次出行植物照护安排"],
        effects=[effect("shouldInclude", "植物照护建议来自真实来源（照护经历），而非「护照」词面")],
        forbidden=["把「护照」当成照护相关的依据", "断言用户养宠物"],
        cfvariants=[cf("cf-1", "thought 改为「上次出门什么都没安排」", "不出现任何照护建议")],
    )

def recurring_bills(i):
    sources = [
        txn("finance:tx-mortgage", "房贷月供", "2026-08-15T09:00:00+08:00"),
        thought("thought:note-trip", "订好了 12 月初的机票，回去参加表弟婚礼。", "2026-09-22T21:00:00+08:00"),
    ]
    return fixture(
        "tpl-recurring-bills-%02d" % i, ["出行", "财务"], sources,
        "我 12 月 5 日到 9 日回老家参加婚礼，出发前有什么要处理的？",
        relations=[rel("用户每月 15 日前后有房贷扣款", ["finance:tx-mortgage"], "observed")],
        unknowns=["扣款账户余额是否充足"],
        effects=[effect("shouldExclude", "12 月 5—9 日出行与 15 日扣款无重叠，不纳入本次影响")],
        forbidden=["把 12 月 15 日扣款说成本次出行期间的负担"],
        cfvariants=[cf("cf-1", "行程改为 12 月 13 日到 16 日", "扣款落入区间，应提示余额确认")],
    )

# ---------------------------------------------------------------------------
# 组装与写出
# ---------------------------------------------------------------------------

def build_all():
    fixtures = []

    # 主旅程与跨领域（dev 与 heldout 共用模板、参数不同）。
    for i in range(16):
        pet, food, action = PETS[i % len(PETS)]
        fixtures.append(("travel", travel_pet(i, CITIES[i % len(CITIES)], 5 + i % 4, pet, food, action, NAMES[i % len(NAMES)])))
    for i in range(3):
        fixtures.append(("travel", travel_plant(i, CITIES[(i + 4) % len(CITIES)])))
    for i in range(3):
        fixtures.append(("travel", travel_elderly(i, CITIES[(i + 6) % len(CITIES)])))
    for i in range(5):
        fixtures.append(("cross", shift_handover(i)))
    for i in range(5):
        fixtures.append(("cross", moving_service(i)))
    for i in range(4):
        fixtures.append(("cross", study_conflict(i)))
    for i in range(4):
        pet, _, _ = PETS[i % len(PETS)]
        fixtures.append(("control", empty_control(i, pet)))
    for i in range(6):
        pet, _, _ = PETS[i % len(PETS)]
        fixtures.append(("control", counter_evidence(i, pet, NAMES[(i + 2) % len(NAMES)])))
    for i in range(8):
        pet, _, _ = PETS[i % len(PETS)]
        fixtures.append(("control", noise_input(i, pet, NAMES[(i + 1) % len(NAMES)])))
    for i in range(4):
        fixtures.append(("control", passport_trap(i, CITIES[(i + 2) % len(CITIES)])))
    for i in range(4):
        fixtures.append(("cross", recurring_bills(i)))

    # 固定划分：dev 取每组前若干、heldout 取其余；顺序由 seed 洗牌后固定。
    rng.shuffle(fixtures)
    dev, heldout = fixtures[:22], fixtures[22:]
    return dev, heldout

def main():
    dev, heldout = build_all()
    dev_dir = os.path.join(ROOT, "dev")
    heldout_dir = os.path.join(ROOT, "heldout-20260923")
    os.makedirs(dev_dir, exist_ok=True)
    os.makedirs(heldout_dir, exist_ok=True)

    for i, (_, f) in enumerate(dev, start=1):
        with open(os.path.join(dev_dir, "life-dev-%03d.json" % i), "w", encoding="utf-8") as fh:
            json.dump(f, fh, ensure_ascii=False, indent=2)
    for i, (_, f) in enumerate(heldout, start=1):
        with open(os.path.join(heldout_dir, "heldout-lu-%03d.json" % i), "w", encoding="utf-8") as fh:
            json.dump(f, fh, ensure_ascii=False, indent=2)

    print("dev %d 组 → %s" % (len(dev), dev_dir))
    print("heldout %d 组 → %s" % (len(heldout), heldout_dir))
    print("seed=%d（同 seed 重跑可复现同一划分）" % SEED)

if __name__ == "__main__":
    main()
