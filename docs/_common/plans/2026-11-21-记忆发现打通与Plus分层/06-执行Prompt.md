# 06 · 执行 Prompt（直接复制给执行模型）

## 使用说明（给东林）

- **一次只派一个任务**，按顺序：B1 → B2 →（问你后）B3；I1 → I2 → I3 → I4a → I4b → I5 → I6 → I7 → I8 → I9。后端和 iOS 两条线可以并行，iOS 线内部必须串行（同一时间只能跑一个 xcodebuild）。
- 每个任务都开一个**新会话**，先贴「公共前言」，再贴该任务的 prompt。
- 模型建议：B1、B2、I1~I4b、I6、I7、I9 用低阶模型即可；**I5（服务层串联）和 I8（评审页串联）逻辑最多，建议至少用中档模型**，或者低阶模型做完后让高阶模型 review 一次。
- 执行者每做完一个任务都会在 `07-实施记录.md` 追加一条；派下一个任务前看一眼上一条是不是「完成」。

---

## 公共前言（每个任务都先贴这段）

```
你在 Holo 仓库（/Users/tangyuxuan/Desktop/Claude/HOLO）里执行一个已经设计好的施工任务。设计已经定稿，你的工作是照施工图实现，不要重新设计，也不要扩大范围。

必读（按顺序）：
1. docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/00-README.md（全局红线）
2. docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/01-产品方案与文案真源.md（文案逐字照抄这里）
3. 本任务对应的施工图章节（下面会告诉你是哪一节）

硬规则：
- 先做「开工检查」（B0 或 I0）。检查不通过就停下，在 07-实施记录.md 写明原因并告诉我，不要继续。
- 工作区有其他会话的改动：只能 git add 本任务列出的文件，禁止 git add -A / git add . / git commit -a。
- Swift 禁止：强制解包 !、try!、as!、print()、uniqueKeysWithValues、date.formatted()、Text(date, style:)。日志用 Logger，日期用 DateFormatter + zh_CN。ScrollView 必须 showsIndicators: false。
- 不新建测试文件，测试追加到施工图指定的既有测试文件。
- iOS 构建/测试一律用 Holo/Holo APP/Holo/BuildScripts/holo_build.py，不要手敲 xcodebuild。同一时间只跑一个构建。
- 不改 Localizable.xcstrings，不改 Xcode 工程签名配置，不 push，不部署，不装真机。
- 施工图里写着「先核对」的地方，必须先读代码核对，按实际代码调整，并在实施记录里写明你核对到了什么。
- 同一个编译/测试错误修两轮还没好，就停下，把错误原文和你试过的办法写进实施记录，告诉我。
- 完成后：①跑施工图里的验收命令并贴出结果摘要；②按施工图的 commit 信息提交（type(scope): 中文描述，结尾加当前会话要求的 Co-Authored-By 行）；③在 07-实施记录.md 末尾按模板追加一条记录（这个文件也要一起 git add）；④用中文简短告诉我做了什么、测试结果、有没有偏离施工图。
```

---

## B1 · 额度信息回传

```
任务：执行 03-后端实施.md 的「B0 开工检查」和「B1 · 撞墙与送达时回传额度信息」。
范围：只改 HoloBackend/src/discovery/insightDeliveryStore.js、HoloBackend/src/discovery/insightGate.js、HoloBackend/src/app.js、HoloBackend/tests/discoveryInsight.test.js。
重点：buildDraftEnvelope 不带 quota 时输出必须和改前逐字相同；quotaInfo(usedCount + 1) 必须在 record 之后调用。
验收：node --test tests/discoveryInsight.test.js 全绿且新增 4 例执行到；npm test 失败数不多于开工基线。
```

## B2 · Plus 点名看（后端 + prompt 双端同步）

