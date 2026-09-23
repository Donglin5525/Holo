# Holo 生活理解与 Matter 主动筹备：完整产品与实施方案

> 版本：V3，2026-09-23。本文是下一阶段唯一实施依据。此前《Holo生活理解与主动筹备完整实施方案》保留为历史草案；两者不一致时以本文为准。
>
> 范围：本轮交付审查与实施规格，不代表代码、模型、真机或生产能力已经通过。
>
> 仓库根目录：`/Users/tangyuxuan/Desktop/Claude/HOLO`。先检查在途改动，实施时只修改本阶段文件。

## 0. 审查结论：截图指出了什么

“护照”与“照护”字义不同，所以“用户没有明说宠物照护”在自然语言层面仍成立。但用含“护照”的句子当唯一正例，会让验收结果失去证明力：当前 `HoloContextRetrievalService.tokenized` 把中文按单字切分，两词都形成“护”和“照”。`lexicalScores` 只要有一个字重叠就给分，`conditionMatches` 也接受一个字重叠。因而检索可能靠词面碰巧命中照护记录，再由模型写出看似聪明的答案。静态审计只能证明存在这条误召回路径，尚未证明某次真实运行确实沿此路径命中。

同次审查发现更多会让“方案写得对、开发做不成”的问题：

| 编号 | 原稿问题 | 代码或逻辑依据 | V2 修正 |
|---|---|---|---|
| R1 | S2 含“护照”，却把得到“照护”建议当隐性洞察证明 | 中文单字 token 集合重合；一次命中无法归因 | 主验收输入同时不含“护”“照”及宠物词；“护照”变成对抗输入 |
| R2 | 把 P0 的门禁写成真实记录一直走到计划，但四域来源、关系和规划分别安排在后续阶段 | 前置依赖未完成 | P0 只交差异诊断、冻结夹具与契约；真实端到端门禁放在 R3/R4 |
| R3 | “朋友 1—3 号来喂猫”就说前三天覆盖 | 没有到访频率，也没有全部照护内容 | 只有明确日期、频率和事项才评估相应范围；否则状态为待核实 |
| R4 | 写了 `PlanEffectV1` 新类型，但代码已经有 `HoloContextPlanEffect` | 现有 Draft 和旧卡片使用它 | 增量扩展现有类型及 V1 兼容；不再建第二套效果对象 |
| R5 | 方案要求解释个性化变化，但默认 V2 卡片不渲染 `planEffects` | `ContextPlanChatCard` 开关开启时显示 `MatterPlanLaunchCard`；效果区只在旧卡片 | 修改 `MatterPlanLaunchCard` 主路径并验收首屏，不能只改旧卡片 |
| R6 | 原稿称来源修订有门禁，规划调用实际没提供当前修订目录 | `selectAdviceCandidates` 缺省 map 时把缺项视作仍有效；`HoloContextChatPlanner` 未传当前 map | 新推断入选、生成返回、展示和保存前必须查真实修订；缺项按不可用处理 |
| R7 | 把 Release A 的上线验证放到最后 P6，而 P5 主动能力尚未完成 | 里程碑先后不自洽 | A 有自己的发布门禁 R5A；B 再做 R5B 与 R6B |
| R8 | 曾说“删除来源后不再展示建议”，但历史草案会保留个性化文字快照 | `HoloContextPlanBasisEntry` 注释写明历史快照；`answerText` 可包含推断 | 遗忘后隐藏关联的生成建议/依据并提供中性占位；已接受任务另行管理，不自动删除 |
| R9 | `conditionMatches` 中只要存在 `linkedContextIDs` 就返回 true | 无目标关联验证 | 链接只用于已命中候选的受控扩展，不构成独立召回理由 |
| R10 | 时间匹配用 `now...now+30 天` 而非本次旅行区间 | 远期事项可能漏检，近 30 天无关事项误入 | 所有影响与安排覆盖以冻结的情境区间为准 |

R1、R5、R6、R9、R10 是当前代码可定位的缺陷或缺口；R2、R3、R7、R8 是前稿实施和产品契约的内部冲突。不要把审查发现说成线上故障，除非真机或生产请求另有证据。

## 1. 唯一产品目标与范围

用户只表达“我将离家旅行”，Holo 从已授权的财务、任务、习惯、想法原始记录中发现与本次离家相关的持续责任，检查这次是否已有安排，将有依据的缺口加入可审阅计划。用户一次接受后，Matter 持续推进；新的安排或纠正能改变同一事项。

**Release A 的完成定义：用户开口以后，Holo 能补出他没有说的、确实与自己有关的安排。** Release B 在此基础上，从已确认的情境变化主动提出站内建议。系统通知单独验收。

“更懂你”还包括减少和调整计划：有完整安排则不重复建任务；有明确偏好则改变方案；已有承诺占满时间则收缩行动。新待办数量不是效果指标。

本阶段不新增宠物档案入口，不要求逐条确认记忆，不新建图数据库，不让模型自动写任务或静默重排用户接受过的计划。

## 2. 冻结主旅程与不被词面误导的验收

### 2.1 测试数据，均须经正常业务入口或受控导入进入真实 Repository

测试时钟固定为 2026-09-23，时区 Asia/Shanghai；以下都是**模拟账号的测试记录**，不得写成东林个人数据已被读取。

| sourceKey（示例） | 原始记录 | 必须保留的状态 | 允许的推断 |
|---|---|---|---|
| `finance:tx-01` | 8 月 20 日买猫粮；商品/备注字段确实有“猫粮” | 交易有效、非重复导入、商品来源可核验 | 只能是宠物相关弱线索，独自不能证明所有权 |
| `task:task-01` | 9 月 12 日任务“给摩卡换水” | 已完成时间真实；若仅创建未完成，须如实传递 | 至少有一次照料活动；不证明摩卡物种 |
| `habit:habit-01` 及独立打卡事件 | “给摩卡换水”，有多日真实打卡 | 定义与打卡分开；同一打卡派生记录算同一血缘 | 可能存在持续照料责任 |
| `thought:note-01` | “上次出门找过人上门喂猫。” | 用户本人陈述的历史经历，非引用他人 | 曾有离家时的猫咪照护安排；不代表本次已安排 |

不预建“我养猫”“摩卡是猫”等手工记忆，不在用户消息中注入照料提示，也不直接给规划器塞加工好的情境对象。关系必须由这四类真实原始记录进入统一管道。

