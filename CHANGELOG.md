# Holo 更新日志

记录 Holo App 的版本更新历史

---

## [2026-07-19] 轻量新人引导 V1：三页引导 + HoloAI 入口提示

新用户首次进入 App 时展示三页轻量引导（认识 Holo → 功能与使用方式 → AI 数据处理授权），完成后在首页底部中央按钮上方出现一次性 HoloAI 入口提示。引导只让用户看懂、会用、敢授权，不在引导内要求完成真实记账或创建数据。

### 变更
- **三页全屏引导**：第一页认识 Holo 并选填昵称（合并移除原首页单独的昵称 Alert）；第二页用三张能力卡说明记录 / 查询 / 回看三种核心用法；第三页讲清 AI 数据处理授权并提供「同意并开始使用」与「暂不授权」两个出口。前两页右上角可直接「跳过」。
- **新老用户规则**：新用户展示；已完成的不展示；旧昵称 onboarding 已完成的老用户自动迁移写入新 completed key 后跳过；DEBUG 截图 / 模拟器验收模式最高优先级跳过。
- **Deep Link 优先**：本次进入首页前存在待处理 Deep Link（小组件 / 外部链接）时本次不展示、不写 completed key，避免拦截用户主动发起的跳转。
- **一次性 HoloAI 入口提示**：引导完成（含跳过）后在底部导航栏中央按钮上方显示单行气泡，点击气泡或按钮进入 Chat，点击空白关闭，仅本次会话出现一次。
- **授权选择**：同意则授予 AI 数据处理授权；暂不授权保持原状态，本地记账 / 待办 / 习惯 / 观点不受影响；隐私政策复用现有 `LegalDocumentSheet`。

### 技术说明
- 仅新增一个 UserDefaults Bool（`holo_onboarding_lightweight_v1_completed`），不引入状态机 / Core Data / CloudKit；AI 入口提示用会话内 `@State` 控制，不持久化。
- 跳过不保存昵称草稿；完成或暂不授权才保存有效昵称。
- 未修改 Chat、IntentRouter、Repository、确认卡片链路、后端网关与 Prompt。

### 验证
- 新增 `LightweightOnboardingSettingsTests`，覆盖新用户展示、completed key 隐藏、旧用户迁移写新 key、Deep Link 不写 key、截图 / 模拟器验收模式跳过（6/6 通过）
- Holo iOS Simulator（iPhone 17 Pro / iOS 26.3）编译通过，并完成新装三页、跳过、昵称留空、授权分支、老用户迁移、浅深色和入口提示单行布局验收

## [2026-07-19] 财务重绘图标融入原有分类

财务图标选择器移除突兀的「财务重绘 / 财务重绘 v4」独立分组，将全部新版图标按语义归入原有分类，找图标时不再需要区分资源版本。

### 变更
- **回归原有分类结构**：选择器继续保留餐饮、交通、娱乐、购物、个人护理、家居、医疗健康、学习成长、家庭人情、生活服务、收入资产、其他 12 个分组。
- **186 个重绘资源语义归位**：新版 Asset Catalog 图标按用途融入对应分组，并优先展示；原有 SF Symbols 继续作为补充选项保留。
- **历史数据零影响**：不修改分类模型、资源名称和已选图标，已有账目与自定义分类无需迁移。
- **资源类型识别修正**：财务 Asset Catalog 图标不再进入 SF Symbol 可解析性校验，测试口径与实际渲染方式保持一致。

### 验证
- 图标目录独立契约校验通过：12 个分组、366 个图标无重复、186 个财务资源无缺失
- Holo iOS Simulator Debug 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-18] 编辑器验收修复：工具栏固定、引用截断、Token 菜单与跳转

### 变更
- **工具栏固定键盘上方**：编辑工具栏（#/@/加粗/图片/列表）从内容区移出，与候选面板一起固定在底部安全区内边，键盘弹出时始终吸附键盘上沿不再被遮挡。
- **@ 引用显示截断**：行内引用 Token 显示文字限制 24 字符，超出以省略号收尾，避免长标题撑破正文行（快照保留完整摘要）。
- **Token 菜单去重**：选区恰好是完整 Token 时禁用系统复制/剪切气泡，点按 Token 只弹自定义「查看/移除」菜单。
- **「查看记录」跳转修复**：NavigationLink 从 NavigationView 外层背景移入内部，点按引用 Token 菜单的「查看记录」可正常跳转到目标想法详情。
- **禁用自动填充菜单**：系统 AutoFill / Writing Tools 菜单不走 canPerformAction 过滤，点按 Token 时会与自定义菜单重叠弹出；编辑器与阅读态统一关闭 writingToolsBehavior 并清空键盘助手栏按钮组。
- **根治自动填充残留**：点按 Token 不再制造系统选区（吸附到较近边缘直接弹自定义菜单），系统编辑菜单失去触发源；拖选恰好覆盖 Token 时通过自定义 UIEditMenuInteraction 返回空菜单兜底。

### 验证
- 新增 2 个截断用例，序列化器套件 17/17 通过
- 全量回归 212 个测试，唯一失败为 main 分支遗留 Chat 用例（与本次无关，昨日已对照验证）
- Holo iOS Simulator（iPhone 17）编译通过（BUILD SUCCEEDED）

## [2026-07-18] 观点编辑器行内 # 标签与 @ 引用

想法正文中的 `#` 和 `@` 从纯文本升级为带唯一 ID 的结构化 Token：输入即弹候选面板，多级标签、引用想法、反向引用全链路落地。

### 变更
- **结构化内容模型**：新增 `HoloContentNode`（text/tag/reference）与 `RichContentSerializer`，`Thought` 新增 `richContentJSON`（Token 事实源）与 `firstLine` 字段；`content` 保留为派生平文本，AI 分类/搜索/卡片等下游零改动。
- **编辑器双层架构**：`MarkdownTextView` 渲染管线改为节点驱动，Token 属性在 Markdown 重渲染中不丢失；节点往返一致性有专项测试守护。
- **# 多级标签**：输入 `#` 或点工具栏按钮弹出候选面板（最近使用/路径匹配/创建新标签，150ms 防抖）；支持 `#工作/Holo/编辑器` 多级路径（路径即名称，逐段归一化）；`ThoughtTag` 新增 `lastUsedAt`。
- **@ 想法引用**：输入 `@` 搜索历史想法（首行/正文/标签，排除当前想法），插入行内引用 Token；`ThoughtReference` 新增首行与摘要快照字段；保存时以结构化内容为准全量重建引用关系。
- **Token 原子化**：光标不可进入 Token 内部（键盘吸附边缘、点按选中整体）、退格一次整删、选区横跨自动扩展、Token 插入/替换为单次 undo 单元；点按 Token 弹出「查看/移除」菜单。
- **标签触发规则收紧**：`#` 仅在文首或空白/换行/标点后触发，URL/单词内的 `#` 不再误识别；提取与触发共用同一套判定。
- **阅读态**：详情页复用节点管线只读渲染，点击标签跳转列表筛选、点击引用打开目标想法；目标已删除时显示灰色「原记录已删除」并可查看历史快照；反向引用列表沿用。
- **路径子树重命名**：标签全局重命名支持整棵子树（「工作」改名同步「工作/Holo」等子路径，目标已存在自动合并）；知识树抽屉路径标签按层级缩进展示。
- **编辑器收敛**：移除独立引用区与手动标签 chip 入口，标签/引用统一走行内 #/@（存量数据兼容，旧正文不自动升级 Token）。

### 验证
- 新增 5 个测试套件 49 个用例全部通过（序列化器 15 + 节点管线 7 + 触发检测 14 + 内联标签/归一化 14 + 富内容仓储 13 中本套件 13）
- 全量回归 210 个测试，唯一失败为 main 分支遗留的 Chat 模块用例（干净 HEAD 对照实验确认与本次无关）
- Holo iOS Simulator（iPhone 17）编译通过（BUILD SUCCEEDED）

## [2026-07-18] 想法知识树固定吸附并统一 AI 分类体验

想法知识树不再随手指横向漂移，打开后稳定吸附左侧；AI 自动分类新增模块内开关，并将高饱和紫色收敛为小型 AI 来源标识，整体视觉重新统一到 Holo 品牌橙色。

### 变更
- **知识树稳定吸附**：移除抽屉整层双向跟手位移，保留遮罩点击和右侧边缘手势关闭，浏览标签树时不再被轻微横向手势带走。
- **AI 自动分类开关**：知识树与全局设置共用同一开关；关闭后新想法不再自动生成 AI 标签，历史标签、手动标签和手动批量整理不受影响。
- **未归类语义保留**：AI 标签分类与主题归纳继续分层，尚未进入主题的想法仍会出现在「未归类」，避免 AI 强行归入错误主题。
- **关闭后仍可补整理**：修正 disabled 状态被排除在手动批量整理之外的问题，用户重新需要 AI 时仍可主动补整理。
- **品牌视觉收敛**：整理按钮、开关、进度状态、主题图标和选中态统一使用 Holo 橙色；AI 标签改为中性卡片，紫色仅保留在小型 sparkles 等来源标识。

### 验证
- ThoughtAIClassificationPolicyStandaloneTests 通过
- Holo iOS Simulator（iPhone 17）全工程编译通过（BUILD SUCCEEDED）

## [2026-07-18] 修复「Apple Health 部分连接」误报并支持点按补权限

无 Apple Watch 用户站立恒无数据、活动分钟兜底已生效时，健康页仍错误提示「部分连接」。修复判定逻辑，并为真正缺权限的场景提供授权引导。

### 变更
- **连接判定修复**：HealthRepository 的连接状态判定从「三项 availability 全为 available」改为「三项指标是否已覆盖」——站立无数据但活动分钟兜底生效（unsupported）时视为已覆盖，无 Watch 用户数据齐全后正确显示「已连接」，「部分连接」提示自动消失。
- **授权引导**：数据源卡片在「部分连接」状态下支持点按，跳转系统设置补全健康权限，并增加 chevron 指示；副标题改为「点按前往设置补全权限」。

### 验证
- Holo iOS Simulator 编译通过（BUILD SUCCEEDED）
- SF Symbol chevron.right 存在性已验证

## [2026-07-18] 健康详情页支持按天切换

步数、睡眠、站立详情页新增日期切换条，与外层健康看板一致：左右翻页查看任意历史日期，非今天时可一键回到今天。

### 变更
- **详情页按天切换**：HealthDetailView 的 selectedDate 改为 Binding，头部新增日期切换条，切换后自动重拉当天数据（含睡眠阶段卡片）与近 7 天趋势。
- **日期状态共享**：详情页与外层看板共用同一份 selectedDate，详情页切完日期返回外层时日期保持一致。
- **组件抽取**：新增 HealthDateNavigator 共用组件，外层看板同步复用，移除重复代码。

### 验证
- Holo iOS Simulator 编译通过（BUILD SUCCEEDED）

## [2026-07-18] AI 回答结论先行，详细分析按需展开

普通提问和深度分析的回答结构统一升级：第一段直接给答案，不再寒暄和复述问题；默认只保留一个主结论和最多三个关键点，想看依据时再展开「详细分析」。

### 变更
- **回答结构升级**：第一段直接回答，不寒暄、不复述；短问题一段自然短文，多主题才用短标题，不再固定套用「事实/变化/模式/建议」全套结构。
- **长度收敛**：普通回答 80-240 字、分析回答 180-320 字；数字只为支撑结论出现，不再流水账式枚举。
- **通用阅读视图**：新增 AIReadableResponseParser / AIReadableResponseView，把 AI 文本解析为导语、段落、小标题、列表等阅读块，排版稳定兜底。
- **Prompt 双端同步**：systemPrompt v3 / analysisPrompt v4，后端以 contract 注入同等阅读规则。

### 验证
- AIReadableResponseParserStandaloneTests 通过
- Holo iOS Simulator 编译通过（BUILD SUCCEEDED）

## [2026-07-18] 聊天页记忆收件箱胶囊，能力入口只在空会话展示

### 变更
- **记忆收件箱胶囊**：Holo 写入记忆后，聊天页顶部出现胶囊提示「Holo 已记住」，点击直达记忆中心，可手动关闭。
- **界面降噪**：快捷能力入口只在空会话展示，进入对话后自动收起，内容与输入框保持安静。

## [2026-07-18] 周历整周共享弹性时间轴

### 变更
- **同一小时七天同高**：新增 WeeklyGridAxisProfile，同一小时在七天内保持同一高度和坐标，跨天对比日程不再错位。
- **布局重构**：WeeklyGridEventLayout 按共享轴重算事件排布，小时高度随事件密度弹性伸缩。

### 验证
- WeeklyGridAxisProfileStandaloneTests 通过
- CalendarEventProviderTests 通过

## [2026-07-18] 看板习惯可撤销今日记录

### 变更
- **计数类 -1 按钮**：误点 +1 可一键撤销今日最近一笔记录。
- **测量类长按撤销**：长按习惯弹出确认框，撤销今日最近一笔；撤销后按「有记录即完成」口径刷新完成状态。

## [2026-07-18] 表单页防误关

记账、新建习惯、新建任务表单统一拦截系统下拉关闭手势，未保存内容不再因误滑丢失，统一走页面内确认逻辑。

## [2026-07-18] 记忆洞察一键追问 AI

记忆长廊洞察卡片的行动建议可直接转成追问：点击后自动带上卡片标题与内容进入 AI 对话，继续深入分析。

### 验证
- MemoryInsightActionPromptBuilderTests 通过

## [2026-07-18] Agent 深度分析适配深色模式

修复 Agent 深度分析详情在 Dark Mode 下仍叠加浅色背景的问题。「查看数据依据」展开区域现在与页面深色层级保持一致，不再出现突兀的灰白卡片和低对比度文字。

### 变更
- **证据卡片动态适配**：数据依据容器改用 Holo 动态卡片色，边框、阴影和折叠按钮随系统外观调整。
- **文字对比度提升**：依据标题、来源数量与折叠箭头在深色模式下保持清晰可读。
- **页面浅色叠层清理**：移除详情页顶部和信号卡片中的固定白色渐变，避免暗色背景被洗成灰白。
- **同类界面复核**：扫描视图与通用组件中的固定浅色容器，未发现第二处同类问题；看板入口保留的白色仅用于品牌按钮高光。

### 验证
- Holo iOS Debug / generic iPhoneOS 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-18] 睡眠详情页展示深度睡眠等阶段数据

睡眠详情页此前只有总时长和 7 天趋势，看不出每晚的睡眠结构。现在支持睡眠阶段的设备（如 Apple Watch）记录的深度睡眠、核心睡眠、快速眼动和清醒时长会直接展示在详情页。

### 变更
- **深度睡眠主视觉**：睡眠详情页新增「睡眠阶段」卡片，深度睡眠以大数值突出展示，并标注占总睡眠的百分比。
- **全阶段一览**：核心睡眠、快速眼动、清醒时长按比例条展示，睡眠结构一目了然。
- **无阶段数据自动隐藏**：数据源只有卧床时间没有阶段细分时，卡片不出现，页面保持原样。
- **AI 对话同源**：卡片与 HoloAI 健康工具共用同一条睡眠明细链路，Agent 本就支持深睡查询（`health.sleep.deep_hours`），无需额外改动。

### 验证
- 主 App xcodebuild 编译通过

## [2026-07-17] 记忆默认生效：普通记忆免确认，健康统计不再误拦

Holo 生成的记忆此前默认进入「待确认」，每条都要手动确认才会参与回答。现在普通记忆通过安全校验后直接生效，只有真正需要你把关的内容（敏感信息、身份档案、人生节点、假设推断、首次跨域结论）才会进入待确认；记忆不准确时随时可以评价、纠正或删除。

### 变更
- **普通记忆默认生效**：领域观察生成的常规记忆（如消费习惯、打卡规律）通过安全校验后自动采用，直接参与 HoloAI 回答，无需逐条确认。
- **确认边界收敛**：仅敏感内容、身份档案、永久事实与人生节点、假设性推断、首次跨域结论保留确认；待确认记忆不参与回答。
- **健康统计放开**：步数、睡眠、站立等客观健康数据不再一刀切视为敏感，默认生效；健康数据的本机敏感存储隔离保持不变。
- **存量记忆自动转正**：策略升级后，此前被误拦的待确认记忆在下次启动时自动重评估并生效；已评价或删除的记忆不受影响。
- **记忆回执胶囊**：个人页顶部胶囊提示「Holo 已记住 / 想和你确认」，点击直达记忆管理，24 小时内最多出现一次。
- **历史候选迁移**：旧长期记忆迁入统一仓库时，未处理的候选按历史迁移自动转正，保留原始时间。
- **记忆实验室反馈**：「运行一次真实观察」运行中显示转圈，结果直接展示在按钮下方，成功 / 未执行原因一目了然。

### 验证
- HoloMemoryActivationPolicyStandaloneTests：16/16 通过（普通健康统计自动采用、五类确认边界保留）
- HoloMemoryCandidateReconcilerStandaloneTests：11/11 通过（误标激活 / 身份保留 / 用户表态不动 / 幂等）
- HoloCrossDomainFusionStandaloneTests：24/24 通过（首次跨域待确认、重复跨域自动生效）
- 主 App xcodebuild 编译通过

## [2026-07-17] 观点标签全局管理（编辑 + 删除）

观点标签此前只能逐条想法管理：AI 打出的碎标签要删几十次，打错的标签名也无法统一修正。现在知识树抽屉的标签支持长按全局管理，一处操作、全部想法生效。主题同样支持长按重命名与删除。

### 变更
- **长按标签管理**：知识树抽屉「AI 标签池」任意标签长按，弹出重命名 / 删除菜单。
- **全局删除**：标签从全部想法上一次性摘除，并写入 AI 拒绝偏好，AI 以后不再推荐该标签。
- **全局重命名**：改名即时生效于全部想法；新名称与已有标签同名时自动合并，同一想法上手动标签优先于 AI 标签，不会重复出现。
- **重命名防分裂**：改名后旧名进入 AI 拒绝偏好，防止 AI 再次打出旧名导致标签池重新分裂。
- **长按主题管理**：知识树抽屉主题长按，支持重命名与删除；删除主题后想法回到未归类，并写入归并拒绝记录，AI 90 天内不会再归纳出同名主题。
- **主题缓存同步**：删除 / 改名 / 合并后，主题的关联标签缓存同步重算，AI 对话不再读到已删除的脏标签名。
- **筛选状态保护**：被删除的标签或主题若正用于列表筛选，自动回到「全部笔记」，不出现空白列表。

### 验证
- ThoughtRepositoryTagManagementTests：13/13 通过（删除 / 重命名 / 合并 / 去重 / 主题缓存重算）
- ThoughtTagManagementServiceTests：3/3 通过（拒绝偏好写入 / 旧名防分裂 / 新名移除）
- TopicRepositoryDeleteTests：4/4 通过（想法回未归类 / 标签关联断开 / 自引用清理 / 返回值）
- 覆盖范围：assignments 迁移来源保留、同想法 manual 优先去重、usageCount 重算、Topic 缓存一致性

## [2026-07-16] 稳定个人状态查询进入 Agent

修复“我最近状态怎么样”同一句需要重复询问多次，才从澄清或普通问答进入 Agent 的问题。个人近期状态查询现在第一次就会直接读取 Holo 数据并进入对应分析，不再依赖模型随机选择路由。

### 变更
- **综合状态稳定分流**：个人近期整体状态直接进入跨领域 Agent 分析，不再追问财务、健康或其他领域。
- **确定性路由保护**：高置信状态问法由服务端规则直接识别，绕过模型意图漂移；重复提问保持一致结果。
- **单领域精准归类**：财务、健康、睡眠、习惯、任务、目标和观点状态查询继续进入对应领域分析。
- **误触发边界**：“你最近怎么样”、天气、Holo 服务状态、自有项目状态和查询执行混合请求不会误入个人综合分析。
- **Prompt v24 双端同步**：后端生效 Prompt 与 iOS 后备 Prompt 使用同一状态查询契约。

### 验证
- HoloBackend：115 tests，115 pass，0 fail，0 skip
- PromptManagerIntentRecognitionTests 真实 Test Target：2/2 通过
- 生产环境同句“我最近状态怎么样”连续验证 20/20 稳定进入跨领域 Agent
- 综合、财务、睡眠表达变体及 4 类反例全部通过；既有记账、待办、健康路由无回归
- HoloBackend 已部署 ECS，生产运行 `intent_recognition v24`

## [2026-07-16] 想法标签并存与卡片快捷筛选

修复想法新增用户标签后 AI 标签在卡片上看起来被覆盖的问题，并让内容标签本身成为快捷筛选入口。

### 变更
- **标签并存展示**：用户标签与 AI 标签同时显示，同名标签自动去重，不再互斥隐藏。
- **卡片点击筛选**：点击想法卡片内的用户标签或 AI 标签，直接筛选对应想法。
- **筛选状态可见**：非常用标签也会在顶部标签栏显示当前筛选状态，便于一键退出。
- **搜索口径统一**：想法搜索与筛选同时识别用户标签和 AI 标签。

### 验证
- ThoughtTagPresentation standalone 测试通过
- Holo iOS Debug / iPhone 17 Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-15] HoloAI 领域记忆与跨域融合升级

HoloAI 新增按模块独立理解、跨模块谨慎融合、按问题精准召回的统一记忆底座。普通用户仍只需要管理“自动形成记忆”和“记忆辅助回答”，内部评分、调度和灰度逻辑保持静默。

### 变更
- **八领域独立记忆**：财务、观点、健康、习惯、任务、目标、对话和个人信息分别提炼；个人信息不会被后台 AI 静默改写。
- **跨域阶段理解**：共同时间、共同主题与独立证据同时成立时，才形成关联；首次未确认候选只临时预览，不把相关性写成因果。
- **精准问题路由**：开放式状态问题读取已整理记忆，明确金额、次数或日期问题继续查询原始明细。
- **动态时间权重**：按最后有效证据时间持续衰减，更新的结论优先参与回答，内部评分不展示给用户。
- **静默运行闭环**：启动、回前台和数据变化会触发轻量检查，完成领域萃取、校验、跨域融合与容量治理；无数据变化时跳过 AI 调用。
- **用户控制与状态可见**：记忆管理外层直接显示“准确 / 不准确 / 已纠正”；反馈可随时修改，不准确记录不会参与回答，但可重新改回准确。
- **单条删除边界**：“不再使用”只删除当前记忆及其证据引用，不写阻止重生的墓碑；之后出现新的有效证据时，Holo 仍可重新形成相似记忆。永久忘记能力继续保留独立的防重生语义。
- **个人页统一入口**：记忆管理与 AI 记忆实验室从设置页迁移到“个人”，普通用户只看到易理解的记忆控制，实验室继续保持 Debug 隔离。
- **开发者真实验收链**：实验室支持手动运行一次真实观察、安全重置当日验证状态，并展示 Signal、Package、AI request、Validator、计划变更、实际提交和最终结果；脱敏回执跨页面保留。
- **稳定调用与契约兼容**：仅观察时间或滚动窗口变化不会重复标脏和消耗调用额度；服务端固定返回的 `requestedActions: null / []` 可正常通过，非空越权动作仍会拒绝。
- **隐私与正式版隔离**：普通记忆可进入 iCloud 私有库，健康派生记忆仅保存在本机；Release 不包含 AI 记忆实验室、敏感 Trace 和内部评分文案。
- **安全灰度**：默认处于 shadow，只生成和统计、不注入普通用户回答；萃取、融合和回答注入可独立熔断。

### 验证
- 20 组 standalone 测试共 349 条 Swift 断言通过，HoloMemoryTool 场景套件通过
- HoloBackend：110 tests，110 pass，0 fail，0 skip
- Holo iOS Debug / Release generic iPhoneOS 全工程编译通过（BUILD SUCCEEDED）
- Release binary 扫描未发现实验室、内部审计、查询模拟器、内部评分或记忆 Prompt 标识
- HoloBackend 已完成 ECS 发版；两类 memory Prompt v1 的公网契约、真实 JSON 候选请求和既有 intent 回归均通过
- 模拟器 `full-chain-v1` 全链路验收 33/33 通过，Mock 数据保留，可继续在模拟器复核
- 记忆反馈专项 standalone 测试 23 条断言通过；准确 → 不准确 → 准确状态可逆，单条删除不写防重生墓碑
- 最新签名 Debug Simulator 包稳定运行，Release Simulator 全工程编译通过；此前模拟器闪退确认为无签名验证包缺少 CloudKit entitlement，并非功能代码或数据损坏
- 回答注入仍保持 shadow，进入内部账号灰度前需完成双真机 CloudKit 与真实指标验收

## [2026-07-14] 记忆长廊深色模式适配

修复记忆长廊日历与活跃热力图在 Dark Mode 下仍使用固定浅色的问题，深色界面不再出现突兀的亮白切换器和浅色日期格。

### 变更
- **日历切换器**：周历/月历、网格/列表两组切换器改用动态语义背景，保留品牌橙选中态。
- **月历色阶**：为 0～4 级活跃度补齐独立深色色阶，日期格、非本月日期和图例随系统外观同步变化。
- **活跃热力图**：最近 13 周热力图补齐 1～5 级深色橙阶，保持现有记录分级和点击交互不变。

### 验证
- CalendarHeatmap Dark Mode standalone 测试通过
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-13] 修复冷启动闪屏问题

去掉 SwiftUI 启动覆盖层（AppStartupSplashView），仅保留系统 LaunchScreen.storyboard 渲染启动图，消除双层渲染造成的闪烁。

### 变更
- **移除 AppStartupSplashView**：该 SwiftUI 视图与 LaunchScreen.storyboard 渲染同一张图片，过渡时产生视觉闪烁
- **简化图片资源**：Contents.json 改为单一 universal 图片，不再区分 1x/2x/3x

## [2026-07-13] 上周洞察改为首页单次胶囊投递

上周洞察生成完成后不再占用 HoloAI 对话页，而是在首页胶囊中单次提醒；点击后立即消费，并直达记忆长廊中对应洞察的展开内容。

### 变更
- **周期口径统一**：周洞察固定分析上一个完整自然周（周一至周日），手动生成、后台补偿与 Push 使用同一时间范围。
- **单次胶囊投递**：首页仅展示上周已成功且未读的洞察，点击即标记已读并移除，不再重复曝光失败态或旧洞察。
- **精准直达**：胶囊与 Push 携带洞察 ID，进入记忆长廊后自动切换到洞察页并展开对应回放。
- **失败自动恢复**：启动、回前台与后台任务均可补偿生成；同一周失败后按 1 分钟、10 分钟最多自动重试两次，历史成功内容不被失败尝试覆盖。
- **生成稳定性**：洞察请求超时放宽至 70 秒，后端输出预算提升至 4096 tokens；空响应或截断响应自动重试一次，仍失败时返回可诊断错误分类和 requestId。

### 验证
- 上周周期与首页单次投递 standalone 测试全部通过
- HoloBackend：106 tests，106 pass
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-13] 上线前敏感信息与内部日志收口

正式版不再向用户提供模型、API Key、温度、Token、Prompt 工坊、Agent 调试等开发配置；Prompt 改由 Holo 后端按业务用途注入，公网 Prompt 与完整运行配置接口已关闭。

### 变更
- **正式版开发能力隔离**：完整 AI/语音配置、Prompt 编辑与测试、Mock Provider 仅参与 Debug 编译，Plus 会员也不会获得这些入口。
- **原始日志默认关闭**：普通账号不再生成或持久化完整 AI 请求/响应；升级时自动清理历史 rawLog、旧模型 Keychain 配置和自定义 Prompt 缓存。
- **仅本人日志权限**：Apple 登录凭证由后端验证，只有服务端白名单中的内部账号获得短期诊断权限；完整日志仅在本人设备保存 7 天，不进 iCloud，退出或权限失效即清除。
- **商店包彻底移除日志**：App Store Release 不编译内部会话交换、日志抓取、日志仓库、日志页面和“查看日志”入口；Debug 与显式启用 `INTERNAL_DIAGNOSTICS` 的内部 Release 继续保留东林真机排障能力。
- **服务端 Prompt 边界**：客户端只提交业务上下文与 purpose，托管 Prompt 永远由后端作为首条 system message 注入；公网 `/v1/prompts*` 不再开放。
- **公网信息最小化**：公开发布状态只保留服务与版本身份，模型、温度、Token、Prompt 版本和数据库状态改为管理员鉴权后验收。
- **用户错误脱敏**：聊天气泡不再展示 provider、model、URL、HTTP 或 JSON 解码原文，详细错误仅进入受控诊断链路。
- **隐私与审核口径对齐**：AI 数据授权页明确说明可能发送的问题文本、业务摘要与语音片段；App 内隐私说明、网页版隐私政策和审核备注同步为真实 Release 行为与实际入口路径。

### 验证
- HoloBackend：101 tests，101 pass
- 后端生产依赖审计：0 vulnerabilities
- iOS 敏感边界 standalone：7 组全部通过
- Holo iOS Release / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）
- Release 产物扫描未发现 Prompt 工坊、模型配置、Agent 调试、Mock 提示或 Prompt 正文特征
- 标准 Release 与 Internal Release 双构建通过；标准包扫描未发现日志入口、内部日志类型、内部接口或内部会话标识，Internal 包确认保留诊断链路

## [2026-07-13] 修复分类管理页二级分类点击无响应

分类管理页中，二级分类行没有点击交互，用户只能通过右滑找到编辑按钮。现支持点击整行直接打开编辑弹窗。

### 变更
- **CategoryManagementView**：`categoryRow` 添加 `onTapGesture`，非系统分类点击即打开编辑 Sheet；右滑编辑/删除和铅笔按钮保持不变。

### 验证
- Holo iOS Simulator 编译通过（BUILD SUCCEEDED）

## [2026-07-13] 修复 Agent 结果返回后当前页面空白

Agent 深度分析完成后，结果卡片现在会在当前 HoloAI 页面立即出现，不再需要退出页面后重新进入才能看到。

### 变更
- **完成状态原子同步**：最终文本、结构化 Agent 结果与元数据可用状态在同一次消息快照更新中完成，避免结果已经保存但界面仍判定为不可渲染。
- **恢复路径保持一致**：前台即时完成与退出重进后的数据库恢复使用同一 `loaded` 状态语义。
- **回归保护**：新增消息完成测试，锁定停止 streaming、Agent 结果写入和卡片可渲染三项状态必须同时成立。

### 验证
- HoloTests 测试 target 编译通过（TEST BUILD SUCCEEDED）
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-12] Agent 深度分析升级为可读答案

Agent 深度分析从“把内部计算结果直接展示给用户”升级为“先回答问题，再解释依据”。针对“最近一个月平均步数是多少？”这类查询，结果会直接显示日均步数、数据覆盖和相关补充，不再出现睡眠主题、内部指标名或重复的“观察 01”。

### 变更
- **直接回答优先**：卡片首屏先给出一句可独立理解的结论，再按需要补充达标情况、趋势和数据覆盖。
- **主题严格一致**：标题由用户问题与确定性指标共同生成，步数问题只显示步数主题，不再套用宽泛的“睡眠与健康数据”。
- **用户语义层**：统一把内部 metric key、工具字段和小数原值转换为自然中文、正确单位与符合阅读习惯的数字格式。
- **去重与降噪**：移除外层、详情层重复的“观察 01”和同义结论；普通数据查询不再强行追加空泛建议。
- **证据边界明确**：展示查询周期、有效记录天数和缺失限制，让用户知道结论基于多少数据得出。
- **稳定降级**：模型输出不完整或不可读时，使用本地已校验指标生成同样可读、完整的确定性答案。
- **Prompt v10**：iOS 与后端同步可读答案契约，禁止在展示文案中泄露内部字段、JSON 或机器表达式。

### 验证
- HealthTool、Agent Runtime、答案展示与旧结果兼容 standalone 回归通过
- HoloBackend：85 tests，85 pass
- Holo iOS Debug / iOS Simulator 全工程测试构建通过（TEST BUILD SUCCEEDED）

## [2026-07-12] 习惯打卡误记撤销

数值型习惯（计数类 +1、测量类记录）误操作后今日进度无法回退的问题修复：今日看板卡片新增撤销入口，计数类误多打的 +1 与测量类输错的数值现在都能一键回退，今日进度自动重算。顺带修复 HabitRepository 缺少 `init(context:)` 导致测试 target 编译失败的历史问题。

### 变更
- **计数类 -1**：喝水/吃药等计数类习惯卡片 `+1` 旁新增 `-1` 按钮（仅有今日记录时显示），撤销今日最近一笔。
- **测量类长按撤销**：体重/血压等测量类习惯长按数值区弹确认，撤销今日最新一笔；若今日仍有更早记录自动回退显示。
- **进度自动重算**：撤销后今日进度按「数值型有记录即完成」语义重算，记录清空则该习惯回到未完成。
- **测试入口修复**：补齐 HabitRepository 的 `init(context:)`，与 Finance/Todo/Thought 等 Repository 一致，恢复 HabitRepository 与 CalendarEventProvider 测试编译。

### 验证
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）
- HabitRepositoryCalendarTests 新增 4 个撤销用例并通过（计数类删最新 / 测量类回退 / 无记录返回 false / 不误删昨日）

## [2026-07-12] 修复 AI 记账分类时段覆盖用户品类映射

用户在分类映射里维护的明确品类映射（如“奶茶→饮品”）会被时段启发式覆盖：只要一级分类是餐饮，就按当前时间重算餐次，导致“奶茶21”在晚餐时段被归到“晚餐”而非用户映射的“饮品”。

### 变更
- **时段化判定修正**：`CategoryCandidateResolver` 新增餐次集合 `mealSlotSubCategories`；`IntentRouter.matchCategory` 用户学习映射分支改为按“映射目标二级是否为餐次（早/午/晚/夜宵）”决定是否按时间重算，不再因一级是餐饮就覆盖具体品类映射。
- **餐次能力保留**：映射目标本身是餐次时（如“吃饭→晚餐”）仍按当前时间动态重算餐段。
- **契约固化**：standalone 测试新增 `testMealSlotSubCategoriesConfig`，锁定饮品/咖啡/零食等品类不属于餐次。

### 验证
- CategoryCandidateResolver standalone 测试通过
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-12] 财务长期成本管理

新增“长期成本”入口，统一管理周期性支出与一次性购买，让日常账本之外的订阅承诺、耐用品成本和到期自动记账可以持续追踪。

### 变更
- **周期自动记账**：支持月度/年度项目、无限期/结束日期/总周期数；后台任务与前台补账使用同一幂等规则，不重复生成流水。
- **一次性购买**：可记录购买日期、金额和分类，按购买日至今天的自然日数计算日均成本，并支持后续编辑。
- **财务分类复用**：长期成本项目直接选用财务二级分类，复用现有分类图标资源；历史无分类项目回退为中性购物袋图标。
- **Holo 视觉统一**：总览、详情和编辑页统一为 Holo 背景、卡片和主色层级，移除系统默认列表风格。
- **安全删除**：删除项目保留既有账本流水，并调整导航与 Core Data 的删除时序，避免已删除对象参与视图渲染。

### 验证
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-12] 修复 Agent 查询完整性与睡眠质量分析

Agent 查询链路从“拿到一个数字就生成观察”升级为按用户问题完整规划、确定性计算并逐项回答；睡眠质量会依据 HealthKit 实际能力完整分析或诚实降级。

### 变更
- **睡眠完整数据**：按起床日读取深睡、核心睡眠、REM、清醒、在床、睡眠效率、入睡/起床时间、夜间中断与作息波动，避免跨午夜记录被拆分。
- **能力降级**：设备没有睡眠阶段时明确说明只能评估睡眠时长，绝不把单一时长包装成完整睡眠质量。
- **健康专属兜底**：固定输出平均睡眠、有效晚数、低于 6 小时晚数和上期变化，并组合全部相关指标与证据。
- **多指标完整回答**：模型只回答部分子问题时，Runtime 自动用已校验的确定性指标补齐遗漏项。
- **自然日日均**：动态 DSL 新增 `perDay` 安全派生算子，“最近十天总支出和平均每天支出”使用十个自然日作为分母。
- **结果页语义**：健康查询使用健康专属标题；裸数字带指标名、单位与覆盖率；无数据展示缺省态；有数据依据的查询不再强行显示空泛“下一步”。
- **Prompt v9**：iOS 与后端同步完整子问题规划、睡眠质量边界、自然日日均和查询建议约束。

### 验证
- Health、Finance、Local Agent Runtime standalone 回归通过
- HoloBackend：85 tests，85 pass
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-12] 财务分类图标与科目体系升级

接入财务图标 v4 全量资源，统一替换一级分类和二级科目图标，并补齐 v4 清单中的新增默认科目。

### 变更
- **一级分类图标**：新增 13 个支出/收入一级分类矢量图标。
- **二级科目图标**：接入 v4 清单中的 161 个二级科目资源，按父级分类保持独立映射。
- **默认科目补齐**：新增餐饮、交通、购物、娱乐、居住、医疗、学习、人情、其他及收入分类下的 v4 科目。
- **历史数据兼容**：新增 v6 分类图标迁移，已安装用户的默认分类自动切换；用户自定义分类保留原图标。
- **规格保持**：继续使用矢量资源、透明背景、模板单色渲染和现有显示尺寸。