```
任务：执行 03-后端实施.md 的「B0 开工检查」和「B2 · Plus 点名看」。前置：B1 已提交。
范围：HoloBackend/src/discovery/insightGate.js、HoloBackend/src/app.js、HoloBackend/src/prompts/defaultPrompts.json、HoloBackend/tests/discoveryInsight.test.js、Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift。
动手改 prompt 前先读 docs/standards/PROMPT_GUIDELINES.md 的双端同步流程。
重点：defaultPrompts.json 必须用施工图给的 node 脚本修改，git diff --stat 只能显示 1 行变化，否则回滚并停下；两端插入的段落逐字一致，用 grep -c "用户点名（可选）" 验证两个文件各为 1；PromptManager 的 promptVersions 里 .discoveryInsightV2 从 2 改为 3。
验收：node --test tests/discoveryInsight.test.js 全绿；npm test 失败数不多于基线。
不要部署。
```

## B3 · 部署（只在东林明确同意后派）

```
任务：执行 03-后端实施.md 的「B3 · 部署」。东林已在本条消息里同意部署：【东林在这里写「同意部署」】。
走 skill holo-backend-deploy，不要手敲 docker 命令。部署后按 B3 第 3 步验证，并把结果写进 07-实施记录.md。
```

## I1 · 契约

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I1 · 契约」。
范围：DiscoveryInsightContract.swift、DiscoveryInsightContractTests.swift（路径见施工图）。
重点：focusFeatureIds 用 var + 默认 nil，现有调用点不改；InsightDraft 的便利初始化加 quota 参数且默认 nil。
验收：./holo_build.py test --dest "platform=iOS Simulator,id=<UDID>" --only HoloTests/DiscoveryInsightContractTests 全绿，新增 3 例执行到。
```

## I2 · 本机短句

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I2 · 候选构建器：本机短句」。前置：I1 已提交。
范围：DiscoveryInsightCandidateBuilder.swift、DiscoveryInsightBuilderTests.swift。
重点：短句逐字照 01 §5 的短句表；绝对不要改任何 feature 的 description 文字（那是发给模型的）；挖掘器提案不生成短句；写测试前先核对 f_checkin 的 id 用的是哪个下标。
验收：--only HoloTests/DiscoveryInsightBuilderTests 全绿（含既有用例）。
```

## I3 · 预告问题拼装器

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I3 · 预告问题拼装器」。前置：I2 已提交。
范围：新建 Holo/Holo APP/Holo/Holo/Services/AI/Discovery/V4/DiscoveryTeaserBuilder.swift；测试追加到 DiscoveryInsightBuilderTests.swift。
施工图给了完整代码和测试，照抄即可；新文件会被文件系统同步自动编进 target，不要改 pbxproj。
验收：--only HoloTests/DiscoveryInsightBuilderTests 全绿。
```

## I4a · 本机存储

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I4a · 本机存储」。前置：I3 已提交。
范围：DiscoveryTopicStore.swift、DiscoveryReviewSheet.swift（只改 isInsightQuotaWalledToday 那一处调用）、DiscoveryInsightService.swift（只改 markInsightQuotaWalled 那一处调用为 until: nil）、DiscoveryInsightBuilderTests.swift。
重点：删除按日撞墙的旧 API，改成按截止时刻；todayCard 对 isFocusedPick 的卡放行；改写既有那个「墙标记当日有效、次日重探」用例为新语义。
验收：./holo_build.py build 绿 + --only HoloTests/DiscoveryInsightBuilderTests 全绿。
```