### 2.2 主输入与对抗输入

**主输入 Q0**：

> 我 10 月 1 日到 7 日去日本，第一次去，打算去东京和大阪。签证、机票、酒店都还没有安排，预算大约一万元。请帮我做好出发前的准备。

Q0 不含“猫、摩卡、宠物、喂、换水、照护”，也不含“护”或“照”两个字。自动检查这些字，避免以后编辑用例时重新引入词面线索。

**对抗输入 Q1**：在 Q0 增加“护照已经办好”。Q1 与 Q0 的宠物相关结果应相同；“护照”只能影响证件准备，不能成为召回照护责任的原因。

**空库对照 Q2**：同一 Q1，但移除所有宠物照护原始记录。不得说“你有宠物要照顾”，也不得生成个人化宠物任务。

**反转对照 Q3**：交易是替朋友买，任务对象“摩卡”被明确纠正为咖啡，想法是引用朋友故事。不得继续推断本人有宠物照护责任。

Q0 有相应证据才允许提出“本次离家期间可能需要确认宠物照护安排”；摩卡身份仍不清楚时只称“宠物照护”。回答必须说“目前在可访问记录中没有找到本次安排”，不能说“你还没安排”。

### 2.3 可接受的首次输出

计划卡中出现一项，例如：“确认 10 月 1 日至 7 日的家中宠物照护安排”。其来源说明可以折叠为“结合你记过的照料活动和以往离家安排”。展开时展示获准的真实记录和限制。计划与用户本轮说出的签证、机票、住宿一起展示。

成功日志必须形成可追踪链：

```text
原始 sourceKey + revision
→ 关系 contextID + decision/useLevel + 独立血缘
→ 情境区间与影响方向
→ 召回原因，不得仅为“护/照”字符重合
→ HoloContextPlanEffect + 对应 plan itemID
→ 一次接受后的真实 matterID、todoTaskID、MatterLink 与回执
```

若只得到漂亮文案，没有以上任一关键链接，则该层失败。Q0、Q1 都要独立跑；只跑 Q1 不能替代 Q0。

### 2.4 接受与后续变化

- 点击“开始推进”前，只持久化草案或聊天状态，不创建 Matter/任务等业务对象；点击后沿现有 `launchPlan` 原子建成，重复点击复用同一回执。
- 用户后续明确写“朋友确认 10 月 1、2、3 日每天上门喂猫并换水”，可以认定**这两项在前三天有安排依据**；4—7 日仍未在已查记录中看到安排。不得推断其他照护事项也全部完成。
- 用户只写“朋友 1—3 号来一次”时，频次与覆盖未知。表现为“已约一次，是否覆盖这几天的日常照料还需确认”。
- “找人问了但没答复”是待定，“约好了”是安排，“实际喂过”是发生事件。三个状态不可互相替代。
- 用户接受增量修改才更新原任务，不能再建一条同义任务；日期变化导致原提案失效并重算。
- 用户纠正“我没有这项照护责任”后，本次建议撤回，后续同义记录不得使之自动复活。若明确说“我照料邻居的猫”，只撤回所有权推断，保留责任。

### 2.5 用户真正看到的完整链路

| 步骤 | 用户动作/系统时机 | 用户看见的结果 | 背后必须发生的事 | 失败时的合理表现 |
|---|---|---|---|---|
| S0 日常积累 | 正常记账、完成任务、打卡、写想法 | 原产品体验不加确认弹窗 | 授权范围内异步记录原始来源、版本和处理水位 | 处理失败留队重试，不阻塞记账或写想法 |
| S1 形成理解 | 用户不在场时处理已授权记录 | 默认不打扰；个人情境页可看、纠正、忘记 | 多源证据形成带限定语的关系，保留不同解释 | 证据弱时只观察，不把猜测写成档案事实 |
| S2 提出眼前的事 | 输入 Q0 | 先看到旅行基础准备，同时看到与本人相关的照护确认项 | 把“离家 7 天”变成条件变化，检索相关持续责任和本次已有安排 | 来源覆盖不足时承认未知；不以空库断言用户没有安排 |
| S3 理解建议 | 展开“为什么” | 能读到简洁理由和真正的来源；关闭后仍是易读计划 | 每句个人化结论可追到来源、关系和影响 | 来源失效时隐藏旧理由并提示重算 |
| S4 开始推进 | 一次点击“开始推进” | 一个 Matter、可操作任务和回执，Today 显示下一步 | 现有启动事务原子写入，稳定 ID，不重复创建 | 写入失败保持草案可重试，不出现半成品 |
| S5 现实变化 | 用户记下朋友已确认部分日期 | 同一 Matter 中只剩未覆盖范围，原任务可调整 | 解析安排的对象/事项/日期/频次/承诺状态，产生增量提案 | 不明频次只说待核实；不悄悄改已接受任务 |
| S6 纠正/遗忘 | 用户说“那是替朋友买的”或删除来源 | 相关推断撤回；可管理已接受任务 | 反证和 suppression 生效，旧聊天冷启动仍受展示门禁 | 不能从旧摘要重新推断并复活 |
| S7 完成/下一次 | 旅行结束或再次提出离家 | 本次 Matter 可结束；下一次重新核对当前安排 | 历史安排可作为经验，绝不自动等同新行程安排 | 缺失当前覆盖时继续写“未查到”，而非“未安排” |

日常使用的交互上限：不要求用户逐条给记忆打标签；首次规划只需一次“开始推进”；后续只有真实业务对象要修改时才要用户确认。推断存在不等于自动建任务，也不等于一次行程的安排能沿用到下一次。用户纠错、关闭来源、关闭主动建议的入口应复用现有个人情境控制面，不能为了这项能力增加一套宠物配置页。

### 2.6 产品决策规则：从洞察到少做事

每个候选先问四个问题：它是否是**这个用户的**持续责任；本次情境是否改变执行条件；本次时间窗内是否已有足够安排；改变计划是否比现状更好。四问任何一问未知，都不能升级为确定性“你必须做”。可提出低打扰的核实建议，但必须保留限定语。

效果类型只允许四种：`add` 补缺口、`adjust` 调整已有项、`skip` 避免重复、`choice` 提供由用户选择的替代方案。举例：有明确 1—7 日每天喂食换水的安排，则 `skip` 原照护确认项；只有 1—3 日，则 `adjust` 为核实 4—7 日；旅行预算紧时减少非必要景点采购，也可视作成功。一个事实不能同时产生两个语义相同的任务。