### 验证
- v4 资源契约检查：174/174 资源存在且已接入选择器
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-12] 修复财务统计总览图表显示

修复统计分析总览图在收入与支出同时存在时自动堆叠、首个柱形贴边裁切，以及余额折线平滑插值产生虚假峰谷的问题，恢复为可正常阅读的收支趋势图。

### 变更
- **收支柱并排显示**：按日期和类型分组，收入、支出不再堆叠遮挡。
- **余额线稳定显示**：改用线性连接，避免曲线过冲制造不存在的数据波动。
- **图表边界修复**：X 轴首尾增加绘图区留白，避免首尾柱形被裁切。
- **回归保护**：补充余额缩放的恒定值测试。

### 验证
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）
- 针对性测试构建完成；测试运行器在 App 启动阶段异常退出，未进入测试用例执行

## [2026-07-11] Holo Agent 动态查询 Phase 3-4：全域目录与统一查询入口

Agent 的动态查询能力从财务、健康扩展到 Holo 全部 10 个用户数据域。确定数字查询与深度分析统一进入同一个 Agent 规划入口，固定 query 只作为兼容快捷模板和 Feature Flag 降级路径，不再限制长尾指标能力。

### 变更
- **全域动态目录**：新增习惯、任务、目标、观点、Memory、Insight、Profile 与受控对话元数据目录；连同财务、健康覆盖全部 10 个用户数据域。
- **统一能力装饰器**：保留原工具名称、权限和固定 query，通过统一装饰器接入同一套计划校验、行数据适配、确定性计算与证据生成逻辑。
- **统一查询入口**：动态能力开启时，`flexible_data_query` 与 `query_analysis` 均进入本地 Agent；关闭开关时继续回退旧执行器，旧持久化结果保持兼容。
- **目录覆盖契约**：生产启动同时校验 10 个工具与 13 个必需动态数据集，未来新增数据域未注册时在开发阶段直接暴露。
- **隐私边界**：对话域只公开 role、intent、timestamp 等元数据，不提供历史消息原文；Profile、Memory、Insight 继续按敏感证据裁剪。
- **默认启用动态计划**：动态查询默认开启，仍保留 UserDefaults 灰度开关用于紧急降级。
- **Prompt v8**：iOS 与后端同步全域动态规划、统一查询入口和对话隐私约束。

### 验证
- Cross Domain / Dynamic Decorator / Tool Registry standalone 回归通过
- HoloBackend：85 tests，85 pass
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-11] Holo Agent 动态查询 Phase 2：受控跨域关联分析

Agent 可以按自然日对齐健康与财务、健康与习惯、任务与习惯、目标与任务数据，现场计算相关性、条件均值和分组差异，不再依赖预先写死的跨域指标。

### 变更
- **受控跨域计划**：`crossDomainPlan` 已开放健康 × 财务、健康 × 习惯、任务 × 习惯、目标 × 任务，禁止任意 join 和未注册字段访问。
- **任务与目标日序列**：新增每日完成任务数、高优任务数和活跃目标关联任务累计进度；无任务日明确补零，避免只在完成日对齐造成样本偏差。
- **确定性关联计算**：设备本地完成 Pearson 相关系数、条件均值和分组对比，并保留两侧来源记录 ID、公式、覆盖天数与缺失警告。
- **非因果边界**：工具结果和 Prompt 均明确只能表达“相关/同时出现”，不得将关联解释为因果。
- **稳定失败处理**：对数据对齐天数不足、非法数据域组合、字段缺失和计划超限返回明确错误，不生成空洞洞察。
- **Prompt v7**：iOS 与后端同步四类跨域工具选择、计划格式、字段语义及安全边界。

### 验证
- Cross Domain Tool 与 Response Parser standalone 回归通过
- HoloBackend：85 tests，85 pass
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-11] Holo Agent 动态查询 Phase 1：财务与健康现场计算

Agent 不再只能从固定 query 和预定义指标中选择。新增本地数据目录、受控查询 DSL 和确定性计算引擎，模型负责规划，设备负责读取原始记录与计算，所有结果携带公式和来源记录后再进入证据校验。

### 变更
- **动态数据目录**：公开财务交易与睡眠、步数、站立、活动的字段、类型、单位、权限和最大范围，不向后端发送完整原始数据。
- **安全计算 DSL**：支持筛选、日/周/月/周末/字段分组，count/sum/average/min/max/distinctCount，以及差值、比例、变化率、趋势和覆盖率。
- **长尾现场计算**：支持“低睡眠天数占比”“周末平均步数”“麦当劳平均每顿”“环比增长最高分类”等未预定义 metricKey 的组合问题。
- **证据可追溯**：动态指标持久化计算公式和来源记录 ID；模型心算值与本地结果不一致时由 Claim Verifier 拒绝并使用确定性结果兜底。
- **灰度与兼容**：旧固定 query 保留为快捷模板；动态目录通过独立 Feature Flag 暴露，计划失败最多修正一次。
- **Prompt v5**：iOS 与后端同步动态查询规则、字段值格式和安全边界。

### 验证
- Health、Finance、Response Parser、Tool Registry、Local Agent Runtime standalone 回归通过
- HoloBackend：85 tests，85 pass
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-11] 修复 Agent 健康结论被误判为空，并重做空结果缺省态

健康工具此前返回了平均睡眠、日均步数等汇总指标，却只保存逐日明细证据，字段不一致导致可信度校验把有效结论和本地兜底同时拒绝。现在睡眠、步数、站立、活动、运动都会为每个汇总指标生成一一对应的可核验证据。

同时重做深度分析空结果体验：不再展示“这段时间有几个信号”“观察 01”等伪内容，改为带缺省图的明确说明“这次没有形成可信结论”。

### 验证
- 健康工具全指标 standalone 回归通过
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

## [2026-07-11] 观点标签统一识别：AI 优先复用用户认可标签

AI 给想法打标签时，现在能平等识别并优先复用全部「用户认可的标签」（手动打的、正文 # 提取的、用户确认过的 AI 标签），不再只参考「按用量前 20」导致手动标签被挤掉、不停造同义重复标签。

### 变更
- **新取数 `fetchUserRecognizedTagNames`**：DB 层用 SUBQUERY 取所有存在 `source ∈ {manual, inline, confirmedAI}` 分配记录的标签，保证用户手动建/确认的标签全量进入 AI 视野。
- **`organizeThought` 接入新取数**：替换原 `getRecentTagNames(20)`（按用量取前 20、不分来源，手动标签被高频 AI 碎标签挤出）。
- **prompt v2（双端同步）**：「参考已有标签风格」（软引导）→「能准确描述的必须复用，不要生成同义重复」（硬引导）；同时去掉客户端早已丢弃的废弃输出字段 `topicCandidate` / `matchedTopicId`，聚焦标签任务、省输出 token。
- **数据模型零改动**：`ThoughtTag` / `ThoughtTagAssignment` 已满足，纯取数 + prompt 层优化。

### 验证
- Holo iOS（generic/iOS Simulator）编译通过（BUILD SUCCEEDED）
- 后端 prompt 已部署 ECS 并验证：`/v1/prompts/thought_organization` 含「必须复用」、旧字段已清

### 范围
- 本次只做「统一标签池 + AI 平等识别」地基；7 领域大类、语义匹配（认得「工作」=「工作事业」）、Topic 层级重构留待后续立项。

### 部署备忘
- ECS（国内）git 拉 GitHub 超时（GnuTLS -110）→ 改用 scp 直传 `defaultPrompts.json`
- buildx/buildkit 镜像存储隔离看不到本地 base 镜像 → 改用 legacy builder（`DOCKER_BUILDKIT=0`）

---

## [2026-07-11] 补齐 HoloAI Agent 全数据覆盖与健康全指标读取

把 Agent 从 7 类工具扩展为 10 类用户语义工具，解决“健康页有步数/站立，但 HoloAI 只能读睡眠”的断点，并补上预算、账户、观点 Topic、Profile、近期对话意图和 Memory Insight。

### 变更
- **健康全指标**：新增综合健康、步数、睡眠、站立、活动分钟、运动会话 6 类查询，输出聚合指标与逐日证据；统一 Agent 半开时间范围与 HealthKit 包含结束日的边界，避免跨月多算一天
- **核心数据补齐**：财务新增预算状态与账户净资产；观点新增 Topic/归并主题；新增 Profile、受控对话元数据、近期观察 3 个独立工具
- **隐私分层**：健康、Profile、对话元数据、洞察和观点证据按敏感数据标记；不向模型暴露历史聊天原文、附件二进制、内部任务/缓存/日志
- **证据归因修复**：10 类工具统一映射真实来源，修复 goal/thought 此前落成通用 agent 来源的问题
- **覆盖防回退**：生产注册表加入 10 类工具覆盖契约；Agent prompt 双端升级为 v4，明确健康及新增工具的选择规则

### 验证
- 10 类工具 standalone 测试全部通过
- Tool Registry、Tool Executor、Local Agent Runtime 回归通过
- HoloBackend 全量测试：85 tests，85 pass，0 fail
- Holo iOS Debug / iOS Simulator 全工程编译通过（BUILD SUCCEEDED）

### 报告
- `docs/_common/plans/2026-07-11-Holo-Agent数据覆盖排查报告.md`

## [2026-07-11] 系统性修复 HoloAI 灵活账单查询的时间、计算与明细一致性

修复「最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱」出现错误日期、统计范围不可信，以及“查看全部”混入 5 月历史账单的问题。

### 变更
- **明确时间优先**：用户说“最近一个月/近一个月/近30天”时，统一按含今天的最近 30 个自然日计算；“本月/上个月”按自然月计算，并覆盖模型返回的冲突日期
- **非法日期阻断**：Planner 与 Executor 共用严格 `yyyy-MM-dd` 解析，`2026-02-31` 等日期直接拒绝，不再因解析失败静默退化成全历史查询
- **完整集合计算**：移除 200 条粗筛上限；顿数、总金额和平均每顿金额始终基于全部命中记录，卡片 20 条限制只负责预览
- **查询范围与数据跨度分离**：回答和卡片展示实际执行的查询范围，不再把“命中记录恰好落在哪几天”冒充用户查询范围
- **查看全部同源**：结果持久化完整交易 ID 快照，详情页按快照精确加载，不再只拿“麦当劳”关键词重新搜索全历史；旧消息只展示当时保存的明细并明确标注
- **后端能力归主线**：合入专用 `flexible_query_planner` 路由、独立 token 预算与 intent v23 单动作约束，避免同一问题被拆成多条 action

### 验证
- HoloBackend 全量测试：85 tests，0 failures
- HoloTests 全量回归：116 tests，0 failures；新增 12 项一致性测试与既有 3 项查询卡片测试均真实执行
- Holo iOS generic device 目标完整编译通过；原本未接入 target 的 `FlexibleQueryChatCardDataTests` 已补齐工程接线

---

## [2026-07-11] 修复「编辑想法」看不到 AI 归类标签

AI 自动打的标签在「编辑想法」页的标签栏里显示不出来。

### 变更
- **根因**：`ThoughtEditorView.loadEditingData` 仅用 `thought.tagArray`（手动标签，`tags` 关系）回显，对 AI 标签（`ThoughtTagAssignment`，来源 `ai`/`confirmedAI`）完全无感知。详情页已分「标签」+「AI 归类」两区正确展示，编辑页却漏了 AI 那一套。
- **只读回显**：编辑页加载时额外调用 `fetchVisibleAIAssignments`（与详情页同源）取 AI 标签，在「标签」区下方新增「AI 归类」区域——灰色 chip + AI 角标，视觉与列表卡片、详情页一致，**只读**。
- **保存逻辑零改动**：AI 标签只进展示态 `aiAssignments`，不进 `selectedTags`，`update()` 仍只处理手动标签，避免 AI 标签被误存为手动标签或被误删；变更检测（`hasUnsavedChanges`）同样不受影响。

### 验证
- Holo iOS（generic/iOS Simulator）完整编译通过（BUILD SUCCEEDED）
- 手动验证路径：详情页可见 AI 归类标签的想法，进编辑页现在也能看到

### 备注
- AI 标签在编辑页暂为只读（保留/拒绝仍去详情页）。编辑能力计划与「二次分类」一起设计，避免「在编辑页删 AI 标签」的语义歧义导致返工。

---

## [2026-07-10] 修复 HoloAI「返回首页再进入」深度分析/查询被误判中断

发送问题后**立马返回首页、再立马进入 HoloAI**，AI 直接显示「抱歉，处理时意外中断了」，但 AI 其实仍在后台正常计算。

### 变更
- **根因（孤儿清理竞态）**：页面进入时的孤儿 streaming 消息清理（`cleanupOrphanedStreamingMessages`）在 AI 任务结果落盘前就已执行——此时 `syncRecoverableChatMessages` 读不到关联 job，该消息不在 preserve 集合，被当成「App 崩溃残留」清理成中断文案。深度分析 job 在 Coordinator 意图识别（LLM，数秒）后才落盘；商户查询消息则根本不关联 agent job，更易被误杀。
- **宽限期保护**：给孤儿清理加宽限期（对齐 Agent normalDeep budget 120s + 安全余量 = 180s），近期创建的 streaming 消息即使读不到关联 job 也保留，留给后台 runLoop / 查询执行推进；超期真孤儿（App 崩溃残留）仍正常清理。
- **顺带修复 snapshot 连带误清**：原内存 snapshot 刷新会连带把宽限期内消息状态清成中断，改为只刷新实际被清理的消息。
- **可测性**：`cleanupOrphanedStreamingMessages` 新增 `now` 参数（默认 `Date()`），支持注入时间验证近期 / 超期场景。
- **回归测试**：新增 3 项（近期保留、超期清理、preserve 保护），并显式加入 HoloTests target。

### 验证
- Holo iOS 模拟器（iPhone 17）完整编译通过
- 新增 3 项回归测试全部通过，现有 `ChatMessageRepositoryCacheRecoveryTests` 无回归

---

## [2026-07-09] HoloAI 商户消费查询改为确定性计算

修复「最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱」这类基础聚合查询被错误包装成生硬深度分析、没有直接回答数字的问题。

### 变更
- **直接回答三个数字**：同一结果同时展示消费顿数、总金额和平均每顿金额；次数与均价使用用户原话对应的「顿 / 次 / 笔」单位
- **确定性本地规划**：字段完整的商户次数 + 总额 + 均价查询直接生成查询计划，由本地账单执行器计算，不再依赖模型临场算术
- **上游不再拆单**：意图 Router 将同一批账单的次数、总额和均价固定识别为一个 `single_action` 查询，并兼容实际返回的 `categoryCandidate` 商户字段
- **独立后端规划通道**：未命中本地快路径的灵活查询使用专用 `flexible_query_planner` 路由、稳定 JSON 输出和独立 4096 token 预算，不再复用普通聊天链路
- **自然化结果页面**：标题改为「近30天『麦当劳』消费结果」，通用「观察 01」改为「账单结果」，商户查询隐藏与问题无关的通用「下一步」
- **查询口径保持完整**：总额、次数和均价基于全部命中记录计算，20 条限制只作用于账单依据预览

### 验证
- Holo iOS Debug 真机目标完整编译通过
- HoloBackend 全量测试通过：85 tests，0 failures

---

## [2026-07-09] 修复 HoloAI 本周观察关闭与重试无响应

治理 HoloAI 顶部「本周观察」失败卡片的阻塞态：关闭立即生效，重试提供明确进度并防止重复请求，同时把空响应、非法 JSON 和内容不完整分开提示。

### 变更
- **关闭立即生效**：用显式卡片交互状态替代未被视图读取的版本计数；点击 × 后当前页面立即隐藏，并保留「当天不再显示」规则
- **重试可感知、可恢复**：点击后立即显示「正在重新生成…」，防止连续点击重复发起任务；成功后原地刷新观察，失败后恢复重试按钮并展示可读错误
- **错误不再静默**：移除重试链路中的 `try?`，确保生成错误能回到卡片状态，而不是按钮点击后毫无反馈
- **解析失败分类**：区分 AI 空响应、非法 JSON、Schema 内容不完整；UI 不再展示截断的模型原始响应，减少含糊报错与潜在隐私噪声
- **回归测试接入工程**：新增卡片状态 4 项测试与响应解析 3 项测试，并显式加入 HoloTests target，避免再次出现 `Executed 0 tests` 的假通过

### 验证
- iPhone 17 Pro 模拟器定向测试通过：7 tests，0 failures
- `xcodebuild build -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` 通过
- 扫描 HoloAI 同类用户触发异步入口；聊天发送、确认卡片与语音输入已有失败反馈，本次未扩大到非阻塞的后台/删除流程

---

## [2026-07-07] 周历网格布局优化（凌晨折叠 + 多模块纵向堆叠）

优化记忆长廊周历网格的密度与可读性：默认收起 0:00-6:59 低频时段，主时间轴从 7 点开始；同一小时内多个模块不再左右挤压成省略号，改为按模块纵向堆叠占满列宽，明细进弹窗查看。

### 变更
- **凌晨时段折叠**：`WeeklyGridView` 默认折叠 0:00-6:59（可手动展开，状态持久化于 `holo.memoryGallery.weeklyGrid.collapseMorning`），主时间轴从 7 点开始，底部补「24」边界标签；移除旧的凌晨空白 bucket，减少无效占位
- **多模块纵向堆叠**：`WeeklyGridEventLayout` 新增 `DisplayItem` 与 `displayItems`，同一小时内多模块按模块纵向堆叠并占满列宽（不再左右分 lane 挤压），堆叠时显示「模块名 +N」摘要、点击进弹窗看明细；单模块拥挤仍以胶囊表达
- **布局行为测试**：`CalendarEventProviderTests` 补 3 个用例——同一小时多模块合并为模块摘要、单模块保持自然胶囊、0..<7 折叠后 7 点起展示

### 验证
- 新增 `CalendarEventProviderTests` 三个用例，覆盖凌晨折叠与多模块纵向堆叠的布局行为

---

## [2026-07-07] HoloAI 本周观察：首页胶囊统一入口 + 洞察分级 + consent 最终防线

实现「本周观察首页胶囊与 Push 方案」（最终实施方案见 `docs/_common/plans/2026-07-07-Holo本周观察-最终实施方案.md`）。把首页顶部提醒胶囊升级为统一入口，承载 HoloAI 本周观察的唤起与新用户洞察养成。观察产物复用现有 `MemoryInsight(periodType:.weekly)`，分 3 天轻量版（light3d）与 7 天完整版（full7d）；Push 整体 defer 到 V1.1。

### 变更
- **consent 最终防线（Phase 0）**：`MemoryInsightService.generateInsight` 入口加 AI 数据处理授权检查，一处覆盖全部 8 个调用入口（手动 / Chat 意图 / 后台日周月 / 前台补偿日周月），未授权抛 `aiDataProcessingConsentRequired`；手动入口显示授权引导而非 `.failed`，后台/前台静默跳过。修存量「未授权时靠底层兜底显示请稍后重试」的同类 bug
- **observationStage 字段 + 去重修复（Phase 1）**：MemoryInsight 加 `readAt`/`snoozedUntil`/`hiddenUntil`/`observationStage` 4 字段（自动轻量迁移）；`fetchRecentReadyInsights` 接入 stage 过滤，修复 light3d 被算作 full7d 相似历史、导致 full7d 复用不生成的去重陷阱
- **有效记录日 builder（Phase 2）**：新建 `EffectiveRecordDayAggregator`（纯逻辑）+ `EffectiveRecordDayService`（缓存 + 通知驱动），跨 Finance/Todo/Habit/Thought 按天聚合去重，窗口级 ≥2 模块门槛（G6）；首页 onAppear 命中 UserDefaults 缓存不全表扫
- **首页胶囊排序层（Phase 3）**：提取 `ScheduleRanker`（业务优先级 + 稳定 tiebreaker），weeklyObservation 给独立 P0（newInsight），不再硬编码 `.pending`；24h 保护期 + 曝光限频持久化（currentState 变化口径）；新增 `buildWeeklyObservationCandidate` 承载养成/授权/未读/失败状态
- **生成时机接入（Phase 5）**：后台/前台 weekly 生成改为基于有效记录日 eligibility 决定 light3d/full7d，禁用 `effectivePeriodRange.minDays`，养成期不伪造洞察
- **卡片与兜底（Phase 4/6）**：light3d 承诺文案合规（不冒充完整周报）；修 `MemoryInsightHeroCard` `.needConsent` 错绑 `onGenerate` 的 bug，改跳 AI 设置授权入口
- **ChatView 本周观察区块（Phase 4/6 扩展，决策 1A/2A）**：ChatView 顶部新增 `WeeklyObservationCard`（复用 HoloAI 卡片视觉），承载养成/授权/未读/失败状态；未授权态作为正式版统一授权入口（复用 `.aiSettings` sheet，不受 `#if DEBUG` 限制）；新增 `MemoryInsight.markRead` 回写——卡片展示即视为已读，首页胶囊不再顶置同条观察（方案 §7.5）
- **验收修复**：① 首页胶囊与 ChatView 卡片统一取「最新一条 weekly 观察记录」（`fetchLatestReadyInsight`），修两边查询范围不一致导致卡片查不到胶囊看到的记录；② 卡片有观察记录即展示（已读可回看）；③ 卡片右上角 × 关闭（当天不再显示）+ 失败态显示报错详情 + 「重试」按钮直接重新生成

### 验证
- `xcodebuild -scheme Holo build` 通过（iPhone 17 系列模拟器）
- 核心纯逻辑 standalone test 全绿：`EffectiveRecordDayAggregator`（23 断言：同天去重 / G6 单模块门槛 / light-full 达标 / 未来日期排除）、`ScheduleRanker`（12 断言：P0 压过 P1 / 稳定 tiebreaker / 保护期）

### 后续
- Phase 7 App Store 合规（东林暂缓，上架前手动）：隐私问卷勾选第三方 AI 出站处理 + Review Notes + Xcode 核实 Health/Microphone usage description

---

## [2026-07-06] 修复 HoloAI 发送按钮静默失败与输入草稿丢失

修复 App Store 合规批次后 HoloAI 对话出现的两个回归（未授权时点发送无提示、退出界面未发送内容丢失），并清理 Debug scheme 中错误指向本地后端的环境变量。

### 变更
- **发送按钮静默失败**：AI 数据处理授权未开启时，`sendMessage` 原先静默 `return`，且提示写进聊天界面全程不渲染的 `errorMessage`。改为触发 `showConsentPrompt`，由 `ChatView` 弹 alert 明确提示「需要开启 AI 数据处理授权」，并提供「去开启」按钮一键跳转 AI 设置页授权开关（不依赖 DEBUG 齿轮，正式版也可达）
- **输入草稿持久化**：`ChatViewModel.inputText` 增加 `didSet` 实时写入 UserDefaults（`holo_chat_inputDraft`），`init` 时读回。退出界面再回来自动恢复未发送文字；发送成功后 `inputText` 置空会自动清空草稿
- **清理 Debug scheme**：移除 `LaunchAction` 中错误的 `HOLO_BACKEND_URL=http://localhost:8788` 环境变量，避免本地后端未启动时 App 连不上、回退到代码默认的线上 `https://api.holoapp.cn`

### 验证
- `xcodebuild -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build` 通过

---

## [2026-07-06] App Store 上架隐私口径、AI 授权与 ASO 文档准备

为 App Store 首版提交补齐隐私合规口径、AI 数据处理授权门禁和 ASO 元数据草稿，避免“未授权上传 AI/语音数据”或“隐私政策与真实后端行为不一致”影响审核。

### 变更
- 统一网页版与 App 内隐私政策：明确 Holo 不主动保存用户发给 AI 的原始请求正文、语音音频或完整上下文作为用户资料；服务安全、限流和排障会保留最小化技术日志或摘要并按后台配置清理
- 明确 HealthKit 数据边界：Holo 只读展示 Apple Health 授权数据，不会将 HealthKit 原始健康数据写入或同步到 Holo 的 iCloud 数据库
- 新增 AI 数据处理授权开关：用户未开启授权前，HoloAI 聊天、AI 解析/洞察和语音转写请求会在本地拦截，不上传到 HoloBackend 或第三方 AI/ASR 服务
- 新增 AI 数据处理授权持久化与功能开关测试，覆盖默认关闭、授权/撤销和 feature flag 读取
- 新增 `docs/app-store/` 上架材料：App Review Notes、ASO 元数据草稿、截图建议、Support/Privacy URL 待办和 preflight 缺口报告
- 按 ASO 策略重写 App 名称、副标题、宣传文本、描述和 100 字符以内关键词字段，避免重复标题/副标题关键词和第三方 AI 品牌词

### 验证
- `plutil -lint` 校验 PrivacyInfo、entitlements 和 Info.plist 通过
- AI 数据处理授权 standalone 测试通过
- `xcodebuild ... -configuration Release -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build` 通过

---

## [2026-07-06] 记忆长廊日历视图复刻与 Holo 化修正

基于真机效果对齐设计稿方向，压缩首屏控件密度，并把周历/月历从“数据日历”拉回更符合 Holo 的记忆长廊表达。

### 变更
- 压缩记忆长廊顶部 Tab 与日历首屏间距，周历默认切到网格视图，减少进入日历后的操作成本
- 月历默认使用热力视图并补充图例，弱化首屏筛选/样式控件，让月份概览更接近设计稿
- 周历网格改为 6:00-23:00 时间轴，增加星期头、当前时间线与模块图例，事件卡片按时间定位
- 修复周历同时间/近时间事件重叠：同一时间簇自动拆成并列 lane 展示
- 修复深夜/凌晨记录的误导呈现：凌晨事件进入独立「凌晨」提示带，不再被夹到 6 点附近
- 新增轻量「观察摘要」：本地规则从模块集中度、峰值日期、夜间记录等角度生成可信观察，不阻塞首屏加载

### 验证
- `xcodebuild build -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination "generic/platform=iOS Simulator"` 通过
- `git diff --check` 通过
- 定向 `CalendarEventProviderTests` 可编译，但当前 Xcode test action 仍显示 `Executed 0 tests`

---

## [2026-07-05] 记忆长廊日历视图 P2+P3（筛选/维度/网格/色块形式 + 观点呈现）

P1 闭环后，P2 增强日历交互，P3 补充观点间接呈现。

### P2 变更
- **模块筛选栏**（`CalendarFilterBar`）：全部 + 4 模块 chip，按模块过滤事件（`ViewModel.moduleFilter`）
- **待办时间维度切换**：`TodoRepository` 加 `getTasks(field:from:to:)` 支持 `completedAt`/`dueDate`/`plannedDate`；`Provider.fetchEvents` 加 `todoDimension` 参数；UI 切换器（筛选含待办时显示）
- **周历网格视图**（`WeeklyGridView`）：7 列 × 24h 时间轴，事件按 timestamp 定位；周历列表/网格切换（`WeekViewMode`）
- **月历色块形式切换**：`MonthCell` 支持 `heatmap`（热力色深，默认）/ `badge`（数字徽章）；月历形式切换器（`MonthCellStyle`）

### P3 变更
- **观点间接呈现**：`CalendarEvent` 加 `relatedTopics`；`Provider.fetchThought` 映射 `Thought.topics`（active/candidate 标题）；详情卡显示「相关观点」chip（紫）
- 「在 X 模块打开」跳原模块编辑页：受画廊 `fullScreenCover` 隔离 + 跨模块路由复杂，暂留 TODO（`originID` 已具备回查能力）
- 完整 HealthKit 图层（月历每格步数/睡眠热力）：保底 chip（P1B）保持，完整图层留 TODO

### 验证
- `build_sim` 通过
- `test_sim` 全量 85 测试通过（0 失败）

### 待办（后续）
- 详情跳原模块编辑页（需 deep link / dismiss 画廊后路由整合）
- 完整 HealthKit 步数/睡眠图层（替代保底 chip）

---

## [2026-07-05] 记忆长廊日历视图 P1C（删除生活星图 · 日历正式升主线）

P1A/P1B 日历体验闭环后，删除已无实际用途的生活星图（MemoryConstellationCard），日历正式成为记忆长廊主线。旧洞察/明细 Tab 仍保留（Daily Sense / AI 回放 / 深度分析 / 时间线 / 热力图 等既有能力不受影响）。

### 变更
- 删除 `Components/MemoryConstellationCard.swift`（星图卡视图）
- 删除 `Models/MemoryConstellationModels.swift`（星图数据模型）；`FeaturedMemoryNode` 迁出到独立文件（featuredStoriesSection「可回看的片段」仍消费）
- `MemoryGalleryViewModel` 移除 constellation* 计算属性（summary/signals/snippets/healthState/lastUpdatedAt/periodLabel）+ loadConstellationHealthState + constellationHealthSummary + constellationModule + dailySummariesInRange + gentleTitle/Icon（约 290 行）
- `MemoryGalleryView` 移除洞察 Tab 内星图卡渲染
- 删除 3 个星座测试文件，从 `project.pbxproj` 清理引用
- 保留：`featuredNarrativeNodes` / `FeaturedMemoryNode`（featuredStoriesSection 用）/ `dailySummary(for:in:)` static（todaySummary 用）

### 安全性（逐符号审查消费者）
- 纯星图专属（A 类）：constellation* 属性、loadConstellationHealthState、constellationHealthSummary、MemoryConstellationModels 内 5 类型 → 删
- 非星图专属（B 类）：featuredNarrativeNodes + FeaturedMemoryNode（featuredStoriesSection「可回看的片段」复用）、dailySummary(for:in:)（todaySummary 复用）→ 保留
- HealthStatusChip（P1B）已确认独立，不依赖星图健康逻辑

### 验证
- `build_sim`（iPhone 17）通过
- `test_sim` 全量 85 测试通过（删 3 个星座测试文件后剩余全绿，0 失败）

### 待办（后续阶段）
- **P2**：周历网格视图 / 待办时间维度切换 / 模块筛选 / 月历色块形式切换
- **P3**：完整 HealthKit 步数/睡眠图层（替代 P1B 保底 chip）+ 观点经想法间接呈现

---

## [2026-07-05] 记忆长廊日历视图 P1B（月历 + 当天详情 + 健康保底）

P1A 周历列表上线后，P1B 补齐月历视图：周历/月历顶部切换；月历 31 格热力色块（5 档暖色阶）+ 底部模块色条；点格选中当天平铺详情（按模块分组）；月历顶部「健康状态 chip」保底入口（Q3，健康维度不随星图消失）。

### 变更
- 新增 `Models/Calendar/CalendarHeatmap.swift`：事件数→5 档色阶纯函数（0 条=空档，1 条起即有色，区别于热力图）
- 新增 `Views/MemoryGallery/Calendar/Monthly/`：`MonthCell`（色深背景+底部模块色条+今天/选中态）、`MonthlyCalendarView`（周一首 7×N 网格+上下月补位）、`DayDetailCard`（选中当天按模块分组平铺）、`HealthStatusChip`（三态：未授权/已连接无数据/已连接·本周步数·睡眠）
- `CalendarViewModel` 重构：加 `mode`（周/月）+ `anchor`（统一锚点替代 weekAnchor）+ `selectedDay` + `monthEventsByDay`/`selectedDayEvents`
- `CalendarRootView` 重写：顶部「周历/月历」segmented + 月历视图接入 + 健康 chip（月历左上）
- 复用 `MemoryHeatmapView` 5 档暖色阶色值（`#F5F2ED→#FF8C66`）；健康 chip 复用 `loadConstellationHealthState` 的 `HealthRepository` 调用范式（独立自取，不耦合 ViewModel）

### 验证
- `build_sim`（iPhone 17）通过
- `test_sim` 全量测试通过，含新增 `CalendarHeatmapTests`（色阶边界 0 / 1-2 / 3-5 / 6-9 / 10+）

### 待办（后续阶段）
- **P1C**：日历升画廊主线 + 拆解星图耦合（健康聚合/featuredNarrativeNodes/AI 洞察刷新）后删星图
- **P2**：周历网格视图 / 待办时间维度切换 / 模块筛选 / 月历色块形式切换
- **P3**：完整 HealthKit 步数/睡眠图层（替代 P1B 保底 chip）

---

## [2026-07-05] 记忆长廊日历视图 P1A（周历列表上线）

生活星图实用价值低，改用「周历 + 月历」替换（方案：`docs/_common/plans/2026-07-05-Holo记忆长廊日历视图（周历+月历）方案.md`，已经过 Codex 对抗审查 + 东林拍板 A 路线）。本轮交付 P1A：记忆长廊新增「日历」Tab（默认首屏），周历列表聚合记账/习惯/待办/想法 4 模块，按天横向铺开事件；旧「洞察/明细」Tab 保留并存，生活星图隐藏不渲染、代码保留（P1C 验证后再清理）。

### 变更
- 新增 `Models/Calendar/`：`CalendarModule`（5 模块分色，待办改靛蓝 `#6366F1` 避撞记账橙）、`CalendarEvent`（单条事件 1:1 实体）、`CalendarEventsResult`（含 `CalendarModuleLoadState`，失败不静默）
- 新增 `Services/Calendar/`：`CalendarRangeBuilder`（统一半开区间 `[start,end)`、周一首）、`CalendarEventProvider`（4 模块聚合，各模块独立 do-catch，失败在 `moduleStates` 标 `.failed`，UI 据 `hasFailure` 显示「部分数据暂未载入」+ retry）
- 新增 `Views/MemoryGallery/Calendar/`：`CalendarRootView`（周导航 + 失败态横条）、`WeeklyListView`/`WeeklyEventChip`（7 天横向事件流）、`CalendarEventDetailSheet`（只读详情）、`CalendarViewModel`
- `HabitRepository`：新增 `getRecords(from:to:)`（不带 habitId，半开）+ `getActiveHabits()`
- `TodoRepository+Stats`：新增 `getTasks(completedFrom:completedTo:)`（半开，返回实体而非每日计数）
- `ThoughtRepository`：新增 `fetchThoughts(from:to:)`（现有 `fetchAll` 无 range 参数）
- `MemoryGalleryView`：新增「日历」Tab 并设为默认，旧洞察/明细保留并存（零回归）
- `MemorySegmentedTabs`：`MemoryGalleryTab` 加 `calendar`

### 设计要点
- 区间语义 4 模块原不一致（Finance 半开 / Habit 闭 / Todo 同文件内一半开一闭），日历统一半开 `[start,end)`，避免跨周/跨月重复计数
- 复用 `FinanceRepository.getTransactions(from:to:)`（已半开返回实体），仅 3 模块新增 fetch 契约
- `CalendarEventProvider` 串行调用 4 模块（共享 Core Data context，并发违反线程安全）

### 验证
- `build_sim`（iPhone 17）通过
- `test_sim` 全量 100 测试通过，含新增 5 个测试类：`CalendarRangeBuilderTests`（半开/周一首边界）、`Habit/Todo/ThoughtRepositoryCalendarTests`（各 4 测：区间/半开边界/软删过滤/空）、`CalendarEventProviderTests`（aggregate 失败态/排序/empty + fetchEvents 集成）

### 待办（后续阶段）
- **P1B**：月历色块 + 选中当天详情 + 健康保底 chip
- **P1C**：日历升画廊主线 + 拆解星图耦合（健康聚合/featuredNarrativeNodes/AI 洞察刷新）后删除星图代码
- **P2**：周历网格视图 / 待办时间维度切换 / 模块筛选

---

## [2026-07-04] 上架前内部入口隐藏与隐私政策修订

为 App Store 上架做准备：将仅供开发自测的 HealthKit 诊断入口限定在 DEBUG 构建，Release 不暴露；同步修订隐私政策以覆盖观点数据并如实反映 HealthKit 采集范围；移除与实际行为矛盾的 HealthKit 写权限声明。模型切换 / API Key / Prompt 编辑等调试入口此前已 `#if DEBUG` 隔离，本轮维持现状，首版不向普通用户暴露。

### 变更
- `SettingsView.swift`：HealthKit 诊断页入口加 `#if DEBUG`，section header 由"诊断与数据管理"改为"数据管理"
- `LegalDocumentSheet.swift`：隐私政策 1.1 节补充"观点记录"数据条、用途表追加观点数据行；HealthKit 描述由"步数、睡眠时长和站立时长"改为"步数、睡眠、站立、运动时长等"，与实际采集对齐
- `project.pbxproj`：删除 `NSHealthUpdateUsageDescription`（App 全量只读，写权限声明属矛盾配置）；`NSHealthShareUsageDescription` 文案同步补全运动等采集项；附带 Xcode 保存时的两处规范化（SubtaskParserTests 引用排序、UILaunchScreen_Generation 通用行去重），功能等价无影响

### 验证
- `xcodebuild ... build`（build_sim, iPhone 17）通过

---

## [2026-07-03] HoloAI 对话增加微信风格时间分隔条

对话界面在相邻消息间隔 ≥ 5 分钟（或首条消息）时，于较新消息上方居中显示一个时间胶囊，避免每条消息都打时间戳。几秒内的用户消息与 AI 回复天然不显示，满足「近几分钟对话不每条都显示」的诉求。时间格式：今天 `14:32` / 昨天 `昨天 14:32` / 同年 `7月3日 14:32` / 跨年 `2025年12月31日 14:32`。