## I4b · 往期存档 + 文案工具

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I4b · 往期发现存档 + 文案工具」。前置：I4a 已提交。
范围：新建 DiscoveryInsightArchive.swift、DiscoveryPlusCopy.swift（都在 Services/AI/Discovery/V4/）；测试追加到 DiscoveryInsightBuilderTests.swift。
重点：先读 DiscoveryInsightCardBuilder 核对 QueuedCard.body 的含义；测试里星期几的断言先用施工图给的终端命令确认（施工图已核对过 2026-11-27 是周五、11-12 所在周是 11-9~11-15，仍需你复核）。
验收：--only HoloTests/DiscoveryInsightBuilderTests 全绿。
```

## I5 · 服务层

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I5 · 服务层」。前置：I4b 已提交。
范围：DiscoveryInsightService.swift、DiscoveryInsightFeedbackBridge.swift、DiscoveryInsightBuilderTests.swift。
重点（逐条自查）：
1. 删掉 applyDraft 里 switch 之前那行无条件的 markInsightV2Attempted，改到各分支内；quota_exhausted 分支绝不能调用它。
2. 撞墙：墙截止到 quota.resetDate；后端回 tier=free 但本机 isPlusActive 时只墙 600 秒。
3. none_worthwhile 清空预告；送达时保存排除了本次引用特征的新预告。
4. 点名卡（isFocusedPick）不写当日尝试标记、不写 noneDay。
5. FeedbackBridge：confirm 和 deferCard 写往期存档，reject 不写。
6. applyDraft 新增的两个参数都有默认值，现有调用点不改。
验收：build 绿 + --only HoloTests/DiscoveryInsightBuilderTests 全绿（既有用例不能挂）。
```

## I6 · 发现卡文案 + 撞墙卡重写

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I6 · 发现卡文案 + 撞墙卡重写」。前置：I5 已提交。
范围：DiscoveryInsightCardView.swift；DiscoveryReviewSheet.swift 只允许改 DiscoveryQuotaWallCard 的那一处调用（施工图给了临时写法）。
重点：文案逐字照 01 §4.3，代码里标注编号；子件拆成小函数，不要写一个巨型 body；不要自己造新颜色，金色按钮只在项目已有样式时使用。
验收：./holo_build.py build 绿。
```

## I7 · Plus 说明页 + 往期发现页

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I7 · Plus 说明页 + 往期发现页」。前置：I6 已提交。
范围：新建 Holo/Holo APP/Holo/Holo/Views/Chat/DiscoveryPlusExplainerSheet.swift、DiscoveryInsightArchiveView.swift。
重点：文案逐字照 01 §4.4、§4.5；字号/颜色/圆角常量必须是 Utils/DesignSystem.swift 里真实存在的（先搜再用）；日期用 DateFormatter + zh_CN。
验收：./holo_build.py build 绿。
```

## I8 · 评审页接入

```
任务：执行 04-iOS实施.md 的「I0 开工检查」和「I8 · 评审页接入」。前置：I7 已提交。
范围：只改 Holo/Holo APP/Holo/Holo/Views/Chat/DiscoveryReviewSheet.swift。
重点：
1. 墙卡不再依赖「等你确认」列表为空；有 wallState 时不出空态。
2. 说明页点开通 → 先关说明页 → 在 .sheet 的 onDismiss 里调 requirePlus（不要在说明页还开着时直接调）。
3. 购买成功的 resume 里清撞墙标记并发 .holoDiscoverySettingsDidChange 通知。
4. 删掉 I6 留下的临时墙卡调用。
5. DiscoverySectionHeader 的 trailing 是可选 String，直接传 quotaTrailing。
验收：build 绿；然后按 05-验证与验收.md 的「模拟器走查」执行 S1~S8（模拟器无头运行，截图交给只读子代理判读，你自己不读图片）。S4 必须实点确认系统付费墙弹出；不弹就停下记录现象，告诉我。本机后端起不来时，S2~S5 标「需东林真机验收」。
```

## I9 · 记忆中心文案 + 付费墙标题 + 权益表 + 收尾

```
任务：执行 04-iOS实施.md 的「I0 开工检查」「I9」和文末「收尾」。前置：I8 已提交。
范围：HoloMemoryCenterView.swift、HoloPortraitInsightsSection.swift、HoloPlusActionCoordinator.swift、HoloPlusBenefitComparisonTable.swift；收尾时追加 CHANGELOG.md、TODO.md。
重点：只改文案和施工图列出的横幅/滚动条，不动逻辑；新 SF Symbol 先用命令验证存在；grep requirePlus 记忆中心目录必须无输出；CHANGELOG 只追加不覆盖。
验收：build 绿；记忆中心截图（子代理判读）确认横幅出现、无滚动条。
```

---

## 可选：高阶模型复核 prompt（I5、I8 完成后各用一次）