## 3. 数据与推断的可执行边界

### 3.1 来源、覆盖和变更

新增最小 `SourceObservation` 适配层，字段为：`sourceKey(domain:entityID)`、`revision`、`sourceKind`、`authorship`、`lineageRootIDs`、`recordedAt`、`eventAt/precision`、真实 `businessState`、获准的 `normalizedText`、`sensitivity`、`accessGeneration`、`coverageGap`。财务商品字段缺失时不得从商户猜“猫粮”；任务 `completed=false` 不得当成照料已经发生。assistant 自己生成的计划不是新的独立事实。

Release A 接四域：财务交易、待办及状态、习惯定义与实际打卡、想法正文。每域有独立 `(updatedAt, entityID)` 游标和完成水位；从 Core Data 保存、导入、删改、恢复、CloudKit 合并统一进入持久变更队列。页处理完成后推进 checkpoint，重复消息按 `sourceKey + revision + extractorVersion + policyVersion` 幂等。学习基线之前的数据仍受原授权控制。

用户请求规划时采用已有派生关系，必要时做有界原文补查；不用等历史全库回填。界面与诊断能区分“无相关证据”和“仍有未处理记录”。

### 3.2 关系、身份和时效

复用 `HoloMemoryRecord`、其 `personalContext` 载荷和现有五路 `HoloMemoryDecisionPolicy`；只增量补 `entityMention`、责任关系、有效区间、原始证据、独立血缘、替代解释、反证和用户纠正。模型提出候选，程序核验证据与资格。

“摩卡”可能是宠物名，也可能是饮品；“买猫粮”可能是代购。实体归并需要来源支持，不能按名字相同合并。`用户有宠物照护责任`、`摩卡是宠物`、`宠物属于用户` 是三个独立命题，可以有不同资格。

关系支持至少保留来源版本和原始事件根 ID。任务、AI 摘要、模型再次表述如果来自同一原始事件，只算一份血缘。删除来源、反证、职责过期、用户纠正使相关命题和提案重新评估。被明确“不再参考”的命题沿 suppression 阻止改写后复活。

新推断使用前必须能解析当前来源修订。现有 `HoloContextAccessPolicy.selectAdviceCandidates` 的缺省空修订 map 只可用于旧兼容；新跨域推断查询时，无法确认任一关键来源当前版本则拒绝使用并入重试队列。规划开始、模型返回、展示、执行前分别重查控制代际和涉及的来源/任务修订。

### 3.3 目标影响与检索

在 `HoloPlanningRequestFrame` 中区分 `declared` 用户事实与 `derivedHypothesis` 检查方向。Q0 只能推出“可能离开常住地一段时间、日常责任的执行条件可能变化”；不能先凭旅行目标推断用户有猫。检索命题仍以源记录和政策为准。

召回至少包含直接目标、有效责任、时间冲突、本次已有安排四个通道。影响计算使用 `2026-10-01…2026-10-08` 的本地日半开区间及实际时区，不用 `now+30 天` 固定窗口。分值可排序，不能替代资格硬门禁。

中文词法降级不得按单个 CJK 字符做语义命中。首版用词/相邻字组合或经验证的结构化关系候选，要求匹配短语及其上下文；尤其 `护照` 和 `照护` 反序、`摩卡咖啡` 和宠物名必须有回归断言。`linkedContextIDs` 只允许在已命中且获准的候选上做受限一跳扩展，不直接让候选入池。向量召回也需后续关系适用性与证据检查。

当前 raw fallback 只沿已召回 ID 回查，现有一次规划运行的原文回退预算也是 1 次。Release A 新增**一次**发现性补查：在明确影响方向下，用获准的只读来源目录查最多 4 段、总共最多 8,000 字符；原有回查与发现性补查须合并纳入同一次预算和一次证据包。若需第二轮，须先显式升级运行预算、状态持久化和成本门禁，并在后续版本另行验收。查询不能由模型任意执行 SQL，找不到时要保留覆盖范围与未知。

### 3.4 方案效果与默认卡片

**扩展已有的 `HoloContextPlanEffect`**：保持旧 `kind/summary/contextRefs` 可解码，新增可选 `effectID`、`requirementKey`、`evidenceRefs`、`whyNow`、`baseline`、`personalizedDelta`、`affectedItemID` 和证据修订。`kind` 使用明确白名单映射到 add/adjust/skip/choice；不要另建 `PlanEffectV1` 当第二真相源。`HoloContextPlanDraft` 仅在不兼容字段必需时升 schemaVersion，并保留旧草案读取与降级展示。

主 UI 路径是 `ContextPlanChatCard` → `MatterPlanLaunchCard`。在该卡显示真实个人差异及可展开的“为什么”，不把实现只放进旧 `ContextPlanChatCard.planEffectsSection`。`planEffects` 与对应 item 要有稳定 ID 关联；有个性化文字但无合法 effect/evidence 时，validator 降级为普通建议或拒绝个人化表达。

### 3.5 已有安排与业务写入

安排覆盖按“对象、责任内容、日期区间、频次、方式/执行方、承诺状态”计算，输出 `unknown/partial/covered/contradicted/notApplicable`。某维缺失就保持该维未知。无记录表示“未查到”，不是现实中“没有安排”。

未接受的 requirement/effect 只属于草案或可重建建议投影，不能创建真实 `HoloMatterOpenLoop`、任务或改 `planOrder`。Matter 首次启动复用现有事务；后续增量采用 `logicalActionKey + expectedMatterRevision + expectedTaskRevision` 预检，在明确确认后修改真实 ID，失败原子回滚并可恢复。历史安排、任务状态和本次覆盖是不同真相源。

### 3.6 遗忘后的展示与业务对象

现有 Draft 的 `basisEntries` 和 `answerText` 可能保留个性化快照。新增由 `usedContextRefs`、evidenceRefs 与 effect/条目关联的展示门禁：当来源失权或用户遗忘命题时，隐藏相关生成说明、个性化事项草案及来源入口，旧聊天使用“相关个人背景已不可用，这份建议需要重新生成”的中性占位。不能把旧快照继续展示成当前事实。

