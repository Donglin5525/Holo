#!/usr/bin/env python3
"""目标共创修复批·外科手术暂存（2026-09-19 夜）
共享文件构造暂存版 = HEAD + 仅共创 hunks（不卷入并行会话在途）：
- pbxproj：difflib 块级放行（insert 块含共创行→整块放行；replace 块→HEAD 侧+共创行）
- HoloAICapability / ChatView / ChatViewModel：HEAD + 已知共创块手工锚点插入
- Localizable.xcstrings：HEAD + 本次 33 条三语词条
其余共创文件整文件 git add。"""
import difflib, json, re, subprocess, sys

REPO = "/Users/tangyuxuan/Desktop/Claude/HOLO"
P = "Holo/Holo APP/Holo/Holo"

def git(*args, input=None):
    return subprocess.run(["git", "-C", REPO, *args], input=input, capture_output=True, text=True, check=True).stdout

def head_lines(path):
    return git("show", f"HEAD:{path}").splitlines(keepends=True)

def read(path):
    with open(f"{REPO}/{path}", encoding="utf-8") as f:
        return f.readlines()

def stage_blob(text, path):
    proc = subprocess.run(["git", "-C", REPO, "hash-object", "-w", "--stdin"], input=text, capture_output=True, text=True, check=True)
    sha = proc.stdout.strip()
    subprocess.run(["git", "-C", REPO, "update-index", "--cacheinfo", f"100644,{sha},{path}"], check=True)
    print(f"  staged {path} -> {sha[:12]}")

fail = False

# ---------- 1. pbxproj ----------
path = f"{P}.xcodeproj/project.pbxproj"
hl, wl = head_lines(path), read(path)
rx = re.compile(r"GoalWorkshop|GoalPlanRevision|GoalWorkshopJourney")
out = []
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, hl, wl, autojunk=False).get_opcodes():
    if tag == "insert":
        blk = wl[j1:j2]
        if any(rx.search(l) for l in blk):
            out.extend(blk)
    else:
        # equal/replace/delete 都保留 HEAD 侧（delete=别人会话的搬动删改，不跟进）；
        # replace 额外放行工作区侧的共创行（自包含的 pbxproj 条目行）
        out.extend(hl[i1:i2])
        if tag == "replace":
            out.extend(l for l in wl[j1:j2] if rx.search(l))
constructed = "".join(out)
# 校验1：共创文件挂载数与工作区一致
bases = ["GoalWorkshopModels", "GoalWorkshopSessionMO", "GoalWorkshopStore", "CoreDataStack+GoalWorkshopEntities",
         "GoalPlanRevisionMO", "GoalPlanRevisionStore", "GoalWorkshopFlowView", "GoalWorkshopDefinitionCard",
         "GoalWorkshopOptionsCard", "GoalWorkshopQuestionCard", "GoalWorkshopResumeCard", "GoalWorkshopCoordinator",
         "GoalWorkshopCommitService", "GoalWorkshopPromptBuilder", "GoalWorkshopServiceFactory", "GoalWorkshopValidator",
         "GoalWorkshopCommitTests", "GoalWorkshopStoreTests", "GoalWorkshopJourneyUITests", "GoalWorkshopValidatorTests",
         "GoalWorkshopStateTests", "GoalWorkshopCoordinatorTests"]
for b in bases:
    if constructed.count(b) < wl.count(b):
        print(f"FAIL pbxproj 挂载缺失: {b} 构造{constructed.count(b)} < 工作区{wl.count(b)}"); fail = True
# 校验2：plist 合法性
with open("/tmp/staged_pbxproj", "w", encoding="utf-8") as f:
    f.write(constructed)
lint = subprocess.run(["plutil", "-lint", "/tmp/staged_pbxproj"], capture_output=True, text=True)
print("pbxproj lint:", lint.stdout.strip() or lint.stderr.strip())
if lint.returncode != 0: fail = True
if not fail:
    stage_blob(constructed, path)