### 变更
- 新增 `Views/Chat/ChatTimeStampSeparator.swift`：时间分隔条视图 + 5 分钟阈值判断（`shouldShow`）+ 微信式时间格式化（`DateFormatter` + `zh_CN`）
- `ChatView.messageList` 的 `ForEach` 改为 `enumerated()`，每条消息前按需插入分隔条
- 数据层 / ViewModel 零改动；时间格式化置于 `@MainActor` View 内部，遵循上次 `displayDateText` 的 Swift 6 隔离教训

### 验证
- `xcodebuild ... build`（build_sim, iPhone 17）通过，未引入新 Swift 6 warning

---

## [2026-07-02] 财务卡片展示记录日期

记账卡片在分类行右侧露出记录日期：昨天 / 前天 / M月d日；今天记账是常态，不占位。日期格式化逻辑放在 `TransactionChatCard`（@MainActor）内部，避免在 nonisolated 的 `TransactionCardData` 上调用 `NLDateParser` / `Calendar` 产生 Swift 6 并发 warning。

### 变更
- `TransactionChatCard` 新增 `categoryDateRow` 与 `relativeDateText`，分类行右侧按需展示历史日期
- 移除 `TransactionCardData.displayDateText`（原实现位于 nonisolated struct，触发并发 warning）

### 验证
- `xcodebuild ... build`（build_sim）通过，未引入新 Swift 6 warning

---

## [2026-07-02] HoloAI 记账日期与待确认卡片修复

修复 HoloAI 识别「昨天停车18」这类记账输入时，交易日期可能落成今天的问题；同时修复待确认记账卡片在消息退出重进或轻量重载后，确认/取消按钮点击无效的问题。

### 变更
- **交易日期贯通**：后端与 iOS intent prompt 明确输出 `transactionDate`，iOS 记账落库、卡片展示和编辑预填都消费该字段，确保“昨天 / 今天”等相对日期落到真实交易日
- **待确认卡片操作恢复**：消息更新不再只依赖实时缓存，确认/取消时可从 Core Data 取回消息后更新 execution batch，避免按钮点击后状态不变
- **回归覆盖**：补充后端 golden、交易日期解析、PromptManager、ChatCardData 和消息缓存恢复测试，并把相关测试接入 HoloTests target

### 验证
- `npm test --prefix HoloBackend`
- `xcodebuild test -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HoloTests/ChatCardDataTests -only-testing:HoloTests/TransactionDateResolverTests -only-testing:HoloTests/PromptManagerIntentRecognitionTests -only-testing:HoloTests/ChatMessageRepositoryCacheRecoveryTests`

---

## [2026-07-02] 观点模块标签筛选栏稳定性修复

修复观点首页切换不同标签时，选中的标签可能突然平移到其他标签旁边的问题。根因是常用标签在使用次数相同或接近时缺少稳定排序，同时「AI 整理」动作 chip 会随状态/徽章宽度变化挤动后续标签。

### 变更
- **常用标签稳定排序**：标签按 `usageCount desc -> name asc -> id asc` 固定顺序，避免刷新后同分标签重新洗牌
- **筛选栏布局稳定**：AI 整理 chip 固定宽度，待整理数超过 99 显示 `99+`，减少状态切换时的横向位移
- **回归覆盖**：补充同 usageCount 标签稳定排序测试，锁定用户数据量较大时的顺序契约

### 验证
- `xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/holo-derived-data build`
- `xcodebuild ... -only-testing:HoloTests/ThoughtRepositoryAITagBucketTests test` 当前仍显示 `Executed 0 tests`，仅能证明测试包构建，不能视为测试通过

---

## [2026-07-01] HoloAI Agent 财务分析可靠性修复

修复 HoloAI 深度分析「上个月花了 1.4 万，钱都花哪了」这类财务问题中，时间识别、数据调度和结果展示不稳定的问题。现在 Agent 会确定性解析“本月 / 上月 / 6月 / 2025年6月”等时间语义，优先调用 finance 账单拆分工具，并在模型输出格式失败时使用已验证的工具事实兜底完成，避免用户看到 `state=failed`、`解析失败` 或内部 metricKey。

### 变更
- **时间语义确定化**：新增 `HoloAgentTimeSemanticResolver`，把常见中文时间表达解析成明确的自然月/周/年范围，工具请求缺少 `timeRange` 时自动继承 job 范围
- **财务工具强制调度**：对“钱花哪了 / 去哪了 / 消费结构 / 1.4万花哪了”等问题先执行 `finance.spending_breakdown`，不再完全依赖模型自觉发起工具调用
- **可信结果兜底**：模型 claim 无证据或 JSON 解析失败时，只要 finance 工具已返回事实，就基于总额、Top 分类和大额样例生成可核对结论
- **展示可读性**：财务详情页按账单口径展示，使用正确时间标签，保护金额小数不被窄屏换行误读，并隐藏内部调试字段

### 验证
- `HoloLocalAgentRuntimeTests passed`
- `HoloAgentResponseParserTests passed`
- `swiftc -parse HoloAgentResultRendererTests.swift`
- `xcodebuild build -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' -derivedDataPath /private/tmp/holo-derived-data-agent-parse-fallback build -quiet`

---

## [2026-07-01] iCloud 同步运行时误判修复

修复设置页显示“当前签名未启用 iCloud CloudKit，同步功能暂不可用”的问题。根因是 Debug 包在读不到 `embedded.mobileprovision` 时被运行时守卫误判为 CloudKit 不可用，导致 App 主动退回本地 Core Data 容器，iCloud 同步链路被关掉。

### 变更
- **CloudKit 可用性守卫**：Debug 下只有在明确读取到 provisioning profile 且其中缺少 CloudKit entitlement 时才禁用 CloudKit；读不到 profile 不再直接关闭同步
- **同步后台能力**：`UIBackgroundModes` 补充 `remote-notification`，避免 Core Data + CloudKit 后台推送同步缺少系统能力声明
- **回归测试**：新增 `CloudKitRuntimeAvailabilityTests`，覆盖无 embedded profile、profile 缺 CloudKit、profile 包含 CloudKit 三种判断路径

### 验证
- `xcodebuild test -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HoloTests/CloudKitRuntimeAvailabilityTests -derivedDataPath /private/tmp/holo-cloudkit-runtime-final-test`
- `xcodebuild build -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/holo-cloudkit-runtime-build`

---

## [2026-06-29] HoloAI 深度分析详情页改为观察手记式布局

重做 HoloAI 深度分析结果弹窗，去掉原先“核心结论 + 观察卡片 + 数据依据卡片瀑布”的生硬结构，改为更适合手机阅读的观察手记式页面。核心结论会拆成可阅读段落，观察内容采用更清晰的标题、字号和间距层级；数据依据默认折叠为底部轻入口，避免喧宾夺主。

### 变更
- **叙事化详情页**：新增 `AgentDeepAnalysisNarrativeModel`，把 summary、观察段和 evidence 映射为开场、信号摘要、观察章节、下一步和数据依据入口
- **长文本拆段**：summary 优先按分号、句号、问号、感叹号和换行拆段；没有强分隔时按逗号兜底拆，减少真机上一整串文字堆叠
- **观察卡重排**：泛化的“观察 1/2”标题不再原样展示，改为更稳定的观察编号和默认标题；移除观察旁边重复的小图标
- **数据依据折叠**：数据依据默认显示为一条轻量入口，点开后才展示明细；带财务 drilldown 的依据仍可继续点按核对
- **设计原型**：补充 A/C 依据入口对比稿，并按方案 A 落地

### 验证
- `xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HoloTests/ChatMessageViewDataAgentResultTests test` 8/8 通过
- `xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` 编译通过

---

## [2026-06-28] 意图识别分流修复：频率/日均折算类归 query_analysis 走 Agent

修复「买烟的频率怎么样 / 平均一天抽烟花多少钱」这类需要折算统计的问题，被意图识别误判为 `flexible_data_query`（轻量查询），导致没走深度 Agent 的问题。现在这类「频率、日均、平均每天、趋势折算」明确归到 `query_analysis`，由本地深度 Agent 处理。

### 变更
- **后端 intent_recognition（生效端）**：`flexible_data_query` 明确限定为「查一个确定的单值，不做折算/统计」；`query_analysis` 补充频率/日均/折算能力；分流规则新增「频率/折算类 → query_analysis」；例句新增买烟频率、日均用例
- **iOS PromptManager（后备）**：同步上述分流规则与例句，`promptVersions .intentRecognition` 19 → 20
- **根因**：`ConversationCoordinator.shouldRouteToDeepAgent` 仅对 `query_analysis` 路由 Agent；且 `FlexibleQueryExecutor.averageAmount` 是「总额÷笔数」（平均每笔），算不了「日均」（总额÷天数），意图分错后即使走轻量查询也答不准

### 验证
- `build_sim`（iPhone 17）编译通过
- 待后端部署后 `curl /v1/prompts/intent_recognition` 验证版本与内容

---

## [2026-06-28] Agent 深度分析修复「证据缺失」

修复 Agent 深度分析结果中频繁出现「（证据缺失）」的问题。根因是 LLM 在 claim 顶层 `evidenceIDs` 容易写错 canonical ID（四段 UUID 拼接的长串），而 Verifier 只校验 `metricAssertions.evidenceIDs` 不校验顶层；render 层原先只取顶层 ID 展示，找不到就显示「证据缺失」。

### 变更
- **Renderer 方向 A**：`HoloAgentResultRenderer.render` 证据引用改为优先取 `claim.metricAssertions.flatMap(\.evidenceIDs)`（Verifier 保证有效），顶层 `claim.evidenceIDs` 仅作补充；找不到 record 的 ID 跳过，不再拼「证据缺失」
- **回归测试**：新增 `test顶层EvidenceID无效时改用已校验证据不显示缺失`（11/11 全绿）

### 验证
- `test_sim -only-testing:HoloTests/HoloAgentResultRendererTests` 11/11 Passed

---

## [2026-06-28] Agent 进度状态改为真实 job 状态

修复 HoloAI 页面退出再进入、回桌面、锁屏或杀进程后，深度分析卡片误显示“处理时意外中断”或串入旧分析结果的问题。现在 Chat 进度卡会以 Agent job 的真实状态为准：运行中继续转圈，后台时间耗尽时显示已暂停，回前台或冷启动后恢复并回填当前 job 的结果。

### 变更
- **真实状态源**：Chat 进度不再依赖页面内 `streamingText`，改为由持久化 Agent job 状态同步
- **页面重建恢复**：Agent loading 状态写入 Core Data，回首页再进入 HoloAI 仍能展示真实状态
- **结果绑定修复**：深度分析完成后按当前 `jobID` 读取结果，避免误展示旧的“最近一次”分析
- **生命周期修复**：快速回桌面再回来只同步状态，不重复启动 runLoop；后台时间到期或冷启动后才恢复未完成 job
- **测试**：补充状态展示、快速回前台不重复恢复、后台到期后恢复的回归用例

### 验证
- `xcodebuild test -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HoloTests/HoloAgentSchedulerTests -quiet`
- `xcodebuild build -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -quiet`

---

## [2026-06-28] Agent 后台恢复回填 Chat 消息

修复真机切到桌面再回到 App 后，Agent 结果被 Chat 层误判为“处理时意外中断了”的问题。现在 Agent job 会记录来源消息，回前台恢复完成后把结果回填到原来的深度分析气泡。

### 变更
- **Chat 恢复桥接**：Agent job 新增 `sourceMessageID`，用于绑定触发它的 assistant streaming 消息
- **ChatMessageRepository**：保护可恢复的 Agent streaming 消息，避免启动/回前台清理时提前改成“意外中断”
- **HoloBackgroundContinuationManager**：回前台续跑完成后回填已完成的 Agent job 结果
- **测试**：补充 Scheduler 用例，验证 `sourceMessageID` 会随 job 落盘，供恢复回填

### 验证
- `xcodebuild test -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HoloTests/HoloAgentSchedulerTests -quiet`

---

## [2026-06-28] Agent 后台短时续跑与恢复验证

修正 Agent 进入后台时立即暂停的问题：现在会先申请 iOS 后台执行时间，让在途 Agent 短时间继续推进；系统回收后台时间后再落盘为可恢复状态，回到 App 后由 Scheduler 继续 runLoop。

### 变更
- **HoloBackgroundContinuationManager**：进入后台时不再立即 `pauseForBackground`，改为持有 `UIBackgroundTask`；到期回调再标记 `waitingForForeground`
- **Agent 文案**：Chat loading 卡、streaming 文案与 AI 设置页补充“前台最稳、切后台短时尝试、失败后回前台继续”的风险提示
- **测试**：补充后台续跑用例，验证刚切后台保持 running、到期后才进入 `waitingForForeground`
- **验证流程**：新增 `docs/_common/plans/2026-06-28-Agent后台能力生效验证流程.md`

### 验证
- `xcodebuild test -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HoloTests/HoloAgentSchedulerTests -quiet`

---

## [2026-06-28] 记账键盘增加震动与品牌色按压反馈

新增记账时自绘数字键盘的点击反馈：每次按键即时轻震 + 品牌色（#F46D38）按压底色闪现，提升输入手感与交互确定性。

### 变更
- **TransactionKeypadComponents**：`KeypadButtonStyle` 增加按压色叠层 —— 数字/功能键叠加品牌橙 `holoPrimary.opacity(0.16)`，确认键 `✓` 叠加黑色遮罩变深（模拟实体键质感），保留原 `scaleEffect` 缩放
- **TransactionNumericKeypad**：`handleKeypadPress` 入口加 `HapticManager.light()`，每次按键统一即时触觉反馈（复用项目统一封装）

### 验证
- build_sim iOS Debug 编译通过

---

## [2026-06-28] 全局可恢复 Agent evidence id 撞车崩溃修复

修复回前台续跑 Agent 时，重复 evidence id 触发 `Dictionary(uniqueKeysWithValues:)` fatal error，导致 App 在 Claim 校验阶段崩溃的问题。

### 变更
- **runtime.runLoop**：工具结果进入 checkpoint / LLM 上下文前，将事件 id 规范化为 `jobID:tool:toolRequestID:eventID`
- **ClaimVerifier / ResultRenderer**：兼容旧 ledger 中重复 evidence id，避免校验或渲染阶段直接崩溃
- **测试**：补充重复 evidence id 回归测试，以及全局唯一 evidence id 贯穿 checkpoint / LLM 上下文测试

### 验证
- HoloClaimVerifierTests passed
- HoloLocalAgentRuntimeTests passed
- xcodebuild Holo Debug iOS build succeeded

---

## [2026-06-28] 全局可恢复 Agent Phase 2 Health 入口预留（jobType/trigger 扩展）

`HoloAgentJobType` 加 `healthInsight` case，`HoloAgentTrigger` 加 `healthInsight` case（方案 §4.1 预留接口，不接实际链路）。`deepAnalysis` rawValue 不变（不迁移）。

### 变更
- **HoloAgentJobType**：+ `healthInsight`
- **HoloAgentTrigger**：+ `healthInsight`
- test_sim 五测试绿

### 待办
- Health 入口实际接入：需决定健康洞察现有独立 LLM 链路与 Agent runLoop 的关系（迁移合并 or 共存）

---

## [2026-06-28] 全局可恢复 Agent CAS 取消在途续跑（Phase 1 增强）

`HoloBackgroundContinuationManager` 存 `resumeTask` 引用：进后台 cancel 在途续跑 Task（避免后台浪费 token），回前台 cancel 旧续跑 + 启动新续跑。`Scheduler.resumeAndContinue` 加 `Task.isCancelled` 检查，cancel 后 break 循环。

### 变更
- **HoloBackgroundContinuationManager**：+ `resumeTask` 引用，进后台/回前台 cancel 旧 Task
- **Scheduler.resumeAndContinue**：for 循环内加 `guard !Task.isCancelled else { break }`
- **test_sim**：五测试绿

---

## [2026-06-28] 全局可恢复 Agent wallTime 超时生效（Phase 3）

runLoop while 循环条件加 wallTime 超时判定（§9.6 点名缺陷：`maxWallTimeSeconds` 不生效）。循环条件从「仅判 LLM 轮数」改为「轮数 && wallTime 未超」。

### 变更
- **runtime.runLoop**：while 循环条件加 `Date().timeIntervalSince(budget.startedAt) < maxWallTimeSeconds`
- **测试**：`testStart` now 改用 `Date()`（避开远过去 now 与 `Date()` 的 wallTime 误判）

### 测试
- test_sim 五测试绿

---

## [2026-06-28] 后端 agent_loop 日志脱敏 + runId/stepId 透传（Phase 4）

agent_loop 日志不再存完整 messages 与 response（§9.4 隐私合规）。只存 runId/stepId/messageCount/summary（前 300 字），response 只存 status + usage。同时透传请求体 runId/stepId。

### 变更
- **app.js**：agent_loop request 日志脱敏（`summarizeMessages`，前 300 字）+ response 只存 `status + usage`
- **app.js**：请求体透传 `runId` / `stepId`（供 iOS 端对接）
- **npm test**：75/75 绿

### 待办
- iOS 端传 runId/stepId（`HoloAgentLLMClient.next` + `runLoop`；后端已支持接收）

---

## [2026-06-28] 后端客户端断连 abort 上游（Phase 4）

客户端断开时同步 abort 上游 provider，避免浪费 token（§6.2 断连治理）。

### 变更
- **openAICompatibleProvider**：`callUpstream` 接受 `clientSignal`，客户端断开时 abort 上游 fetch
- **app.js**：agent_loop 路由传 `context.req.raw.signal` 给 provider

---

## [2026-06-28] 全局可恢复 Agent checkpoint inputSnapshotHash（Phase 3）

`HoloAgentCheckpoint` 加 `inputSnapshotHash`（job 输入 `userQuestion + timeRange` 的稳定 hash）。恢复时 `Scheduler.resumeAndContinue` 对比 hash：匹配则恢复，不匹配则跳过（用户改了问题/时间范围，需重新规划，§4.3）。

### 变更
- **HoloAgentCheckpoint**：+ `inputSnapshotHash: String?`
- **makeCheckpoint**：加 `inputSnapshotHash` 参数（默认 nil，`startAnalysisJob` 传 `computeInputSnapshotHash`）
- **Scheduler.resumeAndContinue**：`inputSnapshotMatches` 校验 + `computeInputSnapshotHash`（不匹配则跳过该 job）
- **测试**：`testResumeAndContinue_hash匹配恢复不匹配跳过`（XCTest）

### 测试
- test_sim 五测试绿（N1 + 清理 + start + 限量恢复 + hash 校验）

---

## [2026-06-28] 全局可恢复 Agent checkpoint schema 向前兼容（Phase 3）

`HoloAgentCheckpoint` 加 `schemaVersion: Int?` 字段（`nil` = 旧数据迁移前，`1` = 当前版本；Codable 合成编码，旧 checkpoint 解码 `nil` 兼容）。`makeCheckpoint` 新写入设 `1`。

### 变更
- **HoloAgentCheckpoint**：+ `schemaVersion: Int?`
- **runtime.makeCheckpoint**：设 `schemaVersion: 1`
- **测试**：新 checkpoint `schemaVersion == 1`

### 剩余 Phase 3
- `inputSnapshotHash`（job 输入 hash，恢复时对比）
- `wallTime` 超时（runLoop 时钟抽象 + 超时判定）
- 旧 `deepAnalysis` rawValue 兼容（JobType 改名后，相位待 JobType 扩展时）

---

## [2026-06-28] 全局可恢复 Agent 限量恢复与优先级排序（Phase 1 增强）

回前台时 `Scheduler.resumeAndContinue` 按 trigger 优先级排序（P0 用户对话 > P1 刷新 > 其余），限量 `maxResume=3` 恢复，避免批量恢复拖慢首屏（§9.5）。

### 变更
- **runtime**：+ `collectResumableJobs`（返回完整 job，供排序限量）
- **Scheduler**：`priorityRank` + `maxResume` 限量 + 排序
- **测试**：`testResumeAndContinue_限量恢复按优先级排序`（XCTest）

### 测试
- test_sim 四测试绿（N1 + 清理 + start + 限量恢复）

---

## [2026-06-28] 健康洞察生活闭环空态优化（Verifier 放宽 + UI 区分）

修复生活闭环系统性显示 0 条（记忆 12743）。

### 根因（叠加）
- Verifier `minLoopConfidence 0.55` 与候选 `confidenceHint` 上界（lift=1.5 恰 0.55）临界，LLM loop 易全弃
- loop 无 fallback（诚实策略「不伪跨模块」，失败必 0）
- UI 空态不区分「数据不足」与「暂无关联」

### 修复
- `HealthInsightVerifier`: `minLoopConfidence` 0.55→0.45（破临界过滤，有 evidence+跨域背书的 loop 更易通过）
- `HealthView.lifestyleEmptyHint`: 区分 `insufficientData`（数据积累中）vs 暂无关联，避免生硬「0 条」

### 验证
- test_sim HealthInsightVerifierTests 绿

### 待办
- 若用户数据足仍 0，需抓 `rawResponse` 确认 LLM 是否生成 loop（区分 Verifier 过滤 vs 候选空=数据不足）

---

## [2026-06-28] 健康页闪退修复（健康洞察 build 跨线程 trap）

修复健康洞察接入（Task 8）引入的打开健康页直接闪退（记忆 12616/12617）。

### 根因
`HealthInsightContextBuilder.build()` 的 9 路 `async let` 并发拉取，跨域 Repository（`extractXxx` 读 `Transaction`/`Habit`/`HabitRecord`/`TodoTask`/`Thought` 等 `NSManagedObject`）在并发上下文访问主线程 `viewContext` → **CoreData 跨线程 trap**（`EXC_BAD_ACCESS`）。`ThoughtRepository` 缺 `@MainActor` 是隔离缺口。

### 修复（Explore 排查 + 记忆 12724 双重确认）
- `HealthInsightContextBuilder.build()` 加 `@MainActor`：整个构建收口主线程
- 9 路 `async let` 并发 → **串行 `await`**：消除并发 fetch 风暴 + 跨线程

### 验证
- test_sim 健康洞察测试绿（编译 + 单元测试）
- Core Data 跨线程难单测（需真机并发触发），建议真机复验打开健康页

---

## [2026-06-28] Observer Tier2 联动主闸（Phase 2 §5.2）

修复 Phase 0 盘出的旁路缺陷：`HoloMemoryObserverService` Tier2 触发原只检查 `agentObserverTier2Enabled`，主闸 `agentRuntimeEnabled` 关闭时仍触发 runAnalysis，绕过灰度总闸。加 `&& agentRuntimeEnabled` 联动。

---

## [2026-06-28] 全局可恢复 Agent Phase 2 启动：Scheduler 接管 Chat/Observer 入口

Phase 2 第一步：`HoloAgentAnalysisService.runAnalysis` 改经 `Scheduler.start`（一次覆盖 Chat + Observer 两入口——Observer 经 `HoloMemoryObserverService:140` 也调 AnalysisService），Scheduler 成为所有 Agent 运行的统一入口（方案 §5.2）。

### 变更
- **HoloAgentScheduler.start**：创建 job + 拉起 runLoop + 返回终态 job（供前台同步渲染；未来在此层加 Task 池/去重/取消）
- **HoloAgentAnalysisService**：注入 scheduler，`runAnalysis` 经 `scheduler.start`（原直接调 `runtime.startAnalysisJob` + `runtime.runLoop`）
- **testStart**（XCTest）：验证 start 创建 deepAnalysis job 并跑完到 completed

### 测试
- test_sim 三测试绿（N1 闭合 + 终态清理 + start）

### 待办
- Observer 旁路主闸联动（`agentObserverTier2Enabled` 在主闸关闭时仍触发，待加 guard）
- Health 入口接入（`healthInsight` job type，较大）

---

## [2026-06-28] 全局可恢复 Agent Phase 1：闭合恢复链断点 N1

HoloAgent 原本的「可恢复」承诺实际断裂：App 被系统杀掉后重启，未完成 job 经 `resume` 只被标记 running、不重启推理，且下次回前台被 `where state != .running` 永久排除 → 晾死。本 commit 闭合该断点（方案 `docs/_common/plans/2026-06-27-Holo全局可恢复Agent运行方案.md` Phase 1，方案 §14 验收硬指标）。

### 变更
- **HoloAgentScheduler**（新，actor）：第一职责是恢复时真正重启未完成 job 的 runLoop；`resumeAndContinue` 扫描全部非终态 job（含 running 孤儿）逐个拉起 runLoop 到达终态
- **HoloLocalAgentRuntime**：+ `collectResumableJobIDs`（含 running 孤儿、不改状态，区别于旧 `resumeUnfinishedJobs` 排除 running）
- **HoloBackgroundContinuationManager**：`appWillEnterForeground` 改走 Scheduler（注入 systemTemplate/toolDescriptions），生产链真正闭合 N1
- **HoloAgentSchedulerTests**（新，XCTest）+ pbxproj 接入 test target

### 测试
- TDD 闭环：RED（骨架复刻现状，job 停 running，断言终态失败）→ GREEN（Scheduler 拉起 runLoop，job 到 completed）
- test_sim 编译通过、Scheduler 测试绿

### 待办
- Phase 1 增强：pauseForBackground 对在途 Task 的 state CAS、优先级/去重/限量恢复、终态 job 清理（§9.6）
- Phase 2：迁移 Chat/Observer/MemoryGallery/Health 入口经 Scheduler
- Phase 3/4：checkpoint schema/wallTime 超时；后端 runId/stepId/脱敏/断连

---

## [2026-06-28] 全局可恢复 Agent Phase 1 续：终态 job 清理（§9.6 体积治理）

闭合 §9.6 缺口：evidence/checkpoint 无上限 append 会导致 `jobStore.load()` 随历史线性变慢。

### 变更
- **CheckpointStore/ResultStore**：+ `deleteByJobIDs`（终态清理级联删除）
- **PersistenceManager.cleanupTerminalJobs**：编排 `jobStore.cleanup` → 级联删 checkpoint/result（evidence 软删除仍由 cleanupOrphanedEvidence 独立驱动）
- **runtime/Scheduler.cleanupTerminalJobs**：透传
- **HoloBackgroundContinuationManager**：回前台续跑后顺手清理过期终态 job（completed 30d / failed 7d）

### 测试
- `testCleanupTerminalJobs_删终态超期job并级联清理checkpoint`（XCTest）：删终态超期 job + 级联清 checkpoint，非终态 job 保留
- test_sim 两测试绿（N1 闭合 + 终态清理）

---

## [2026-06-27] 健康洞察 LLM 生成链路（iOS 全链路完成，后端待部署）

将健康页「今日核心洞察」与「生活闭环」从固定规则文案升级为基于真实证据、LLM 生成、可校验可回退的个人健康洞察。方案文档 `docs/_common/plans/2026-06-27-Holo健康洞察LLM生成方案.md`（含三轮对抗审查 P1-P14/R1-R6/N1-N5）。

### 变更
- **生成模型**（Task 2）：`HealthInsightGenerationModels`（Snapshot / GeneratedHealthInsight / Evidence / 状态枚举 + LLM 宽容响应模型，Codable+Sendable）
- **上下文 Builder**（Task 3）：`HealthInsightContextBuilder` 复用 HealthRepository/FinanceRepository 同源数据，14d 显式窗口，evidence.id 统一 `<domain>-<subKind>-<yyyyMMdd>`，跨域候选（低睡眠∩咖啡）按日集合交叉 + lift≥1.5 门槛 + |S_low|≥3
- **后端 health_insight_generation**（Task 4）：config.js 加 route（temp 0.35 / maxTokens 1600）；defaultPrompts.json 加 prompt v1（医疗安全 + evidenceId 约束）；PROMPT_VERSIONS 登记 v1；response_format 由 iOS 请求体透传（route 不配，审查 P1）
- **iOS 调用链路**（Task 5）：`HoloBackendPurpose.healthInsightGeneration` + `generateHealthInsight(contextJSON:)`（对齐 generateMemoryInsight，JSON mode + promptVersion 带出，N1）；`HealthInsightResponseParser`（同源 evidenceId 过滤 + 围栏提取）；`HealthInsightGenerationService` 编排
- **Verifier + Fallback**（Task 6）：`HealthInsightVerifier`（core≥1 evidence / loop≥2 evidence 且 domain 去重≥2 / confidence≥0.55 / 长度 / 医疗因果禁词）；`HealthInsightFallbackBuilder`（诚实空态，不伪装跨模块）
- **缓存**（Task 7）：`HealthInsightCache` JSON 文件存储 + contextHash + promptVersion 失效（N4）+ 30 分钟失败节流（P8）+ 手动 3 次/天 + 7 天清理（P7）
- **UI 接入**（Task 8）：`HealthInsightViewModel` + HealthView coreInsightCard/lifestyleInsightCard 优先 LLM 结果回退规则文案 + `HealthInsightEvidenceSheet` 证据详情；布局不变

### 测试
- iOS 7 个测试类全过：HealthDashboardStateTests（基线 P13 结构断言）/ Models / ContextBuilder / ResponseParser / Service / Verifier / Cache
- 后端 npm test 75 过（含 healthInsight.test.js 5 测试：route config / prompt 内容 / PROMPT_VERSIONS / response_format 请求体透传 P1 / 回归）
- build_sim 主 target 编译通过

### 待办
- ⚠️ 后端 health_insight_generation 待部署 ECS（api.holoapp.cn）才能真机生效
- Task 9 反馈闭环（v2）

---

## [2026-06-27] 观点知识树真机验收修复（抽屉交互 6 项）

## [2026-06-27] 观点知识树真机验收修复（抽屉交互 6 项）

### 变更
- **抽屉手势修复**：右边缘左滑关闭去 HorizontalGestureLock 过度判定（边缘手势已定向，原 axis 锁定太严导致 onClose 不触发）+ 边缘加宽 20→36pt + 补 tap 关闭（点右边缘空白收起）
- **抽屉隔离**：打开时 `allowsHitTesting(false)` 禁用下层观点列表，防抽屉内滑动穿透触发卡片右滑删除误删；点任何筛选节点立即收起抽屉
- **文案/状态修复**：「.ai 标签池」→「AI 标签池」；AI 整理 `ready([])` 不再误显示「处理完」，改「暂未发现可归并主题」；抽屉监听 `thoughtDataDidChange` 刷新（归并后收纳降权实时反映）

### 测试
- `build_sim` 编译通过（仅预存 Swift 6 actor 警告）
- ⚠️ 待真机复验：手势/点外部关闭/点标签关抽屉/AI 整理收纳降权

---

## [2026-06-27] 观点知识树 P2 端到端完成（后端已部署上线）

### 变更
- **P2.1 后端 thought_tag_convergence**：config.js 加 purpose 路由（temperature 0.3 / maxTokens 1024）；defaultPrompts.json 加归并 prompt（输入:N 条观点+标签聚合+Topic 列表+已拒绝建议；输出:suggestions 数组 JSON）；promptRegistry 自动识别（`PROMPT_TYPES = keys(defaultPrompts)`，无需显式注册）
- **P2.1 iOS PromptManager 后备**：`PromptType` 加 `thoughtTagConvergence` + 后备模板（对齐后端 prompt）+ `promptVersions` v1；运行时后端 prompt 优先，本地后备兜底（双端同步策略）
- **P2.4 归并数据迁移**：`TopicRepository.applyConvergence`（get-or-create Topic 幂等 + 来源词写 `associatedTags` 主源 + 观点关联 `Thought.topics`，**source 保持 `.ai` 不变** spec 决策 4）
- **P2.5 建议级拒绝实体**：新建 `ThoughtTagConvergenceRejection`（代码定义模型，无关系独立实体，随 iCloud 同步）；幂等键=主题名+来源词集合（归一化/集合语义/不含观点 hash，spec §6.4 决策 10）；`ConvergenceRejectionRepository`（reject 幂等更新 + isRejected 过期判断 + fetchActiveRejections 供 Job 传「已拒绝建议」+ purgeExpired）
- **P2.2 收敛任务**：新建 `ThoughtTagConvergenceJob`（@MainActor ObservableObject，状态机 idle→generating→ready/failed，**不复用单条 `ThoughtOrganizationQueue`** spec 验收14）；`ConvergenceSuggestion` 模型（topicTitle/matchedTopicId/thoughtIds/sourceTerms/confidence/reason）；`ThoughtRepository.fetchConvergenceCandidates` 取带 .ai 标签观点；`HoloBackendPurpose.thoughtTagConvergence` 注册；参考队列重试(5/30/120s)+rateLimited 不重试+已拒绝建议过滤+输入<3 静默
- **P2.3 归并确认 UI**：新建 `ConvergenceConfirmView`（状态分支 generating/ready/failed/idle；逐条卡片：主题名+关联观点数+来源词+理由，操作 **确认归并/改名后确认/拒绝/暂不**）；接入「AI 整理」入口（替换 P1 的「功能开发中」预告）→ 关抽屉 + 触发 Job + sheet 确认页；确认走 `applyConvergence`（P2.4）、拒绝走 `ConvergenceRejectionRepository`（P2.5）
- **P2.6 后端部署上线**：scp 同步 `config.js` + `defaultPrompts.json` 到 ECS（123.56.104.9）；`DOCKER_BUILDKIT=0 docker compose build --no-cache` 绕过 Docker Hub 坑重建镜像；`docker compose up -d` 容器 Up；`/v1/health` ok + `/v1/prompts/thought_tag_convergence` version 1 上线验证通过

### 测试
- `TopicRepositoryTests` applyConvergence 2 测试（新建主题 / 归入现有复用）全过
- `ConvergenceRejectionRepositoryTests` 13 测试（幂等键归一化/集合语义/过期/重复拒绝/查询/清理）全过
- `ThoughtTagConvergenceJobTests` 10 测试（建议产出/空建议/rateLimited/重试耗尽/重试成功/输入不足不调AI/markdown fence/已拒绝过滤/reset）全过
- 后端 `defaultPrompts.json` JSON 有效性验证通过

### 待真机验收（东林）
- 真机点「AI 整理」→ 调后端 `thought_tag_convergence` → 展示归并建议 → 确认 → 收纳 → AI 标签池降权
- 真机后端指向生产 `HoloBackendEnvironment.baseURL`（Release 暂未启用，Debug 环境 + 真机连生产验证）

---

## [2026-06-27] 观点知识树 P1 + P1.5 本地闭环实施完成

### 变更
- **P1 抽屉骨架 + AI 标签池（1.1-1.4）**：新建 `ThoughtKnowledgeDrawerView`（`DrawerNode` 枚举 + 左侧抽屉），`ThoughtsView` 菜单按钮唤出 + overlay + 遮罩关闭；`ThoughtRepository.fetchAITagBuckets` 走 `ThoughtTagAssignment` 聚合 `.ai/.confirmedAI`（排除 `rejectedAI`/`rejectedAt`）；抽屉接真实 AI 标签池 + AI 整理预告（「待整理 N 条」/「功能开发中」）；`drawerSelection` 联动右侧筛选（`fetchThoughtsByAITag` SUBQUERY 走 assignment + `fetchUnclassifiedThoughts`），抽屉/chip 筛选互斥
- **P1.5 Topic 本地闭环（5.1-5.7）**：新建 `TopicRepository`（创建/幂等查重 `normalizedKey`/隐藏/合并/`thoughtCount` 实时算/`fetchThoughts byTopic`/`setSourceTerms` 来源词主源/`assign` 移入移出/`mergeDuplicateTopics` 同步后去重）+ `TopicService`（`primaryDisplayTopic` 主主题展示层取 + `isAbsorbed` 三者交集收纳判断）；抽屉 Topic 区接真实 + 点 Topic 筛选；`fetchAITagBuckets(excludeAbsorbed:)` 收纳降权；`TopicPickerView` 手动移入/新建主题（卡片 contextMenu）；`RightEdgeCloseOverlay` 右边缘左滑关闭（`UIScreenEdgePanGestureRecognizer.right` + `HorizontalGestureLock`）；`ThoughtsView` 进入时 `mergeDuplicateTopics`
- **设计遵循 spec**：归并不改 source（收纳靠 Thought+Tag+Topic 三者交集）；走 assignment 不走 `Thought.tags`（数据源割裂）；P1.5 不加 `canonicalKey`（运行时归一化 + 同步后合并）；手势 `UIViewRepresentable+UIGestureRecognizer` 禁 `DragGesture`

### 测试
- `ThoughtRepositoryAITagBucketTests`（AI 标签池聚合 + `fetchThoughtsByAITag` + `excludeAbsorbed` + 未归类，9 测试）
- `TopicRepositoryTests`（CRUD/幂等/归一化/状态/合并/`thoughtCount`/来源词，11 测试）
- `TopicServiceTests`（主主题 + `isAbsorbed` 三者交集各种边界，6 测试）
- `build_sim` 编译通过；`test_sim` 全绿
- ⚠️ 右边缘手势需真机验证不与系统返回/卡片左滑/标签横滑/列表竖滑冲突

---

## [2026-06-26] 观点模块知识树设计方案定稿 + 实施计划