用户已经亲手接受的真实任务是业务对象，不因遗忘记忆自动删除；仍提供用户可见的编辑、删除或撤销入口。用户原始账单/想法的删除与已接受任务的处理分别遵从各自领域的用户操作。单靠运行时遮盖可能遗漏已持久化的生成摘要，R4 必须审计 ChatMessage、Draft、Matter 投影的持久化字段，并以“遗忘后冷启动不再露出被忘记的推断”验收。

### 3.7 四域接入清单与覆盖声明

| 领域 | 读取的原始字段与业务状态 | 不可越过的边界 | 变更事件和回填范围 |
|---|---|---|---|
| 财务 | 交易稳定 ID、金额、商户、真实商品/备注、交易日、来源/导入批次、有效/作废状态 | 商品未记录时不能因商户是宠物店就断言买猫粮；单笔消费不证明所有权，退款/重复导入不能累加证据 | 新建、编辑、删除/恢复、导入去重、CloudKit 合并；历史有效交易按当前权限回填 |
| 待办 | 任务稳定 ID、标题、正文、计划日期、完成/撤销时间、所属 Matter、来源类型 | 创建任务不等于发生照料；模型生成而未由用户接受的任务不可反哺为独立生活证据 | 新建、改期、完成、撤销、删除、恢复、远端合并；历史任务按状态回填 |
| 习惯 | 习惯定义 ID、名称、频次、有效期，以及每次独立打卡事件的 ID/时间/状态 | 定义表达意图，打卡表达发生；一次打卡若同时生成日程/任务，按同一血缘只算一证 | 定义/打卡各自编辑、补卡、撤销、停用、删除、远端合并 |
| 想法 | 想法 ID、用户原文、创建/修改时间、引用/转述归属、删除/恢复状态 | 历史“上次找人”不等于本次已安排；引用朋友经历不能变成用户事实 | 正文编辑、合并、删除/恢复、导入、CloudKit 合并 |

每域在诊断中分开给出授权状态 `authorized / disabled`，以及索引状态 `scanning / complete / unavailable`，另记已处理水位、待处理数、失败数、最旧待处理时间。产品文案不能说“已检查全部记录”，除非四域均已授权，且在本次检索所需时间范围都已 `complete`。覆盖不全时说“目前能查到的记录里没有看到”，并在来源页能看到哪些数据暂未参与。

Release B 才考虑对话中用户原话、已接受的 Matter/目标和显式偏好作独立来源；assistant 回答只作历史展示，不能作为佐证。健康等敏感域默认不进入本次跨域计划；后续接入须另定授权和用途。所谓“全库洞察”是对已授权领域、完整历史和当前增量做有界检索与来源覆盖说明，并非把全部数据库原文上传给模型。

### 3.8 建议的数据合同：增量落在现有类型上

以下为语义合同；R0 须对照当前 Core Data/Swift 类型确定落点。持久化字段用可选默认值完成迁移，不能强迫旧记录拥有新字段。新对象的 `schemaVersion`、`policyVersion`、`extractorVersion` 进入幂等键和诊断。

| 对象 | 最小字段 | 不变量 |
|---|---|---|
| `SourceObservationV1`（拟建适配值） | `sourceKey, sourceRevision, sourceKind, authorship, rootEventIDs, recordedAt, eventInterval?, precision, businessState, normalizedText, sensitivity, accessGeneration, deletedAt?, coverageState` | `sourceKey` 使用真实实体 ID；`rootEventIDs` 用于去重；不把 LLM 摘要当原始来源 |
| `ContextRelationV2`（增量放入 `HoloMemoryRecord.personalContext`） | `contextID, predicate, subjectRef?, objectRef?, qualifiers, validInterval?, supportRefs[(sourceKey,revision,span)], contradictRefs, alternativeInterpretations, lineageRoots, decision, useLevel, policyVersion, accessGeneration, suppressionKey?` | `predicate` 开放，不能只写猫规则；证据和反证均可追溯；`qualifiedAdvice` 不被解码成确认事实 |
| `SituationFrameV2`（扩展既有 `HoloPlanningRequestFrame`） | `goal, declaredFacts[], derivedHypotheses[], localTimeZone, interval[start,end), trigger, sourceCoverageSnapshot` | `declaredFacts` 仅来自用户或可验证记录；`derivedHypotheses` 只是检索方向，不创建个人事实 |
| `SituationRequirementV1`（规划期临时值） | `requirementKey, relationContextIDs, appliesToInterval, successCondition, coverageStatus, decisionState, gapDescription?, evidenceRefs` | `coverageStatus` 描述现实安排证据，`decisionState` 描述用户是否接受任务；两者不能混为一个状态 |
| `HoloContextPlanEffect`（已有类型增量字段） | 既有 `kind, summary, contextRefs`，可选 `effectID, requirementKey, evidenceRefs, whyNow, baseline, personalizedDelta, affectedItemID, sourceRevisions` | 只有可验证 evidence 才能作个人化断言；effect 与真实草案 item 稳定关联；旧 Draft 仍可解码 |
| `IncrementalMatterProposalV1`（提案，非自动业务对象） | `proposalKey, matterID, targetTaskID?, logicalActionKey, expectedMatterRevision, expectedTaskRevision?, action, before, after, reasonEffectID` | 提案生成不改业务对象；用户接受后沿现有 repository 原子提交并返回稳定回执 |

`requirementKey` 由“责任命题 + 情境类型 + 时间窗 + 需要完成的事项”稳定生成；行程日期修改后产生新版本并使旧提案失效。`proposalKey` 与 `logicalActionKey` 不依赖自然语言标题，避免“猫的事”和“照顾宠物”各建一次。`supportRefs` 持有当前源修订与可定位的原文范围，UI 只展示用户被允许看的最小来源摘要。

### 3.9 一条候选如何通过：资格先于排序

程序侧硬门禁顺序：权限和来源当前有效 → 命题身份与时间适用 → 反证与 suppression → 独立血缘 → 与本次情境的因果相关性 → 已有安排覆盖 → 排序与表达。`factEligible` 可作事实但仍要看本次适用性；`qualifiedAdvice` 只能生成带限定语的建议；`observeOnly` 不进入用户建议；`askWhenRelevant` 仅在当前目标相关且决定下一步所必需时提一个具体问题；`discard` 不存为可用记忆。置信分数只用于同资格候选排序，不可抬升被门禁拒绝的候选。