# ---------- 2. HoloAICapability ----------
path = f"{P}/Models/AI/HoloAICapability.swift"
text = git("show", f"HEAD:{path}")
WS_BLOCK = (
    "    // MARK: - Goal Workshop（目标共创，2026-09-17 完整开发计划任务 5）\n"
    "\n"
    "    /// 目标共创「一起想清楚」总闸：本地默认关 + 服务端 goalWorkshopV1 控制。\n"
    "    /// 关闸时旧 AI 规划与手动创建行为不变，已保存 Goal 不受影响。\n"
    "    static var goalWorkshopEnabled: Bool {\n"
    "        #if DEBUG\n"
    "        if ProcessInfo.processInfo.arguments.contains(\"GOAL_WORKSHOP_FORCE_ON\") { return true }\n"
    "        #endif\n"
    "        return HoloServerFeatureFlags.value(\"goalWorkshopV1\", localDefault: false)\n"
    "    }\n"
    "\n"
)
anchor = (
    "    var memorySummaryInjectionEnabled: Bool {\n"
    "        get { memoryAssistedAnsweringEnabled }\n"
    "        set { memoryAssistedAnsweringEnabled = newValue }\n"
    "    }\n"
)
assert text.count(anchor) == 1, "HoloAICapability 锚点1不唯一"
text = text.replace(anchor, anchor + WS_BLOCK)
# 第二处：enum HoloAIFeatureFlags 里 isShadowEvaluation 之后
anchor2 = "        HoloMemoryOperationalControls.current().isShadowEvaluation\n"
assert text.count(anchor2) == 1, "HoloAICapability 锚点2不唯一"
idx = text.index(anchor2) + len(anchor2)
# 跳过紧随的空行（若有）后插入
rest = text[idx:]
if rest.startswith("\n"):
    idx += 1
text = text[:idx] + WS_BLOCK + text[idx:]
stage_blob(text, path)

# ---------- 3. ChatView ----------
path = f"{P}/Views/Chat/ChatView.swift"
text = git("show", f"HEAD:{path}")
SHEET = (
    "        .sheet(item: $viewModel.goalWorkshopLaunch) { launch in\n"
    "            GoalWorkshopFlowView(launch: launch)\n"
    "        }\n"
)
anchor = "        .sheet(isPresented: $showMemoryConfirmationQueue) {"
assert text.count(anchor) == 1, "ChatView 锚点不唯一"
text = text.replace(anchor, SHEET + anchor)
stage_blob(text, path)

# ---------- 4. ChatViewModel ----------
path = f"{P}/Views/Chat/ChatViewModel.swift"
text = git("show", f"HEAD:{path}")
PROP = (
    "\n"
    "    /// 目标共创（一起想清楚）流程入口：开闸时旧「规划目标」入口指向同一会话\n"
    "    @Published var goalWorkshopLaunch: GoalWorkshopLaunch?\n"
)
anchor = "    @Published var goalDraftForReview: GoalDraft?"
assert text.count(anchor) == 1, "ChatViewModel 锚点1不唯一"
text = text.replace(anchor, PROP + anchor)
REDIRECT = (
    "        // 目标共创开闸时，旧入口直接指向新流程（同一会话）；关闸走原有链路\n"
    "        if HoloAIFeatureFlags.goalWorkshopEnabled {\n"
    "            goalWorkshopLaunch = .new(seedText: seedText)\n"
    "            return\n"
    "        }\n"
)
anchor = "    func startGoalPlanning(seedText: String?) {\n"
assert text.count(anchor) == 1, "ChatViewModel 锚点2不唯一"
text = text.replace(anchor, anchor + REDIRECT)
stage_blob(text, path)