### 变更
- **新增观点模块知识树设计 spec（定稿）**：`docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md`，经 5 轮 GLM/GPT 交叉对抗审查收敛。核心方向：观点列表 + 左侧菜单按钮唤出的知识树抽屉 + 复用 `.ai` source 的标签补位 + 用户主动确认的主题归并。定 19 条决策（砍右滑手势 / 两层结构 / 归并不改 source / Thought+Tag+Topic 三者交集收纳判断 / P1.5 不加 canonicalKey 等）
- **新增实施计划**：`docs/thoughts/plans/2026-06-26-Holo观点知识树-实施方案.md`，拆 P1（抽屉骨架 + AI 标签池，零后端）/ P1.5（Topic 本地闭环）/ P2（后端跨观点收敛），含文件清单、TDD 落点、验收标准
- **实施计划补齐 P1 实施细节**（2026-06-27）：§3 核实清单补 #9-#12 字段级事实（`ThoughtTag.name` / `Assignment.{source,rejectedAt,thought,tag}` / `Thought.topics` / `fetchByTag` 走 `tags` 不走 assignment）并复核全部成立；新增 §4.6 `DrawerNode` 枚举 + §4.7 抽屉→筛选映射；Phase 1.1 补菜单按钮落点（`headerView` 返回按钮右侧）+ `sidebar.left` SF Symbol 验证 + 抽屉尺寸/层级/状态传递；Phase 1.4 补 DrawerNode→筛选映射（`.aiTag` 走 assignment、不复用 `fetchByTag`）。文档已达可无脑开工状态

### 测试
- 纯文档，无代码改动

---

## [2026-06-26] 财务桌面小组件改为本月收支

### 变更
- **财务小组件口径由「今日」改为「本月」**：桌面「今日收支」小组件原先展示当日支出/收入，现改为展示当月支出与收入，更贴合月度预算视角。`HoloWidgetFinanceSnapshot` 移除 `todayExpense/todayIncome`，新增 `monthIncome`；`refreshFinanceSnapshot` 去掉今日交易查询，由月度交易同时汇总支出与收入；小尺寸展示「本月支出」+ 预算进度条，中尺寸并列「本月收支」支出/收入。预算进度条（月度口径）保留

### 测试
- `build_sim` 编译通过

---

## [2026-06-24] 今日看板习惯展示与打卡实时刷新修复

### 修复
- **今日看板不显示每周/每月习惯**：`KanbanHabitSection` 写死只取 `.daily` 频率习惯，导致用户新建的每周/每月习惯在今日看板不可见（自引入频率维度以来一直如此）。现去掉 daily 硬过滤，列表展示所有可见习惯（含每日/每周/每月）；`createHabit` 同步改为不限频率纳入看板白名单，保证周/月新习惯自动进白名单
- **打卡后进度环不实时刷新**：`toggleCheckIn` / `addNumericRecord` 完成后只发了 `NotificationCenter` 通知、未触发 `objectWillChange`，而 `KanbanProgressHero` 仅依赖 `@ObservedObject` 且无通知监听，导致打卡后进度环不更新、需退出重进。`notifyDataChange` 补发 `objectWillChange.send()`，一处惠及所有依赖习惯进度的视图

### 变更
- 今日看板习惯区标题「每日打卡」→「习惯打卡」、空态文案适配（列表现已含周/月习惯）

### 测试
- `build_sim` 编译通过

---

## [2026-06-24] 健康页头部按钮补齐左右留白

### 修复
- **健康首页返回/同步按钮贴屏幕边缘**：`headerView` 顶部按钮行（返回按钮 + 标题 + 同步按钮）原先缺少水平留白，导致返回按钮贴左边缘、同步按钮贴右边缘。现把 padding 提到 `headerView` 整体层级，并去掉 `dateNavigationBar` 重复的 padding，使返回按钮、同步按钮、日期选择栏与下方卡片四者左右边缘对齐

### 测试
- `build_sim` 编译通过

---

## [2026-06-23] 健康页返回与日期导航优化

### 变更
- **健康首页日期切换收敛为居中控件**：把原先贴在左侧的日期左箭头收回到日期标题两侧，形成「上一天 / 当前日期 / 下一天」的一组控件，避免和顶部页面返回箭头在左上区域重复抢层级；非今日时「今天」回跳按钮保留在右侧
- **健康详情页补显式返回入口**：详情页顶部新增与健康首页一致的圆形返回按钮，并让内容滚动区下移到 header 下方，减少 fullScreenCover / push 详情页返回路径不明确的问题
- **边缘返回手势支持隐藏导航栏详情页**：`swipeBackToDismiss` 新增 `ignoreNavigationStack` 参数，用于健康详情页这类隐藏系统导航栏的 push 页面，避免系统返回手势失效后无法返回

### 测试
- `xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-dd-health-date-nav CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/private/tmp/holo-module-cache-health-date-nav build` 通过

---

## [2026-06-23] 知识架构整理：开发规范归仓库、memory 只留协作反馈

### 文档
- **开发规范新增 11.6**：Swift Charts 数据源「质变」禁止 `withAnimation` 包裹（EXC_BREAKPOINT 踩坑立条）；原 11.6 顺延为 11.7 并入 Finance 饼图角度坐标系约定
- **CLAUDE.md 编码约定表**新增「数值型习惯完成判定」高频铁律（有记录即完成，不看达标）
- **CLAUDE.md 模块文档表**清理 5 条虚构路径，Finance 改指开发规范；删除模块级 `Views/Finance/CLAUDE.md`（项目只保留根 CLAUDE.md）
- **memory 重构**：2 条技术规范（Charts 动画 / 习惯判定）迁入仓库文档；新增东林协作画像（user）；修复老记忆 slug 断链

---

## [2026-06-23] 数值型习惯完成判定改为「有记录即完成」

### 变更
- **数值型习惯完成判定调整**：进度环与看板「每日打卡」header 中，数值型习惯（计数类 / 测量类）的「完成」由「今日值达到目标（≥）」改为「**今日有记录即算完成**」。功能核心是鼓励用户保持记录习惯，与数值大小、是否达标无关——体重高低、喝几杯水都不影响，只要记了就算完成
- 移除 `isNumericHabitTargetMet` 目标比较逻辑，简化为 `hasTodayNumericRecord`（今日有记录）

### 测试
- `build_sim` 编译通过

---

## [2026-06-23] 首页进度环 + 今日看板打卡链路修复

### 修复
- **首页习惯进度环冷启动丢失**：`HomeView` 冷启动只初始化了 `TodoRepository` 漏了 `HabitRepository`，导致首页三环习惯进度依赖的 `activeHabits` 内存数组为空、习惯环恒为 0，需进入今日看板后才被加载、杀进程重进又丢失。现补 `HabitRepository.shared.setup()`，并让 `DailyKanbanEntryButton` 监听 `activeHabits.count` 变化补刷新
- **新建每日习惯不出现在今日看板**：用户在「习惯统计设置」配置过看板显示项后，新建习惯不在白名单会被过滤。`createHabit` 现对 daily 习惯自动调用 `HabitStatsDisplaySettings.addDashboardHabitIfNeeded` 纳入白名单（白名单为空=全部显示时不处理）

### 变更
- **进度环纳入数值型习惯**：`getTodayCheckInProgress` 由「仅打卡型」扩展为「打卡型 + 数值型达标」合计——计数类求和 / 测量类取最新值达到目标即算完成，未设目标则今日有记录即算；`KanbanHabitSection` header 口径同步对齐（分母本就含数值型，现分子也含达标）

### 说明
- 数值型「达标」默认规则：计数类 sum ≥ 目标、测量类 latest ≥ 目标、无目标有记录即算；测量类「维持/减重到 X」等目标语义可能不适用 `≥`，后续按需区分正负向
- `seedDailyRitualsForToday()` 空实现属未启用功能，本次不涉及

### 测试
- `build_sim` 编译通过（2 次）

---

## [2026-06-23] 想法模块批量 AI 自动整理

### 新增
- **筛选栏「自动整理」入口**：想法列表「全部」旁新增紫色动作 chip（`sparkles` + AI 角标 + 待整理数徽章），点击弹确认 Sheet，一键给所有未整理想法批量打 AI 标签；整理时 banner 显示「X/总」进度，配额耗尽显示「明日续做」
- **`ThoughtOrganizeActionChip` 组件** + **`Color.holoAI`**（#7C5CFC，AI 专属紫色，区别于品牌橙）
- **`ThoughtRepository` 批量查询**：`fetchUnprocessedThoughtIds` / `countUnprocessed` / `markBatchPending`，用「排除终态」predicate 覆盖 nil/空字符串等脏值

### 变更
- **队列配额错误处理**：`ThoughtOrganizationQueue` 改 `ObservableObject`，识别 `APIError.rateLimited` 后**不重试、当前条回退 pending、当日整体暂停**（原对任何失败重试 3 次会把当天配额在重试里烧光）；条间隔 2s→4s（15/分钟，避开后端 20/分钟限额）
- **`organizeThought` 改 `throws`**：透传 `rateLimited` 给队列；`notFound`/`parseFailed` 直接标 failed 不重试（避免浪费配额）
- **`fetchPendingThoughtIds` 补 `isArchived` 过滤**，与批量查询一致

### 修复
- **老想法被 `createdDeviceId` 过滤导致批量整理捞不到**：`fetchUnprocessedThoughtIds` / `countUnprocessed` 去掉设备过滤——老想法（`createdDeviceId` 为 nil 或旧值）现在能正常纳入；已 `organized` 的无论哪台设备都排除，不重复

### 测试
- `ThoughtOrganizationBatchTests` 新增 7 个用例：未整理范围（纳入 unprocessed/nil、排除终态、排除归档删除）、nil deviceId 老想法回归、计数一致、批量标记状态流转、空列表安全
- `test_sim` 通过

---

## [2026-06-22] 主屏小组件暗色模式可读性修复

### 修复
- **所有主屏小组件适配 dark mode 高对比主题**：`HoloAI 语音启动`、`Holo 快捷控制台`、`今日收支`、`想法随机漫步` 统一读取系统 `colorScheme`，暗色模式下切换为深色背景、高对比白色文字和更亮的品牌橙，避免系统暗色/壁纸材质把浅色小组件压成灰褐色后文字看不清
- **今日收支进度条与金额色增强**：暗色下支出橙、收入绿、预算进度轨道改为专用高对比色，保留轻扫可读性
- **快捷入口与想法标签暗色补齐**：快捷按钮卡片、图标、想法标签底色改为暗色语义色，避免局部仍沿用浅色透明卡片

### 测试
- 四个 Widget 视图均接入 `colorScheme` 与自适应背景的静态检查通过
- `xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-widgets-dark-all-derived CODE_SIGNING_ALLOWED=NO build` 通过

---

## [2026-06-22] 财务分析日期选择重构 + 趋势图修复

### 新增
- **日期范围月历 `DateRangeCalendar`**：自制月历替换原生 `DatePicker(.graphical)`（系统组件不支持高亮一段范围）。范围内日期铺浅品牌色形成连续胶囊，首尾端点实心圆形高亮——横条高度 = 端点圆直径，半圆正好衔接横条，融为一体无方块隔断；支持左右切月

### 变更
- **日期选择融合「点两次自动完成」**：点日期标签直接进入起止选择（原需绕「自定义」按钮）。选开始 → 自动进入选结束 → 选完自动应用关闭。两个 DatePicker 共用独立范围不互相约束，回避「选开始时结束被 clamp 触发误应用」的时序陷阱；应用时保证 start ≤ end
- **外层时间标签居中**：`TimeRangeLabel`（「统计分析」下方的日期标签）两端对称 `Spacer`，整体水平居中于标题正下方
- **柱图与余额折线对齐**：`BarChartView` 去掉 `.position(by:)`，支出/收入柱叠加在同一 X，柱居中对齐余额折线点和触摸指示线（原并排导致柱分两侧、单柱视觉错位）
- **X 轴日期格式 + 稀疏**：按天 label 从 `"d"`（1 2 3）改为 `"M/d"`（6/1）；柱图 X 轴数据点 >14 时只标 6 个稀疏刻度（参照折线图 `axisMarkDates`）
- **单天趋势图修复**：`ChartGranularity.from(dayCount≤1)` 从 `.hour` 改为 `.day`——原按小时展开 24 个空柱（满图空坑），现单天 = 1 个点

### 删除
- **`DrillDownDatePicker`**：原点日期标签弹出的单日下钻选择器（只能选某天跳到所在周/月/季/年，不灵活），融合后无引用

### 说明
- **数据流审查**：概览/明细/类别 tab 的所有统计（`periodSummary` / `chartDataPoints` / 分类聚合 / TOP3）均基于 `currentDateRange` 查的 transactions，一致受时间组件驱动；唯一问题是粒度规则与坐标格式，已修
- 单天范围只有 1 个数据点是正常的（1 天无趋势可言）；柱叠加后支出>收入时收入靠半透明透出，可读性略降但换得柱与折线精确对齐
- build_sim 通过（主 app + widget extension）

---

## [2026-06-22] HoloAI 意图识别上下文瘦身

### 变更
- **意图识别 Router 改为轻量上下文**：`AIUserContextMessageBuilder` 在 `purpose == .intentRecognition` 时不再复用聊天场景的大上下文，提前返回专用最小上下文，只保留日期、今日收支、近期交易、可用账户、默认账户和使用边界
- **去除记账等明确动作的无关干扰**：意图识别日志不再注入用户档案、近期任务、待办积压、近期想法、近期趋势、当前目标等内容，避免简单记账请求被无关生活/任务上下文污染
- **聊天上下文保持不变**：普通聊天仍保留用户档案、趋势、目标、记忆摘要等长期信息，不影响个性化回答和分析表达

### 测试
- `AIUserContextMessageBuilderStandaloneTests` 新增最小 Router 上下文断言，确认 intent 上下文保留财务消歧信息，并排除档案/任务/想法/趋势/目标
- `AIUserContextMessageBuilderStandaloneTests` 通过
- `xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-deriveddata-agent-context build` 通过

---

## [2026-06-22] 今日收支小组件点击跳转财务分析页

### 修复
- **今日收支小组件跳转错误**：`HoloFinanceWidget`（今日收支）点击用 `holo://finance/add`，解析为 `.addTransaction`，HomeView 直接弹记账 sheet——想看分析却被带去记账。改为 `holo://finance/analysis`，新增 `HoloWidgetDeepLink.financeAnalysis`，路由层映射到 `.financeAnalysis(本月范围)`，打开财务页统计 Tab（`FinanceAnalysisView`）显示本月概览

### 变更
- `HoloWidgetDeepLink` 新增 `.financeAnalysis` case，`parse` 加 `holo://finance/analysis` 分支
- `DeepLinkTarget(_ widgetTarget:)`：widget 的 `.financeAnalysis` → `.financeAnalysis(FinanceAnalysisDeepLink)`，复用 `TimeRange.month.dateRange()`（半开区间，下月首日为 end），label 标「本月收支」（`FinanceAnalysisState.applyDeepLink` 只用 start/end，label 不参与）
- 复用现有 `.financeAnalysis` 路由，**未新增 `DeepLinkTarget` 枚举 case**，不影响 ContentView/HomeView/FinanceView 等既有 switch

### 测试
- `HoloWidgetModelsStandaloneTests` 新增 `testDeepLinkParsesFinanceAnalysis`：`holo://finance/analysis` → `.financeAnalysis`，并回归保护 `holo://finance/add` 仍为 `.addTransaction`
- build_sim 通过（主 app + widget extension），test_sim 39/39 通过

### 说明
- `FinanceAnalysisState.applyDeepLink` 收到 link 后设本月范围、清空下钻（`selectedDetailCategory = nil`），打开即本月总览而非某类别下钻
- widget extension 改动需重新 build & run 装机后桌面 widget 才生效（已添加的 widget 实例无需重新添加）

---

## [2026-06-22] 记忆长廊刷新入口统一 + AI 洞察每日配额

### 变更
- **星图「更新」升级为统一入口**：原先星图顶部最显眼的「更新」按钮只刷本地数据（Core Data + HealthKit），真正能重新生成 AI 洞察的「刷新洞察/重新生成」却藏在下方可折叠的「AI 回放」里——用户找不到入口、显眼按钮点了没效果。现 `refresh()` 在本地刷新后，若 AI 洞察刷新配额未满则顺带 `refreshInsight(force:true)`，配额耗尽时只刷本地不报错
- **AI 回放「重新生成/刷新洞察」共享配额**：星图「更新」与 AI 回放两处按钮共用同一 2 次/天配额池，任一处用完两处同步 disabled（按钮变「今日已满」灰色），副标题显示「AI 洞察还能刷新 X 次 / 今日已刷新完」
- **配额守卫位置**：放在 `refreshInsight(force:)` 开头（两入口汇聚点），过了 `generating` 守卫才 `consume()`，避免连点重扣；耗尽时静默返回、不改 `insightGenerationState`（保持已显示的洞察），UI 仅靠 `insightRefreshRemaining` 提示，不新增枚举 case

### 新增
- **`MemoryInsightRefreshQuota`**：每日 2 次配额、按自然日重置。UserDefaults 存「日期戳 + 计数」，复用 `UserDisplayNameSettings` 封装范式 + `Date.isToday`（`CalendarHelpers`）做跨天判定；`init(userDefaults:)` 可注入便于单测隔离。`maxPerDay=2`

### 测试
- `MemoryInsightRefreshQuotaTests`（5）：初始满额 / 消耗到上限 / 超限计数不涨 / 跨天重置后从 1 重新计数 / 同 defaults 新实例可见已用次数
- test_sim 5/5 通过，0 失败；新测试文件用 ruby xcodeproj gem 注册进 HoloTests target

### 说明
- **设计决策**（东林未答取推荐默认）：配额只限 AI 洞察生成（本地刷新便宜，不限次）；全局共享 2 次/天（不分周期，符合「一天 2 次」原话）；旧「重新生成」按钮保留共享配额（诉求是入口明显，非唯一）
- 首次生成（onGenerate，idle 态）不计配额，只限 `refreshInsight` 路径（重新生成/刷新洞察）；Agent 深度分析是独立路径，记忆长廊刷新不触发它重生成，配额不用管
- 同日的「生活星图数据接入修复」见下方条目

---

## [2026-06-22] 记忆长廊生活星图数据接入修复 + 健康卡片接入

### 修复
- **周期回退范围被截断**：`MemoryInsightContextBuilder.periodRange` 用 `min(start.addingDays(N), referenceDate)` 截断 end，本意是「本期不超过今天」，但 `effectivePeriodRange` 回退到上一周期时传入的 `referenceDate` 是历史日期，把上一周期 end 错误截断到周期起点（只剩 1 天）——导致每周一/二/三和每月初 1-6 号时星图全显占位、AI 洞察只看 1 天数据。解耦「周期定位」（referenceDate）与「截断上限」（新增 `now` 参数），回退周期返回完整历史范围
- **星图信号卡片聚合漏算 range 最早几天**：`constellationSignals` 从 `timelineSections`（时间线分页，第一页仅最近 7 天）取数，回退到上一周时 range 是 6/15~6/21 但分页最早只到 6/16，漏掉 6/15 → 财务/习惯/任务卡片误判「等待 XX 记录」。新增 `dailySummaries(items:in:)` 纯函数，按洞察 range 直接从 `cachedItems` 逐天聚合，脱离分页窗口，与 AI 洞察（直接查 Core Data range）取数逻辑一致

### 新增
- **星图健康卡片接入真实 HealthKit**：原先硬编码「健康证据接入中」占位（与 Agent Health 系统无关，是星图这块单独留的坑），现接入 `HealthRepository` 真实睡眠/步数——按洞察周期取日均，转口语化摘要（如「本周平均睡 7.2 小时，每天走 8521 步左右」/「本周睡得偏少，平均才 5.5 小时」），复用 AI 洞察侧健康阈值（睡眠偏少 < 6h、步数偏低 < 3000）；未授权显示「等待健康数据」引导，已授权无数据显示占位，切换洞察周期时数据与周期词（本周/本月/这段时间）同步重算

### 测试
- `MemoryInsightContextBuilderPeriodRangeTests`（4）：周一/月初回退覆盖完整上一周期 + 不回退对照
- `MemoryGalleryViewModelConstellationTests`（4）：range 起点必覆盖、range 外不计入、空 items、多类型聚合
- `MemoryGalleryConstellationHealthTests`（7）：正常 / 睡眠偏少 / 步数偏低 / 只睡眠 / 只步数 / 无数据 / 周期词
- test_sim 全量 34/34 通过，0 失败 0 跳过

### 说明
- AI 洞察（生成式回放）的健康数据此前已接入 HealthKit，本次是星图信号卡片补齐
- 星图故事片段区（`featuredNarrativeNodes` 高亮/里程碑）仍依赖 timelineSections 分页，回退周期可能少一个故事片段，但不会误判「无数据」，留作后续
- 真机验证：模拟器走 mock 健康数据，真机才读真实 HealthKit；新测试文件用 xcodeproj gem 注册进 HoloTests target（非文件系统同步组）

---

## [2026-06-21] Agent 证据核验 + 财务关键词趋势 + 记忆星图改版

### 新增
- **Agent 声明核验（防幻觉）**：Agent loop 在工具执行后即时生成 `HoloEvidenceRecord` 持久化（携带真实 `timeRange`/`baselineTimeRange`），结果阶段引入 `HoloClaimVerifier` 核验每条 claim 的证据支撑，仅保留 `acceptedClaims`——无证据支撑的声明被丢弃，杜绝 Agent 编造数据；`HoloLocalAgentRuntime` 新增 `evidenceRecords(from:)` + `sourceModule(for:)` 映射
- **财务关键词趋势查询（keyword_trend）**：`HoloFinanceTool` 新增 keyword_trend 查询，按关键词（咖啡/奶茶/星巴克等）在 note/remark/category/tags 全文检索，返回本期 vs 对比期命中次数、金额与脱敏样例（最多 5 条）；`validate` 强制要求 `parameters.keyword`
- **财务证据核对页**：新增 `FinanceEvidenceReviewView`（320 行），从 Agent 深度分析卡片下钻到原始账单明细（本期 + 对比期并排），支持就地编辑纠正；配套 `FinanceEvidenceReviewDeepLink` / `FinanceAnalysisDeepLink` 路由（`DeepLinkState` + `HomeView` + `FinanceView` 接入）
- **记忆星图改版组件**：新增 `MemoryConstellationCard`（345 行，记忆星座卡片）+ `GentleHighlightNode`（78 行，柔和高亮节点），`MemoryGalleryView`/`ViewModel`/`MemoryConstellationModels` 重构星图呈现

### 变更
- **证据携带时间范围**：`HoloEvidenceEvent`/`HoloEvidenceRecord` 新增 `timeRange`/`baselineTimeRange` 字段，`HoloRenderedEvidenceReference` 新增 `financeDrilldown`（带时段 + 关键词），证据从脱离上下文的纯文本升级为可下钻的结构化引用
- **财务时间范围边界修正**：`HoloDefaultFinanceDataSource.snapshot` 重算 currentEnd/baselineEnd（baselineEnd 由 currentStart 起算），snapshot 签名增加 `parameters` 参数，避免本期/对比期边界重叠错位
- **agentLoop Prompt v1→v2**：PromptManager 引导 Agent 遇到具体消费对象/商品/品牌趋势查询时优先请求 `finance.keyword_trend` 并填 `parameters.keyword`，不再用分类集中度敷衍

### 测试
- `HoloFinanceToolTests`（keyword_trend 命中/金额/样例）、`HoloAgentResultRendererTests`（financeDrilldown 渲染）、`HoloLocalAgentRuntimeTests`（证据持久化 + 核验）、`ChatMessageViewDataAgentResultTests` 同步补齐

### 说明
- 预先存在的 Swift 6 actor 隔离 warning（main actor-isolated conformance）非本次引入，属历史技术债，build succeeded 无 error

---

## [2026-06-15] 健康模块补齐固定返回按钮（对齐全局 fullScreenCover 约定）

### 修复
- **健康模块此前无返回入口**：`HealthView` 隐藏了系统导航栏（`.toolbar(.hidden, for: .navigationBar)`）且 header 在 `ScrollView` 内随内容滚动消失，正常使用时只能靠右滑手势返回；而记账/习惯/待办/观点四个同级 `fullScreenCover` 模块都有 `chevron.left` 返回按钮，唯独健康漏了
- **统一固定返回栏**：新增 `backButton` + `topBackBar` 复用组件，content 分支 `headerView`（返回 + 标题 + 同步 + 日期导航）移出 `ScrollView` 固定在顶部，对齐 `FinanceLedgerView`；权限引导 / 不可用兜底两个边界分支前置 `topBackBar`，三分支都有固定返回入口
- 保留 `.swipeBackToDismiss` 手势作为补充；改动集中在 `HealthView.swift` 单文件

---

## [2026-06-14] 图标系统重构（财务侧 · 占比统一 + 语义重选）

### 变更
- **统一图标占比**：新增 `CategoryIconBadge` 组件（单一占比常量 0.58、底色透明度 0.12、选中态加深+描边），替换 14 处散落的 `ZStack { Circle + icon }` 硬编码（TransactionCategoryGrid / CategoryPicker / CategoryManagementView / CategoryBudgetPicker / AccountDetailView / FinanceComponents 等），解决原 `size * 0.6` 折算导致图标占比仅 30%、小且看不清的问题
- **重选 16 个语义错位 / 识别度差的图标**：
  - A 类语义错位（8）：夜宵 moonphase→`mug.fill`、旅行 figure.walk→`airplane.departure`、过路费 building.columns→`road.lanes`、保健品 leaf→`pill.fill`、美妆 sparkles→`wand.and.stars`、娱乐一级 music.note→`theatermasks.fill`、房租 key→`house.lodge.fill`、家政保洁→`bubble.left.and.bubble.right.fill`
  - B 类自绘换 SF Symbol（5）：早餐 / 午餐 / 晚餐 / 水果 从手画 Path 换成 `sunrise.fill` / `fork.knife.circle.fill` / `moon.stars.fill` / `carrot.fill`
  - C 类重复差异化（3）：请客→`person.2.fill`、送礼→`shippingbox.fill`、罚款→`yensign.circle.fill`
- **数据迁移 v4**：`migrateRefreshedCategoryIcons` 按 name + isDefault + 旧 icon 三重匹配，把老用户的旧图标名平滑迁移到新 SF Symbol，幂等、不误伤用户自定义分类

### 说明
- 牙齿保健（SF Symbols 无 tooth）、烟酒（无 cigarette）本轮摘出，由产品侧后续处理
- 4 个 `holo.category.*` 自绘 Shape 代码保留兜底，但已从图标选择器候选库移除（breakfast/lunch/dinner/fruit），避免用户再选到识别度差的自绘图标
- 习惯侧、收入侧图标留作第二阶段

---

## [2026-06-14] Agent 深度分析卡片化（阶段 1：卡片化 + 排版）

### 新增
- **Agent 深度分析结果卡片化**：Agent loop 结果从「纯文本气泡」改为 Chat 内卡片承载（入口卡四态：loading/loaded/unloaded/degrade），点击进入结构化详情 Sheet（核心结论卡 + 观察段 + 数据依据段）。新增 `AgentDeepAnalysisCard` + `AgentDeepAnalysisDetailSheet`，复用底层组件（ChatCardView/CardHeaderView/HoloAIHeroMetric/HoloAIFactItem）
- **agentResultJSON 持久化**：`ChatMessage` 新增 `agentResultJSON` Core Data 字段（轻量迁移），结构化存储 `HoloRenderedAgentResult`；`ChatMessageViewData` 加 `agentResult` 字段 + `decodeAgentResult`，4 处 init 解码 + 向后兼容
- **XCTest test target 启用**：项目原本无 test target（HoloTests/ 孤儿目录），本次启用 HoloTests target + 修正 widget 扩展 Bundle ID（`com.holo.HoloWidgets`→`com.holo.Holo.HoloWidgets`，符合 iOS 扩展规则），test_sim 可跑标准 XCTest

### 修复
- **渲染器 title/body 同值浪费**：`HoloAgentResultRenderer.render` 之前 section 的 title 和 body 都设成 `claim.displayText`（同值，无视觉层级）；改为 title 用「观察 N」短 kicker、body 用 claim 正文
- **section 暴露 confidence**：`HoloRenderedAgentSection` 新增可选 `confidence: Double?`，透传 `claim.confidence`，为阶段 2 可视化铺路；Codable 向后兼容，旧 JSON 缺该字段解码为 nil
- **ChatViewModel 不再拍扁结果**：Agent 路径之前用 `\n` 把 title+summary+所有 claims 拼成一坨文本塞气泡（连 markdown 都不渲染）；改为结构化存 agentResultJSON，由卡片渲染

### 测试
- test_sim 11/11 通过：渲染器 7 个（title≠body、confidence、多 claim title 互不相同 + 4 旧测试）+ ViewData 编解码 4 个（valid/nil/invalid/旧 JSON 向后兼容）

### 说明
- 阶段 2（AI 驱动可视化：预算进度条/趋势图/对比条/数据源表格）、阶段 3（目标+感受工具）、阶段 4（全局 AI→Holo 文案）待后续

---

## [2026-06-14] HoloBackend 模型路由分级 + 全量迁移 DeepSeek V4

### 变更
- **Agent 升级 Pro**：agent_loop 路由单独切到 `deepseek-v4-pro`（默认思考模式），配套 maxTokens 2048→8192 给思考过程留空间，否则 JSON 易被思考 token 截断触发 INVALID_AGENT_JSON；普通记账/对话/意图识别不受影响仍走 flash
- **全量迁移 V4 新名**：chat / intent / insight 及所有回退路由（finance/task parser、voice summary、memory observer、thought org）从旧名 `deepseek-chat` 显式迁到 `deepseek-v4-flash`（官方别名，行为零变化），规避 DeepSeek 旧名 2026/07/24 弃用

### 说明
- 后端按 purpose 路由分流，iOS 端零改动、立即生效（model 由后端决定，App 无需重开）
- 最终路由：对话/记账/意图/洞察/解析 → v4-flash（非思考）；Agent 深度推理 → v4-pro（思考）
- 冒烟验证：pro 思考内容走 reasoning_content 不污染 JSON（4.7s 通过校验）；v4-flash chat 1.1s 正常返回
- 服务器 .env.production 改动不入 git（被 gitignore），仅同步 env.production.example 模板

---

## [2026-06-14] Agent 灰度开关 UI 接入「设置 → AI」

### 新增
- 设置 → AI 新增「Agent 深度分析（灰度）」Section，四个 Toggle 一步到位开关：Agent 深度分析引擎 / 记忆长廊展示 Agent 结果 / 后台观察自动深挖 / Agent 调试入口，全部默认关

---

## [2026-06-14] HoloAI Agent V3.1 数据时间范围接 ToolRequest（遗留 ③）

### 修复
- **时间范围动态化**：Habit/Finance dataSource 协议加 timeRange 参数（habits(timeRange:) / snapshot(timeRange:baseline:)），Tool.execute 从 HoloToolRequest 提取传参，生产实现用 timeRange.start/end 算日期范围（nil 默认 14 天），aggregate bucket 动态 dayCount
- test mock 同步签名，standalone 工具测试回归绿

### 说明
- HoloAgentTimeRange 是简单 struct（start/end Date），无需枚举解析；链路：request.timeRange → execute 传 → dataSource → 动态日期范围
- xcodebuild BUILD SUCCEEDED + standalone HabitTool/FinanceTool 回归绿

---

## [2026-06-14] HoloAI Agent V3.1 修复 Agent 结果渲染（遗留 ②+①）

### 修复
- **对话结果短文**（①）：AnalysisService.runAnalysis 改为返回渲染后的 HoloRenderedAgentResult，ChatViewModel 用 title/summary/claims 拼成短文，替代之前的「深度分析已完成」占位文本
- **evidence 引用**（②）：新增 PersistenceManager.loadEvidence / runtime.loadEvidence（按 ID 从 ledger 读证据记录），记忆长廊卡片与对话短文经 HoloAgentResultRenderer 渲染时携带脱敏证据引用

### 说明
- xcodebuild BUILD SUCCEEDED + standalone PersistenceManager/AgentRuntime 回归绿

---

## [2026-06-14] HoloAI Agent V3.1 Habit/Finance 工具接真实数据（Task #34）

### 新增
- **习惯数据源**：HoloDefaultHabitDataSource 包裹真实 HabitRepository，按日聚合近 14 天打卡/数值记录为 dailyCounts（数值型累加 value，打卡型 +1），转 HabitTool 中性结构
- **财务数据源**：HoloDefaultFinanceDataSource 包裹真实 FinanceRepository，聚合本期/基线（各 14 天）的晚间餐饮频次（22:00–06:00 + 餐饮关键词）、分类次数、支出金额
- **三工具注册**：生产 runtime 现注册 Memory + Habit + Finance 三个工具，Agent 可读三域真实数据

### 说明
- 习惯同步 repo 经 MainActor.run 保证 Core Data 线程安全；财务 async getTransactions 直接 await
- 生产 DataSource 仅随 app 编译，不进 standalone 测试；xcodebuild BUILD SUCCEEDED + standalone 工具测试回归绿

---

## [2026-06-14] HoloAI Agent V3.1 Observer 自动触发深度 Agent（Phase 6.4）

### 新增
- **Tier2 触发接线**：HoloMemoryObserverService 跑完 Tier1 浅观察后，在 agentObserverTier2Enabled 灰度下，将目标信号确定性映射为 goalConflict pattern，经 HoloObserverTriggerPolicy 判断（360 分钟冷却 + 严重度），命中则 fire-and-forget 启动 Tier2 深度 Agent
- 冷却时间持久化在 UserDefaults；Tier2 在 @MainActor Task 异步跑，不阻塞 Observer

### 说明
- patterns 映射为简单规则（目标信号数 → goalConflict high pattern），语义可后续细化
- Policy 与 standalone 测试此前已完成；本次仅接线。xcodebuild BUILD SUCCEEDED

---

## [2026-06-14] HoloAI Agent V3.1 记忆长廊展示 Agent 结果（Phase 6.3）

### 新增
- **Agent 结果落盘**：runLoop 完成 final_claims 时构造 `HoloAgentResult`（claims + 汇总 evidenceIDs）并持久化，补齐 6.2 的结果产物缺口
- **结果读取链**：`ResultStore.latest` / `PersistenceManager.saveResult`+`loadLatestResult` / `runtime.loadLatestResult`
- **记忆长廊展示**：MemoryGalleryViewModel 在 agentMemoryGalleryEnabled 灰度下读取最近 Agent 结果，新增 `HoloAgentResultCard` 卡片展示 verified claims；旧 insight 保留 fallback

### 说明
- evidence 引用渲染待后续接入 evidence 读取；agentMemoryGalleryEnabled 默认关，不影响线上
- xcodebuild BUILD SUCCEEDED + standalone PersistenceManager/AgentRuntime 回归绿

---

## [2026-06-14] HoloAI Agent V3.1 对话深度分析接入本地 Agent（Phase 6.2）

### 新增
- **对话→Agent 分流**：query_analysis 意图命中（agentRuntimeEnabled 灰度）时，ConversationCoordinator 分流到本地深度 Agent，ChatViewModel 启动 Agent job 并展示「正在深度分析」状态
- **生产 Agent runtime**：`HoloLocalAgentRuntime.shared` 升级为生产 runtime（接真实后端 LLM + Memory 工具），5.1 后台续跑与 6.2 对话分析共用同一实例
- **AnalysisService**：封装「创建 job → 构建 agent_loop 提示 → 多轮 runLoop」单一入口
- **工具装配同步化**：HoloToolRegistry 支持 `init(tools:)` 同步构造，避开 actor 异步装配

### 说明
- 结果短文渲染（claims → 可读文本）与 Habit/Finance 工具生产数据源待后续接入
- agentRuntimeEnabled 默认关，不影响线上；xcodebuild BUILD SUCCEEDED + standalone AgentRuntime 回归绿

---

## [2026-06-14] 财务与习惯图标语义体系优化

### 优化
- **财务默认科目图标重设计**：早餐 / 午餐 / 晚餐 / 水果改用 Holo 自绘语义图标，不再用日出、太阳、月亮或胡萝卜硬代替
- **历史用户自动迁移**：已有默认餐饮科目若仍使用旧图标，会自动迁移到新语义图标；用户自定义过的非默认分类不强制覆盖
- **聊天卡片与财务局部页面统一渲染**：分类选择器、聊天记账卡片、账户明细、预算选择、导入匹配等入口共用同一套图标渲染逻辑，避免局部空白或风格割裂
- **习惯图标预设补齐**：感恩改为心意文本图标，减少改为中性的 minus 圆形图标；新增呼吸、拉伸、护眼、站立、编程、日记、数据复盘、控制、少刷短视频、减少咖啡因等预设

### 验证
- xcodebuild generic iOS build succeeded
- `VerifyChatCardData.swift` standalone 校验 33/33 通过

---

## [2026-06-14] HoloAI Agent V3.1 后台续跑接入 App 生命周期（Phase 5.1）

### 新增
- **Agent 后台续跑接线**：新建 `HoloAgentRuntimeShared`（runtime + 后台续跑管理器双 App 级单例）；`HoloApp` 监听 `scenePhase`，进后台暂存 checkpoint、回前台恢复未完成任务，全程 `agentRuntimeEnabled` 门控（默认关，不影响现有行为）