有三类“未知”须分别记录：身份未知（摩卡是不是宠物）、现实未知（本次是否另有线下安排）、系统覆盖未知（有未扫描数据）。可以在身份未知但责任有证据时建议“核实宠物照护”；现实未知时说“未查到安排”；系统覆盖未知时进一步限定来源范围。不要用一句“可能”掩盖三种不同原因。

### 3.10 后台处理、隐私和性能预算

来源写入先完成原业务保存，观察队列后续异步处理。队列按 `sourceKey + revision` 去重；同一来源新修订到达时旧批次可取消或标过期。处理页只在持久化成功后推进水位；冷启动、断网、模型失败和 CloudKit 合并都能重试。模型抽取仅收到通过权限门禁的最小片段和目的，不接收完整账本。财务金额若与责任无关可省略；展示 evidence 时遵从源记录原有访问控制。诊断使用稳定匿名 ID 和阶段结果，不记录完整原文或敏感账单内容。

R0 先测现有延迟和成本，再冻结预算。Release A 初始上限沿用当前检索器的最多 8 条关系进入规划；单次交互发现性补查与现有原文回退共用 1 次、4 段/8,000 字符；超限按相关性裁剪并记录覆盖缺口。S0 异步抽取沿现有批处理预算与系统后台时机，不为回填常驻唤醒 App。目标是首次卡片延迟相比基线新增 P95 不超过 2 秒、总 P95 不超过 12 秒；若 R0 基线已超限，分别报告基线与增量。Today 页面保持本地只读构建，不在页面打开时触发 LLM。

### 3.11 来源失效、旧客户端和回退细则

新字段必须可选、旧客户端可无损跳过；若旧客户端会覆盖未知字段，须将新载荷置于现有可版本化容器并做跨版本读写回归。源被删除、修订或授权撤销时，先使受影响关系与草案投影 `stale`，停止新使用，再异步重算；已接受任务保留业务状态并给用户编辑/删除路径。缓存的模型答案不能绕过展示门禁。CloudKit 只同步 canonical 来源、用户确认/纠正与必要的可重建关系；后台推断不得制造设备间互相“确认”的证据回路。

若生产出现严重误归属、未经接受创建任务、遗忘后仍显示推断，关对应开关并停止新提案；不回滚/删除用户已接受的 Matter。源处理开关回退后已记录的来源仍归原领域管理，恢复开关时从水位重放；若策略版本变更，旧关系标过期重算。支持按域停用，避免一类导入脏数据拖垮所有领域。

### 3.12 Token 成本门禁：历史回填先改重复传输

截至 2026-09-23 的代码审查，现有萃取每包最多 12 段/12,000 字符，通常先做一次抽取，再对候选做一次核验。当前核验组包使用整页 `sourcesByID`（页大小 50），而非仅本包实际引用的来源；一页拆成多包时，同一页原文会反复发送。抽取又把全部已有 `personalContext` 候选放进每一包 `existingCandidates`，候选越多，每包上下文越大。四域历史数据直接接到现有流程会造成远高于原文量的 token 消耗，必须在 R1 大规模回填前治理。

R0 先用实际生效模型和 Tokenizer，对 100、1,000、10,000 条三档模拟记录分别量测：抽取/核验输入输出 token、包数、重试数、每条记录的增量 token、重复原文比例和既有候选占比；若有真实 `ai_call_logs` 可读，只取聚合用量，不读取个人正文。R1 的硬门禁是：核验只发送本包实际引用的最短原文证据；归并候选用本地检索得到的相关 Top-K（初始上限 20），而非全量已有候选；结构化账单先建本地可查询的商品/备注索引，只有开放语义关系确需判断时才发模型，且以留出集检查不能因此漏掉关键责任；日常来源变更先合并成有界批次，不能每记一笔账就发两次模型请求；记录修订幂等，失败重试复用已完成结果；历史回填按用户当前授权、近期数据和当前事项相关性排序，并受每用户/全局日预算与暂停恢复控制。预算值以 R0 实测和服务容量冻结后写入配置，超额排队，不牺牲用户正在进行的规划。

Release A 的在线目标是：在已有请求框架与方案生成之外，生活关系的本地检索不新增模型调用；发现性补查与原有一次回退共用预算，不能叠成两次；一次正常 Q0 规划的总 token 相比当前规划基线增量 P95 控制在 25% 以内。若用户的当前数据确需原文补查，单独报告“触发补查”的成本，不通过砍掉必要证据伪造达标。Release B 对每个主动触发先本地判断是否有可行动缺口，只对通过门禁且未冷却的事件调用模型；绝不把页面打开或每条账单写入变成规划请求。

## 4. 分阶段交付、文件与门禁

工期为一位熟悉工程的开发者的初估，不等于已有功能或上线日期。每阶段必须提交“代码差异 → 实际运行的测试 → 用户旅程证据 → 未过项”的记录；前一门禁未过不扩大能力。

| 阶段 | 初估 | 开发交付 | 当阶段能宣称什么 | 硬门禁 |
|---|---:|---|---|---|
| R0 基线与夹具 | 3—4 人日 | 冻结 Q0—Q3、原始来源合同、调试追踪；记录当前失败在哪一层；实测 100/1,000/10,000 条 token 放大系数 | 已定位缺口和目标契约 | 单字误召回测试红；证据链可逐层诊断；成本预算已冻结，**不要求尚不存在的全链路通过** |
| R1 四域来源 | 4—6 人日 | 正常数据库接线、修订与变更队列、权限和覆盖统计；先消除核验整页原文与全量既有候选重复发送 | 四域原始线索被可靠读到 | 新增、编辑、删除、恢复、导入、远端合并可重放；背景 token 受预算约束；没有实体/规划承诺 |
| R2 生活关系 | 6—8 人日 | mention/关系提取、五路裁决、代购/同名/过期/纠正/遗忘 | 可形成可追溯的限定责任 | Q0 来源能产生合法责任候选；Q3 不成立；独立血缘正确 |
| R3 影响与计划 | 4—6 人日 | frame、词法修复、责任召回、补查、旧 effect 增量字段、默认卡片 | 原始记录实际改变首次计划 | Q0、Q1 同样补项；Q2 不补；效果和来源在 `MatterPlanLaunchCard` 可见 |
| R4 Matter 延续 | 4—6 人日 | 一次启动回执、覆盖状态、增量提案、纠正/遗忘冷启动 | 可持续推进这一件事 | 完整旅程 Q0 → 接受 → 部分安排 → 增量更新 → 撤销/结束；零未授权写入 |
| R5A Release A 发布门 | 3—4 人日 | 模型留出评测、模拟器/真机、双设备、Prompt 和生产核验 | 仅全部门禁通过后称 Release A 可发布 | 具体结果和未过项分层报告，后端实际部署及真实请求核验 |
| R5B 站内主动 | 4—6 人日 | 明确情境变更触发、Today/Matter 一条建议、更多来源与打扰治理 | 不提问也能收到站内建议 | 弱消费/愿望不触发确定筹备；拒绝和已安排不重显 |
| R6B Release B 发布门 | 2—3 人日 | 主动链路、通知关闭状态、跨域场景、生产验收 | 仅全部门禁通过后称 Release B 可发布 | B 的真机/双设备/生产与限流指标单独通过 |

