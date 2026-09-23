#!/usr/bin/env python3
# 补齐「一起想清楚」词条三语（2026-09-19 修复走查问题产出的一批新文案 + 功能本体此前缺失词条）
# 插入策略：整块插到锚点「返回重新选路径」前，格式逐字节仿 Xcode（" : " 分隔、2 空格缩进）。
# 目录按拼音序由 Xcode 维护，脚本不模拟排序；JSON 对象序对构建无影响，Xcode 下次编辑会自动重排。
import json, re, sys

PATH = "Localizable.xcstrings"
ANCHOR = '    "返回重新选路径" : {'

# key -> (en, zh-Hant)
ENTRIES = {
    # 流程容器
    "一起想清楚": ("Think It Through Together", "一起想清楚"),
    "下面是针对这个目标的调整建议，不会改动你的原目标": ("Suggestions for this goal below — your original goal won't be changed.", "下面是針對這個目標的調整建議，不會改動你的原目標"),
    "正在连接…": ("Connecting…", "正在連接…"),
    "看看有哪些路径": ("Show Me the Paths", "看看有哪些路徑"),
    "正在想…": ("Thinking…", "正在想…"),
    "想清楚的事：%@": ("The goal: %@", "想清楚的事：%@"),
    "已选「%@」": ("Selected: %@", "已選「%@」"),
    "按这条路径出草案": ("Draft It with This Path", "按這條路徑出草案"),
    "正在按这条路径出草案，通常需要半分钟，写好会自动出现": ("Drafting with this path — usually takes about half a minute. It will appear here automatically.", "正在按這條路徑起草，通常需要半分鐘，寫好會自動出現"),
    "去确认这份草案": ("Review This Draft", "去確認這份草案"),
    "返回换条路径": ("Back to Pick a Different Path", "返回換條路徑"),
    "目标已保存": ("Goal Saved", "目標已保存"),
    "完成": ("Done", "完成"),
    "会话已结束": ("This session has ended", "這場共創已結束"),
    "已确认的事": ("Confirmed Details", "已確認的事"),
    "纠正": ("Correct", "糾正"),
    "纠正这条": ("Correct This", "糾正這條"),
    "原来的说法": ("What You Said Before", "原來的說法"),
    "更准确的说法是…": ("A more accurate version…", "更準確的說法是…"),
    "提交": ("Submit", "提交"),
    "你说": ("You said", "你說"),
    "记录": ("From records", "記錄"),
    "推测": ("Inferred", "推測"),
    "未知": ("Unclear", "未知"),
    "这会儿服务太忙，进度已保存，稍等几分钟再继续。": ("The service is busy right now. Your progress is saved — try again in a few minutes.", "這會兒服務太忙，進度已保存，稍等幾分鐘再繼續。"),
    "这场会话已失效，重新开始一场就好。": ("This session is no longer available. Just start a new one.", "這場會話已失效，重新開始一場就好。"),
    "上一条还在处理，稍等一下。": ("Still working on the last one — hang on a moment.", "上一條還在處理，稍等一下。"),
    "Holo 这次没把结果想明白，你的进度都在。再试一次通常就好。": ("Holo couldn't make sense of the result this time. Your progress is intact — trying again usually works.", "Holo 這次沒把結果想明白，你的進度都在。再試一次通常就好。"),
    "这场共创的思考次数用完了（保险丝保护，正常走完用不完）。点下面重新开始一场。": ("This session used up its thinking budget (a safety fuse — a normal run won't hit it). Tap below to start fresh.", "這場共創的思考次數用完了（保險絲保護，正常走完用不完）。點下面重新開始一場。"),
    "网络开小差了，进度已保存，稍后再试。": ("Network hiccup. Your progress is saved — try again later.", "網路出了點狀況，進度已保存，稍後再試。"),
    "放弃这场，重新开始": ("Discard and Start Over", "放棄這場，重新開始"),
    # 四步进度条
    "聊清楚": ("Clarify", "聊清楚"),
    "选路径": ("Paths", "選路徑"),
    "定草案": ("Draft", "定草案"),
    "去确认": ("Confirm", "去確認"),
    # 问题卡
    "你刚说：「%@」": ("You said: “%@”", "你剛說：「%@」"),
    "Holo 正在想…": ("Holo is thinking…", "Holo 正在想…"),
    "说说你的情况…": ("Tell me about your situation…", "說說你的情況…"),
    "先跳过这个问题": ("Skip This Question", "先跳過這個問題"),
    # 路径卡
    "有%@走得通的路，代价各不相同：": ("%@ that could work, each with different trade-offs:", "有%@走得通的路，代價各不相同："),
    "选这条": ("Pick This", "選這條"),
    "听你的，按「%@」来": ("Sounds good — go with “%@”", "聽你的，按「%@」來"),
    "适合": ("Fits", "適合"),
    "投入": ("Effort", "投入"),
    "代价": ("Trade-off", "代價"),
    # 定义/草案卡
    "以下是调整建议，尚未修改原目标": ("Suggestions below — your original goal is untouched", "以下是調整建議，尚未修改原目標"),
    "期望结果": ("Desired Outcome", "期望結果"),
    "期限": ("Deadline", "期限"),
    "成功标准": ("Success Looks Like", "成功標準"),
    "所选路径": ("Chosen Path", "所選路徑"),
    "关键假设（未确认信息，可改）": ("Key Assumptions (unverified — editable)", "關鍵假設（未確認資訊，可改）"),
    "里程碑": ("Milestones", "里程碑"),
    "第一步：%@": ("First step: %@", "第一步：%@"),
    # 恢复卡
    "有一个想到一半的目标": ("A goal you were thinking through", "有一個想到一半的目標"),
    "（未命名的心愿）": ("(An unnamed wish)", "（未命名的心願）"),
    "换个新的想法": ("Start a New Idea Instead", "換個新的想法"),
    "正在想清楚": ("Clarifying", "正在想清楚"),
    "在比较路径": ("Comparing paths", "在比較路徑"),
    "已选路径，待出草案": ("Path picked — draft pending", "已選路徑，待出草案"),
    "草案待确认": ("Draft awaiting review", "草案待確認"),
    "已保存": ("Saved", "已保存"),
    "已放弃": ("Discarded", "已放棄"),
    # 目标页入口
    "和 Holo 一起想清楚第一个目标": ("Think Through Your First Goal with Holo", "和 Holo 一起想清楚第一個目標"),
    "或让 HoloAI 直接规划": ("Or let HoloAI plan it directly", "或讓 HoloAI 直接規劃"),
    "一起想清楚怎么调整": ("Think Through How to Adjust", "一起想清楚怎麼調整"),
    "还没有目标": ("No goals yet", "還沒有目標"),
    "把模糊的想法变成能走的目标": ("Turn a vague idea into a goal you can walk", "把模糊的想法變成能走的目標"),
    "新建目标": ("New Goal", "新建目標"),
}