```
请对照 docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/04-iOS实施.md 的【I5 或 I8】一节和 02-对抗审查记录.md 的 E1~E10，审查最近一个 commit（git show HEAD）。只找三类问题：①与施工图不符的地方；②E1~E10 里任何一条没有被真正处理；③会导致崩溃、卡死或数据错误的问题。不要提风格建议。每个问题给出文件:行号、问题、具体后果、建议改法。没有问题就直接说没有。
```

---

## 一次性全量执行 prompt（夜间无人值守，2026-11-21 追加）

````
你在 Holo 仓库（/Users/tangyuxuan/Desktop/Claude/HOLO）里，今晚无人值守地把一套已经定稿的方案从头实施到尾。东林今晚不在，明早验收。设计已经定稿，你的工作是照施工图实现，不重新设计，不扩大范围，不向东林提问（他看不到）；遇到下面列出的「硬停止」情况就按规则停下并留记录，其他情况按方案文档的推荐做法自行决定，并把决定写进实施记录。

# 一、先读（按顺序，全部读完再动手）

方案目录：docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/
1. 00-README.md —— 全局红线、任务依赖、本轮不做的事
2. 01-产品方案与文案真源.md —— 所有界面文案逐字照抄这里
3. 02-对抗审查记录.md —— E1~E10 是必须处理的工程坑
4. 03-后端实施.md —— 后端施工图 B0~B3
5. 04-iOS实施.md —— iOS 施工图 I0~I9 + 收尾
6. 05-验证与验收.md —— 测试清单与模拟器走查
7. 07-实施记录.md —— 记录模板
另外读项目规则：AGENTS.md、CLAUDE.md、docs/standards/quality-redlines.md 第 9 节、docs/standards/跨端接口契约规范.md。

# 二、执行顺序

严格按这个顺序，一个任务完成并提交后才开始下一个：

后端线：B0 → B1 → B2（B3 部署见第五节）
iOS 线：I0 → I1 → I2 → I3 → I4a → I4b → I5 → I6 → I7 → I8 → I9 → 收尾

先做完整个后端线，再做 iOS 线（你只有一个会话，不要并行；同一时间只能跑一个 xcodebuild）。

每个任务的流程固定为：
1. 开工检查（B0 / I0，见施工图）
2. 读施工图该节，把标「先核对」的地方逐一读代码核对
3. 实现（文案逐字照 01，代码注释标文案编号和「2026-11-21 Plus 分层 Ixx」）
4. 跑该节的验收命令
5. 只 git add 该节列出的文件 + 07-实施记录.md，按该节的 commit 信息提交（type(scope): 中文描述，结尾加当前会话要求的 Co-Authored-By 行）
6. 在 07-实施记录.md 末尾按模板追加一条

# 三、硬规则（任何时候都不能违反）

- 工作区有其他会话的改动：禁止 git add -A / git add . / git commit -a / git stash / git checkout 别人的文件 / git reset。只动施工图列出的文件。
- Swift 禁止：强制解包 !、try!、as!、print()、uniqueKeysWithValues、date.formatted()、Text(date, style:)。日志用 Logger；日期用 DateFormatter + Locale(identifier: "zh_CN")；ScrollView 必须 showsIndicators: false。
- 不新建测试文件，测试只追加到施工图指定的既有测试文件。新的业务源文件放到指定目录即可（主 target 是文件系统同步型），不改 pbxproj。
- iOS 构建/测试一律用 Holo/Holo APP/Holo/BuildScripts/holo_build.py；测试需要 --dest "platform=iOS Simulator,id=<UDID>"，UDID 用 xcrun simctl list devices available | grep -m1 iPhone 取。build 不编译测试，改了测试必须跑 test。
- 模拟器一律无头运行（skill holo-sim-headless），不开模拟器窗口。主会话禁止用 Read 读任何图片/截图；截图判读派一个只读子代理去看，并让它只回文字结论。除截图判读和第六节的复核外，不要派其他子代理。
- 不改 Localizable.xcstrings、不改签名/Bundle ID、不 push、不装真机、不改 CloudKit 相关任何东西、不碰真实用户数据。
- 不使用 DeepSeek pro 档或任何贵档模型；本机后端如需模型，只用现有配置，不改模型路由。
- 不找、不读、不改任何密钥或 .env 内容；本机后端起不来就按 05 的说明降级。
- 新 SF Symbol 先用 00-README 红线 5 的命令验证存在。