Release A = R0—R5A，约 24—34 人日；Release B 再加 R5B、R6B，累计约 30—43 人日。以上另留约 20% 集成与模型效果缓冲，具体成本在 R0 实测后调整。Release A 的真实模型、真机与后端验收不能推迟到 B。

### 4.1 必须先读并复用的代码入口

| 绝对路径 | 执行动作 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloPersonalContextRuntime.swift` | R1 将仅 Thought 的 paging/writer 扩为四域；真实源修订查询 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloPersonalContextExtractor.swift` | R1/R2 批处理、组包、证据和版本 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/HoloPersonalContextModels.swift` | 来源/关系载荷，V1 与新字段兼容 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift` | 唯一最终使用裁决；不能另造一套 confidence 决策 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextAccessPolicy.swift` | R2/R3 显式核验当前来源修订和用户控制 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextRetrievalService.swift` | R0 锁定“护照”误召回，R3 修词法/链接/时间窗 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextChatPlanner.swift` | 本地和云端共享 frame；真实 revision map 与 coverage |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextPlanningCoordinator.swift` | R3 影响检索、有限补查、Prompt、返回前验证 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/HoloContextPlanningModels.swift` | 扩展既有 `HoloContextPlanEffect`，Draft 兼容 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextPlanValidator.swift` | R3 校验 effect/item/证据关系 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/Cards/MatterPlanLaunchCard.swift` | R3 默认卡片展示差异与原因，保持一次 CTA |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Data/Repositories/HoloMatterRepository.swift` | R4 原子执行及稳定回执 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Today/HoloTodaySnapshotBuilder.swift` | R5B 只读站内建议、避免焦点重复 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift` | 与后端目的 Prompt 同步和版本管理 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/prompts/defaultPrompts.json` | extraction/verification/request/planning 任务契约 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/prompts/promptRegistry.js` | 后端生效版本；相应云任务协议和配额也要审查 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextSourceReader.swift` | 原文补查的权限、来源与修订边界；避免另造无约束读库入口 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextPlanExecutionAdapter.swift` | 草案到 Matter 的既有适配；增量行为与首启行为保持同一 ID 语义 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/HoloPersonalContextControls.swift` | 用户可控的来源/用途授权、纠正和遗忘边界 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/agent/cloudAnalysisExecutor.js` | 后端结构化规划输入/输出、目的与证据字段透传 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/src/prompts/serverPromptPolicy.js` | 后端 Prompt 用途与版本一致性 |

可能新增的来源注册、变更队列、实体解析和覆盖计算放在 `Services/AI/PersonalContext/`，实际文件名由 R0 冻结。先复用现有类型和仓储；新增文件必须对应明确单一职责。前稿 14.2 的文件名单只是候选，不作为必须逐个创建的检查表。

### 4.2 每阶段按顺序实施的工作包

**R0 基线与契约。** 用真实四域入口或受控导入建立 Q0—Q3 的模拟账号夹具，固定时钟、时区和真实 ID；先跑当前流程并保存“源是否存在、关系是否形成、是否命中、effect 是否保留、默认卡是否显示、接受后是否写入”六段诊断。写三个确定性红测：`护照/照护` 单字交叉、孤立 `linkedContextIDs`、远期旅行错窗。核对在途改动与当前 `HoloPlanningRun` 回退预算，冻结新增字段、覆盖指标、价格/延迟基线和评测样本。在 R0 的结束报告中明确哪些测试预计仍红，不能用四域全旅程未通过否定 R0，也不能把纯文案通过当作能力完成。

**R1 来源与回填。** 建一个统一观察值适配接口，四个领域分别实现“当前记录分页 + 单实体当前修订读取 + 变更监听/重放”。先实现按域水位和幂等，再接保存、导入、删除、恢复和 CloudKit 合并。分批回填老数据，暂停/重启/断网后仍可继续；新写入先于回填到达时按修订择新。每域用至少一个真实实体做“新建→编辑→删除→恢复→另一设备修改”追踪；证明原业务操作未被抽取失败拖慢。

**R2 关系与治理。** 复用现有记忆记录、五路决策、控制面和用户纠正；增加开放的责任/承诺、周期/触发、依赖/资源、约束/可用性、目标/偏好关系。先让“摩卡”只成为待消歧实体，再聚合不同来源支持“可能存在宠物照料责任”；代购、引用朋友、同名咖啡、过期职责构成反证。合并前按 root event 去重，提取失败或来源缺字段时保留未知，不把缺字段补成事实。对每条可用关系完成修订核验、用户纠正和遗忘后的冷启动回归。

**R3 情境影响与首次计划。** 扩 `HoloPlanningRequestFrame` 的用户声明和假设区分；在用户提出离家时生成“日常责任的执行条件变化”检索方向，并用冻结旅行区间查源。修 CJK 字符误召回和无条件 linked 命中；预算内一次发现性补查。按当前安排计算 requirement，再把 `add/adjust/skip/choice` 映射到现有 `HoloContextPlanEffect`，校验 evidence/item 连结，默认 `MatterPlanLaunchCard` 首屏可见个性化变化。Q0 与 Q1 结果在宠物责任上等价，Q2/Q3 无误归属；旧 Draft 仍能读且无来源时仍可显示一般旅行计划。

**R4 Matter 延续。** 首启继续用现有 `launchPlan`，记录 effect→item→真实 Matter/Task/Link ID。后续安排变化只能生成针对已存在 ID 的提案；用户接受才原子提交，失败可重试且不重复。任务完成与现实安排覆盖分开：确认有人负责 1—3 日不等于 4—7 日已解决；用户说“问了朋友”不等于朋友承诺；行程改期使旧提案失效。纠正、来源删除和遗忘后，重新打开聊天、Matter、Today 都不能露出失效的生成断言；已接受任务由用户决定如何处理。

**R5A Release A。** 运行冻结留出集与真实模型，输出逐层失败和成本；做模拟器、真机、冷启动、双设备 CloudKit、旧客户端兼容。若后端 Prompt 或执行器有变化，iOS 后备、后端生效端、版本号和生产镜像必须一致，部署后用真实 Q0 请求验证。仅在所有红线和产品指标通过后开内部灰度，再逐级扩大；每级保留开关和错误恢复证据。

**R5B/R6B Release B。** 仅在 A 已稳定后，订阅有明确影响的情境变更，例如用户已确认行程日期、已接受 Matter 的截止日改变、计划内责任的安排失效。异步生成站内建议；只在可行动、证据当前有效、用户未拒绝且无同义已接受项时展示。Today 最多一条此类建议，Matter 详情展示与本事项相关的原因，点击进入现有草案/增量提案；不在页面打开时现算。弱信号如“想去日本”“买了旅行书”不得自动建旅行 Matter。系统通知保持关闭，若将来开启须单独定义授权、频控、隐私和通知实测。R6B 独立测主动触发、漏报/误报、打扰频次和跨设备状态。

### 4.3 代码工作区和交付边界

截至本方案整理时，`HoloContextAccessPolicy.swift`、`HoloContextPlanRunController.swift`、`HoloContextPlanningCoordinator.swift`、`HoloPersonalContextExtractor.swift` 均有并行在途改动。GLM 开始 R0 时重新查看 `git status --short` 与这些文件的 diff，先合并已有的五路裁决、澄清、运行状态修复，不覆盖他人的未提交工作。方案中的代码路径是当前审查入口，不保证实施当天代码完全相同。

每阶段仅暂存和提交本阶段文件；不要批量暂存整个脏仓库，不自动部署或发布。Prompt 变更必须同时处理 iOS 后备、后端生效文件及版本。若 R1—R4 发现需要改后端，阶段回执明确写“后端改动需要发版/部署后端”；本地通过不代表线上生效。

## 5. 测试、发布与回退

### 5.1 每阶段实际执行的测试

- **R0—R3**：现有 `scripts/run-personal-context-standalone.sh` 能覆盖的纯逻辑就用它；补针对源语义、CJK 误召回、身份合并、修订失效的有意义断言。`Executed 0 tests` 不算通过。
- **R3**：用正常数据库入口建立四域源，分别运行 Q0/Q1/Q2/Q3；收集来源、关系、召回原因、effect、默认卡片截图/状态。只给已加工 `HoloMemoryRecord` 的模型评测不算端到端。
- **R4**：用模拟器、真机分别验收原子启动、真实 ID、冷启动恢复、任务完成/撤销、部分安排、纠正和遗忘；双设备同步单独列证据。
- **R5A/R6B**：至少 40 组独立留出情境，含反事实与无关噪声；报告分子/分母、失败案例、耗时、token 与成本。正式 runner 使用产品同一 Prompt 和配额身份，不追加只在评测中存在的答题提示，也不轮换设备标识绕限额。
- **整体验收**：除旅行/宠物，至少有未见的排班交接、搬家服务、学习时间冲突等关系场景，证明机制可迁移。方案变少或改变做法也计作成功。

发布起始门槛：有效相关补全召回 ≥85%，个人化建议准确率 ≥95%，关键反事实响应 ≥95%，无关噪声稳健 ≥95%；权限/失效/未授权业务写入的确定性红线必须 100% 通过或零事件。R0 在运行留出集前冻结定义和阈值，之后不能降低门槛把失败说成发布成功。

### 5.1.1 固定验收矩阵与成功判定

| 编号 | 数据/输入变化 | 期望的产品行为 | 必须核验的底层结果 |
|---|---|---|---|
| A01 | Q0 + 四域原始数据 | 建议核实旅行期间宠物照护 | 来源→关系→影响→effect→item 全链，且无词面宠物提示 |
| A02 | Q1 加“护照” | 宠物结论与 Q0 相同 | 宠物召回理由不含单字“护/照”重合 |
| A03 | Q2 空宠物源 | 不个人化提宠物 | 无伪造 evidence/effect/任务 |
| A04 | Q3 代购+咖啡+引用朋友 | 不归属用户宠物责任 | 反证压制候选，历史候选 stale |
| A05 | 只有猫粮交易 | 不断言用户养猫，不生成个人化宠物任务 | 弱线索只观察，不能变事实或触发任务 |
| A06 | 只有“给摩卡换水”任务，未完成 | 不说已经照料过，也不定物种 | `businessState` 和身份未知保真 |
| A07 | 同任务已完成+习惯打卡由同一事件派生 | 不算两条独立证据 | `rootEventIDs` 去重 |
| A08 | 想法写“替邻居照顾猫” | 可有责任建议，但不写“你的猫” | 所有权与照料责任命题分离 |
| A09 | “朋友 1—3 号来一次” | 显示覆盖待核实 | 频次未知，未标 `covered` |
| A10 | 明确 1/2/3 每天喂食换水 | 只认前三天这两项有安排，提示 4—7 日 | 维度化覆盖及原任务增量调整 |
| A11 | 朋友尚未回复 | 不标已安排 | `asked` 与 `committed` 不混淆 |
| A12 | 本次 1—7 日每天都有明确安排 | 不添重复照护任务 | `skip` effect 有来源，可解释为什么不添加 |
| A13 | 下次再出远门 | 不沿用上次的人和日期 | 新情境区间重新覆盖核对 |
| A14 | 旅行改期/取消 | 旧提案失效，先重算 | `expectedMatterRevision` 与时间窗门禁 |
| A15 | 删除、编辑、恢复任一关键原始来源 | 建议随当前证据变化 | revision 校验、stale、重算、冷启动 |
| A16 | 用户纠正、遗忘、关闭来源 | 新旧 UI 都不再宣称失权推断 | suppression、展示门禁、历史快照审计 |
| A17 | 权限未知/回填未完成/断网 | 说明已查范围，不编造全库结论 | coverageState 和重试水位 |
| A18 | 连点“开始推进”、杀进程重试 | 只得到同一个 Matter 和真实任务 | 原子事务、幂等回执、无孤儿条目 |
| A19 | 增量接受中途失败 | 原对象保持原状态，可重试 | expected revisions、回滚、同一 action key |
| A20 | 另一设备改源或改任务 | 当前设备不展示旧结论或覆盖别人改动 | CloudKit 合并后失效与冲突处理 |
| A21 | 旧 Draft/旧客户端 | 仍能读取一般计划 | 可选字段与 schema 兼容 |
| A22 | 排班交接/搬家服务/学习时间冲突 | 对未见关系也能增、减或调整计划 | 开放 predicate 与目标条件，非宠物硬编码 |
| B01 | 已确认出行日期变化 | 可提出一次站内增量建议 | 真正 trigger + 当前证据 + 去重 |
| B02 | 只有想去日本/买旅行书 | 不建 Matter、不打扰 | 弱信号无法越过主动触发门禁 |
| B03 | 用户拒绝或已处理 | Today 不反复出现 | suppression、冷却与跨设备状态 |

最少以 A01—A22 作为 Release A 的确定性用例；B01—B03 只在 Release B 验收。每条记录实际 source ID、触发、决策、卡片内容、最终业务对象或未写入证明。遇到模型波动不能只展示成功截图：保留失败响应与执行轨迹，并判断是抽取、关系、检索、规划、校验、UI 或写入哪一层。

### 5.1.2 模型评测口径和红线

R0 冻结至少 20 组开发集和 40 组从未用于写规则/Prompt 的留出情境。留出集至少涵盖正例、空库、反证、含噪输入和其他生活领域；按账号隔离，避免同一原始事件换个句子混入训练和留出。每组原始来源通过正常 Repository 建立，均跑无泄题主问、干扰问、反事实问三种变体，每变体重复 3 次。统计“单个旅程一次输出”而非把同一次输出里的任务条目当独立样本；若比较基线与新版，40×3×3×2=720 次旅程，具体模型调用数按实际记录。

指标按已冻结人工标注的责任/影响项计算：**相关补全召回**＝正确补出的必要个人化项÷应补项；**个人化准确率**＝有源且与情境有关的个人化项÷全部个人化项；**关键反事实响应**＝反证输入中正确撤回或限定的旅程÷全部反证旅程；**噪声稳健**＝加无关词后个人化结论仍正确的旅程÷全部噪声旅程。分母为 0 的子集单列为“不适用”，不可记 100%。有效、弱证据和不可用来源分层报告，单列“误说你养猫”“误说你没安排”“重复建任务”的次数。发布目标沿 5.1 的阈值，另要求权限越界、未经接受写入、用户遗忘后仍展示相关断言、重复 Matter/任务均为 **0**；只要出现一例红线，阻断放量并查根因。

评测时固定 Prompt 版本、模型版本/参数、设备环境、账号数据快照、时间与时区；不在评测请求末尾附加“请记得检查宠物”之类提示。成本记录每个阶段的输入/输出 token、补查次数、后台抽取总量、P50/P95 首次卡片延迟及相对基线新增延迟。阈值若未达标，应收缩灰度或修原因，不能在看到结果后重写分母或把限定语输出算成确定事实命中。

### 5.2 Prompt、灰度与后端

若修改 Prompt，同时更新 iOS 后备模板、后端 `defaultPrompts.json` 和版本；后端源码变更必须经过后端发版才会在线上生效。发布前核对 `/v1/release/status`、`/v1/prompts/meta`、source digest 和一条真正的 Q0 请求，健康检查只证明服务存活。

开关分层为“来源处理 → 关系推断 → 请求内规划 → Matter 增量 → 站内主动 → 系统通知”，上层关掉时已有用户任务仍可读可操作。Release A 先内部影子运行、真实请求、真机和小比例灰度；B 的站内主动另行放量。系统通知保持关闭，后续单独定授权与隐私文案。

任一严重误归属、重复业务写入或遗忘后泄露，先关闭相应的规划/主动开关，停新提案，继续保留已接受的真实任务和用户纠正/suppression。错误来源可按域关闭并重算；不清空用户数据。旧客户端未知载荷无损保留，不得把推断降格为“已确认事实”。

### 5.3 实施者每阶段回执

```text
阶段与提交范围：
用户实际新增的体验：
本阶段业务文件绝对路径：
Q0/Q1/Q2/Q3 和跨领域用例的输入、来源、召回原因、输出：
sourceKey → contextID → effectID → itemID → taskID 的真实链路：
测试命令、执行数量、失败记录和修复：
模拟器 / 真机 / 双设备 / 真实模型 / 后端 / 生产：各自通过或未做：
当前来源覆盖、权限边界、成本和延迟：
开关、迁移、回退和遗留问题：
阶段门禁是否通过：
```

## 6. 可以直接交给 GLM 的执行指令

> 请以本文为唯一下一阶段实施规格。先读适用的 `AGENTS.md`、`docs/standards/Holo-Agent研发与验收规范.md`、`docs/standards/PROMPT_GUIDELINES.md`、`docs/standards/quality-redlines.md` 与当前代码；先查 `git status --short`，不要混入并行会话改动。
>
> 从 R0 开始：冻结 Q0—Q3 四组原始记录夹具和查询输入；为“护照/照护”单字误召回、`linkedContextIDs` 无条件命中、`now+30 天` 错窗写失败定位测试；核对默认 `MatterPlanLaunchCard` 与来源修订门禁；产出实际失败链路和 R1 所需字段合同。R0 不承诺完成四域真实端到端。
>
> 然后按 R1 → R2 → R3 → R4 → R5A 交付 Release A。每次跨阶段必须附 5.3 回执并完成硬门禁。Release B 只在 A 验收后推进 R5B → R6B。旧草案里的“P0 直接跑通全链路”、单个含“护照”的成功示例、另建 `PlanEffectV1` 和只改旧卡片 UI 都已废止。
>
> 东林将本文件交给你时，请按 R0→R5A 实施并逐阶段提交可审查结果；不要把方案文档本身当成已实现或已验收。生产后端部署和对外发布属于独立发布动作，须按项目发布流程执行。