### 说明
- 仅接线场景生命周期；Agent 真正端到端运行（生产 runtime + 启动入口）在后续 Phase 6.2 接入
- xcodebuild BUILD SUCCEEDED

---

## [2026-06-13] 修复习惯信号判断与手势冲突

### 修复
- **习惯信号区分四种状态**：新增 `buildHabitSignal` 独立函数，区分「未打卡 / 部分完成 / 全部完成 / 断节奏」，不再笼统显示"打卡都完成了"
- **DailySense 快照升级至 schema v4**：新增 `isCurrentSchema` 属性，旧版本快照自动重新生成；新增 `invalidateToday()` 供源数据变更后清除缓存
- **手势冲突修复**：HealthDetailView / HealthView 的自定义 DragGesture 替换为统一 `swipeBackToDismiss` 修饰符
- **首页功能按钮点击修复**：TapGesture 改为原生 Button，拖拽 minimumDistance 从 0 调至 6，避免普通点击被卷入拖拽

### 新增
- 4 份 HoloAI Agent 架构方案文档（V1 → V3.1 迭代过程）

---

## [2026-06-13] HoloAI Agent V3.1 本地优先地基（Phase 0 + Phase 1）

### 新增
- **Agent 可恢复执行骨架**：新增本地优先的 Agent 运行时（`HoloLocalAgentRuntime`），支持任务启动、分步推进、App 重启后从断点自动恢复、随时取消，全程不依赖云端状态
- **可信持久化层**：任务 / 断点 / 结果 / 证据分仓库原子落盘，写入顺序固定（证据 → 断点 → 任务状态），崩溃后状态保持一致；支持孤儿证据归档与断点引用校验
- **统一数据模型**：定义 Agent 任务、预算、断点、工具请求、证据、模式信号、结果等 8 类模型，作为整个 AI 洞察体系的数据基础
- **安全开关与止血**：4 个灰度 Feature Flag（默认全关）、旧格式浅摘要标记拦截、Agent 子系统调试快照导出（`HoloAgentDebugExporter`）
- **Mock 生命周期验证**：用 mock 数据跑通「启动 → 推进 → 重启恢复 → 取消」完整闭环，证明可恢复承诺

### 说明
- 本阶段不接入真实 LLM 与数据工具，仅夯实确定性骨架；真实能力在后续阶段逐步接入
- 位于分支 `feature/holoai-agent-v31-foundation`，Feature Flag 默认关闭，不影响线上功能

### 验证
- swiftc 独立测试用例全部通过 + xcodebuild BUILD SUCCEEDED

---

## [2026-06-12] 习惯统计周视图对齐为周一至周日

### 修复
- 月历格子强制从周一开始排列，不再跟随系统地区设置
- 星期表头重排为「周一、周二、…、周日」
- 好习惯和坏习惯的月份格子构建统一生效

---

## [2026-06-12] 修复习惯完成率分母计算

### 修复
- **完成率分母改为按频率和目标次数折算**：好习惯的完成率分母从「时间范围天数」改为「期望完成次数（dayCount × targetCount ÷ periodDays）」，例如「每周 4 次」在 7 天内分母为 4 而非 7
- 新增 `expectedCompletions(for:inDays:)` 统一计算方法，替代原来 `getCompletionStats` 中硬编码的 switch 逻辑
- 涉及 `calculateCheckInCompletionRate`、`calculateNumericCompletionRate`、`getCompletionStats` 三个方法

---

## [2026-06-12] 修复删除习惯闪退

### 修复
- **删除习惯不再闪退**：`HabitListView.loadHabits()` 移除 `Task { @MainActor in }` 延迟包裹，改为同步更新 `habits` 数组
- 根因：`@Published activeHabits` 更新触发 SwiftUI 重渲染，但 `Task` 延迟了本地 `habits` 数组更新，导致 `ForEach` 用旧数组渲染已删除的 Core Data 对象

---

## [2026-06-12] 任务模块「检查项」更名为「子任务」

### 优化
- 任务模块中所有「检查项」相关文案统一更名为「子任务」，包括页面标题、空状态提示、输入框占位符、函数注释和错误日志
- 涉及 ChecklistView、AddTaskSheet、TaskCardView 等 7 个文件，代码逻辑和变量名不变

---

## [2026-06-11] 想法图片贴合正文布局

### 优化
- 想法编辑页中图片预览并入正文内容卡片，跟随文字末尾展示，不再作为独立附件卡片割裂显示
- 想法详情页中图片缩略图贴在正文内容下方，保持内容和图片的一体化阅读体验
- 想法列表卡片直接在「展开/收起」下方展示图片缩略图，替代底部纸夹数量提示

### 验证
- iOS Debug build 通过：`xcodebuild -project ".../Holo.xcodeproj" -scheme Holo -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`

---

## [2026-06-11] AI「今日状态」上下文数据修复

### 修复
- **任务统计不再包含历史任务**：`todayTotal` 改为 `dueToday`（今日到期）和 `completedToday`（今日完成），不再把所有历史未删未归档任务算作"今日任务"
- **习惯今日打卡详情填充**：`recentCheckIns` 从硬编码空数组改为展示每个习惯的今日状态（打卡型：已打卡/未打卡，数值型：具体数值，负向习惯：已发生/未发生）
- **负向习惯语义分离**：习惯摘要分正向（已打卡）和负向（已发生）独立展示，避免 AI 说出"坏习惯完成率为 0 需要加油"这类反直觉的话

### 改进
- AI 上下文中任务信息分为「今日到期/今日完成/逾期」三个独立数字，语义更清晰
- 新增「待办积压」展示未完成任务列表，AI 能看到当前有哪些待办
- 近期任务列表增加兜底逻辑：今日到期任务不足 3 条时自动补充最近的未完成任务
- `HabitRepository` 新增 `getTodayCheckInSplit()` 方法，分正负向统计打卡进度

---

## [2026-06-11] 图片画廊交互优化

### 改进
- 图片浏览器从 SwiftUI 手势切换为 `UIScrollView`（`GalleryScrollView`），未缩放时手势穿透 TabView 实现左右滑动翻页
- 单击图片退出全屏画廊，双击缩放/还原，互不干扰
- 提取共享组件 `GalleryScrollView`，供任务和想法两个模块的图片浏览器共用

---

## [2026-06-10] 想法模块支持图片上传

### 新增
- 新增 `ThoughtAttachment` CoreData 实体，支持想法关联多张图片附件（最多 9 张）
- 想法编辑器（ThoughtEditorView）新增图片选择功能：支持从相册选择和拍照两种来源
- 想法编辑器展示图片缩略图网格：3 列布局，支持添加、长按删除、点击全屏浏览
- 新增 `ThoughtGalleryView` 全屏图片浏览器：横向滑动浏览、双指缩放、双击缩放、页码指示
- 想法详情页（ThoughtDetailView）新增图片缩略图横向列表，点击可全屏浏览
- 想法卡片（ThoughtCardView）新增图片数量指示器（📎 图标 + 数量）

### 数据层
- `ThoughtRepository` 新增附件扩展：addAttachment / deleteAttachment / reorderAttachments
- 删除想法时自动清理附件文件（cascade 级联删除 + 磁盘文件清理）
- 图片数据存入 CoreData 二进制字段，支持 iCloud 同步

### 验证
- iOS Debug build 通过：`xcodebuild build` 编译成功

---

## [2026-06-10] App 启动页视觉改造

### 新增
- 新增全屏 `LaunchScreen.storyboard`，App 冷启动时使用 Holo 专属启动页视觉，避免系统自动启动屏的空白感
- 新增 SwiftUI 启动过渡页，进入主界面前短暂展示同一套 Holo 启动视觉，减少冷启动到首页的突兀切换
- 新增 `StartupSplashArtwork` 图片资源，按现代 iPhone 竖屏比例重新适配，避免上下留白和主体拉伸

### 优化
- 启动页从“居中 App icon”改为完整品牌插画，顶部状态栏和底部 Home Indicator 区域都由画面自然铺满
- 过渡页支持减少动态效果设置，降低系统辅助功能场景下的视觉干扰

### 验证
- iOS Debug build 通过：`xcodebuild -project ".../Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-startup-splash-derived CODE_SIGNING_ALLOWED=NO build`

---

## [2026-06-09] 想法卡片文本行间距优化

### 优化
- 想法卡片正文增加行间距（lineSpacing: 8pt），多行文字阅读更舒适
- 卡片内边距从 16pt 增加到 20pt，区域间距从 12pt 增加到 16pt
- 卡片圆角从 12pt 调整为 16pt，视觉更柔和
- ExpandableText 组件支持可配置的 lineSpacing 参数
- 修复卡片预览丢失段落换行的问题，多段落内容现在能正确体现段落感

---

## [2026-06-09] AI 记账分类智能兜底 + 想法模块 AI 自动整理

### 记账分类智能兜底
- 品牌名记账（麦当劳、张记面馆等）不再直接归为「待分类」，AI 语义理解自动识别所属大类
- 餐饮类分类跟随时间动态推断：早上→早餐、中午→午餐、晚上→晚餐、深夜→夜宵
- 已学习的品牌记忆不再锁死到某个餐段，同一品牌不同时间自动适配
- Prompt 优化：品牌类消费必须填写所属一级分类

### 想法模块 AI 自动整理
- 想法保存后自动触发 AI 标签归类，串行队列 + 指数退避重试
- 详情页展示 AI 标签区域，支持确认/拒绝操作
- 列表卡片 AI 标签角标 + 处理中状态条
- 后端新增 thought_organization 路由和 prompt 配置

---

## [2026-06-09] HoloAI 财务查询卡片体验优化

### 优化
- 灵活财务查询卡片从“完整明细列表”调整为“答案摘要 + 3 条最近明细 + 查看全部入口”，突出总金额和查询结果本身
- 明细行去掉厚重嵌套卡片样式，降低聊天页视觉负担
- 「查看全部 N 笔」支持带关键词进入财务搜索结果页，单条明细仍可直接打开具体记账明细

---

## [2026-06-08] 洞察推送文案修复

### 修复
- 定时通知文案从「本周/本月记忆已准备好」改为「上周/上月」，与实际推送的数据周期一致
- 首页信号灯标签跟随 `effectivePeriodRange` 回退状态：周期刚开始时显示「上周/上月洞察」，周期中后期显示「本周/本月洞察」

---

## [2026-06-08] 记一笔科目管理 Bug 修复

### 修复
- 记一笔中新增一级科目后不显示在分类网格最外层（根因：过滤条件要求一级分类必须包含子分类）
- 删除科目时的防御性加固：防止访问已删除 NSManagedObject 导致崩溃
- 分类数据刷新后自动清理 `selectedCategory` / `drillDownParent` 的失效引用

---

## [2026-06-08] HoloAI 多层路由 Prompt 瘦身

### 优化
- `intent_recognition` prompt 从 11007 字符精简至 2347（降幅 78.7%），降低 token 消耗和路由噪音
- 去掉全字段 JSON schema、科目归一规则、坏习惯语义规则等下沉内容，Router 只做意图分流和基础字段抽取
- 保留 `flexible_data_query`/`query_analysis` 分流规则和 `subtasks`/`description`/`reminderDate` 最小规则

### 后端
- 新增 9 个 golden test，覆盖 11 个核心意图用例（record_expense/income/create_task/check_in/flexible_data_query/query_analysis/query）
- Mock provider 扩展支持全部 golden test 用例
- `promptRegistry.js` 版本 15→17，`defaultPrompts.json` 同步更新
- 线上已部署验证：version=17, contentLength=2347, source=default_sync

### iOS
- `PromptManager` fallback prompt 同步精简，版本 14→17
- 时间映射对齐后端（早上/上午=09:00）
- `ConversationCoordinator` parser 合并改为显式 `Set<String>` 白名单，防止 parser 字段覆盖基础字段
- 新增 `#if DEBUG` 探针日志（只记录 key set，不记录 value）

### 方案文档
- `docs/_common/plans/2026-06-07-HoloAI多层路由Prompt瘦身方案.md`（经三轮审查定稿）

---

## [2026-06-07] HoloAI 负向习惯分析口径修正

### 修复
- 习惯分析卡片识别到戒烟、控烟等负向习惯时，指标文案改为“控制/完成记录”“平均控制/完成率”和“控制/完成趋势”
- 避免把减少型坏习惯继续按正向习惯的“完成率”口径展示，降低 HoloAI 对戒烟类目标的误读感

### 验证
- iOS Debug build 通过：`xcodebuild -project ".../Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

## [2026-06-07] AI 回复时自动收起键盘

### 修复
- AI 开始流式回复时自动收起键盘，避免键盘遮挡回复内容

## [2026-06-07] 智能分类归纳学习

### 新增
- 智能分类归纳：用户多次修正同一类消费的分类后，LLM 自动归纳出规律规则并持久化，后续同类消费自动匹配正确分类
- pending card 编辑确认时触发分类学习，记录用户修正的分类用于后续归纳
- 后端新增 category_pattern_induction Prompt 模板和路由

## [2026-06-07] Holo AI Sense Loop 公测人格化闭环

### 新增
- HoloAI 表达强度层：新增 observe / summarize / remind / suggestAction / celebrate 决策，聊天与洞察上下文会带入允许表达和禁止表达边界
- Daily Sense v3：保留 3 个主状态，新增“信号偏紧”和“出现新阶段”标签，旧 v2 缓存可继续解码
- 生活模式模型：新增 HoloLifePatternModel / HoloLifePatternService，用稳定反馈沉淀低价值主题，避免单次异常长期化
- 洞察反馈新增“没感觉”和“少提醒这个”，用于公测收集用户是否真的觉得 Holo 懂自己

### 改进
- 洞察偏好画像会把 notMeaningful / tooFrequent 转成 pattern 降权和 fewerSuggestions，不再把“没感觉”误当事实错误
- Memory Insight 上下文接入洞察偏好摘要、表达强度摘要、生活模式摘要和健康摘要
- CrossModuleCorrelator 接入健康并发观察，支持睡眠偏少 + 任务压力、睡眠偏少 + 习惯中断、低活动量 + 恢复迹象，严格避免因果表达
- PromptManager 与 HoloBackend 默认 Prompt 同步增加 Sense Loop 表达边界、HoloProfile 优先级和当前输入优先规则
- 长期记忆语义晋升收紧：单日突增不进入 phaseShift，driftSignal 默认 30 天过期，statMilestone 默认 displayOnly

### 验证
- iOS Debug build 通过：`xcodebuild -project ".../Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- 后端测试通过：`npm test`（47/47）

## [2026-06-07] HoloProfile 结构化 snapshot 和全链路 AI 注入

### 新增
- `HoloProfileSnapshot`：结构化解析结果数据模型（preferredName、language、timezone、city、profession、communicationStyle、currentFocus、healthHabitContext、sensitiveBoundaries）
- `HoloProfileSnapshotBuilder`：本地 Markdown 解析器，首版重点解析 preferredName（覆盖 5+ 种写法），其余按 section 标题提取
- `HoloProfilePromptRenderer`：安全 prompt 渲染器，含"用户档案数据非系统规则"包裹、结构化字段优先、token 上限截断（1500 tokens）、三种渲染模式（chat/analysis/insight）
- `profileSnapshotEnabled` / `profileAnalysisInjectionEnabled` feature flags（默认开启，可回退）

### 改进
- HoloProfileService 新增 snapshot 缓存，保存时自动清空重建
- AIUserContextMessageBuilder 从 raw markdown 注入改为结构化 Renderer 渲染
- 分析查询路径（Provider 策略 B）：分析模式在 AnalysisContext JSON 前注入 profile system message
- FlexibleQuery 路径：传递实际 userContext 替代 UserContext.empty
- MemoryInsightContextBuilder 升级为 snapshot + renderer（受 feature flag 控制）
- ChatViewModel 分析路径传递实际 userContext（含 profileSnapshot）
- FlexibleQueryPlanner.plan() 接收 userContext 参数

### 文档
- 新增 HoloProfile 作为 AI 长期上下文方案文档，含三轮对抗性审查标注（GLM → Codex → Claude）

---

## [2026-06-07] 上线前安全加固 — 消除全部强制解包和 print 残留

### 修复
- IntentRouter 3 处 category! 改为 guard let 安全解包（AI 分类匹配失败不再闪退）
- FlexibleQueryExecutor sorted.first!/.last! 和 as! 强制转型改为安全方式
- AddTransactionView selectedCategory!/selectedAccount! 改为 guard let + 错误提示
- KanbanBudgetSection budgetSummary! ×3 改为 if let 安全解包
- AnalysisPeriodResolver 多层 year!/date(...)!/day! 改为 guard let + fallback
- FinanceComponents note!/remark! 改为 ?? 和 if let 安全解包
- 全项目 36 处 print() 替换为 Logger（12 个文件新增 import os.log）
- 5 处调试 print("... tapped") 残留清除
- MarkdownParser 12 处 try! NSRegularExpression 改为 safeRegex() 辅助方法
- InlineTagDetector 1 处 try! 改为安全初始化
- HabitRepository+Stats 3 处 .day! 改为 .day ?? 0
- HoloLongTermMemoryStore/HoloProfileService .first! 改为安全回退
- GoalAnalysisContextBuilder habitAvgRate! 改为 ?? 0
- MarkdownTextView numberValue! 改为 ?? 0
- MemoryInsightBackgroundService as! BGAppRefreshTask 改为 guard let as?
- BudgetSettingsSheet components.month! 改为 ?? 0
- AIParseBatchValidator primary!/sub! 改为 ?. 安全访问

### 优化
- 后端 errors.js publicMessage 映射补全并按分类整理
- 后端 SSE 流式错误事件同时返回 code 和 message
- PrivacyInfo.xcprivacy：移除 VoiceRecordingService 中未使用的 FileTimestamp API 调用（.creationDateKey → nil），避免苹果静态分析误报
- 账号删除流程：新增 markAccountDeleted() 替代 signOut()，明确区分账号删除与退出登录场景（Guideline 5.1.1 合规）

---

## [2026-06-07] App Store 上架预检修复

### 新增
- 隐私政策页面（完整 HTML，本地离线可用，自动适配深色模式）
- 用户协议页面（完整 HTML，本地离线可用，自动适配深色模式）
- 法律文档查看器 LegalDocumentSheet（WKWebView 渲染）
- 设置页新增「法律与隐私」section，可直接查看隐私政策和用户协议

### 修复
- 后端错误消息中文化（errors.js 补全 6 个缺失的 publicMessage）
- 后端 SSE 流式错误事件包含用户友好的中文消息
- iOS APIClient 优先解析后端返回的中文错误消息
- iOS APIError 枚举描述改为用户友好的中文文案
- ImportExportView「加载测试数据」用 #if DEBUG 包裹，Release 不可见

---

## [2026-06-07] 记忆管理类型化重构

### 新增
- 5 种语义类型（阶段变化/稳定习惯/偏离提醒/人生节点/轻量记录）替代旧来源类型，记忆按 AI 使用场景分类
- 双摘要机制：displaySummary（用户审核）+ aiUseSummary（AI 召回上下文 + 误用边界）
- 记忆候选语义 Mapper（MemoryCandidateSemanticMapper）：校验 LLM 输出、本地补默认值、降级处理
- useScopes 使用场景筛选：coreContext/recentInsight/goalPlanning/retrospective/displayOnly
- prohibitedInferences 误用边界：每种语义类型有默认禁止推断规则
- 洞察 prompt v6：增加 memoryCandidate 子结构输出规则，仅 habit/finance/task/milestone 卡片输出
- 3 个灰度 Feature Flag：semanticMemoryPromptEnabled / semanticMemoryTypesEnabled / semanticMemoryRecallEnabled（默认全 false）

### 修复
- 修复长期记忆召回链路断路：UserContextBuilder.buildContext() 硬编码 memorySummary: nil 导致 AI 对话无法获取已确认记忆
- 长期记忆 Store 增加并发 barrier 队列，修复并发 upsertCandidate + confirm 可能丢数据的问题
- 过期记忆归档而非硬删，queryConfirmed/queryCandidates/queryPromptSummary 自动过滤已过期记忆
- HoloLongTermMemoryCandidateObserver 不再硬编码所有候选为 .recurringPattern 类型

### 优化
- 晋升策略按 semanticType 分流：phaseShift/lifeEvent 需确认、stablePattern 多证据可静默写入、driftSignal 自动 21 天过期、statMilestone 轻量收藏
- AI 召回注入格式增强：含 [useScopes] 标签和「避免推断」误用边界
- 记忆管理页 UI 展示语义类型标签、displaySummary 和旧格式标记
- 后端 defaultPrompts.json 同步更新，已部署至 ECS

---

## [2026-06-07] App 图标满幅修复

### 修复
- 重新裁切并生成 AppIcon 全套尺寸，移除图标素材中烘焙的外层预览背景与阴影，修复桌面 App 图标显示内缩的问题，并将头像主体回收约 10% 以避免视觉过满
- 补齐 AppIcon catalog 中缺失文件引用的 iPhone/iPad 小尺寸槽位，避免不同系统位置取图不一致

---

## [2026-06-07] 生产后端 HTTPS 接入

### 修复
- 将 iOS 默认 HoloBackend 地址从公网 IP 明文 HTTP 切换为 `https://api.holoapp.cn`，修复 ATS 拦截导致 HoloAI 请求失败的问题
- 阿里云 ECS Nginx 已启用 `api.holoapp.cn` HTTPS 证书，并将 HTTP 请求自动跳转到 HTTPS

---

## [2026-06-06] 全局背景色一致性修复

### 修复
- 全局统一 List/Form 页面背景色为 holoBackground，修复三级/四级页面底色与主页不一致的问题
  - 记忆管理页面（HoloMemoryCenterView）主列表 + 详情 Sheet
  - 情景记忆详情 Sheet（HoloEpisodicMemoryDetailView）
  - 分类管理页面主列表 + 新增/编辑分类 Sheet（CategoryManagementView）
  - 分类学习映射页面（CategoryLearnedMappingView）
  - AI 设置页面（AISettingsView）
  - 语音识别设置页面（VoiceRecognitionSettingsView）
  - 重复规则页面（RepeatRuleView）
- 聊天输入框和 AI 气泡背景从系统 systemGray6 统一为 holoCardBackground
- 记账键盘和快捷标签栏背景从硬编码颜色统一为 holoCardBackground

---

## [2026-06-06] App Store 上线前巡检修复

### 新增
- 新增 `PrivacyInfo.xcprivacy` 隐私清单，声明 Holo 使用的账号、健康、健身、财务和用户内容数据，以及 UserDefaults Required Reason API 使用原因
- 设置页新增“删除账号与 Holo 数据”入口，可清除本机 CoreData 记录、附件、AI 记忆、缓存、Keychain 登录状态和本地偏好

### 修复
- 添加 Apple ID 凭证撤销实时监听（`credentialRevokedNotification`），用户在系统设置撤销授权后 App 立即感知并自动登出
- 任务附件图片数据存入 CoreData，支持 iCloud 同步：换设备后附件图片自动恢复，不再丢失
  - TaskAttachment 实体新增 `imageData` / `thumbnailData` 二进制属性
  - 新附件图片直接存入 CoreData，旧附件仍通过文件系统兼容加载
  - AttachmentFileManager 新增 `processImageData` / `processRawImageData` 纯数据处理方法（不写磁盘）
- 移除 `NSAllowsArbitraryLoads` 全局 ATS 放开，发布包默认只允许符合 ATS 要求的网络连接
- 设置页 Release 可见“调试”文案改为“诊断与数据管理”，避免提审时出现内部调试入口感

---

### 新增
- 记忆长廊顶部 Daily Sense 卡片全新设计：收起态彩色圆点概览各维度状态，点击展开查看信号详情
- 健康信号接入：睡眠时长和步数参与每日状态判断（睡眠 <5h 标红，<6h 标橙，步数 <2000 标橙）

### 改动
- 状态标题改为节奏视角：「节奏不错」/「节奏有点乱」/「节奏在找回」
- 消费信号从「偏离均值 Nx」改为实际金额对比「今天 ¥560 · 平时 ¥50」
- 消费异常阈值从 1.5x 提升至 3x 且今日金额 >¥100，避免小额误报
- 习惯信号从「2 个习惯断连」改为「2 个断了节奏」
- DailySenseSnapshot 模型升级 v2：结构化 `DailySenseSignal` 替代 `reasons` 字符串数组
- `DailySenseStateBuilder.buildToday()` 改为 async，支持健康数据异步获取

---

## [2026-06-05] 健康模块日期切换

### 新增
- 健康主页面新增日期导航栏，支持左右切换查看历史健康数据
- 显示格式：今天"今天 · M月d日"，昨天"昨天 · M月d日"，更早"M月d日 周X"
- 非今日时右侧出现"今天"按钮可快速返回当日
- 右箭头在今日时自动禁用，不允许查看未来日期
- 健康详情页同步支持指定日期查看，趋势图以所选日期为终点

### 改动
- HealthRepository 新增 `fetchDayData(for:)` 按日期获取全部指标
- `fetchWeeklyData` 新增 `endingOn` 参数支持自定义结束日期
- 状态文本"今天状态很好"改为"状态很好"，适配历史日期

---

## [2026-06-03] 修复 HoloAI 分期记账确认与卡片状态

### 修复
- 修复 `finance_action_parser` / `task_action_parser` 返回裸字段 JSON 时，iOS 仍按旧批量结构解析，导致分期记账字段丢失的问题
- 修复分期记账确认后聊天卡片误显示“已删除”的问题，卡片现在绑定真实交易 ID，而不是分期组 ID

### 优化
- 结构化执行解析失败时保留 action parser 调用日志，便于在调试页区分 intent 粗路由和二段字段解析
- action parser 调用改为携带当前用户上下文，避免解析阶段丢失用户类别、习惯和偏好信息

### 验证
- 后端测试通过：`npm test`（46 tests passed）
- iOS 构建通过：`xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-installment-linked-entity-fix CODE_SIGNING_ALLOWED=NO build`

### 不变
- 后端无代码变更，无需发版

---

## [2026-06-03] 任务描述语音输入

### 新增
- 任务模块新建/编辑任务时，描述输入框下方新增语音输入入口
- 语音输入复用想法模块的录音、识别、确认插入和智能总结能力，长语音会整理成更易读的段落

### 优化
- 语音按钮放在描述输入框下方，不覆盖原本输入区域

### 验证
- iOS 构建通过：`xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-task-voice-derived CODE_SIGNING_ALLOWED=NO build`

### 不变
- 后端无变更，无需发版

---

## [2026-06-03] HoloAI 财务查询卡片与确定金额路由优化

### 新增
- 灵活财务查询结果新增聊天卡片渲染，展示合计金额、命中笔数和可点击记账明细
- 明细行点击后可打开对应记账记录，便于从 HoloAI 查询结果跳回财务模块核对

### 优化
- 查询卡片改为轻量摘要样式，最多预览前 5 笔明细，避免长列表撑满聊天界面
- `intent_recognition` 升级到 v15：确定数字类财务问题（如“今年的收入是多少”“上周花了多少钱”）优先走 `flexible_data_query`；趋势、结构、复盘类问题继续走 `query_analysis`
- iOS 本地 fallback prompt 同步新路由规则，降低后端不可用时的行为漂移

### 验证
- 后端测试通过：`npm test`（46 tests passed）
- iOS 构建通过：`xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-flex-card-green CODE_SIGNING_ALLOWED=NO build`

### 后端
- 需要后端发版，已同步 `HoloBackend` prompt/provider 相关改动

---

## [2026-06-02] 编辑任务描述输入框自适应高度

### 修复
- 修复编辑任务页描述内容较长时输入区域高度不随文字增长、下方检查清单位置过早贴近的问题
- 描述框现在会根据文字内容自动增高，内容过长后再启用内部滚动，避免键盘弹起时占满页面

### 验证
- iOS 构建通过：`xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-desc-autosize-build CODE_SIGNING_ALLOWED=NO build`

### 不变
- 后端无变更，无需发版

---

## [2026-06-02] HoloAI 灵活数据查询模块（Phase 1）

### 新增
- 新增 `flexibleDataQuery` 意图，支持「上一次」「最近一次」「哪一笔」「超过」等自然语言数据查询
- 新增 FlexibleQuery 子模块：Planner（结构化查询规划）→ Executor（Core Data 后台查询）→ AnswerBuilder（自然语言回答）
- ConversationCoordinator 集成灵活查询拦截分支（Branch 3.5）
- PromptManager 新增 flexibleQuery_planner prompt 类型及模板
- MockAIProvider 新增灵活查询关键词匹配
- 后端 defaultPrompts.json / promptRegistry.js 同步新增 flexible_query_planner 端点

### 不变
- ChatViewModel / ChatView 渲染侧尚未接入 flexibleQueryResult，待后续 PR 完成

---

## [2026-06-02] 语音输入模式防止屏幕自动熄灭

### 修复
- 修复语音输入期间屏幕自动熄灭的问题，录音时禁用系统 idle timer，退出后恢复

---

## [2026-06-02] 想法语音输入确认页与智能总结体验优化

### 优化
- 想法语音输入确认页复用最终插入文本的段落整理规则，长语音不再在确认页显示为一整段
- 开启智能总结时，ASR 识别完成后先展示可编辑原文，智能总结改为后台继续处理，减少等待确认页出现的体感耗时
- 智能总结完成后，如果用户未编辑原文则自动切换为总结；如果用户正在编辑，则保留用户改动并提供还原总结入口

### 验证
- iOS 构建通过：`xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo\ APP/Holo/Holo.xcodeproj -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-voice-final2 CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild ... test` 暂不可用：当前 Holo scheme 未配置 test action

### 不变
- 后端无变更，无需发版

---

## [2026-05-31] 财务统计明细页按日趋势与交易联动优化

### 修复
- 修复统计分析明细页交易行点击无响应的问题，现在可打开对应交易详情/编辑页
- 修复明细页趋势图按周/月聚合导致光标日期与下方交易明细错位的问题，趋势图改为按日展开
- 修复趋势图卡片随交易明细列表一起滚动的问题，趋势图固定，仅「交易明细」下方列表滚动

### 优化
- 趋势图新增支出/收入切换，并将切换控件收进图表卡片顶部，减少外部占位，让下方展示更多交易明细
- 支出/收入趋势独立展示为单条曲线，不再同时绘制两条线
- 未发生当前类型交易的日期按 0 参与趋势展示，连续无数据日期形成平滑的 0 线
- 去掉每个日期上的数据点，避免日维度展开后图表过密；横坐标仍抽样展示日期标签
- 图表拖动时只吸附当前支出/收入类型下有数据的日期，并自动滚动到对应日期分组

### 验证
- Swift 解析通过：`xcrun swiftc -parse "Holo/Holo APP/Holo/Holo/Models/TransactionType.swift" "Holo/Holo APP/Holo/Holo/Views/Finance/Analysis/DetailTabView.swift" "Holo/Holo APP/Holo/Holo/Views/Finance/Analysis/Components/LineChartView.swift"`
- 完整 iOS 构建被本机 CoreSimulator 环境阻断：`No available simulator runtimes for platform iphonesimulator`

### 不变
- 后端无变更，无需发版

---

## [2026-05-31] 财务统计分析页图表与分类排行优化

### 优化
- 分类排行改为支出/收入切换的全宽 Top 5 展示，压缩行间距并让切换控件与金额列对齐
- 趋势图中余额折线提升层级和线宽，避免被收入/支出柱状图遮挡
- 收支左轴和余额右轴统一使用 5 个刻度，改善左右坐标轴视觉对齐

### 新增
- 点击支出/收入分类排行项后可跳转到明细页，并自动按对应分类筛选交易

### 验证
- iOS 构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-rank-type-align-fixed-build CODE_SIGNING_ALLOWED=NO build`

### 不变
- 后端无变更，无需发版

---

## [2026-05-31] HoloAI 支持创建待办确认卡片

### 新增
- HoloAI 识别“创建任务/待办/提醒我”类自然语言后，先展示待确认任务卡片，用户点击“确认创建”后再写入待办
- 任务卡片支持展示标题、备注、提醒时间和子任务列表，避免 AI 识别后直接静默落库
- 支持把“今天要买苹果、买胡萝卜、买哈密瓜、买水蜜桃”识别为「购物清单」，并拆分为多个子任务

### 优化
- HoloBackend `intent_recognition` 默认 Prompt 增强任务创建规则，补充 `reminderDate` 输出和购物清单拆分示例
- “明天早上”“明天下午”等提醒表达会解析为具体时间，分别默认映射为次日 09:00 和 15:00
- 只有 `reminderDate`、没有 `dueDate` 的任务也能正确进入任务日期/提醒创建流程

### 验证
- 后端测试通过：`npm test`（44 passed）
- iOS 构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-ai-task-create-build CODE_SIGNING_ALLOWED=NO build`

### 后端
- 本次包含 HoloBackend Prompt 变更，已同步到 ECS 并通过 Docker 重新构建部署

---

## [2026-05-30] 编辑交易支持分期功能（转分期/修改/取消）

### 新增
- 编辑已有交易时新增分期设置入口，与新增交易保持一致
- 支持三种编辑模式分期操作：
  - 普通交易 → 转为分期：当前金额作为总金额拆分为 N 期
  - 分期交易 → 取消分期：删除整组分期，保留当前金额作为单笔交易
  - 分期交易 → 修改分期参数：按每期金额 × 新期数重建分期组

### 改动文件
- `TransactionInfoInputArea.swift`：移除编辑模式下分期行隐藏逻辑
- `TransactionStateManager.swift`：编辑分期交易时初始化分期 State
- `TransactionSaveHandler.swift`：编辑保存逻辑拆分为 4 分支处理分期变更

### 已知限制
- 编辑分期交易时无法恢复原始手续费（模型未存储），手续费字段默认为 0

---

## [2026-05-30] HoloAI 财务分类卡片与待分类兜底修复

### 修复
- 修复收入记录详情页分类正确、但 HoloAI 聊天卡片不显示科目的问题
- 收入和支出现在统一把 Core Data 匹配后的真实一级/二级科目回填到卡片 `renderData`
- 无法可靠匹配科目时仍然完成记账，并统一归入「待分类」，不再展示「无法识别分类」的失败提示
- 用户把「待分类」交易手动改为具体科目后，学习映射现在记录真实父子科目，避免下次仍匹配失败

### 优化
- iOS 本地 Prompt 和 HoloBackend 默认 Prompt 补充工资收入识别规则与「工资23870」示例
- HoloBackend `intent_recognition` 默认 Prompt 版本升级到 v9
- 兼容旧「待确认」分类，首次兜底时会迁移为「待分类」

### 验证
- 后端测试通过：`npm test`（44 passed）
- iOS 构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-derived-income-card-build build`

### 后端
- 本次包含 HoloBackend Prompt 变更，需要部署后端后生产环境生效

---

## [2026-05-28] 任务清单进度条丝滑动画与完成彩带

### 优化
- 编辑任务页的检查清单进度条改为显式动画状态，勾选、添加、删除检查项时不再直接跳到最终进度
- 独立检查清单页同步使用显式进度状态和进度条动画，避免 Core Data 关系刷新导致动画被跳过
- 检查项勾选按钮增加轻量弹跳反馈

### 新增
- 检查清单从未完成推进到 100% 时展示轻量彩带庆祝动画

### 原因
- 实际编辑任务入口的进度条位于 `AddTaskSheet.swift`，此前只改 `ChecklistView.swift` 未覆盖用户正在操作的页面
- 原实现直接按最新完成比例设置宽度，SwiftUI 没有稳定的旧值到新值过渡帧

### 验证
- iOS 构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-checklist-animation-addsheet CODE_SIGNING_ALLOWED=NO build`

### 不变
- 后端无变更，无需发版

---

## [2026-05-28] 财务科目快速新增入口

### 新增
- “记一笔”分类网格末尾新增圆形 `+` 入口：一级分类总览中用于新增一级分类，进入某个一级分类后用于新增该一级下的二级分类
- 分类管理页同步增加列表末尾新增入口，二级分类为空时直接展示大号 `+` 空状态卡片

### 优化
- 快速新增入口复用现有 `AddCategorySheet`，保存后自动刷新分类数据，不新增平行数据路径
- 保留原右上角 `+` 和“管理”入口，兼容既有操作习惯

### 验证
- iOS 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/holo-derived-data build`

### 不变
- 后端无变更，无需发版

---

## [2026-05-28] 任务提醒生命周期修复

### 修复
- 完成任务后不再触发已过期的提醒通知
- 删除任务（软删除/永久删除）后取消对应提醒
- 归档任务后取消对应提醒
- 重复任务完成后为新生成的实例自动调度提醒（之前遗漏）
- 取消完成、恢复、取消归档时自动重新调度提醒

### 根因
- `TodoRepository` 中 `cancelReminders` 方法已实现但从未在完成/删除/归档流程中调用

---

## [2026-05-28] 长期记忆候选写入链路修复

### 修复
- 修复打开“长期记忆”后仍不会保存任何候选记忆的问题
- App 启动时现在会注册长期记忆候选观察器，避免洞察生成完成通知无人消费
- “长期记忆”开关现在会真正控制洞察候选抽取，不再依赖未暴露的内部开关
- 设置页文案改为“从洞察中学习”，避免误导为普通对话会自动写入长期记忆

### 触发方式
- 打开“长期记忆”后，生成或刷新记忆洞察；带有 `patternType` 和 evidence 的洞察卡片会进入“记忆管理”的待确认列表
- 用户确认候选后才会成为已记住内容

### 验证
- 独立测试通过：`HoloMemorySettingsStandaloneTests`
- iOS 真机构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-long-term-memory-dd build`