# ---------- 5. Localizable.xcstrings（HEAD + 本次 33 条） ----------
path = f"{P}/Localizable.xcstrings"
ENTRIES = {
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
    "聊清楚": ("Clarify", "聊清楚"),
    "选路径": ("Paths", "選路徑"),
    "定草案": ("Draft", "定草案"),
    "去确认": ("Confirm", "去確認"),
    "你刚说：「%@」": ("You said: “%@”", "你剛說：「%@」"),
    "Holo 正在想…": ("Holo is thinking…", "Holo 正在想…"),
    "说说你的情况…": ("Tell me about your situation…", "說說你的情況…"),
    "先跳过这个问题": ("Skip This Question", "先跳過這個問題"),
    "有%@走得通的路，代价各不相同：": ("%@ that could work, each with different trade-offs:", "有%@走得通的路，代價各不相同："),
    "选这条": ("Pick This", "選這條"),
    "听你的，按「%@」来": ("Sounds good — go with “%@”", "聽你的，按「%@」來"),
    "适合": ("Fits", "適合"),
    "投入": ("Effort", "投入"),
    "代价": ("Trade-off", "代價"),
    "以下是调整建议，尚未修改原目标": ("Suggestions below — your original goal is untouched", "以下是調整建議，尚未修改原目標"),
    "期望结果": ("Desired Outcome", "期望結果"),
    "期限": ("Deadline", "期限"),
    "成功标准": ("Success Looks Like", "成功標準"),
    "所选路径": ("Chosen Path", "所選路徑"),
    "关键假设（未确认信息，可改）": ("Key Assumptions (unverified — editable)", "關鍵假設（未確認資訊，可改）"),
    "里程碑": ("Milestones", "里程碑"),
    "第一步：%@": ("First step: %@", "第一步：%@"),
    "有一个想到一半的目标": ("A goal you were thinking through", "有一個想到一半的目標"),
    "（未命名的心愿）": ("(An unnamed wish)", "（未命名的心願）"),
    "换个新的想法": ("Start a New Idea Instead", "換個新的想法"),
    "正在想清楚": ("Clarifying", "正在想清楚"),
    "在比较路径": ("Comparing paths", "在比較路徑"),
    "已选路径，待出草案": ("Path picked — draft pending", "已選路徑，待出草案"),
    "草案待确认": ("Draft awaiting review", "草案待確認"),
    "已保存": ("Saved", "已保存"),
    "已放弃": ("Discarded", "已放棄"),
    "和 Holo 一起想清楚第一个目标": ("Think Through Your First Goal with Holo", "和 Holo 一起想清楚第一個目標"),
    "或让 HoloAI 直接规划": ("Or let HoloAI plan it directly", "或讓 HoloAI 直接規劃"),
    "一起想清楚怎么调整": ("Think Through How to Adjust", "一起想清楚怎麼調整"),
    "还没有目标": ("No goals yet", "還沒有目標"),
    "把模糊的想法变成能走的目标": ("Turn a vague idea into a goal you can walk", "把模糊的想法變成能走的目標"),
    "新建目标": ("New Goal", "新建目標"),
    "共创前需要先开启 AI 数据授权：在「设置 → HoloAI 数据授权」里打开，再回来继续就好。": ("Co-creation needs AI data consent first: turn it on in Settings → HoloAI Data Consent, then come back.", "共創前需要先開啟 AI 資料授權：在「設定 → HoloAI 資料授權」裡打開，再回來繼續就好。"),
    "重试": ("Try Again", "重試"),
}
head_json = json.loads(git("show", f"HEAD:{path}"))
existing = set(head_json["strings"].keys())
to_add = {k: v for k, v in ENTRIES.items() if k not in existing}
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
def block(key, en, hant):
    # HEAD 为紧凑风格（"key": {），构造块必须同风格保证 diff 纯新增
    return (f'    "{esc(key)}": {{\n      "localizations": {{\n        "en": {{\n          "stringUnit": {{\n'
            f'            "state": "translated",\n            "value": "{esc(en)}"\n          }}\n        }},\n'
            f'        "zh-Hant": {{\n          "stringUnit": {{\n            "state": "translated",\n'
            f'            "value": "{esc(hant)}"\n          }}\n        }}\n      }}\n    }},\n')
lines = git("show", f"HEAD:{path}").splitlines(keepends=True)
anchor_line = '    "返回重新选路径": {'
if any(l.rstrip("\n") == anchor_line for l in lines):
    idx = next(i for i, l in enumerate(lines) if l.rstrip("\n") == anchor_line)
else:
    idx = next(i for i, l in enumerate(lines) if l.rstrip("\n") == '  "strings": {') + 1
lines[idx:idx] = [block(k, en, h) for k, (en, h) in to_add.items()]
constructed = "".join(lines)
check = json.loads(constructed)
missing = [k for k in to_add if k not in check["strings"]]
assert not missing, f"xcstrings 构造缺键: {missing}"
print(f"  xcstrings: HEAD {len(existing)} 键 + 新增 {len(to_add)} 键")
stage_blob(constructed, path)

print("OK 全部构造完成" if not fail else "FAIL 存在校验失败，未全部入暂存")
sys.exit(1 if fail else 0)