# 四、硬停止规则（遇到就停，按规则处理）

1. 开工检查发现目标文件有「不是本方案提交产生」的未提交改动：
   - 后端线被挡 → 跳过后端线，直接做 iOS 线（两条线互不依赖，I1 只依赖后端的字段定义，不依赖后端代码）。
   - iOS 线被挡 → 停止 iOS 线。
   - 都要在 07 写明 git status 原文。
2. 开工前 ./holo_build.py build 本身就是红的（不是你造成的）→ 停止 iOS 线，记录错误原文，不要去修别人的编译错误。
3. 同一个编译/测试错误修两轮仍未解决 → 停止当前任务及其后续依赖任务，记录错误原文、你试过的办法、你判断的根因。
4. 施工图与实际代码冲突、且按施工图做会改变产品行为或契约 → 停止该任务，记录冲突点和你建议的两种处理方式。纯命名/签名差异（施工图已注明「以实际为准」的）不算冲突，自行对齐即可。
5. I8 走查 S4「点开通后系统付费墙不弹出」→ 最多换一种呈现方式尝试一次，仍不行就记录现象，I8 其余部分照常提交，I9 继续做。
6. B2 中 defaultPrompts.json 的 git diff --stat 超过 1 行变化 → 回滚该文件，停止 B2，记录。

停止某条线后，能独立进行的另一条线照常继续。

# 五、后端部署（B3）

【默认：不部署】B1、B2 只提交不部署，在总结里写「B3 待东林确认后部署」。
（如果东林在这一行写了「今晚允许部署」，才按 03 的 B3 走 skill holo-backend-deploy 部署并验证：＿＿＿＿＿＿）

不部署不影响 iOS 线：iOS 新增字段都是可选的，旧后端下 quota 为空时界面按「不显示额度」处理。模拟器走查用本机后端（见 05）。

# 六、复核

I5 和 I8 各自提交后，派一个只读子代理，给它这段 prompt 做复核：

「请对照 docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/04-iOS实施.md 的【I5 或 I8】一节和 02-对抗审查记录.md 的 E1~E10，审查最近一个 commit（git show HEAD）。只找三类问题：①与施工图不符的地方；②E1~E10 里任何一条没有被真正处理；③会导致崩溃、卡死或数据错误的问题。不要提风格建议。每个问题给出文件:行号、问题、具体后果、建议改法。没有问题就直接说没有。」

复核提出的问题：属于①②③的修掉，重新跑验收，单独提交「fix(iOS): I5/I8 复核修正——<描述>」；你判断不成立的，在 07 写明理由。

# 七、全部结束后

1. 跑一次全量：后端 npm test；iOS ./holo_build.py test --dest ...（不带 --only）。记录通过/失败数，与开工基线对比。
2. 按 04 文末「收尾」追加 CHANGELOG.md 和 TODO.md（只追加，不覆盖），单独提交。
3. 在 07-实施记录.md 最末尾写「## 夜间执行总结」，包含：
   - 每个任务一行：编号 / 完成·跳过·中止 / commit hash
   - 全量测试结果（对比基线）
   - 模拟器走查 S1~S8 每项：通过 / 不通过 / 需东林真机验收，附截图路径（.qa-screenshots/discovery-plus-tier-20261121/）
   - 所有偏离施工图的地方和原因
   - 硬停止的情况和现状
   - 东林明早需要做的事（按优先级排序，例如：同意部署 B3、真机验收哪几项、拍板哪个冲突）
   这份总结用产品语言写：先写结论，再写需要东林决定的事，最后才是技术细节。
4. 总结也一起提交。不要 push。
````