with open(PATH, encoding="utf-8") as f:
    data = json.load(f)
existing = data["strings"]

def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')

def entry_block(key: str, en: str, hant: str) -> str:
    return (
        f'    "{esc(key)}" : {{\n'
        f'      "localizations" : {{\n'
        f'        "en" : {{\n'
        f'          "stringUnit" : {{\n'
        f'            "state" : "translated",\n'
        f'            "value" : "{esc(en)}"\n'
        f'          }}\n'
        f'        }},\n'
        f'        "zh-Hant" : {{\n'
        f'          "stringUnit" : {{\n'
        f'            "state" : "translated",\n'
        f'            "value" : "{esc(hant)}"\n'
        f'          }}\n'
        f'        }}\n'
        f'      }}\n'
        f'    }},\n'
    )

with open(PATH, encoding="utf-8") as f:
    lines = f.readlines()

anchor_idx = next(i for i, line in enumerate(lines) if line.rstrip("\n") == ANCHOR)

added, skipped = [], []
blocks = []
for key, (en, hant) in ENTRIES.items():
    if key in existing:
        skipped.append(key)
        continue
    blocks.append(entry_block(key, en, hant))
    added.append(key)

lines[anchor_idx:anchor_idx] = blocks

with open(PATH, "w", encoding="utf-8") as f:
    f.writelines(lines)

# 校验：写回后必须仍是合法 JSON 且新键全部可读出
with open(PATH, encoding="utf-8") as f:
    check = json.load(f)
missing = [k for k in added if k not in check["strings"]]
print(f"added={len(added)} skipped_existing={len(skipped)} missing_after_write={len(missing)}")
if missing:
    print("MISSING:", missing)
    sys.exit(1)