### 不变
- 后端无变更，无需发版
- 普通聊天仍不会自动写入长期记忆

---

## [2026-05-28] 任务编辑进度条实时更新 + 编辑模式自动保存

### 修复
- 修复编辑任务时，勾选子任务后进度条不更新的问题（需保存后重新进入才能看到进度）
- 修复编辑任务时，不点保存直接返回会导致改动丢失的问题

### 原因
- 进度条读取 Core Data 关系的计算属性，SwiftUI 不会因关系变化重新渲染；改用本地 checkItems 数组实时计算
- 编辑模式 dismiss 时直接丢弃未保存修改；改为自动保存所有字段后再返回

### 不变
- 新建任务模式仍保留"放弃修改"确认弹窗
- 后端无变更，无需发版

---

## [2026-05-25] HoloAI 意图识别当前时间缓存修复

### 修复
- 修复 HoloAI 意图识别日志中 `当前时间` 与系统状态栏时间不一致的问题
- 后端托管 Prompt 和本地 Prompt 缓存现在只保存原始模板，每次请求实时渲染 `{{todayDate}}`、`{{currentTime}}` 等运行时变量

### 原因
- Prompt 缓存此前保存的是已渲染文本，首次加载时的 `{{currentTime}}` 会被冻结，后续意图识别继续复用旧时间

### 验证
- iOS 真机构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-timefix-derived CLANG_MODULE_CACHE_PATH=/private/tmp/holo-timefix-module-cache SWIFT_MODULE_CACHE_PATH=/private/tmp/holo-timefix-module-cache build`

### 不变
- 后端无变更，无需发版

---

## [2026-05-25] HoloAI 交易卡片首屏分类与日志修复

### 修复
- 修复进入 HoloAI 时交易卡片首屏分类路径丢失，滑动后才恢复的问题
- 修复首屏分类丢失状态下长按卡片无法查看 LLM 调用日志的问题

### 原因
- HoloAI 首屏使用轻量消息快照，但未加载交易卡片渲染依赖的 `executionBatchJSON` 和日志依赖的 `rawLogJSON`
- 现在轻量快照会直接带上卡片 renderData 与日志字段，避免等待滚动触发懒加载

### 验证
- iOS 真机构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination "generic/platform=iOS" -derivedDataPath /private/tmp/HoloDerivedData build`

### 不变
- 后端无变更，无需发版

---

## [2026-05-25] HoloAI 能力启动台与记忆层

### 新增
- 能力启动台：替换输入框上方无价值 Tab，新增「今日状态/最近分析/长期模式/规划目标」四个高价值入口
- 新人引导入口：新用户展示使用指南，完成 3 次有效 AI 行动后自动隐藏
- 短期记忆模型：数据覆盖度评估（rich/partial/empty 三档），今日状态兜底
- 长期记忆模型：候选池、晋升策略（丢弃/观察/静默写入/要求确认）、本地 JSON Store
- 记忆注入：AIUserContextMessageBuilder 支持 chat 记忆摘要注入和 intent 保守注入
- MemoryInsight 候选提取：洞察生成后异步提取长期记忆候选
- 记忆管理 UI：设置页新增「AI 记忆」section，支持长期记忆开关、记忆辅助对话开关、记忆管理入口
- 记忆管理中心：查看已确认记忆、处理候选、查看证据、删除记忆

### 修复
- 历史消息空 content 导致后端 400 的既存 bug（loadRecentDTOsAsync 现在过滤 isStreaming 和空 content）
- InsightFeedbackAggregator 过期检查失效（from: now, to: now → 使用 per-item updatedAt）

### 不变
- 后端无变更，无需发版
- V1 不引入 Agent，不跨会话短期缓存，不让 AI 自由写入长期画像

---

## [2026-05-25] HoloAI 卡片纯文本化与后端 Prompt 热更新

### 修复
- HoloAI 分析卡片不再裸露 `##`、`###`、`*` 等 Markdown 语法，前端渲染会将标题和列表转成更适合 C 端阅读的纯文本样式
- 分析回复中的 `{{card:...}}` 卡片标记不再出现在用户可见文本里

### 优化
- iOS 本地 fallback Prompt 和后端默认 Prompt 统一约束分析输出为手机 App 可读的中文纯文本，避免模型生成 Markdown 报告体
- `analysis_prompt` 增加版本声明和后端测试，防止默认 Prompt 回退到 Markdown 输出

### 后端同步
- 后端 `system_prompt` 和 `analysis_prompt` 已通过管理接口热更新到线上，避免等待完整 Docker 重建

### 验证
- 独立测试通过：`MarkdownAttributedStringRendererStandaloneTests`
- 后端 Prompt 测试通过：`npm test`
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build`

---

## [2026-05-24] 待办检查项编辑 + Deep Link 导航 + 观点光标修复

### 新增
- 待办检查项支持点击标题直接内联编辑（AddTaskSheet 和 ChecklistView），回车或失焦自动保存
- TodoRepository 新增 `updateCheckItemTitle` 方法
- DeepLinkState 新增 `navigate(to:)` 方法，处理连续跳转相同目标时 onChange 不触发的问题

### 修复
- 观点模块编辑时光标比文字偏高：UITextView 的 `lineHeightMultiple` 导致行框扩大后光标与文字基线不对齐，改用 `lineSpacing` 修复
- 任务通知/AI 对话点击跳转到任务详情时，连续跳转相同任务 fullScreenCover 不弹出：DeepLinkState 统一走 `navigate(to:)` 方法，TaskListView 增加防御性清空 selectedTask 逻辑

---

## [2026-05-23] 健康数据诊断入口

### 新增
- 设置页“调试”区新增“健康数据诊断”入口，可生成并复制 HealthKit 诊断报告
- 诊断报告按数据类型汇总步数、睡眠、Apple Watch 站立小时、Apple 运动分钟、活动能量、步行跑步距离、体能训练
- 报告按 HealthKit source 汇总来源名称、bundle identifier、设备厂商/型号、样本数和总值，用于排查小米手环等第三方设备数据写入类型不匹配的问题

---

## [2026-05-23] 修复记忆长廊刷新洞察闪退

### 修复
- 记忆长廊点击"刷新洞察"后 2-3 秒闪退：`InsightPreferenceProfileService.loadFromDisk()` 在 `static let shared` 初始化期间通过 `Self.shared` 递归访问自身，触发 EXC_BREAKPOINT 陷阱
- `MemoryInsightContextBuilder` 添加 `@MainActor` 隔离，防止 `async let` 子任务在后台线程访问 `@MainActor` 仓库
- 修复 3 处 force-unwrap 崩溃隐患（MemoryInsightService / MemoryGalleryViewModel / MemoryReplayFallback）
- 在洞察生成关键路径添加 `Task.yield()` 缓解 UI 卡顿
- 修复第三方设备（小米手环等）睡眠数据无法读取：`HKCategoryValueSleepAnalysis` 枚举值映射错误，`asleepUnspecified` 的实际 rawValue 是 1 而非 2，导致非 Apple Watch 设备的睡眠数据被过滤掉；同时修正了 `awake`(2) 被错误计入睡眠时间的问题

### 规范
- CLAUDE.md 新增闪退排查规范：禁止只搜关键词，必须从入口逐函数走完整调用链

---

## [2026-05-23] AI 分析扩展：健康与目标模块 + 习惯分析 bug 修复

### 新增
- 健康（Health）分析域：步数/睡眠/站立/活动 4 指标趋势、达标率、体表分（3 槽位模型）、异常检测（连续低睡眠/低步数/零活动）
- 目标（Goal）分析域：目标进度（任务 60% + 习惯 40%）、风险检测（deadline < 7 天且进度 < 50%）、领域分布
- AI 对话支持健康和目标分析卡片渲染（summary/trend/comparison/highlights）
- 跨模块分析新增健康体表分和目标风险聚合，预算从 5+3 提升到 7+5
- 意图识别新增健康关键词（步数/睡眠/运动/健康/锻炼等）和目标关键词（目标/进展/进度/goal/里程碑）

### 修复
- 习惯分析返回"没有数据"：HabitAnalysisContextBuilder 访问 activeHabits 时未先调用 repo.setup()

### 后端同步
- defaultPrompts.json 同步更新 intent_recognition 和 analysis_prompt 模板

---

## [2026-05-23] Holo Sense Layer 洞察闭环系统（Phase 0-6）

### 新增
- 洞察反馈系统：两维反馈（准确性 + 价值感），支持 5 种不准原因分类，反馈保存到独立 Core Data 实体
- 洞察偏好画像 `InsightPreferenceProfile`：弱信号/稳定偏好分层，30 天过期 + 2 次阈值升级，JSON 原子写入 + 损坏回退
- 反馈聚合器 `InsightFeedbackAggregator`：生成前批量聚合 + App 启动轻量聚合，dataWrong 隔离到 debug 日志
- 本地卡片 Rerank：根据偏好排序，critical anomaly 保底，偏好变化立即生效不改内容
- 每日状态雷达 Daily Sense：3 状态规则引擎（stable/atRisk/recovering），7 天持久化，记忆长廊顶部展示
- 健康洞察上下文框架：`HealthInsightContext` + `HealthDataAvailability` 手写 Codable，`MemoryInsightContext` 新增 health 字段
- 行动闭环：规则生成行动候选（任务清理/习惯回顾/消费提醒），卡片展示行动按钮 + 二次确认弹窗
- Feature Flag 系统：6 个 UserDefaults Bool flag，Debug 默认开启，Release 可关闭
- 反馈 UI Sheet：`InsightFeedbackSheet`，两维选择 + 不准原因 + 补充说明

### 修复
- `snapshotHash` 排除 `generatedAt` 运行时字段，相同业务数据生成稳定 hash
- `mapCardTypeToModule` 不再将 `.anomaly`/default 硬映射为 `.finance`，不可映射类型返回 nil
- `GoalAnalysisContextBuilder` 属性名 `isCompleted` → `completed`
- 补全 `AnalysisContextBuilder`/`AnalysisSummaryFormatter`/`AnalysisDetailSheet`/`AnalysisChatCard`/`ChatCardData` 中缺失的 health/goal case

### 优化
- `MemoryInsightCard` 新增 `moduleHint`/`patternType` 可选字段，post-process 关键词匹配填充
- `MemoryInsightHeroCard` 卡片列表从 `prefix(5)` 改为可展开
- `MemoryInsightResponseParser` 新增 `fillModuleHints` 后处理方法
- `MemoryInsightCardView` 新增反馈按钮 + 行动候选按钮 + 二次确认

### 方案文档
- `docs/_common/plans/2026-05-23-Holo-Sense-Layer洞察闭环方案.md`

---

## [2026-05-23] 个人档案接入全局 AI 上下文

### 新增
- 新增统一的 AI 用户上下文构建器，聊天和意图识别共享同一份个人档案、目标、近期趋势和习惯关注主题上下文
- 意图识别请求现在会携带个人档案，用于分类、习惯、目标等语义消歧
- 记忆洞察上下文新增 `personalProfileContext`，AI 回放生成时可读取稳定用户画像

### 优化
- 为意图识别加入档案优先级护栏：个人档案只能作为消歧和个性化依据，不得覆盖用户当前明确指令
- 去除 Holo 后端 Provider 和本地 OpenAI-compatible Provider 中重复的上下文拼接逻辑

### 验证
- 独立测试通过：`AIUserContextMessageBuilderStandaloneTests`
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-23] 记账卡片编辑后金额同步

### 修复
- 用户在 HoloAI 中点击记账卡片修改金额/类型/日期后，卡片内容未同步更新
- `refreshTransactionCard` 现在完整同步 amount、type、date、primaryCategory、subCategory、note 六个字段到卡片 renderData

---

## [2026-05-22] 目标创建完成卡片跳转

### 优化
- HoloAI 目标规划保存成功后，将最后的「已创建目标」消息改为可点击卡片，展示目标标题、任务数和习惯数
- 点击目标创建完成卡片后，自动跳转到「个人 → 我的目标 → 目标详情」
- 为目标保存消息补充 `goalId` 等关联元数据，支持后续从聊天历史继续跳转

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project Holo.xcodeproj -scheme Holo -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/HoloDerivedData build`

---

## [2026-05-21] 健康模块权限持久化

### 修复
- 健康模块每次打开都显示权限引导页的问题：将 `hasRequestedPermission` 持久化到 UserDefaults，App 重启后不再重复请求授权

---

## [2026-05-21] 首次昵称设置

### 新增
- 首次打开 App 时弹出昵称设置弹窗，引导用户填写 Holo 对自己的称呼
- 首页、今日看板、设置页和个人页统一读取本地昵称，不再显示硬编码「东林」

### 优化
- 设置页修改昵称改为确认后保存，空白输入不会覆盖已有昵称

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## [2026-05-21] HoloAI 普通用户免配置

### 优化
- 正式版默认使用 Holo 自有后端网关提供 AI 对话、AI 回放和语音识别能力，新用户无需配置任何 AI/API Key 即可使用
- 普通用户界面隐藏 AI 助手和语音识别的技术配置入口，保留 Debug 环境下的开发调试入口
- 将「配置 AI / API Key」相关失败提示调整为服务暂时不可用提示，避免误导用户自行配置第三方 Key

### 验证
- Release 真机通用构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Release -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-derived-data build`

---

## [2026-05-21] 首页通知栏修复 & 观点语音智能总结

### 修复
- 首页通知栏点击进入任务页后，回退再次点击无响应：`.tasks`/`.finance`/`.memoryGallery` 三类 deep link 目标未被消费，导致 `.onChange` 无法触发二次导航
- 归档管理页面缺少 `import OSLog` 导致编译失败

### 新增
- 归档管理页面新增「任务」标签页，归档任务可在归档列表中查看和恢复
- `TodoRepository` 新增 `loadArchivedTasks()` 方法
- 观点语音智能总结：语音输入后自动生成结构化总结
- `HoloBackendAIProvider` 新增 `chat(messages:purpose:)` 非流式调用方法

---

## [2026-05-20] iOS 17/18 向下兼容

### 优化
- 将 Holo iOS App 的最低系统版本从 iOS 26.2 下调到 iOS 17.0，覆盖 iOS 17、iOS 18 和当前 iOS 26 设备
- 修正 AppIcon 资源配置，补齐 iOS marketing 图标和缺失的 20pt@3x 图标引用，移除不匹配的 mac/iPad 图标槽位

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`

---

## [2026-05-19] 站立数据修复

### 修复
- 站立数据从 `appleStandTime`（分钟折合小时）改为 `appleStandHour`（Apple Watch 站立环小时数），数据与系统健康 app 一致

---

## [2026-05-19] 记账意图识别语义归一

### 优化
- 意图识别 Prompt 升级为 v8，新增 `normalizedCategoryCandidate` 和 `semanticCategoryHint`，由 AI 负责将品牌、口语和动作短语归一为可匹配的记账分类候选
- iOS 记账路由支持按「归一候选 → 原始候选 → 语义提示」匹配本地分类与后端 catalog，减少「肯德基40」「买烟250」这类输入落入兜底分类
- 后端 finance catalog 增加快餐语义锚点，并补充 Prompt 和 catalog 测试覆盖

### 验证
- 后端测试通过：`npm test`
- iOS 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-18] 洞察推送点击跳转修复

### 修复
- 修复点击洞察（周/月记忆回放）推送通知后无法跳转到对应页面的问题
- `MemoryInsightNotificationService` 为周/月提醒通知添加 `categoryIdentifier`
- `TodoNotificationService` 注册 `MEMORY_INSIGHT` 通知分类并在点击时触发 Deep Link 跳转到记忆长廊

---

## [2026-05-18] 子任务删除闪退修复

### 修复
- 修复删除子任务时 App 直接闪退的问题：`CheckItem.task` 关系的删除规则从 `cascadeDeleteRule` 改为 `nullifyDeleteRule`，防止删除子任务时级联删除父任务
- 优化 `AddTaskSheet` 新建模式下子列表使用 `Identifiable` 包装，消除 `ForEach` 索引越界风险
- `AddTaskSheet` 编辑模式删除子任务时先从本地数组移除，再执行 CoreData 删除，并增加失败回滚
- `ChecklistView` 将 `checkItems` 从计算属性改为 `@State` 数组，手动管理增删状态，避免 CoreData 删除后访问野指针

---

## [2026-05-18] iCloud 手动同步请求

### 新增
- 设置页 iCloud 区支持「请求同步并检查状态」，点击后写入内部 Core Data 同步探针，触发 CloudKit 尽快安排导出
- 新增内部 `ICloudSyncProbe` Core Data 实体，用于产生轻量同步变更，不影响业务数据

### 优化
- 最近同步时间合并到「同步状态」下方的小字，不再作为独立字段展示
- 手动请求后显示「最近请求同步」时间，真正收到 CloudKit 完成事件后再更新为「最近同步」
- App 启动时提前初始化 iCloud 同步监听，减少打开设置页太晚导致错过同步事件的情况

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -quiet -project Holo.xcodeproj -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-17] iCloud CloudKit 同步

### 新增
- 启用 iCloud CloudKit 私有数据库同步，使用 Core Data with CloudKit 在用户设备间自动同步本地数据
- 设置页增加 iCloud 同步状态区，显示账号状态、同步事件和错误信息
- CoreDataStack 增加 Debug 模式 CloudKit schema dry-run 验证方法

### 修改
- `NSPersistentContainer` 切换为 `NSPersistentCloudKitContainer`
- Core Data 模型 7 个 required relationship 改为 optional，适配 CloudKit mirroring 限制
- Debug/Release entitlements 增加 CloudKit 配置

---

## [2026-05-17] 健康模块导航与同步样式优化

### 优化
- 健康首页移除系统导航栏的左上角关闭按钮，改为右滑返回首页
- 健康详情页隐藏系统返回样式，改为 Holo 自绘标题区，并支持右滑返回健康总览
- 健康首页移除 iOS 原生刷新按钮和下拉刷新样式，新增 Holo 胶囊式「同步」控件与自绘小环动画

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-17] 财务分类与图标编辑增强

### 新增
- 财务预设科目轻量扩容：新增车辆充电/保养、住宿门票、家政搬家、AI 工具/软件服务/云存储、家庭育儿/赡养、手续费/税费/快递等支出科目
- 收入科目新增基金、项目款、咨询费、稿费、补贴、个税退税
- 后端 finance category catalog 同步新增上述科目及别名、标签，保持 HoloAI 分类匹配语义与 iOS 本地预置一致
- 图标库新增两个 SwiftUI 自绘万能兜底图标：`holo.category.generic` 与 `holo.category.misc`

### 优化
- 分类管理页的一级/二级分类行新增可见编辑按钮，不再只能依赖左滑发现编辑入口
- 编辑分类页新增当前图标预览和「恢复默认」按钮，可从图标库直接替换预设分类图标
- 图标选择器支持混合展示 SF Symbols 与 SwiftUI 自绘图标，自绘图标不会进入 SF Symbol 可用性校验

### 验证
- 后端测试通过：`npm test -- tests/catalog.test.js`
- iOS Debug 模拟器构建通过：`xcodebuild -project Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build`

---

## [2026-05-17] 目标规划体验优化

### 优化
- 草稿生成后先显示 inline 聊天卡片（显示目标标题和任务/习惯数量），点击后才弹出编辑界面，避免突兀弹窗
- GoalDraftReviewView 全面重写为 Holo 设计风格：卡片容器（holoCardBackground + 圆角 + 边框 + 阴影）、设计系统字体和间距、底部固定操作栏
- 目标规划 Prompt 增加"我是 Holo"人格引导：分轮次追问策略、自然口语化语气、草案质量要求

### 新增
- GoalDraftReadyChatCard：聊天内嵌目标计划入口卡片，复用 ChatCardView 设计风格
- GoalDraft.cardSummary：计算选中任务/习惯数量的摘要文本

---

## [2026-05-17] 目标系统 v1

### 新增
- 目标 Core Data 实体：Goal 与 TodoTask、Habit 的双向关系（nullifyDeleteRule，删除目标不级联删除任务/习惯）
- GoalModels 值类型：GoalStatus、GoalDomain、GoalDraft、GoalPlanningSession、GoalPlanningRequest
- GoalRepository：CRUD、草案落库（saveDraft 同时创建关联任务和习惯）、状态切换、AI 上下文授权查询
- GoalProgressEvaluator：基于任务完成率和习惯近 14 天完成率的粗粒度进展评估（起步中/稳定推进/有些停滞/接近完成/已暂停/已完成）
- GoalPlanningCoordinator：最多 3 轮追问的状态机，信息足够时提前生成 GoalDraft JSON
- GoalPlanningPromptBuilder：追问 prompt 和草案生成 prompt，支持精简/完整模式
- GoalListView：我的目标列表，空状态引导跳转 HoloAI 规划
- GoalDetailView：目标详情页，支持暂停/恢复/标记完成/删除，AI 授权开关
- GoalDraftReviewView：fullScreenCover 确认看板，可编辑标题/领域、勾选任务/习惯、选择频率、AI 授权
- 个人页「我的目标」入口，跨 Tab 跳转（PersonalView → HomeView → ChatView）
- ChatMessage 新增 messageType 字段，区分普通消息和目标规划消息
- ChatViewModel 目标规划分流：sendMessage 检测活跃规划 session，走专用追问链路
- QuickAction 新增「规划目标」快捷入口
- AI Context 注入：授权 active Goal 摘要注入 UserContext.goalContext，OpenAICompatibleProvider 和 HoloBackendAIProvider 均已支持
- MockAIProvider 目标规划确定性响应（固定追问 + 固定草案 JSON）
- HabitRepository 新增 getCompletionStats(for:days:) 窗口完成率统计

### 修复
- 修复目标规划跳转失败：根因是应用主导航在 HomeView 而非 ContentView，onPlanGoal 回调和 goalPlanningRequest binding 需要接入 HomeView 的 sheet/fullScreenCover
- 修复 HealthDetailView switch 缺少 activeMinutes case（预存问题）

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## [2026-05-17] 健康模块产品化重构

### 新增
- 新增健康首页 A+C 组合体验：三环主视觉、身体状态分数、三项指标摘要、Apple Health 数据源卡
- 新增健康展示状态模型，支持身体状态分数、指标可用性、数据源状态、无 Apple Watch 替代环和洞察文案
- 新增首页「今日核心洞察」和「生活闭环」关联线索，串联习惯、财务、思考等模块
- 新增活动分钟指标，用于无 Apple Watch 或无站立数据时替代站立环

### 优化
- 重构步数、睡眠、站立详情页，统一展示大圆环、7 天趋势、统计摘要、单项洞察和关联线索
- HealthKit 仓库新增按指标可用状态和数据源状态，避免把授权回调 success 简单等同于全部读取权限
- 权限引导页强调 Apple Health 只读同步、不写入、不上传原始健康记录
- 趋势图空状态文案改为「暂无可用趋势数据」，避免无数据与零进度混淆

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-17] 财务模块滚动回弹修复

### 修复
- 分类管理二级分类列表超出首屏时无法滚到底部、回弹（缺少底部 safeAreaInset 避让自定义 Tab Bar）
- 账户管理页 ScrollView 同样缺少底部避让，内容多时底部被遮挡
- 账户详情页 ScrollView 同类问题一并修复

### 根因
- FinanceView 自定义 Tab Bar（88pt）通过 `.safeAreaInset(edge: .bottom)` 挂载，但 NavigationLink push 的子页面不会继承该修饰符，每个可滚动容器需自行处理

---

## [2026-05-16] 任务日期时间交互优化

### 优化
- 新建任务页的截止日期区域改为摘要式列表，主表单不再内嵌日期/时间滚轮，减少页面拥挤感
- 日期与时间设置迁移到独立底部弹窗，支持快捷日期、日历选择和全天/具体时间切换
- 具体时间改用紧凑选择器展示，避免日期滚轮和时间滚轮同时堆叠

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## [2026-05-16] HoloAI 聊天卡片双向删除

### 新增
- 支持在 HoloAI 聊天界面长按交易/任务卡片删除底层实体（上下文菜单 → 确认弹窗 → 执行删除）
- 已删除卡片显示灰色 + 删除线 + 红色「已删除」标签，禁用点击跳转
- 在财务/待办模块删除实体后，聊天卡片实时刷新为「已删除」状态（CoreData 通知驱动）

### 变更
- `ChatMessageViewData` 新增 `isEntityDeleted(for:)` 渲染时检查实体存在性
- `ChatCardView` 新增 `isDeleted` 参数，统一处理已删除 UI
- `ChatViewModel` 监听 `NSManagedObjectContextObjectsDidChange` 通知，自动刷新受影响卡片

---

## [2026-05-16] 全局文本长按复制支持

### 修复
- 修复 HoloAI 聊天消息、分析详情、亮点提醒等文本无法长按复制的问题
- 为记忆画廊洞察标题/摘要、高亮事件、里程碑、心情卡片、观点卡片、备注等全局文本添加 `.textSelection(.enabled)`

---

## [2026-05-16] V2 方案实施 — 科目对照与 Prompt 瘦身

### 新增
- 后端新增 `/v1/catalog/finance-categories` 科目对照 Catalog API
- 后端 Prompt 注册机制（promptRegistry），支持版本管理和历史同步
- iOS `FinanceCategoryCatalog` 数据模型 + `FinanceCategoryCatalogProvider` + 缓存
- iOS 分类匹配链新增 `categoryCandidate` 抽取规则和 `matchExistingCategoryByCandidate` 自定义科目匹配
- 后台 admin logs 页面增加手动刷新按钮

### 优化
- Prompt 模板瘦身：移除硬编码科目表，改为科目抽取规则 + categoryCandidate + 系统科目对照 catalog
- 记忆画廊 UI 全面重构：热力图暖橙色系、卡片化布局、品牌色统一
- AI 洞察上下文构建器升级：财务/习惯/待办/任务分析上下文增强
- 后台 `adminLogStore.list()` 改为合并热缓存 + SQLite，不再二选一
- 后台 `contentCaptureEnabled` 默认开启，确保日志存储请求/响应内容

### 修复
- 修复 HoloAI 卡片匹配成功后不显示科目名称的问题：RouteResult 新增 `matchedPrimaryCategory/matchedSubCategory`，`buildRenderData` 用 Core Data 真实科目名回写
- 修复 `matchExistingCategoryByCandidate` 多同名科目时返回 nil 的问题，改为取第一个匹配

---

## [2026-05-16] 记忆长廊重构与回放周期优化

### 新增
- AI 回放周期切换改为右上角下拉菜单，支持本周、本月、本季度、自定义周期
- 自定义周期新增开始日期和结束日期选择器，生成回放时按真实日期范围构建上下文
- `MemoryInsightPeriodType` 新增 `quarterly` 和 `custom`，洞察缓存、生成、刷新和继续问 AI 均适配新周期
- 未生成当前周期回放时新增缺省态卡片，不再展示其他周期的回放内容

### 优化
- 记忆长廊重构为洞察/明细双 tab，热力图移动到明细顶部
- 热力图改为品牌橙 5 档色阶：`#F5F2ED`、`#FFD6C7`、`#FFB499`、`#FF9B7A`、`#FF8C66`
- 洞察页减少内容堆叠，仅在当前周期已有回放时展示对应范围内的里程碑与高光
- AI 洞察卡片支持整卡点击展开，标题、状态标签和生成时间拆行展示
- 里程碑、高光、日摘要和最近日期卡片统一品牌色与清晰文本层级

### 修复
- 修复切换到本季度/自定义周期但未生成回放时仍显示本周内容的问题
- 修复回放兜底文案模板残留 `@` 字符的问题
- 修复热力图旧蓝色色块与品牌色不一致的问题

### 验证
- iOS Debug 真机构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' build`

---

## [2026-05-16] 修复语音创建任务时间识别错误

### 修复
- `NLDateParser.containsTimeComponent` 现在能识别标准格式（`yyyy-MM-dd HH:mm`）中的时间部分，之前只匹配中文时间表达（"X点Y分"），导致语音创建的带具体时间的任务被错误标记为全天任务，时间选择器无法展开且不会自动添加提醒

---

## [2026-05-16] Holo 生活轨迹 AI 洞察升级

### 新增
- Prompt 体系升级：system_prompt 从"数据管理助手"升级为"生活轨迹观察助手"，memory_insight_generation 新增轨迹观察视角、洞察层级（fact/change/pattern/correlation/hypothesis/suggestion）、恢复迹象检测
- analysis_prompt 新增分层分析顺序（事实→变化→模式→关联→建议）
- annual_review 升级为转折点+恢复能力观察，不再逐月流水账
- intent_recognition 新增跨模块分析（crossModule）和混合意图识别规则
- 后端 `/v1/prompts/meta` 批量元数据 API（不含正文，供 iOS 判断缓存版本）
- 后端 Prompt 版本 `change_note` 变更说明字段（migration + 管理后台展示）
- 后端管理后台 Prompt 测试区（purpose + message 输入 + 实时测试）
- iOS Prompt 版本化缓存：`LoadedPrompt` 携带 version，meta TTL 2 分钟自动检测版本变化
- iOS 设置页「刷新后端 Prompt 缓存」按钮
- `LifeEvent` 关键事件流模型（最多 30 条，按优先级排序）
- `DailyLifeSnapshot` 每日快照模型（支出/任务/习惯/想法日维度数据）
- `PersonalBaseline` 个人基线模型（观察期前 4 周基线，含高支出工作日检测）
- `CrossModuleCorrelation` 扩展 `patternType` + `evidenceDates` 字段
- 2 条新跨模块规则：重要任务完成+习惯恢复、恢复迹象优先展示
- 跨模块去重逻辑（同一 modulePair+evidenceDates+patternType 不重复输出）
- 13 个后端 Prompt 相关测试用例

### 变更
- `generateMemoryInsight()` 强制 `responseFormat: .jsonObject`，提升 JSON 解析稳定性
- `AIProvider` 协议 `generateMemoryInsight` 返回 `MemoryInsightGenerationResult`（含 promptVersion），三个 Provider 同步适配
- `MemoryInsightService` 保存真实 promptVersion（不再硬编码 `4`）
- 洞察缓存命中同时检查 `sourceSnapshotHash` + `promptVersion`
- Jaccard 去重只比较同 promptVersion 内的洞察
- 旧 `promptVersion=0` 记录仍可展示但不阻挡新生成
- Token Budget 渐进式裁剪：daily 800 → weekly 2200 → monthly 3800 → annual 5000，CJK 友好估算
- 年度上下文新增专用预算裁剪（`enforceAnnualTokenBudget`）
- `ThoughtRepository` 新增 `getThoughtCountByDay` 聚合方法
- AISettingsView 修复 promptSection 未显示在 body 中的问题

### 涉及文件
- iOS: 13 个文件修改，+1373 行
- 后端: 7 个文件修改 + 1 个新增，+147 行

---

## [2026-05-16] HoloBackend 功能增强 — SQLite 持久化 + 日志增强 + Prompt 版本管理 + ECS 部署

### 新增
- SQLite 持久化基础设施：`src/db/database.js` + `src/db/migrations.js`，WAL 模式、integrity_check、busy_timeout、自动 migration（备份+事务+checksum+失败中止）
- 4 张数据表：`ai_call_logs`、`prompt_versions`、`rate_limits`、`request_logs`
- 请求耗时日志中间件 `src/middleware/requestLogger.js`：队列批量写入 SQLite，控制台结构化输出，队列满时丢弃不阻塞主链路
- ASR 调用摘要日志：ASR 路由已接入 startAiCall/finishAiCall 模式，记录音频格式、转写长度、耗时、错误
- 日志持久化：adminLogStore 从纯内存改为 SQLite + 内存热缓存双层架构
- 日志正文落库开关 `HOLO_LOG_CAPTURE_CONTENT=true`，基础敏感信息脱敏（邮箱/手机号/token/API key/长数字串），截断上限 2000 字符
- Prompt 版本历史 + Diff + 回滚：`getPromptHistory`/`getPromptVersionEntry`/`rollbackPrompt`，diff 库集成
- 管理后台新增 Prompt 版本历史页面：版本列表、行级 Diff 视图、回滚按钮
- 管理后台日志页面增强：ASR 调用卡片展示（音频格式、转写长度、专属 badge）
- 持久化限流存储 `src/usage/sqliteUsageStore.js`：INSERT ON CONFLICT 原子计数，成本接口 fail-closed
- 管理日志自动清理（默认 30 天）、request_logs 自动清理（7 天）

### 变更
- Docker Compose 端口绑定改为 `127.0.0.1:8787:8787`，禁止公网直连 Hono
- Docker Compose 新增 `volumes: ./data:/data` 挂载 SQLite 数据库
- Dockerfile 新增 `build-base` + `python3` 编译依赖（better-sqlite3 原生绑定）
- Nginx 配置明确本期仅代理 `/v1/`，管理后台通过 SSH tunnel 访问
- promptRegistry.js 以 SQLite 为唯一运行时事实源，managedPrompts.json 仅用于一次性迁移
- server.js 新增数据库初始化和优雅关闭（SIGINT/SIGTERM）

### 依赖
- 新增 `better-sqlite3`（SQLite 原生绑定）
- 新增 `diff`（行级 Diff 算法）

---

## [2026-05-16] HoloBackend Prompt 托管与内部管理后台

### 新增
- 新增后端 Prompt 托管接口：`GET /v1/prompts`、`GET /v1/prompts/:type`
- 新增 HoloBackend 内部管理后台，支持账号密码登录、AI 调用日志查看、后台测试调用
- 新增 Prompt 管理页面，可查看、编辑、保存和恢复默认 Prompt
- 新增 `docs/admin-backend.md` 和 `memory.md`，记录管理后台架构决策和后续演进方向

### 优化
- iOS HoloAI 调用优先从后端加载 Prompt，失败时回退本地默认模板
- iOS 设置页和个人页隐藏普通用户 Prompt 编辑入口，Prompt 暂由开发者通过后端管理
- AI 调用日志页面支持展开完整请求/响应 JSON，便于调试模型输入输出

### 安全
- 管理后台使用环境变量配置账号密码，登录后使用 HttpOnly Cookie
- `HOLO_ADMIN_TOKEN` 仅保留给脚本调试；日志仅保存在进程内存中，不保存 ASR 音频二进制
- Prompt 与日志文档不记录真实密码、session secret、API Key 或用户日志内容

### 验证
- HoloBackend `npm test` 通过
- iOS Debug 模拟器构建通过

## [2026-05-14] HoloAI 商用后端网关接入

### 新增
- 新增 HoloBackend 商用网关 MVP，统一代理聊天补全和语音识别请求，前端不再直接暴露大模型 API Key
- iOS Debug 环境默认接入 ECS 后端网关，HoloAI 对话、Prompt 测试、AI 洞察和语音识别均走后端转发
- 新增 DeepSeek 聊天转发、DashScope ASR 转写、设备级限流、请求字段过滤和后端部署文档

### 修复
- 修复服务器 Node 18 环境处理 ASR 上传时 `File is not defined` 导致语音接口 500 的问题
- 为当前公网 IP + HTTP 验收临时放行 iOS ATS，解决 App 语音请求到达服务器前被拦截的问题

### 待办
- 后续增加后端请求耗时日志，用于持续观察聊天和语音链路延迟
- 商用前切换为域名 + HTTPS，并移除临时 HTTP 放行配置

## [2026-05-13] 观点语音输入与编辑体验优化

### 优化
- 语音输入录音与 WebSocket 连接并行，消除打开时约 1 秒的准备延迟
- 观点模块语音输入最大录音时长从 60 秒提升到 5 分钟，HoloAI 对话保持 60 秒不变
- 录音时长显示和自动完成提示文案改为动态生成，不再硬编码
- 观点编辑器内容区改为更宽、更高的长文输入布局，减少右侧空白并提升编辑空间
- 观点编辑器富文本行距调整为 1.5 倍，提升长文本阅读和编辑舒适度
- 语音识别结果确认卡片扩大文本编辑区域，结果态隐藏波形区以优先展示识别文本
- 语音波形音量映射优化，弱声音量也能获得更明显的波形反馈

### 修复
- 修复点击语音识别结果「插入」后需要等待 1-2 秒才写入观点编辑器的问题
- 点击观点列表中的具体想法时直接进入编辑页面，不再打开未同步新编辑样式的详情页

---

## [2026-05-12] 语音识别实时流式上传

### 优化
- 语音识别改为录音期间实时推送 16k PCM 音频到 Qwen-ASR WebSocket，不再等录音结束后按真实时长回放上传
- 停止录音后只等待已发送音频提交和最终转写结果，显著减少长录音的二次等待
- 录音服务从文件式录制切换为 `AVAudioEngine` 输入流，并保留实时音量计算驱动波形反馈

---

## [2026-05-12] 语音识别长录音稳定性修复

### 修复
- 修复超过约 10 秒的语音识别容易因 WebSocket 断开而失败的问题
- Qwen-ASR Realtime 音频上传改为 100ms PCM 小块节流发送，避免一次性推送大音频块
- 语音识别总等待窗口放宽到 120 秒，适配最长 60 秒录音

---

## [2026-05-12] 观点编辑器语音输入

### 新增
- 观点新建和编辑页面的内容框右下角新增悬浮话筒按钮
- 复用 HoloAI 同一套语音录制、暂停、继续、重录、识别和错误处理底部卡片
- 语音识别结果确认后插入到当前光标位置

---

## [2026-05-12] HoloAI 语音输入转文字

### 新增
- HoloAI 聊天输入区新增语音按钮，可打开底部语音输入卡片
- 支持录音、暂停、继续、取消、完成，识别结果可编辑确认后再发送
- 新增阿里云百炼 Qwen-ASR Realtime 接入，支持在设置页配置地域、模型、语言和 DashScope API Key
- 语音识别配置存储在本机 Keychain，API Key 不写入代码仓库
- 录音使用 16k 单声道 PCM/WAV 临时文件，完成、取消或关闭后清理本地音频

### 优化
- 录音声波由真实麦克风音量驱动
- 来电、闹钟等音频中断时自动进入中断态，中断结束后可继续或完成
- 录音开始、暂停/继续、完成、识别成功、失败等关键动作加入触感反馈
- 录音达到 60 秒自动完成并进入识别，UI 明确显示自动完成原因
- 语音卡片按钮适配动态字体和窄屏布局，深浅色沿用 HoloAI 现有颜色体系

---

## [2026-05-11] AI 回放提醒修复

### 修复
- AI 回放每周/月提醒通知不生效：App 启动时未恢复已注册的本地通知，iOS 更新或重启后通知丢失无法恢复

---

## [2026-05-11] 习惯连续性频率感知

### 优化
- 习惯连续坚持显示改为频率感知：每日习惯显示"连续X天"、每周习惯显示"连续X周"、每月习惯显示"连续X月"
- 每周习惯（如"每周3次"）按周统计达标次数，连续达标周数即为连续周数
- 每月习惯按月统计达标次数，连续达标月数即为连续月数
- 里程碑检测使用等效天数比较，保持跨频率的一致性

### 新增
- `HabitStreak` 类型：统一管理连续性值和单位（天/周/月）
- `calculateStreakInfo(for:)` 方法：根据习惯频率智能选择计算逻辑
- `calculatePeriodicStreak` 通用周期连续性计算（周/月复用）
- `countDistinctCompletionDays` 统计时间范围内不同打卡天数

---

## [2026-05-11] HoloAI 超时兜底机制 — 防止对话永久卡死

### 修复
- URLError.timedOut 在 streaming 路径被错误映射为 networkUnavailable，绕过了重试逻辑
- sendStreaming() 无重试机制，超时直接失败
- 超时/错误时已接收的流式内容被完全丢弃
- Core Data 中 isStreaming=true 持久化，app 崩溃后重进对话永久卡在 loading
- ViewModel isStreaming 无 watchdog 守护，异常后 UI 锁死

### 新增
- APIClient: URLError.timedOut → APIError.timeout 正确映射（send + sendStreaming 双路径）
- APIClient: sendStreaming 增加最多 2 次指数退避重试（与 send 一致）
- ChatMessageRepository.cleanupOrphanedStreamingMessages: 启动时清理残留 streaming 消息
- ChatViewModel: 90s streaming watchdog，超时自动取消、保存部分内容、恢复 UI
- ChatViewModel.retryMessage: 错误消息支持基于原始用户消息重新发送
- MessageBubbleView: 错误消息显示红色边框 + 重新发送按钮
- ChatMessageViewData.isError: 错误消息检测计算属性

---

## [2026-05-10] HoloAI 交易卡片编辑后科目同步

### 修复
- 用户在 HoloAI 中编辑交易科目后返回，卡片仍显示旧科目的问题
- 根因：卡片数据来自 ChatMessage 的冻结 JSON 快照，编辑 Transaction 后未同步回 ChatMessage
- 新增 ChatMessageRepository.refreshTransactionCard 方法，onSave 时同步 executionBatchJSON + extractedDataJSON 并刷新内存快照
- 新增 FinanceRepository.findCategory / resolveCategoryNames 支持分类层级解析

---

## [2026-05-10] HoloAI 分析查询卡片化 + loading 状态 + 历史消息零闪烁

### 新增
- 分析查询识别后立即显示「AI 正在分析中」loading 卡片，流式文字不再暴露给用户
- 紧凑分析入口卡片（AnalysisCompactChatCard），streaming/loaded/placeholder 三态切换
- AnalysisDetailSheet 详情页，卡片点击打开展示 AI 分析文本 + 数据卡片混排
- AnalysisDetailBlockParser 解析 AI 文本中的 `{{card:xxx}}` 标记，支持默认插入策略
- AnalysisSummaryFormatter 从 AnalysisContext 生成卡片摘要（icon/title/subtitle/summaryLine）
- MarkdownAttributedStringRenderer 抽取流式文本 Markdown 渲染逻辑为独立组件
- ChatMessageRepository.setAnalysisLoadingState 方法，流式前设置 intent+analysisContext

### 修复
- query_analysis 意图因 LLM 返回 single_action mode 而未被拦截（移除 mode 检查）
- analysisContext 为 nil 时紧凑卡片渲染空白（退化为普通气泡）
- 历史消息进入 Chat 时 queryAnalysis 卡片闪烁（lightweight init 直接解码 analysisContext）

### 优化
- PromptManager analysisPrompt 追加 `{{card:xxx}}` 标记指令，AI 输出可精确控制卡片位置
- MessageBubbleView queryAnalysis 渲染逻辑简化为三路分支（streaming / hasContext / fallback）

---

## [2026-05-10] 记一笔键盘态布局与快捷金额栏优化

### 优化
- 金额和名称上移为紧凑双输入框，键盘弹出时首屏可直接看到金额输入
- 最近使用分类改为横向胶囊样式，保留分类图标并与下方分类网格区分层级
- 快捷金额栏与数字键盘合并为统一托盘，修复边角断层和双重圆角问题
- 快捷金额栏、托盘、键盘按键使用轻微色差分层，改善深色模式下的视觉过渡
- 下拉完成交易的交互范围覆盖金额/名称输入区，减少顶部输入区与内容区割裂感

---

## [2026-05-10] 餐饮科目根据当前时间自动归类

### 新增
- 意图识别 Prompt 新增 `{{currentTime}}` 变量，AI 获知当前时间用于餐类判定
- Prompt 新增「餐饮自动归类」规则：未指定餐次时按时间段自动归类（05-10→早餐，10-16→午餐，16-21→晚餐，21-05→夜宵）
- IntentRouter 新增 `correctMealCategoryIfNeeded()` 本地时间修正，AI 判断错误时兜底纠正
- 用户明确说了"早饭/午饭/晚饭/夜宵"时尊重用户选择，不做覆盖

---

## [2026-05-09] 习惯图标渲染统一为 HabitIconRenderable 协议

### 修复
- 「戒烟」等自定义图标在今日看板、数值输入弹窗中显示空白（3 处遗漏 isCustomIcon 分支）

### 重构
- 新增 `HabitIconRenderable` 协议，集中处理 SF Symbol 和自定义 Asset Catalog 图标的渲染分支
- 4 个数据类型（Habit/HabitDetailSnapshot/HabitStatsDisplayItem/HabitStatsItem）统一遵循协议
- 10 处渲染点替换为 `iconImage(size:)` 一行调用，以后新增自定义图标不会再遗漏

---

## [2026-05-09] 记一笔页面交互重构 — 弹窗替代展开式选择

### 重构
- 账户/日期/分期从 .sheet 底部弹出改为 ZStack 覆盖层弹窗（半透明遮罩+居中卡片），消除页面抖动
- 名称行从展开/收起改为始终可见的 TextField，消除 ScrollView 内容高度变化
- 备注从展开式改为始终可见的 TextEditor 大文本框，带 placeholder 覆盖层
- 移除 showNoteEditor/showRemarkEditor 状态，简化为 @FocusState 焦点管理
- AddTransactionSheet 大文件拆分为 6 个职责单一的扩展文件（InfoInputArea/CategoryGrid/Keypad/SaveHandler/StateManager/KeypadComponents）

---

## [2026-05-09] 任务模块统一：新建与编辑合并为 AddTaskSheet

### 重构
- 废弃 TaskDetailView（1435 行），新建和编辑统一走 AddTaskSheet 表单模式
- TaskListView / TaskSearchView / TagListView 调用方重定向至 AddTaskSheet
- 优先级选择改为等宽按钮平铺一行填满宽度

### 新增
- 编辑模式：完成切换按钮（支持重复任务生成下一实例）
- 编辑模式：状态选择行（待办 / 进行中 / 已完成）
- 编辑模式：检查清单进度条（仅编辑且有待办项时显示）
- 编辑模式：删除任务按钮 + 确认弹窗
- `TaskStatus.color` 扩展迁移至 TodoTaskPriority.swift

## [2026-05-09] 习惯看板展示可见性控制

### 新增
- 习惯设置页新增双开关药丸按钮：每个习惯可独立控制「统计」和「看板」的展示位置
- 统计 = 习惯模块统计页，看板 = 首页今日看板
- 今日看板习惯列表和进度计算均按可见性过滤
- 首页入口按钮进度环同步适配

## [2026-05-08] 手势方向锁定统一方案

### 新增
- `HorizontalGestureLock`：三态方向锁定工具（undecided/horizontal/vertical），touch slop 观望 + 主方向优势比，锁定后不回头
- 所有 ScrollView 内水平手势统一接入：左滑操作按钮、右滑关闭、日历切换、图表交互、饼图高亮
- 单元测试 `HorizontalGestureLockTests`：覆盖观望/锁定/不回头/斜向等场景

### 修复
- 左滑操作按钮在上下滚动时误触：方向判定改为三态锁定 + 优势比，消除垂直/水平互相争抢
- 开发规范第 15 节：新增手势方向锁定规范，含错误方案对照和强制规则

## [2026-05-07] 习惯统计看板修复与月份切换

### 修复
- 坏习惯月度格子：无记录天不再显示打勾，改为空白（之前 `hasRecord = !isExceeded` 导致无记录也算成功）
- 坏习惯数值型完成率：无记录天计入控制住天数，与日历、摘要等其他统计函数保持一致

### 新增
- 统计看板月份切换：左右箭头快速切换上/下月，下月不超过当前月
- 点击月份文字仍可弹出月份选择器

## [2026-05-07] 任务详情页新增所属清单选择

### 新增
- 任务详情编辑页（TaskDetailView）新增「所属清单」选择功能，位于标签卡片下方
- 支持将任务移至任意清单或设为收件箱（未归类）
- 清单选择弹窗显示当前选中项高亮和清单颜色标识

## [2026-05-06] HoloAI 历史消息加载优化

### 优化
- HoloAI 对话页首屏改为轻量消息快照加载，跳过重 JSON 元数据解码，显著降低进入对话时的卡顿
- AI 上下文构建路径独立化，UI 只加载当前会话不影响 AI 追问时的历史上下文
- 消息卡片和日志元数据改为按需批量懒加载，可见时才从数据库读取
- 进入对话默认只显示最近一次会话（4 小时边界），支持下拉加载更早会话
- 加载更早会话时保持用户滚动位置不跳变

### 技术
- `ChatMessageViewData` 新增 `ChatMessageMetadataState` 状态机（unavailable/unloaded/loading/loaded）
- `ChatMessageRepository` 新增轻量加载、当前会话加载、更早会话加载、数据库级 DTO 查询、批量元数据懒加载
- `ChatViewModel` 首屏切换到会话加载，新增元数据 debounce 合并、更早会话加载
- `ChatView` 使用 `.refreshable` 原生下拉加载 + 可点击 header，滚动行为区分首次/流式/prepend
- `MessageBubbleView` 根据 metadataState 控制日志入口显示时机

## [2026-05-06] AI 分类学习映射管理

### 新增
- AI 设置页新增「分类学习映射」管理入口，可查看、搜索、删除 AI 自动学习的分类映射规则
- 支持按候选分类名和目标分类名搜索，支出/收入分组展示
- 支持左滑删除单条映射、一键清除所有映射

### 技术
- `CategoryLearnedMapping` 新增 `LearnedMappingEntry` 展示模型、`listAll()` 和 `removeByKey()` 公开 API
- 新建 `CategoryLearnedMappingView` 视图，使用 `.searchable` + `.swipeActions` 原生交互
- `AISettingsView` 新增 `mappingSection` 区块，带映射数量 badge

## [2026-05-06] 统计分析类别饼图显示与交互修复

### 修复
- 修复类别饼图在导入数据后整图变灰或变成单一红色的问题
- 修复饼图区域阻断页面上下滚动的问题，纵向手势现在可正常滚动到下方明细
- 恢复饼图点击、悬停/手势切换时查看具体分类金额的交互

### 技术
- 类别统计页饼图与图例统一使用图表调色板，避免导入分类共享默认色导致整图单色
- 饼图交互从 SwiftUI `DragGesture(minimumDistance: 0)` 改为 UIKit 透明触摸层，横向追踪高亮、纵向让 `ScrollView` 接管
- 扇区间隔角按扇区角度动态收缩，避免 0.3% 等极小扇区因固定 inset 反向绘制成整圈
- 新增饼图交互与极小扇区回归用例，并将经验沉淀到开发规范

## [2026-05-06] 统计分析余额改为累计值

### 修复
- 分析页面余额折线从「时间范围内净收入累计」改为「真实累计余额」，反映所有账户的实际净资产走势
- 余额计算公式：所有账户 initialBalance 之和 + 历史全部交易净收入 + 时间范围内逐期累加

### 技术
- 新增 `FinanceRepository.getCumulativeBalance(before:)` 计算截止日期的累计余额
- `computeChartDataPoints` 接受 `initialBalance` 参数，余额折线起点为真实余额

## [2026-05-05] CSV 导入科目原样迁移

### 优化
- 导入分类逻辑从“相似匹配预警”改为“原样迁移”：只在 `type + 一级分类 + 二级分类` 完全一致时复用已有科目
- CSV 中不存在于 Holo 的科目会按原始一级/二级结构自动创建，不再因未确认分类阻断导入
- 导入预览从“分类匹配预览”改为“科目导入计划”，展示已存在、新建一级、新建二级科目数量
- 新建导入科目统一使用默认问号图标和灰色系颜色，后续可在科目管理中自行编辑

### 技术
- 新增 `ImportCategoryPlanner`，集中计算导入时复用/新建的科目计划
- 移除导入流程中的同义词、学习映射、模糊匹配自动替换，避免替用户猜测科目归属
- 新增 standalone 行为测试，覆盖同名二级科目在不同一级分类或收支类型下必须分别创建

## [2026-05-05] CSV 导入功能完善 — 防止错导入

### 新功能
- 分类三元匹配：type + 一级分类 + 二级分类联合匹配，防止同名二级分类串线（如「餐饮/其他」与「购物/其他」）
- 导入预览弹窗重构：新增 ViewModel 管理解析、匹配、确认流程，大文件解析移至后台线程
- 分类匹配编辑器：点击任意匹配行可手动选择已有分类或确认新建
- 字段映射编辑器：自动检测错误时可手动修正 CSV 列与 Holo 字段的对应关系
- 解析警告系统：日期解析失败不再静默使用今天，改为阻断性警告需用户确认
- 批量确认模糊匹配：一键接受所有相似匹配，减少手动操作
- 外部文件打开：支持拖拽 CSV 到模拟器/设备直接打开导入（CFBundleDocumentTypes + .onOpenURL）
- 调试加载按钮：沙箱 Documents 目录存在 holo_import.csv 时显示「加载测试数据」入口

### 优化
- 模糊匹配阈值从 0.6 提升至 0.75，减少误匹配
- 一级分类不匹配时精确/同义词匹配降级为模糊匹配，需用户确认
- 学习映射 key 格式扩展为 `type|primary|sub`，防止跨一级分类碰撞
- 旧格式学习映射自动迁移（启动时执行）

### 涉及文件
- 新增：ImportPreviewViewModel、CategoryMatchEditor、FieldMappingEditor、Info.plist
- 修改：ImportPreviewSheet、ImportExportModels、CategoryMatcherService、DataImportService、CategoryLearnedMapping、HoloApp

---

## [2026-05-05] 智能快捷标签栏 Quick Tag Bar

### 新功能
- 记账页面键盘上方新增快捷标签栏，展示历史金额和名称标签，点击一键填充
- 根据输入模式智能过滤：金额输入时只显示金额标签，名称输入时只显示名称标签
- 未选科目时展示全科目历史数据，选择科目后自动切换为该科目数据
- 选择科目后保持键盘显示，标签栏直接出现在键盘上方

---

## [2026-05-05] 交易模块 Core Data 卡死修复 + 数据刷新规范

### Bug 修复
- 修复交易模块整体卡死：Transaction→Category/Account 缺少反向关系，denyDeleteRule 放在 to-one 侧导致 save 卡死
- 修复删除/复制交易后页面不更新：移除 refreshAllObjects()，改用 await 重新 fetch
- 修复删除分类后列表仍显示：loadData 过滤 isDeleted 对象，删除后始终刷新

### 规范
- 新增开发规范第 13 节：Core Data 关系建模与数据刷新（反向关系强制、denyDeleteRule 方向性、刷新模式）
- CLAUDE.md 新增 Core Data 关系编码约定

---

## [2026-05-05] 统计分析饼图交互修复 + 交易金额格式化

### Bug 修复
- 饼图手势冲突：移除 10pt 移动阈值，支持拖拽切换扇区高亮，同时不阻断页面上下滑动
- 详情页黑屏：合并 Sheet 状态为 TransactionSheetData，避免 SwiftUI 状态不同步导致空 sheet
- 金额小数位：编辑交易时始终保留 2 位小数（191.50 而非 191.5，5.83 而非 5.833333）

### 优化
- 类别图例移除冗余颜色圆点，仅保留分类图标
- 下钻后点击子分类弹出交易明细列表
- 交易行整行可点击（contentShape 优化）
- 交易明细中点击单笔交易可跳转编辑页

---

## [2026-05-05] 删除科目后 UI 卡死修复

### Bug 修复
- 修复删除科目后交易列表卡死的问题：Transaction→Category CoreData 关系缺少 deleteRule，删除后触发 fault 卡死主线程
- 三层防御：CoreData 层 denyDeleteRule + Category.swiftUIColor isDeleted 守卫 + View 层 isDeleted 检查

---

## [2026-05-05] AI 能力全景文档

### 文档
- 新增 `docs/_common/AI能力全景(A+B+C).md`：Phase A+B+C 完成后的全部 AI 交互 use case 清单
  - 主动交互 5 类：对话助手（15 种意图）、数据分析、记忆洞察回放、个性化配置、智能分类学习
  - 被动交互 5 类：后台自动生成、定时通知、异常检测、跨域关联、去重缓存
  - 含智能分类学习完整工程链路图、存储设计、能力边界分析

---

## [2026-05-05] AI 智能洞察 Phase B+C

### 新功能
- 结构化异常观察：消费突增、预算超支/预警、习惯断连、任务堆积自动检测
- 异常卡片按严重度区分（critical 红色、warning 橙色、info 蓝色）
- 跨域关联增强：情绪-消费并发检测、工作日/周末消费差异分析
- 用户反馈系统：Core Data 新增评分字段，支持轻量反馈
- 洞察去重：与近期洞察文本相似度 >85% 时自动跳过生成
- 上期回顾注入：本期洞察自动回顾上期建议和异常

### 改进
- Prompt 升级至 v4：anomaly 卡片支持、数据护栏、用户文本注入防护
- 习惯断连检测仅限每日正向打卡习惯，避免误判

---

## [2026-05-05] 交易复制功能

### 新功能
- 列表页长按交易，上下文菜单新增"复制"选项（编辑和删除之间）
- 编辑交易页右上角确认按钮旁新增复制图标按钮
- 复制时弹出日期选择器，默认目标日期与原始交易一致，可自由修改
- 完整复制金额、分类、账户、名称、备注、标签等全部字段

---

## [2026-05-05] 账本周/月历点击切换 + 类别 Tab 重构

### 新功能
- 账本首页新增 chevron 箭头指示器，点击即可在周历/月历之间直接切换
- 箭头同时支持拖拽连续控制，保持原有手势能力
- 类别 Tab 一级科目点击弹出 Sheet 展示子分类详情，替代原有下钻导航

### 优化
- 日历区域改为 ZStack 统一容器，拖拽过程中只有单一高度值变化，消除数字抖动
- dragTranslation 取整 + 去重，减少亚像素布局刷新
- MonthlySummaryCard 金额字号统一为 20/16，移除 minimumScaleFactor，拖动时数字不再缩放
- 饼图交互从拖拽高亮简化为点击选中

---

## [2026-05-05] 财务模块 UI 优化 — 图表压缩 + 日历手势修复

### 优化
- 统计分析页图表高度大幅压缩（柱状图 300→200pt，折线图 220→160pt，类别图 200-320→140-220pt），整体从占半屏降至约 1/4
- 明细折线图 Y 轴锁定：新增 `niceCeil()` 取整算法，切换时间范围时坐标轴不再抖动
- 月历最大展开高度从 300→280pt，视觉更紧凑

### 修复
- 账本首页上滑收起月历手势宽容度极低：阈值逻辑改为方向感知（上滑收起阈值 55% vs 下拉展开 30%），并增大手柄触摸区域（minHeight: 28）
- 弹簧动画阻尼微调（0.8→0.82），切换更丝滑

---

## [2026-05-05] AI 分析异常检测文案修复

### 修复
- 异常消费描述从「2026-05-02 支出 ¥5,736.00」改为「当日合计 N 笔支出共 ¥5,736.00」，避免 AI 将日汇总金额误读为单笔交易

---

## [2026-05-05] AI 智能洞察阶段 A + 幻觉修复

### 新功能
- UserContextBuilder 增加历史趋势对比（周支出/环比/习惯率/任务完成/Top分类）
- 日报洞察完整实现（Service 映射 + ContextBuilder 800 token 预算 + ViewModel 状态管理）
- Prompt v3 升级（趋势分析指令 + 异常检测指令 + 日报专用规则）
- 首页洞察入口（HomeScheduleService 新增 insight 模块）
- 后台/前台补偿增加日报自动生成 + dailyAutoGenerationEnabled 设置

### 修复
- AI 数据查询幻觉：系统提示词新增禁止编造数据规则，数据查询路由到 queryAnalysis（走结构化数据路径）
- 习惯完成率显示 1714%：averageCompletionRate 已是百分比值，去掉多余的 × 100

### 清理
- 移除旧 insightGeneration prompt、旧 InsightType 5 个 case、generateInsight() 死代码

---

## [2026-05-05] 记忆长廊里程碑日期修复 + fetchTasks 谓词确认

### 修复
- 里程碑触发日期永远显示"今天"：连续打卡/累计记账/习惯掌握三类里程碑全部硬编码 `Date()`，现改为按实际达成日期标记
- `detectStreakDays` 从精确匹配改为 `>=` 阈值匹配，避免跳过里程碑触发日后永远丢失
- `detectCumulativeCount` 查询第 N 笔交易的实际日期作为达成日期

### 确认
- `fetchTasks()` 谓词已包含 `deletedFlag == NO AND archived == NO`，此 bug 在之前的版本已修复

---

## [2026-05-05] 记忆长廊里程碑图标显示为文字

### 修复
- 明细页100笔里程碑卡片显示 "trophy.fill" 纯文字而非奖杯图标
- 根因：`MilestoneNode` 使用 `Text(data.icon)` 而非 `Image(systemName:)`

---

## [2026-05-04] 观点编辑器 Markdown 功能重构 — 精简工具栏 + WYSIWYG 加粗 + 列表样式修复

### 修复
- 编辑器加粗功能：点击按钮后文字显示 ** 星号标记而非粗体（WYSIWYG 问题）
- 加粗开关失效：再次点击加粗按钮无法取消加粗，必须换行才能恢复
- 加粗延迟反馈：点击加粗按钮后无即时视觉反馈，需等待输入文字才生效
- 列表样式问题：无序列表使用横杠 `-` 而非圆角点 `•`
- 列表吸附问题：列表会自动吸附到有文字的下一行，而非插入到光标位置

### 优化
- 精简工具栏：只保留加粗、无序列表、有序列表三个按钮（移除斜体、下划线、颜色、标签）
- 加粗即时反馈：点击按钮立即高亮 + 字体变粗，无需等待输入
- explicitBold 状态机制：改为 Bool? 类型，支持强制关闭覆盖 contextual 推断
- parser 兼容：MarkdownParser 正则支持 `•` 前缀

---

## [2026-05-04] 左滑手势彻底重构 — 挂载到 window 解决反复丢失

### 修复
- 任务/观点模块左滑归档和删除手势反复丢失，8 次修修补补均未解决根因
- 根因：Pan 手势挂在 SwiftUI 内部 superview 上，该视图不参与正常 UIKit 触摸分发
- 修复：Pan 手势改为挂在 `UIWindow` 上，通过 `shouldReceiveTouch` 限定只在 overlay 区域内响应
- 新增 `didMoveToWindow` 钩子 + 延迟重试机制兜底极端时序

---

## [2026-05-04] 首页三环旋转动画加速修复

### 修复
- 首页中央看板按钮的同心环旋转动画偶尔加速到 ~2 秒一圈（正常 90 秒）
- 原因：mainButton 上的 `.animation()` 隐式修饰符在 `@ObservedObject` 触发重渲染时，将 2 秒呼吸动画泄漏到 90 秒旋转环
- 修复：呼吸缩放改用独立 `@State breathScale` + 显式 `withAnimation`，与旋转动画完全隔离

---

## [2026-05-04] AI 对话查看 LLM 日志功能

### 新增
- 长按 AI 消息气泡可弹出「查看日志」上下文菜单，点击进入全屏日志页面
- 日志页面展示每次 LLM 调用的请求消息（system/user/assistant）和响应内容
- 每个调用分区独立复制按钮 + 底部浮动「复制全部」胶囊按钮
- Core Data ChatMessage 实体新增 `rawLogJSON` 字段持久化日志
- `LLMCallLog` / `LLMLog` 模型捕获意图识别和对话回复两次调用
- `AIProvider` 协议新增 `lastCallLog` 属性，Provider 侧记录请求，ViewModel 侧填充流式响应
- 左边缘右滑返回手势适配

---

## [2026-05-04] AI 记账分类未识别兜底 + 卡片跳转修复

### 改进
- AI 记账分类匹配策略调整：仅接受精确匹配和同义词匹配，移除模糊匹配和随机兜底
- 无法识别分类时自动归入「待确认」（挂载到「其他」/「其他收入」下），并提示用户点击卡片修改
- 卡片显示与实际存储保持一致：分类未匹配时卡片显示「待确认」而非 AI 原始文本
- RouteResult 新增 `categoryUnmatched` 字段，ConversationCoordinator 据此覆盖卡片渲染数据

### 修复
- 记账卡片无法跳转：`cachedLinkedEntityIds` 在 `updateSnapshot` 后未重新计算，导致新创建的卡片 `resolveLinkedEntityId` 返回 nil。新增 `recomputeLinkedEntityIds()` 方法在快照更新后刷新缓存
- 分类识别错误：「家政服务59」被模糊匹配到「地铁」，移除不可靠的模糊匹配兜底逻辑

### 新增
- `FinanceRepository.ensurePendingCategory(type:)` 按需创建「待确认」系统分类
- `ChatCardData` 图标映射新增「待确认」→ `questionmark.circle.fill`
- `ChatMessageViewData` 新增 `rawLog` 字段支持 LLM 调用日志查看

---

## [2026-05-04] 今日看板交互优化 — 弹窗化 + 进度环修复 + 数据同步

### 改进
- 数值类型打卡记录从全屏 sheet 改为居中弹窗（卡片 + 半透明遮罩），交互更轻量
- 弹窗支持点击遮罩关闭、X 按钮关闭、键盘上方"完成"按钮收键盘
- 弹窗渲染从 KanbanHabitSection 移至 DailyKanbanView 顶层 ZStack，避免 ScrollView 裁剪

### 修复
- 数值打卡首次点击白屏：`.sheet(isPresented:)` + 独立 editingHabit 状态竞态，改用 `@Binding` + 居中 overlay 消除时序问题
- 圆形进度条随进度变化变形：`Circle().trim()` 边界框不稳定导致布局抖动，改用 `Color.clear.frame(64×64).overlay` 固定容器方案
- 首次进入看板习惯数据不同步：`loadActiveHabits()` 排在 async 之后延迟执行，`loadStatus()` 未响应 habits 变化。修复：提前加载 + `onChange` 监听自动刷新

---

## [2026-05-04] 任务附件优化 — 后台图片处理 + 拍照卡死修复

### 改进
- 相册上传改为传原始 Data，解码/压缩/写文件全部后台执行，避免主线程卡死
- 新增 `AttachmentFileManager.saveImageDataInBackground` 和 `previewImageInBackground` 后台方法
- 删除附件改用稳定 `NSManagedObjectID`，避免视图层持有已删除 Core Data 对象
- 附件网格引入 `TaskAttachmentGridItem` 值类型，解耦视图与 Core Data 实体
- CameraView 移除手动 `picker.dismiss`，由 SwiftUI 统一管理 fullScreenCover dismiss

### 修复
- 拍照添加附件卡死：CameraView delegate 中立即将 UIImage 转 Data（切断 picker 生命周期依赖），图片保存延迟到 fullScreenCover dismiss 动画完成后执行，统一走 Data 后台处理路径

---

## [2026-05-04] 任务附件功能

### 新增
- Core Data 新增 TaskAttachment 实体（图片路径、缩略图、排序）
- AttachmentFileManager 管理图片存储与清理
- 任务创建/详情页支持添加图片附件
- 附件缩略图网格展示 + 全屏预览画廊
- 项目配置新增相机权限描述

---

## [2026-05-04] 修复财务图表手势错位与左侧 Y 轴不显示

### 修复
- 手势坐标修正：`proxy.position(forX:)` 返回 plot area 局部坐标，触摸点需减 `plotFrame.minX` 后再比较
- 抽取 `ChartTouchSelection` 工具类统一触摸命中逻辑
- 左侧 Y 轴改用默认 `AxisValueLabel` 确保标签可见
- 禁止使用 `proxy.value(atX:)` 查询分类轴（坐标映射不可靠）

### 新增
- `FinanceChartScaleTests` 测试用例
- 开发规范第 11 节「Swift Charts 坐标系与触摸交互」

---

## [2026-05-04] 首页图标改版 — 回归 iOS 原生质感

### 改进
- 功能按钮底板：去除色染叠层和边框，改用 `.thinMaterial` 系统毛玻璃，自动适配深浅模式
- 图标颜色：五个按钮统一为 `.holoTextPrimary` 自适应色，降低视觉噪音
- 投影调整：更柔和的弥散投影，增强悬浮卡片感

---

## [2026-05-03] 首页视觉丰富度提升

### 改进
- 背景氛围：鲜艳渐变光球（橙/紫/蓝）+ 装饰弧线 + 光点闪烁，全部带浮动/旋转/呼吸动画
- 功能按钮：激活五角形按钮的专属颜色系统（任务=橙、财务=绿、健康=蓝、观点=紫）
- 日期信息条：header 下方新增日期胶囊 + 时段微文案，填补上半屏空白
- 中心按钮外环：虚线 + 缓慢旋转动画，不同速度产生视差效果
- 中心按钮图标：数据驱动三环轨道，外环=总进度/中环=习惯/内环=任务，各环独立旋转 + 末端光点 + 中心呼吸光点

---

## [2026-05-03] 今日看板入口图标

### 改进
- 首页圆圈按钮中心添加三层同心环图标，隐喻习惯/任务/健康三大维度
- 图标白色描边配合橙色渐变背景，与看板内部进度环视觉呼应

---

## [2026-05-03] AI 深度财务分析增强

### 新增
- 子分类明细：Top 3 一级分类的子分类拆解（最多各 5 个子分类），AI 可给出"减少宵夜开销"等精准建议
- 分类环比变化：各一级分类当前期 vs 对比期的金额变化百分比，除零保护
- 消费模式分析：星期几消费最高、工作日/周末日均消费对比、高频消费分类 Top 5
- 6 个新增数据模型：SubCategoryDetail / CategoryTrendItem / SpendingPatterns / DayOfWeekSpending / WeekdayWeekendComparison / FrequentCategory

### 改进
- 分析提示词强化数字精度规则：禁止四舍五入、分数近似，changePercent 必须原值引用
- 财务分析侧重扩展：增加子分类占比、分类环比变化、消费模式维度
- FinanceAnalysisContext 新字段全部为 Optional，兼容已持久化的旧 JSON 数据

### 架构
- 修改 3 个文件：AnalysisDomainContexts / FinanceAnalysisContextBuilder / PromptManager
- 新增 3 个私有计算方法，复用已加载交易数组做内存聚合，避免重复查 Core Data

---

## [2026-05-03] 今日看板优化

### 改进
- 入口按钮简化为纯渐变圆圈，移除百分比文字和"今日看板"标签
- 看板标题改用 ZStack 覆盖层居中，不受左右控件宽度影响
- 健康数据卡片移至最底部（心情之后）
- 打卡板块支持三种习惯类型：打卡型 toggle / 计数类 +1 / 测量类数值输入弹窗
- 待办新增"近期待办"子区域，支持"加入今日"按钮并实时刷新列表
- 心情标签从 6 个扩充到 10 个，改为单排横向滚动
- 标签关联观点模块 ThoughtTag，从 Core Data 加载真实标签，支持自定义输入

---

## [2026-05-02] 今日看板功能

### 新增
- 首页中心入口按钮 `DailyKanbanEntryButton`，显示今日整体进度环，替代原 VoiceAssistantButton
- 全屏看板 `DailyKanbanView`，ScrollView 布局融合五大模块
- `KanbanProgressHero` 顶部进度汇总卡片（橙色渐变，打招呼 + 进度条 + 四项统计）
- `KanbanBudgetSection` 月度预算摘要（剩余金额、进度条、今日支出、日均可用、剩余天数）
- `KanbanHealthSection` 健康数据（睡眠/步数/站立三环图 + 睡眠质量标签）
- `KanbanHabitSection` 每日习惯打卡列表（图标、连续天数、打卡圆圈交互 + haptic）
- `KanbanTaskSection` 今日待办任务列表（完成交互、仪式标签、到期提醒横幅）
- `KanbanMoodSection` 心情日记输入（文本 + 6 种心情 emoji，保存自动同步到观点模块）
- `TodoRepository+Kanban` 扩展：看板查询、每日仪式生成、进度计算

### 改进
- `TodoTask` 新增 `plannedDate`（Date?）和 `isDailyRitual`（Bool）字段，轻量级 Core Data 迁移
- 底部导航中间按钮改为 AI 对话入口（原 Holo One 移至 iPhone Action Button）
- 无预算时自动隐藏预算卡片

### 架构
- 新建 9 个文件：DailyKanbanEntryButton + DailyKanbanView + 6 个 Section + TodoRepository+Kanban
- 修改 4 个文件：CoreDataStack+TodoEntities / TodoTask+CoreDataClass / TodoTask+CoreDataProperties / HomeView

---

## [2026-05-02] AI 通用分析查询功能

### 新增
- AI 分析查询框架：支持财务、习惯、任务、想法和跨模块五大领域的周期性数据分析
- 新增 `query_analysis` 意图，用户可说"分析我2024年的消费""复盘一下最近一个月"等
- 5 种分析卡片 UI：概览(Summary)、趋势(Trend)、分类(Breakdown)、对比(Comparison)、亮点(Highlights)
- 分析上下文持久化到 Core Data，重启 App 后历史分析卡片仍能正常渲染
- 分析查询发送零历史消息，避免上下文污染
- AnalysisPeriodResolver：从用户原文和 LLM 提取结果中智能解析日期范围（支持年/月/周/最近N天等）

### 架构
- 新建 11 个文件：AnalysisDomain / AnalysisContext / AnalysisDomainContexts / AnalysisPeriodResolver / AnalysisContextBuilder / 5 个领域 Builder / AnalysisChatCard
- 修改 14 个文件：AIModels / PromptManager / ConversationCoordinator / AIProvider / OpenAICompatibleProvider / MockAIProvider / ChatViewModel / ChatMessageViewData / ChatMessageRepository / ChatCardData / MessageBubbleView / CoreDataStack+ChatEntities / ChatMessage+CoreDataProperties / IntentRouter / ChatView
- 跨模块分析采用并发构建（async let），无共享可变状态

---

## [2026-05-02] 大文件重构 Phase 1-2

### 重构
- CoreDataStack (1,784→262行) 拆为 7 个模块化实体文件
- HabitRepository (1,402→696行) 统计逻辑提取到独立扩展文件
- FinanceRepository (1,384→271行) 拆为 5 个职责化扩展文件
- TodoRepository (936→809行) 统计逻辑提取到独立扩展文件
- FinanceView (1,360→182行) 拆为 5 个独立子视图文件
- TaskListView (994→744行) TaskCardView 提取到独立文件
- MemoryGalleryViewModel (920→829行) TimelineSectionBuilder 提取到独立文件

### 说明
- 10 个文件拆分为 24 个文件，Phase 3（AddTransactionSheet/AddTaskSheet/TaskDetailView）待后续处理
- 纯重构，不改变任何业务逻辑

---

## [2026-05-02] 记忆长廊智能周期回退

### 新增
- 智能周期回退：当前周期数据不足时自动回退到上一周期（月初/周初不再看到空数据）
- 月度阈值 7 天、周度阈值 3 天，不足则自动展示"上月"/"上周"洞察
- 后台服务新增月度洞察自动生成，前台补偿同步支持

### 改进
- HeroCard 标签动态显示"本周/上周"、"本月/上月"
- 生成/刷新/兜底文案全部适配有效周期

---

## [2026-05-02] 系统编辑菜单中文化

### 修复
- 双击文本弹出的系统菜单（拷贝/粘贴/全选）从英文改为中文：设置 developmentRegion 为 zh-Hans 并添加中文本地化支持

---

## [2026-05-02] 任务模块最近已完成折叠抽屉 + 首次启动卡死修复

### 新增
- 任务列表"最近已完成"改为折叠抽屉，默认展示 3 个任务，点击可展开全部

### 修复
- 首次启动卡死 — Core Data 异步加载 + CheckedContinuation 就绪等待
- TodoRepository init 零 I/O 延迟加载，避免阻塞主线程

---

## [2026-05-02] 行为洞察系统 MVP + AI 回放导航修复

### 新增
- 跨模块行为洞察系统 MVP：财务/习惯/任务/观点四模块数据融合
- CrossModuleCorrelator：4 条规则式跨模块关联检测（习惯↔财务、任务↔财务、想法↔习惯、任务↔习惯）
- MemoryInsightContextBuilder 增强：预算绩效、消费异常检测、习惯排名、任务完成率趋势、文本驱动想法分析
- Prompt v2：跨模块关联指导 + 空数据降级 + data/instruction 分离
- 年度回放提示词模板 + 月度洞察聚合查询
- ThoughtRepository 聚合方法：想法数/心情分布/标签排行/文本采样

### 修复
- generate_memory_insight 意图标签不可点击（补充 EntityCategory.memoryInsight + canTap 逻辑）
- 点击"已生成回放"标签无跳转（DeepLinkTarget.memoryGallery + ChatView 导航处理）
- 意图标签显示原始 key 改为中文"已生成回放"

---

## [2026-05-01] 任务模块 UI 重构 + 聊天数据层重构

### 新增
- 任务完成音效 + 触觉反馈
- 任务详情支持编辑标题和描述
- 任务完成增加撤回机制（Toast 提示可撤销）
- AI 意图标签支持任务跳转
- 深度链接竞态修复

### 变更
- 截止时间从 sheet 改为内联抽屉（图形日期选择器 + 时间切换）
- 检查清单从 sheet 改为内联列表（进度条 + 添加/删除）
- 新建任务布局优化：检查清单上移、属性对齐、优先级右对齐
- 任务排序改为创建时间降序
- 聊天数据读取层重构：统一实体解析 + 修复收入卡片跳转 + 原子化消息写入

### 修复
- 修复左滑手势与垂直滚动冲突（方向确认前不禁用 ScrollView）
- 修复任务/观点模块左滑手势全局失效
- 修复左滑手势拦截按钮点击

---

## [2026-04-27] 首页导航修复 + Prompt 编辑器修复

### 新增
- 首页导航状态修复
- 小黄点指示器
- HoloProfile 个人档案

### 修复
- Prompt 编辑器栈溢出修复（去除 @StateObject ViewModel，改用 @State 属性）

---

## [2026-04-26] 记忆长廊改版 + 金额显示修复

### 新增
- 记忆长廊三 Tab 改版：AI 回放 + 地图 + 明细

### 修复
- 全局金额显示截断修复（紧凑格式 + minimumScaleFactor）
- 最近的日子卡片大小统一（顶部对齐 + 固定最小高度）

---

## [2026-04-25] 预算功能 Phase 2

### 变更
- 预算卡片紧凑化：单行布局，去掉已花金额和分类预警

### 新增
- 分类预算：支持按一级/二级分类设置月度/周度/年度预算（如"餐饮不超过 ¥2000/月"）
- 首页预算卡片：记账首页展示全局预算进度 + 分类预警 chips（超支/接近预算）
- CategoryBudgetPicker：可展开的分类选择器，支持选择父分类或子分类
- BudgetSettingsSheet 模式切换：总预算/分类预算双模式
- AccountDetailView 分类预算列表：显示每个分类预算的 mini 进度条、百分比、剩余/超支

### 修复
- 删除分类时自动清理关联预算记录
- 删除空账户时自动清理关联预算记录
- BudgetSettingsSheet 金额输入非法时显示错误提示

---

## [2026-04-21] 习惯统计模块重构

### 新增
- 月度仪表板：单页滚动布局替代双 Tab 结构（总览/习惯），当前自然月为统计周期
- 周视图优先：每个习惯默认展示折叠态周视图，点击原位展开为完整月历
- 单开规则：同一时间只允许一个习惯展开，点击新习惯自动收起当前展开项
- 月份切换：点击月份标题区域弹出 MonthYearPickerView 切换月份
- 轻量总览卡：展示习惯数、完成率、最佳连续天数
- 设置页：管理统计页展示习惯的可见性和排序（UserDefaults 持久化）
- 折叠态默认定位到最后一个有记录的周
- 分类型摘要：打卡型（完成天数+连续天数）、计数型（完成天数+累计次数）、测量型（记录天数+平均值）

### 变更
- 底部导航从 `统计/习惯/新增` 改为 `统计/习惯/设置`
- 新增按钮从底部导航移入习惯 Tab 右上角
- HabitStatsState 重写为月度仪表板模式
- HabitRepository 新增月度投影方法

### 移除
- 删除旧统计组件：HabitStatsOverviewTab、HabitStatsHabitsTab、HabitOverviewCard、HabitRankingCard、HabitTimeRangeSelector、HabitTrendChartView
- 移除 7天/30天/90天/全部 时间筛选器和排行榜

---

## [2026-04-19] 图标库扩容与分组展示

### 新增
- CategoryIconCatalog 图标目录：12 个展示分组，171 个 SF Symbol 图标（原 88 个 + 新增 83 个）
- 图标分组展示：餐饮、交通、娱乐、购物、个人护理、家居、医疗健康、学习成长、家庭人情、生活服务、收入资产、其他
- 历史图标 fallback：编辑已有分类时，若当前图标不在目录中，顶部自动展示"当前图标"分组
- CategoryIconCatalogTests 自动化校验：符号可解析、旧图标保留、无重复、分组结构验证

### 变更
- IconPickerGrid 从扁平 LazyVGrid 重构为按 section 分组展示（外层 ScrollView + LazyVStack）
- AddCategorySheet 默认图标来源从 presetCategoryIcons 切换为 CategoryIconCatalog.allIcons
- 移除全局变量 presetCategoryIcons，由 CategoryIconCatalog 统一管理

---

## [2026-04-12] AI 对话能力扩展（Phase 1-3）

### 新增
- AI 意图从 9 个扩展到 14 个：新增 completeTask、updateTask、deleteTask、createNote、queryTasks、queryHabits
- 移除 `.chat` 闲聊意图，所有非指令输入走 `.unknown` 追问兜底
- 通用实体链接系统（`LinkedEntity` + `LinkedEntityType`），统一管理交易/任务/习惯/笔记关联
- 任务操作支持关键词匹配（精确 > 标题包含 > 备注包含，三级优先排序）
- 创建任务增强：支持优先级、截止日期、标签、描述
- 意图标签扩展：新增完成/更新/删除任务、笔记、查询等图标和标签
- 快捷操作栏从 5 个扩展到 8 个（新增记笔记、今日任务、习惯状态）
- Prompt 模板重写：14 意图分组、日期解析规则、意图判断规则

### 变更
- ChatViewModel 路由逻辑重构：query→流式对话、unknown→追问、其他→本地路由
- 实体合并采用双写策略（新格式 entityType+entityId + 旧字段），向后兼容
- UserContext 注入活跃习惯名称和未完成任务摘要，辅助 AI 理解上下文
- MockAIProvider 新增所有新意图的关键词匹配

### 待实施
- Phase 4: ConfirmationCardView 确认卡片 UI
- Phase 5: 能量值与限流系统（独立迭代）

---

## [2026-04-12] AI Chat 卡片点击跳转详情页

### 修复
- 记账卡片点击：不再跳转到记账首页，直接弹出交易详情编辑页
- 待办卡片点击：不再跳转到任务列表页，直接跳转到对应任务详情页
- ChatMessage 新增 linkedTaskId 计算属性，从 extractedDataJSON 解析关联任务 ID

---

## [2026-04-07] 坏习惯功能 + 记录删除崩溃修复

### 新增
- 习惯模块新增「坏习惯」标记（如抽烟、熬夜），支持打卡型/计数型/测量型的超标检测
- 坏习惯超过目标值时卡片数值变红，显示「已超过当日限额」自动消失提示
- AddHabitSheet 新增好习惯/坏习惯选择 UI

### 修复
- 习惯详情页删除记录时闪退：Core Data 删除后 `refreshAll()` 的 Task 异步更新，SwiftUI 重新渲染时访问已删除对象导致崩溃。改为先同步从 `records` 数组移除再执行删除

### 重构
- 数值型习惯统计改为按日聚合计算，避免一天多次记录导致统计偏差

---

## [2026-04-07] 饼图颜色一致性修复

### 修复
- 一级分类饼图使用科目指定颜色，保证与 App 其他位置（分类图标、列表）颜色一致
- 图表调色板从 5 色扩展到 12 色，支持更多分类的下钻场景
- PieChartView 改为接收外部颜色数组，由 CategoryTabView 统一分配

---

## [2026-04-06] 推送通知 Deep Link 跳转修复

### 修复
- 冷启动时点击通知不跳转：`.task(id:)` 改为 `.onAppear` + `.onChange` 组合，确保冷启动/热启动都能触发跳转
- `setupDelegate()` 从异步 Task 改为同步调用，避免冷启动时 delegate 未就绪

### 重构
- `DeepLinkState` 引入 `DeepLinkTarget` 枚举替代单一 `pendingTaskId`，支持任务详情/每日提醒/习惯等多模块跳转
- 通知 delegate 按 `categoryIdentifier` 设置不同跳转目标，每日提醒现在也会跳转到任务列表

---

## [2026-04-05] AI 记账科目匹配与饼图 Canvas 重绘

### 新增
- AI 意图识别增加完整科目体系，自动归类一级/二级科目
- 记账消息标签可点击跳转到对应交易的编辑页面
- ChatMessage 新增 linkedTransactionId 计算属性
- FinanceRepository 新增按 ID 查询交易方法

### 重构
- 饼图从 Swift Charts SectorMark 改为 Canvas 自绘，消除动画崩溃风险
- 选中扇区凸出 8pt，大扇区内部显示科目名称，引导线外部显示占比
- 触摸饼图时自动禁用父级 ScrollView 滚动

## [2026-04-05] 饼图标签外移与交互优化

### 优化
- 饼图标签全部移至外侧，引导线连接文字与扇区，不再侵占图表区域
- 触摸高亮与下钻分离：触摸时高亮扇区，松手才触发导航
- 标签碰撞检测：左右分组强制最小垂直间距，防止重叠
- 高亮时白色弧线视觉反馈

## [2026-04-05] 修复财务分析饼图下钻闪退

### 修复
- 修复饼图扇区点击下钻时 EXC_BREAKPOINT 崩溃（withAnimation 包裹数据源切换导致 Swift Charts 动画插值失败）
- 修复饼图触摸交互角度计算坐标系不一致（atan2 归一化空间与扇区起始角度不匹配）
- 各图表视图增加零值数据防护

## [2026-04-05] 财务分析类别页恢复饼图

- 类别 Tab 替换柱状图+折线图为饼图，扇区内显示科目名称，外部显示百分比
- 点击饼图扇区支持下钻至二级分类
- 小于 6% 的扇区不在内部显示标签，外部合并显示科目+百分比

## [2026-04-05] 财务分析页图表重构

### 改进
- 类别占比图表由饼图改为柱状图+折线图组合（柱状图显示金额，折线图显示占比百分比）
- 合并时间范围选择器和标签为统一组件，新增自定义日期按钮
- 分析页 Tab 栏简化样式，移除图标仅保留文字标签

## [2026-04-05] 优化财务统计分析饼图

### 改进
- 饼图缩小一圈（240→200），中心区域去掉分类图标，信息更紧凑
- 所有扇区均展示分类名称和占比，小扇区标签外延显示
- 饼图交互使用 UIKit 手势替代 SwiftUI DragGesture，解决 ScrollView 冲突
- 取消分析模块卡片背景，饼图/图例列表/分类详情与底色融为一体
- 下钻返回按钮移除卡片样式，仅展示简洁文字按钮

## [2026-04-05] 优化财务模块交易记录布局

### 改进
- 交易记录去掉独立卡片样式，改为列表行风格（分隔线替代卡片阴影）
- 交易记录背景与页面底色融为一体，视觉更简洁
- 交易行图标与"交易记录"标题左对齐
- 增大"今日账本"标题与周视图之间的间距（8pt → 16pt）

---

## [2026-04-04] 新增 Prompt 本地编辑器

### 新增
- AI 设置页新增"Prompt 模板"入口，列出 6 个可编辑的提示词模板
- PromptEditorView：查看、编辑、保存自定义 Prompt，支持变量预览
- PromptEditorViewModel：编辑状态管理 + LLM 测试功能
- PromptTestSheet：输入测试文本，发送到 LLM 实时查看响应
- PromptManager 支持 UserDefaults 自定义覆盖，优先于硬编码默认值
- 恢复默认：一键清除自定义 Prompt 回退到系统默认

### 改进
- PromptType 新增 displayName/displayDescription/icon UI 元数据

### 修复
- CategoryPicker 从 `.task` 改为 `.onAppear`，每次打开"记一笔"时重新加载"最近使用"分类
- FinanceLedgerView 月份标题底部间距调整

---

## [2026-04-04] 新增 AI 对话模块

### 新增
- AI 对话主界面（ChatView）：消息列表 + 快捷操作栏 + 输入栏
- 消息气泡（MessageBubbleView）：用户/AI 双样式，意图标签，流式打字动画
- 流式文本渲染（StreamingTextView）：打字中闪烁光标，完成后 Markdown 渲染
- 快捷操作栏（QuickActionBar）：记账/任务/观点/打卡/周报一键触发
- AI 设置页（AISettingsView）：Provider 选择、API Key、模型配置、连接测试
- AI 配置 ViewModel（AIConfigViewModel）：Keychain 安全存储、Provider 切换
- ChatViewModel：消息管理、流式响应、意图路由
- OpenAI 兼容 Provider：统一适配 DeepSeek/Qwen/Moonshot/Zhipu/自定义
- MockAIProvider：关键词匹配意图识别 + 模拟流式响应
- 网络层（APIClient + APIRequest + APIError + SSEParser）：重试退避、SSE 解析
- KeychainService：API Key 安全存储
- PromptManager：JSON 模板加载 + {{变量}} 替换
- UserContextBuilder：从记账/习惯/任务/观点 Repository 构建用户上下文
- IntentRouter：意图识别 → 本地 Repository 操作路由（记账/任务/观点/打卡）
- ChatMessage Core Data 实体 + Repository
- 6 个 Prompt 模板 JSON（系统提示/意图识别/数据提取/澄清/洞察/响应）
- AI 数据模型（AIModels.swift、AIConfiguration.swift）

### 变更
- CoreDataStack 新增 createChatEntities() 方法
- ContentView .holo tab 从占位视图替换为 ChatView
- SettingsView 新增 AI 设置入口
- 首页麦克风按钮连接 ChatView（fullScreenCover）

---

## [2026-04-04] 修复日期显示英文 + 开发规范更新

### 修复
- 任务列表卡片截止日期改用 DateFormatter + zh_CN，避免英文设备显示 "Apr 4"
- 记账页日期行、交易时间已在上一提交修复

### 变更
- CLAUDE.md 编码约定新增日期显示规范（禁止 Text(date, style:) / date.formatted()）
- 开发规范全局中文化章节补充禁止 API 列表和检查清单

---

## [2026-04-04] 账本页 UI 改版 — 月度卡片 + 显示设置

### 新增
- 月度收支概览卡片（MonthlySummaryCard），支持环比对比（如 4.1-4.4 vs 3.1-3.4），自动处理月份天数差异
- 卡片右侧显示当日支出金额
- 财务设置新增"显示设置"区块，支持切换"本月支出"/"本月收入"卡片显隐（默认仅显示支出）
- FinanceDisplaySettings 单例，UserDefaults 持久化显示偏好

### 变更
- "今日账本"标题移至按钮行下方独占一行，修复居中对齐问题
- 删除旧的日级支出/收入卡片（ExpenseCard、IncomeCard）
- 整体布局间距收紧（标题、拖拽手柄、卡片、交易列表标题）
- 卡片水平 padding 收窄 10pt

### 修复
- AddTransactionView 日期显示改用 DateFormatter + zh_CN locale（原 `Text(date, style: .date)` 不符合项目规范）

---

## [2026-04-04] 任务完成按钮交互修复

### Bug 修复
- 修复任务列表中无法直接点击圆形按钮完成任务的问题
- 根因：SwipeActionView 的 UIKit overlay 拦截了所有触摸事件，导致 SwiftUI Button 无法响应
- 方案：overlay 的 hitTest 返回 nil 实现触摸穿透，Pan 手势改挂到父视图，导航点击改由 SwiftUI Button 处理

### 变更
- 点击圆形按钮 → 直接完成/取消完成任务
- 点击文字区域 → 进入任务详情页
- 观点卡片同步采用相同的触摸穿透机制

---

## [2026-04-03] 修复观点新增卡死 + 设置页调试入口

### Bug 修复
- 修复真机上点击"新增观点"按钮后 App 卡死的问题
- 根因：UITextView `isScrollEnabled=false` 在 SwiftUI ScrollView 中产生 `intrinsicContentSize` 无限布局反馈循环，真机布局时序更紧凑导致死循环
- 方案：改用 `isScrollEnabled=true` + `SelfSizingTextView` 通过 `sizeThatFits` 显式计算高度，异步回传给 SwiftUI

### 新增
- 设置页新增"调试"区域，支持清除观点模块数据（Thought/ThoughtTag/ThoughtReference）

---

## [2026-04-02] 修复任务列表滚动冲突

### Bug 修复
- 修复任务/观点列表中卡片铺满屏幕时无法上下滚动的问题
- 根因：SwiftUI `DragGesture` 在 ScrollView 内会拦截滚动手势
- 方案：改用 UIKit `UIPanGestureRecognizer` + `gestureRecognizerShouldBegin` 方向判断，垂直放行给 ScrollView

---

## [2026-04-01] 任务检查清单 + 记忆长廊三层时间线

### 新增功能

#### 任务检查清单
- 新建任务支持添加检查清单，保存时批量创建 CheckItem
- 编辑任务支持管理检查清单（添加、勾选、删除）
- 检查清单区域与任务表单无缝集成

#### 记忆长廊三层叙事时间线
- 重构为垂直时间线布局：日摘要 → 高亮 → 里程碑
- 新增 `HighlightDetector` 算法：检测消费异常、习惯表现、任务完成等值得注意事件
- 新增 `MilestoneDetector` 算法：检测连续打卡、累计记录、习惯掌握等重大成就
- 新增 `MemoryTimelineNode` 数据模型：统一三种节点类型
- 新增组件：`DailySummaryNode`（日摘要卡片）、`HighlightNode`（高亮卡片）、`MilestoneNode`（里程碑卡片）、`TimelineDateHeader`（日期头）
- 支持模块筛选（全部/记账/习惯/任务）

### Bug 修复
- 修复编辑任务时 `list` 参数未传递导致清单归属丢失的问题
- 修复 `MilestoneDetector` 属性名拼写错误（`streakThresholds` → `streakDaysThresholds`）
- 修复 `MemoryGalleryView` 中 ViewModel 属性名不匹配的问题
- 修复 `HighlightDetector` 交易类型查询谓词字段名错误

---

## [2026-03-31] 任务模块描述功能修复

### Bug 修复
- 修复新建任务时描述（desc）字段未保存的问题（createTask 缺少 description 参数）
- 修复新建/编辑任务页面标题"新建任务"重复显示的问题
- 任务详情页描述区域增加"描述"标签，与页面风格统一
- 任务列表卡片中新增描述截断展示（最多 2 行）

## [2026-03-30] 观点模块上线 + 多模块优化

### 新增功能

#### 观点模块
- Core Data 实体：Thought、ThoughtTag、ThoughtReference 注册到数据栈
- Repository 层：ThoughtRepository 实现 CRUD、搜索、标签管理、引用关系
- 视图层：列表页、编辑器、详情页、搜索栏、筛选、心情选择、标签输入、引用选择
- 首页集成：HomeView 观点按钮连通 ThoughtsView
- 通知机制：thoughtDataDidChange 刷新列表数据

### 改进优化

#### 记账模块
- 交易列表区域支持左右滑动手势快速切换前一天/后一天
- 复用 WeekView 两阶段动画模式（滑出 → 数据更新 → 弹入）
- 周视图无消费日期选中时用胶囊底色替代全格背景，减小底色占比
- 用透明文字占位确保有无消费的日期数字垂直对齐

#### 观点模块设计规范对齐
- 全局 holoPurple → holoPrimary，统一为橙色主题
- ThoughtCardView 圆角从 28pt 改为 HoloRadius.md(12pt)，去掉描边改为阴影
- 空状态、引用卡片、标签配色统一到设计规范

#### 习惯统计模块
- 修复时间维度切换不生效（@Binding+回调双重写入竞争）
- 修复时间选择器位置，移至 Tab 栏上方并加横向滚动
- 修复自定义图标不显示（Asset Catalog vs SF Symbol 适配）
- 修复数值型习惯显示错位，合并为单行 "值 / 目标"
- 修复测量类折线图 Y 轴标签过密，限制刻度数量为 4
- 修复完成率趋势图手势阻挡页面滚动

### Bug 修复
- 移除周视图未选中今日的多余边框
- 修复记账键盘交互：选分类后自动收起键盘，回车键跳转备注输入框
- 修复分类管理页面最后一个分类被底部 Tab 栏遮挡的问题

---

## [2026-03-28] 分类系统扩展与图标优化

### 新增功能

#### 分类系统扩展
- 新增支出一级分类「人情」（琥珀色 #F59E0B）
  - 子分类：红包礼金、请客、送礼、探望、其他
- 餐饮新增：饮品、水果、酒水、超市
- 交通新增：公交、火车、机票
- 居住新增：房贷、家电、装修
- 医疗新增：牙齿保健、医疗用品
- 其他新增：话费、烟酒
- 工资收入新增：报销
- 其他收入新增：公积金、出闲置

#### 新增图标（22个）
- 餐饮类：饮品、水果、酒水、超市
- 交通类：公交、火车、机票
- 居住类：房贷、家电、装修
- 医疗类：牙齿保健、医疗用品
- 人情类：红包礼金、请客、送礼、探望、人情其他
- 其他类：话费、烟酒、报销、公积金、出闲置

### 优化

#### 图标渲染统一
- `CategoryPicker.swift`：统一使用全局 `transactionCategoryIcon()` 函数
- `QuickTemplateView.swift`：修正 SF Symbol 字体比例（size → size*0.6）
- 修复 11 个 SVG 图标 viewBox 不一致导致的大小差异

#### 分类数据迁移
- 优化 `seedDefaultCategories()` 支持增量补充新分类
- 已有数据的用户升级后自动获得新增分类

---

## [2026-03-28] 首页图标拖拽修复

### Bug 修复

#### 首页模块图标拖拽交换
- 修复长按拖拽图标到其他位置时，选中和被选中图标剧烈跳动的问题
- 引入 `anchorTotalShift` 累计锚点位移变量，每帧统一计算 `dragOffset = translation - anchorTotalShift`
- 解决 `DragGesture.translation` 不可重置导致的坐标补偿失效
- 拖拽过程中屏蔽外部数据源刷新，防止数据竞争

---

## [2026-03-26] 任务日期选择交互重设计

### 新增功能

#### 任务日期选择弹窗
- 新增 `TaskDatePickerSheet.swift` 整合日期、提醒、重复设置
  - `DatePicker(.graphical)` 日历选择
  - 全天/定时切换按钮
  - 提醒设置（整合 ReminderChip 组件）
  - 重复设置（每天/每周/每月/每年/自定义）
  - 结束条件（永不/指定日期/重复次数）
  - 支持半屏和全屏两种 detents

### 改进优化

#### AddTaskSheet 简化
- 移除内联展开的 `DatePicker`
- 移除独立的 `reminderSection` 和 `repeatSection`
- 点击日期区域弹出 `TaskDatePickerSheet`
- 添加设置摘要徽章显示（提醒数量、重复类型）

#### 组件复用
- 新增 `Components/ReminderChip.swift`
- 新增 `Components/TaskChips.swift`（RepeatTypeChip、WeekdayChip）
- 移除重复的组件定义

### Bug 修复

#### 结束条件 UI
- 添加"重复次数"选择器 UI（1-100 次）
- 修复结束日期弹窗按钮重复问题

---

## [2026-03-25] 健康模块基础实现

### 新增功能

#### 健康数据读取（HealthKit）
- 集成 HealthKit 框架，支持读取步数、睡眠时长、站立时长
- 新增 `HealthRepository` 数据仓库，封装 HealthKit 查询逻辑
- 支持模拟器环境自动切换为模拟数据

#### 健康视图
- 新增 `HealthView` 健康主页面，展示今日健康数据概览
- 新增 `HealthDetailView` 详情页，包含 7 天趋势图表
- 新增 `HealthPermissionView` 权限请求页面

#### 组件
- `HealthRingView` - 圆环进度指示器
- `HealthMetricCard` - 指标卡片（含进度条）
- `HealthTrendChart` - 7 天趋势柱状图（使用 Swift Charts）

#### 项目配置
- 配置 HealthKit entitlements（read-only 模式）
- 首页五角形按钮添加健康模块入口

### 已知问题
- HealthKit 授权在真机上需要手动在 Xcode 中配置 Signing & Capabilities

---

## [2026-03-16] App 图标上线 + 项目结构修复

### 新增功能

#### App 图标
- 正式设计并集成 HOLO App 图标
- 图标风格：暖色调米白背景 + 橙色连续线条勾勒的女性轮廓，顶部带有品牌字母 "H"
- 支持全尺寸适配：iPhone、iPad、App Store（29px ～ 1024px 共 12 个规格）
- 支持 iOS Light / Dark / Tinted 三种模式
- 原始图稿保存于 `icon/Holoicon.png`（2048×2048 高清源文件）

#### 项目文档
- 新增 `CLAUDE.md` 项目规范文件，记录技术栈、目录结构、开发工作流、提交规范等

### 问题修复

#### 项目结构修复（从 Cursor 迁移到 Claude）
- 修复因跨目录复制项目导致的 Swift 文件重复引用问题（`Multiple commands produce` 编译错误）
- 删除根目录 `Holo/` 下的 7 个重复 Swift 文件（与 `Holo APP/Holo/Holo/` 内容完全一致）
- 删除根目录 `Holo/Assets.xcassets/` 重复资源目录，消除 62 个分类图标名称冲突警告
- 清理旧 DerivedData 缓存（3 个指向 cursor 路径的残留缓存）

### 文件变更
- `Holo/Holo APP/Holo/Holo/Assets.xcassets/AppIcon.appiconset/` — 新增全套图标文件及更新配置
- `icon/Holoicon.png` — 新增 App 图标原始源文件
- `CLAUDE.md` — 新增项目规范文档
- 删除 `Holo/Assets.xcassets/`（重复资源目录）
- 删除 `Holo/Components/`、`Holo/Views/`、`Holo/Utils/`、`Holo/ContentView.swift`、`Holo/HoloApp.swift`（重复代码文件）

---

## [2026-03-15] 习惯图标系统扩展

### 新增功能

#### 图标分类系统
- 习惯图标从 20 个扩展到 **62 个**，按 9 大分类组织
- 新增图标分类：运动健身、健康生活、学习成长、自我提升、饮食营养、财务理财、日常习惯、戒除/减少、其他
- 每个图标带有中文标签，方便用户识别

#### 图标选择器升级
- 图标选择器改为分类展示，每个分类有独立标题
- 图标下方显示中文名称（如"跑步"、"阅读"）
- 视觉优化：圆角卡片 + 选中高亮效果

#### 自定义 SVG 图标支持
- 新增 `HabitIcons` Asset Catalog 文件夹
- 创建自定义"戒烟"图标（香烟 + 禁止符号 SVG）
- 支持混合使用 SF Symbol 和自定义 Asset 图标
- `IconItem` 新增 `isCustom` 属性区分图标类型

### 技术要点

#### 图标类型判断
- `Habit` 模型新增 `isCustomIcon` 计算属性
- 根据图标名在 `HabitIconPresets.allItems` 中查找是否为自定义图标
- 自定义图标使用 `Image(name).renderingMode(.template)`，SF Symbol 使用 `Image(systemName:)`

#### 数据结构
- `HabitIconCategory`：图标分类（name, icon, items）
- `IconItem`：单个图标项（name, label, isCustom）
- `HabitIconPresets.categories`：分类数据源
- `HabitIconPresets.allItems`：扁平化图标列表

### 文件变更
- `HabitType.swift`：新增图标分类数据结构和 62 个图标定义
- `AddHabitSheet.swift`：图标选择器改为分类展示，支持自定义图标
- `HabitCardView.swift`：习惯卡片图标显示支持自定义图标
- `Habit.swift`：新增 `isCustomIcon` 属性
- `Assets.xcassets/HabitIcons/`：新增习惯图标资源文件夹

---

## [2026-03-15] 习惯打卡功能

### 新增功能

#### 习惯数据模型
- `Habit` Core Data 实体：支持打卡型（每日打卡）和数值型（记录数值）两种习惯
- `HabitRecord` Core Data 实体：记录每次打卡/数值，与 Habit 一对多关联
- 支持自定义图标、颜色、频率（每日/每周/每月）、目标值
- 数值型习惯支持计数（累加）和测量（取最新值）两种聚合方式

#### 习惯首页 (HabitsView)
- 习惯卡片列表，展示图标、名称、频率/目标、今日状态
- 打卡型习惯：点击勾选按钮完成/取消打卡，显示连续天数
- 数值型习惯：计数类显示 +1 按钮，测量类显示输入按钮
- 底部 Tab 栏：统计 / 习惯列表 / 新增
- 顶部显示今日完成进度（如 2/5）

#### 习惯详情页 (HabitDetailView)
- 习惯信息头部：图标、名称、类型标签、频率目标
- 时间范围切换：本周 / 本月 / 本季度 / 全部
- 统计摘要：打卡型显示连续天数/完成次数/完成率，数值型显示总计/日均/峰值或变化/最低/最高
- 记录列表：按时间倒序展示，支持删除单条记录
- 工具栏操作：编辑 / 归档 / 删除

#### 新增习惯表单 (AddHabitSheet)
- 习惯名称输入
- 类型选择：打卡型 / 数值型（分段选择器）
- 数值型聚合方式：计数 / 测量
- 图标选择：20 个预设 SF Symbols
- 颜色选择：10 种预设颜色（5x2 网格）
- 频率选择：每日 / 每周 / 每月
- 目标设置：打卡型设目标次数，数值型设目标值和单位

#### 首页入口
- 点击首页「习惯」图标进入习惯模块（fullScreenCover）
- 支持从左边缘向右滑动返回首页

### 技术要点

#### SwiftUI + Core Data 最佳实践
- **body 内禁止 Core Data 查询**：所有查询在 `onAppear`/`onReceive` 中执行，结果缓存到 `@State`
- **@StateObject 不能包装 @MainActor 单例**：改用 `@ObservedObject` 或直接 `.shared` 调用
- **访问 @MainActor 单例必须用 Task 包装**：`Task { @MainActor in ... }`

#### NSManagedObject 删除流程
1. 使用 ID（UUID）而非对象引用传递
2. sheet 用 `item` 绑定（值类型 selection），避免 `isPresented + selectedId` 状态不同步导致的 Loading
3. 删除前先从本地数组移除（`habits.removeAll { $0.id == id }`）
4. 延迟 0.1s 再执行 Core Data 删除
5. 访问前检查 `!habit.isDeleted && habit.managedObjectContext != nil`
6. 使用 `isDeleted`/`managedObjectContext` 需 `import CoreData`

### 修复与优化
- 修复 `HabitCardView` / `HabitDetailView` 缺失 `import CoreData` 导致编译失败
- 修复习惯详情 sheet 首次打开偶现「加载中...」与卡顿：改为 `.sheet(item:)` 单一状态驱动展示
- 优化习惯变更通知：携带 `habitId`，仅刷新对应卡片/详情，减少全量 Core Data 查询
- 优化今日完成进度统计：从逐个习惯查询改为单次 fetch 统计

### 文档更新
- 开发规范新增「6️⃣ SwiftUI + Core Data 视图卡死/白屏问题」
- 开发规范新增「7️⃣ NSManagedObject 删除后访问崩溃」（含标准删除流程代码和时序图）

---

## [2026-03-14] 首页功能入口重构

### 新增功能

#### 五角形图标布局
- 首页功能入口从 4 个扩展为 5 个
- 新增「习惯」功能入口，使用 `checkmark.circle` 图标
- 布局从四角定位改为五角形环绕语音助手按钮
- 5 个图标均匀分布在语音按钮周围（每隔 72° 一个位置）

#### 长按拖拽排序
- 长按 0.5 秒激活拖拽模式，伴随触觉反馈
- 拖拽时图标放大 1.15x 并添加阴影效果
- 拖到其他位置 50pt 范围内自动交换位置
- 只能在 5 个固定位置之间交换，不支持自由停放
- 松手后弹性动画归位

#### 图标配置持久化
- 新增 `HomeIconConfig` Core Data 实体
- 用户调整的图标顺序自动保存到本地数据库
- 重启 App 后保持上次的排列顺序
- 预留 `isVisible` 和 `customName` 字段，支持后续扩展

#### iCloud 同步准备
- 数据架构已为 CloudKit 同步做好准备
- 在 `CoreDataStack.swift` 中添加详细的启用指南

### 优化调整
- 图标与文字间距从 8pt 减少到 4pt
- 五角形布局整体上移 10pt

---

## [2026-03-14] 数据导入导出功能

### 新增功能
- CSV 文件导入功能，支持从其他记账 App 迁移数据
- CSV 文件导出功能，支持数据备份
- 导入预览界面，确认数据无误后再导入
- 异常数据智能处理，自动识别和修复格式问题

---

## [2026-03-14] 记账月历视图 Phase 2

### 体验增强
- 月历交互优化
- 日期选择体验改进
- 动画过渡更流畅

### 交易管理优化
- 交易列表展示优化
- 交易详情页面完善
- 编辑和删除交易功能

---

## [2026-03-14] 记账月历视图 Phase 1

### 新增功能
- 周视图：展示一周的收支概览
- 月历视图：日历形式查看每日收支
- 弹窗抽屉：点击日期查看当日交易详情
- 日期导航：快速切换月份和年份

---

## [2026-03-11] 开发工具优化

### 新增
- 添加 `todo-sync-after-commit` 技能
- 自动同步 TODO 状态与 Git 提交

---

## [2026-03-08] 记账键盘优化

### 修复
- 记账键盘输入体验优化
- 金额显示格式修正
- 键盘响应速度提升

### 文档
- 新增记账模块业务规则文档

---

## [2026-03-07] 财务页 UI 大版本升级

### 新增功能
- 分类体系升级：支持 71 个图标的二级分类
- Asset Catalog 规范化管理分类图标
- Figma 导出图标转换脚本

### UI 优化
- 财务页 UI 全面优化
- Tab 栏与加号按钮合一设计
- 收支卡片视觉升级
  - 去除边框，更简洁
  - 微渐变背景
  - 负空间设计
  - 毛玻璃效果

### 文档
- 开发规范文档
- 开发前必读指南

---

## [2026-03-05] 仓库结构统一

### 调整
- 统一仓库结构
- 纳入 iOS 记账 MVP 代码
- 整理项目文档

---

## [2026-03-03] 开发规范

### 文档
- 添加开发规范文档
- 记录频繁提交和推送的最佳实践

---

## [2026-03-02] 首页 UI 实现

### 新增功能
- 实现 Holo 首页 UI
- 基于 Figma 设计稿还原
- 顶部问候语和用户头像
- 中央语音助手按钮
- 四角功能入口按钮
- 底部浮动导航栏
- 日程提醒组件

---

## [2026-03-01] 项目初始化

### 初始提交
- 创建 Holo 项目仓库
- 初始化项目结构
