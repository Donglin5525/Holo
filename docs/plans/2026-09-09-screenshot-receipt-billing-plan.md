# 截图识别记账 · 重启规划（2026-09-09）

> 前身：2026-08-27「HoloAI 识图能力」两段式方案（三决策点待拍板，未动工）。
> 本文档基于 2026-09-09 三路代码核查（iOS 聊天链路 / 后端就绪度 / 财务模块关联面）重新校准，影响面补全。
> 状态：**已拍板（2026-09-09 九点全定，见 §9 拍板结果），进入 M0 评测选型阶段。涉及一次后端发版。**

---

## 0. 结论速览

- **架构维持两段式**：第一段一次视觉调用出「图片理解单」，第二段理解单+随图文字走现有 intent 管道。21→30 个意图、确认卡、学习映射、额度池全部零改动复用。
- **端点建议从「放开聊天校验」改为「独立新端点」**：后端聊天校验仍锁死纯文本 string（app.js:1596），放开它等于在最活跃迭代的关键链路上开口子；独立端点可以让校验/限流/日志/「图片即弃」全部端点级保证。
- **核查发现四个此前没识别的影响面**（本方案新增的拍板点主要来自这里）：
  1. **同一张小票发两次会记两笔**——现有三层防重全部绑定在批量导入管道，单笔 AI 记账无任何去重；
  2. **转账/理财截图若识别成消费会虚增支出统计**——系统没有「转账」交易类型，导入管道有过滤兜底，截图链路没有；
  3. **隐私政策正文未披露任何图片上传**（连已上线的反馈截图上传都没披露），截图识别上线前必须补，含 in-app 法律页与 nginx 对外三语版；
  4. **聊天内图片留存需要 CloudKit schema 增量部署**（Core Data 加字段即触发），这是发版前置依赖，不是随发随生效。

---

## 1. 现状校准：与 2026-08-27 结论的差异

| # | 8/27 口径 | 9/9 实测 | 对方案的影响 |
|---|---|---|---|
| 1 | 聊天链路纯文本 | 仍成立，iOS+后端双重锁死（ChatMessageDTO content 纯 String；后端 validateChatRequest app.js:1596-1614 强制 string） | 不变，两段式前提仍对 |
| 2 | TaskImagePicker 现成可用 | **已成准死代码**：任务/想法两模块各自内联重写了选图，TaskImagePicker View 本体无调用方（其内部 CameraView 仍被复用） | 聊天选图照抄内联模式，不复活旧组件 |
| 3 | 无相册 iCloud 加载器 | **新增 PhotoLibraryImageLoader**（4c0b0a586，9-07）：三层加载+权限前置+失败归因，反馈/任务/想法三处已接 | 直接复用，截图选图的 iCloud 原图下载有了现成方案 |
| 4 | 中文硬编码 | **多语言主体已落地**：三语 xcstrings（3839 keys）+ 种子语言固化 | 新 UI 文案必须三语（zh-Hans/zh-Hant/en）；xcstrings 有在途大改，动它要基于在途版本 |
| 5 | purpose 22 个、5 池 | **purpose 30 个、7 池**；「不占池+独立限流桶」已从隐式默认变成显式先例（personal_context_extraction/verification return null） | vision_extraction 的额度口径有现成范式可照抄 |
| 6 | 后端无视觉模型 | 仍无任何视觉模型接入；生产只喂 DeepSeek（无视觉能力）；qwen/zhipu 供应商位就绪未用 | 模型选型是全新工作项，评测先行 |
| 7 | 聊天确认卡单笔 | 聊天 9 月起新增 contextPlan 草案卡链路，ChatViewModel 发送分支更复杂 | 图片入口的实现要避开这条新链路；分支复杂度是回归风险 |
| 8 | — | **账单 AI 导入（BillImportAIService）已成体系**，带完整安全铁律：金额/日期打码、AI 只指认不发明、白名单校验、失败不阻断 | 截图识别的 prompt 安全范式直接借鉴 |
| 9 | 版本 1.0.x 早期 | 分支 1.0.3（版本号未 bump，仍 1.0.2/24）；1.0.2 提审中；在途 Core Data 变更（FinanceProject 实体） | 排期落 1.0.3；若加 Core Data 字段需与在途变更协调同一模型文件 |

**不变的硬事实**：确认卡=IntentRouter 直接落库（非预填记账页），预填仅「改分类」一处且 PendingTransactionPrefill 只有金额/名称/类型/日期/分类五字段（**无账户**）；反馈 base64 上传是全后端唯一图片入口先例（JPEG 魔数+1.5MB 上限，**无清理机制**——截图识别不能照抄落盘做法）；DeepSeek 无视觉模型。

---

## 2. 总体架构（两段式，微调端点形态）

```
用户选图/拍图
   │  iOS 本地压缩 ≤1MB、剥 EXIF/GPS（复用 FeedbackImageCompressor 思路，抽成共用）
   ▼
【第一段】POST /v1/ai/vision/extract（新独立端点，purpose=vision_extraction）
   │  视觉模型一次调用 → 「图片理解单」JSON：
   │  { 图型: 小票|支付截图|转账截图|理财截图|清单|聊天记录|无关,
   │    金额/币种/商户/日期/条目/支付通道/置信度, 一句摘要 }
   │  服务端识别完即弃，不留盘不进日志正文
   ▼
【第二段】理解单文本 + 用户随图文字 → 现有 intent 管道（零改动）
   │  路由规则：随图文字优先；无文字按图型默认路由
   │  （小票/支付截图→记账；转账/理财截图→拦截引导；清单→二期任务卡）
   ▼
TransactionChatCard 确认卡（复用）→ 用户确认 → IntentRouter 落库（复用）
```

**为什么反对「图片直接进意图识别」**（8/27 结论，仍成立）：破坏确定性正则短路；用最贵的调用干最粗的活；意图识别 prompt 与视觉抽取关注点完全不同。

**为什么端点建议独立而非放开 chat 校验**：
1. validateChatRequest 是所有 30 个 purpose 共用的门，放开 content 数组等于全链路放开，管住「只有 vision_extraction 能带图」需要额外分支，风险面大于收益；
2. 独立端点可以把「图片即弃」做成端点级保证（内存处理、不落盘、日志只记元数据），而 chat 端点日志摘要/审核链路都是按文本语义写的（`extractMessageText` 虽已兼容数组，但图片内容不进审核是已知缺口，独立端点至少把这个缺口的暴露面收窄到唯一一个新端点）；
3. iOS 侧 ChatMessageDTO 继续保持纯文本，聊天历史落库存「本地图引用+理解单摘要」，不用为多模态改造消息模型。

备选方案 B（保留在案）：在 chat/completions 上对 vision_extraction 单独放开 content 数组。优点是复用 chat 端点全部接线（鉴权/日志/限流一行不少）；缺点如上。若后端人力紧张可降级到 B。

---

## 3. 产品方案

### 3.1 一期范围（建议）

- **抽取层全做**：图型分类（小票/支付截图/转账/理财/清单/无关）+ 字段抽取一次到位，prompt 后台可热更，二期只开产品入口不加调用。
- **产品入口只开记账**：小票/支付截图 → 记账确认卡。转账/理财截图一期诚实拒识（见 3.3）；清单/白板 → 二期任务批量卡；无关图 → 拒识引导。

### 3.2 入口与交互流（建议）

- 入口：**聊天输入栏加图片按钮**（PhotosPicker + 相机，内联模式照抄任务/想法两模块）。不做成记账页直达按钮（那是三期「拍小票」快捷入口，直达 AddTransactionSheet 预填）。
- 流程：选图 → 本地压缩 → 气泡显示「图片+识别中」占位（可取消，复用流式取消架构 onTermination+userCancelled 防复活）→ 识别完成 → 确认卡 → 确认落库 / 「改分类」进 AddTransactionSheet。
- 超时与失败：视觉调用比文本慢，超时给足（≥90s，吸取 409 卡死案 60s<90s 的教训）；失败/超时/拒识在气泡内给明确原因与重试/手填引导，不静默。

### 3.3 边界场景产品口径（影响面清单）

| 场景 | 一期口径 | 理由 |
|---|---|---|
| 无关图片（自拍/风景） | 诚实拒识：「这张图里没找到能记的账」，引导重拍或手填 | 宁可问不瞎猜落库 |
| **转账/还款/理财截图** | **识别即拦截**：「这是资金流转，不计入收支」，不生成确认卡 | 系统无转账类型，误记会虚增支出统计+余额口径（导入管道有此过滤，截图链路必须补上） |
| 同一小票重发 | 确认卡前软检测（金额相等+类型相同+±1 天窗口，借鉴 BillDuplicateDetector），命中则卡上提示「可能已记过一笔 ¥xx」 | 现有防重全部绑定导入管道，单笔路径裸奔；不动指纹机制，只提示不阻断 |
| 外币小票 | 一期不支持：识别到非 ¥ 金额→拒识+说明，引导手填 | 交易模型单币种（CNY 硬编码），无汇率字段，硬换算会引入错误数据 |
| 退款截图 | 走收入+退款分类（关键词链已有），正常确认 | TransactionType 仅 income/expense，收入语义天然覆盖 |
| 一张图多笔（合并支付/多商品小票） | 理解单返回 items[]，一期逐笔出确认卡（复用同轮多卡先例，task 卡已支持） | 硬截成单笔会丢数据 |
| 分期小票 | 一期不做分期拆分，按整笔记 | AI 分期路径存在但 Plus 门槛+复杂度高，二期再说 |
| 模糊/低置信 | 置信度阈值以下不给卡，引导重拍或手填 | 防止错账比漏账伤害大 |
| 无网络/超时 | 明确报错+重试，占位可取消 | 复用额度卡/失败卡既有交互 |
| iCloud 图选了下载不下来 | PhotoLoadOutcome 归因提示（权限/网络），不静默 | 三层加载器已内建 |

### 3.4 账户口径（已拍板：默认账户兜底 + 自动识别微信/支付宝）

AI 记账现状硬编码落「默认账户」。
拍板：理解单抽取 `paymentChannel`（微信支付/支付宝/银行卡尾号/现金），iOS 侧自动匹配既有账户：账户名含「微信」→ 微信类账户、含「支付宝」→ 支付宝账户、银行卡尾号能对上 → 对应卡账户；都匹配不到落默认账户。确认卡**展示账户行**，可点改；「改分类」入口的 PendingTransactionPrefill 扩展 account 字段。匹配规则的纠错回流学习（记错了下次自动改）放二期。

---

## 4. iOS 影响面（逐项）

| # | 改动点 | 位置与做法 | 风险 |
|---|---|---|---|
| 1 | 聊天输入加图片按钮 | ChatInputView.swift:72-124 现为纯文本+麦克风+发送；内联 PhotosPicker+相机（照抄 TaskDetailView/ThoughtEditorView 内联模式），复用 CameraView | ChatViewModel 发送分支已很复杂（contextPlan 新链路刚接通），图片发送做成**独立分支**，不嵌入既有文本分支 |
| 2 | 选图加载 | 复用 PhotoLibraryImageLoader（三层加载+权限前置+PhotoLoadOutcome） | 无，现成 |
| 3 | 压缩 | FeedbackImageCompressor（≤1MB、长边 2400、剥 EXIF/GPS）从 Feedback 私有抽成共用服务 | 低 |
| 4 | 消息模型 | **唯一模型变更**：ChatMessage 加图片引用字段（本地缩略图路径，AttachmentFileManager 存图）。气泡渲染图片+理解单摘要 | ①Core Data 模型变更与在途 FinanceProject 变更同文件，需协调；②**触发 CloudKit schema 增量部署（发版前置）**；③跨设备路径不解析（图不跟随同步）——已拍板接受（§9-5） |
| 5 | 新增 vision 网络通道 | AIModels 加 VisionExtractionRequest/Response DTO；HoloBackendAIProvider 加 extractVision 方法（非流式、可取消、超时≥90s） | 取消复活防护照抄 holoai-cancellation 架构 |
| 6 | 确认卡 | TransactionChatCard 复用；新增账户行展示+「改分类」入口的 prefill 扩展 account 字段（AddTransactionSheet.swift:558 struct 加一字段+消费处一行） | 低；保存路径已带学习映射回写，自动继承 |
| 7 | 分类 | 走 IntentRouter.matchCategory 既有优先级链（学习映射→AI 指认→别名→语义推断→兜底「待分类」），零新逻辑 | 无；商户名进链路天然享受学习映射 |
| 8 | 额度 UI | vision_extraction 不占会员池→无额度卡；需新增「今日识别次数用完」提示文案 | 低 |
| 9 | 本地化 | 全部新文案三语（xcstrings）；**xcstrings 有在途大改（±38k 行），动它须基于在途版本或等入库，防合并冲突** | 中，纯流程风险 |
| 10 | 权限文案 | NSCameraUsageDescription 现文案只提「任务附件」（pbxproj:1616/1671），需扩写为覆盖聊天识图 | 改文案不需重新授权，低 |
| 11 | 隐私确认 | 首次使用弹一次性说明（样式照抄 CloudAnalysisPrivacySheet 范式）：上传压缩图、识别后即删 | 建议做，合规加分 |
| 12 | iPad | 聊天双栏下图片按钮与气泡布局过一遍 | QA 项 |
| 13 | 测试 | 发送独立分支的单测；拒识/拦截/防重提示的 UI 测试（锁屏/无窗口铁律 holo-sim-headless；AX 标签≠可见文字等已知坑在档） | 常规 |

**明确不动**：Transaction 模型零字段变更（统计口径 22 处排除链、对账、分期全部不碰）；intent 管道零改动；额度池零改动。

---

## 5. 后端影响面（逐项）

### 5.1 新端点 /v1/ai/vision/extract

- 鉴权/设备 ID/日志：照抄 chat 端点接线（startAiCall/finishAiCall 自动按 device_id+purpose 记账，ai_call_logs 无 per-purpose 注册表，新 purpose 自动被记录，保留 30 天）。
- 校验：base64 解码 + JPEG 魔数（照抄 feedback app.js:1169-1173）+ 单张 ≤1.5MB + 张数=1（一期单图）。
- **图片即弃**：内存 buffer 直传上游，不落盘、不进日志正文（日志本就默认不采集内容，HOLO_LOG_CAPTURE_CONTENT=false）；这是与 feedback 通道的本质区别（feedback 落盘且无清理机制，不能照抄）。
- 超时：上游调用 ≥90s，吸取 agent 超时案教训。
- 审核缺口披露：内容审核（moderation）只吃文本，**图片内容不审核**。一期以 prompt 约束+输出 schema 兜底；是否接图片审核服务列入二期观察项。

### 5.2 purpose 注册六件套（漏一处就 503 或不记账）

| # | 位置 | 动作 |
|---|---|---|
| 1 | config.js routes（55-384） | 加 vision_extraction 条目（provider/model/temperature/maxTokens/限流桶，env 形如 HOLO_VISION_EXTRACTION_*） |
| 2 | app.js quotaTypeForPurpose（1813-1830） | **返回 null（不占会员池）**——照抄 personal_context_extraction/verification 显式先例 |
| 3 | serverPromptPolicy PURPOSE_PROMPT_TYPES（14-43） | 必须加映射，**不加则 injectServerPrompt 直接 503** |
| 4 | defaultPrompts.json + promptRegistry PROMPT_VERSIONS | 加 prompt（进热更体系，可后台改抽取规则）+版本号；输出为结构化 JSON，**不进** x-holo-language 白名单（LANGUAGE_ALLOWED_PURPOSES），防英文指令破坏 JSON 解析 |
| 5 | 隐私元数据口径 | 决定是否进 THOUGHT_CONTENT_PURPOSES / DEFAULT_METADATA_ONLY_PURPOSES（建议进 metadata-only，与「不留正文」口径一致） |
| 6 | 独立限流桶 | 设备级 rate_limits 表按 deviceId:purpose 天粒度原子计数（fail-closed），建议 20/天/设备 |

### 5.3 模型接入（已选定）

- **vision_extraction 用 qwen3-vl-plus**（DashScope 兼容模式；本地评测五轮 23-24/24，资金流转拦截全轮次零失手）。生产 env（ECS deploy/.env.production）需确认 DASHSCOPE_API_KEY 对 qwen3-vl-plus 可用（本地 .env 该 key 已能用）。
- 备选：qwen3-vl-flash 落选（安全项不稳）；glm-4v 未测（无 key）。换模型=改 env，不动代码。
- prompt 热更进 defaultPrompts.json，内容以 scripts/eval-vision-extraction.mjs 中 PROMPT 常量为基准（含外币少样本示例+amountOriginalText 字段），**不得删除少样本示例**（评测实证是精度关键）。
- 单均 ~3240 tokens/张；¥ 成本上线后按拍板点 3 的遗留提醒测算汇报。

### 5.4 发版

- 一次后端发版覆盖：新端点+purpose 六件套+env。部署通道不变（rsync→ECS deploy.sh→docker compose，skill holo-backend-deploy）。
- 无后端 schema 变更（SQLite 无新表；rate_limits/ai_call_logs 复用）。

---

## 6. 财务口径影响面

| # | 事项 | 结论 |
|---|---|---|
| 1 | 与账单导入的边界 | 导入=批量历史文件流（csv/xlsx），截图=即时单笔对话流，互补不重复；「扫描件 OCR 不做」的设计边界由本功能补上（但只做单笔即时，不做批量扫描件导入） |
| 2 | 防重 | 现有三层（指纹/同源单号/软检测）全绑定导入管道；截图一期=确认前软检测提示（§3.3），**不写 importFingerprint**（避免与导入去重互相误伤），落地前需核对 importSource 字段消费方再决定是否标 "screenshot" 来源 |
| 3 | 账户 | 默认账户兜底+确认卡账户行可改（§3.4）；支付通道自动映射二期 |
| 4 | 转账拦截 | 理解单图型枚举含转账/理财，第二段路由直接拦截——这是本功能对统计口径最重要的保护 |
| 5 | 外币 | 一期拒识（模型单币种） |
| 6 | 退款 | 收入+退款分类关键词链天然覆盖 |
| 7 | 统计/对账 | 走普通交易路径，天然进收支统计与余额，无特殊性；isReconciliationAdjustment 等特殊字段一律不碰 |

---

## 7. 评测先行（M0 已完成，2026-09-09）

- **结论：选定 qwen3-vl-plus**（DashScope 兼容模式，temperature=0）。五轮评测详情见 `docs/holoai-audit/vision-eval/README.md` 选型结论表；普惠档 qwen3-vl-flash 落选（两次栽在安全项+跨轮不稳）；glm-4v 未测（本地无智谱 key，不阻塞）。
- 评测资产：24 张合成样张（JPEG）+ 期望清单 manifest.json + 生成器 tools/render_corpus.swift + 评测脚本 scripts/eval-vision-extraction.mjs（key 读 HoloBackend/.env）。
- **评测驱动的三项设计决定**（直接进 M1 后端 prompt/校验）：
  1. 图片理解单契约新增 `amountOriginalText`（逐字抄录金额原文）字段，**下游确定性护栏：原文含外币符号→强制拒识**——模型会伪造 currency 字段（美元抄成 ¥），不能只靠 prompt；
  2. prompt 必须带「外币拒识少样本示例」——规则写十遍不如给一个标准答案（评测实证）；
  3. 退款方向（income）需要显式规则钉死。
- 真实小票回灌：东林真机实拍图在 M2/M3 阶段持续补进语料（合成样张验能力，不验真实鲁棒性）。

---

## 8. 合规与发布

| # | 事项 | 说明 |
|---|---|---|
| 1 | 隐私政策补披露 | **现存缺口：政策正文未披露任何图片上传（连反馈截图都没披露）**。需补「截图识别：上传压缩图→识别→即删，不留存」；in-app LegalDocumentSheet HTML 模板 + nginx 对外三语版同步改 |
| 2 | PrivacyInfo.xcprivacy | 已申报 Photos or Videos（Link+AppFunctionality），**无需改** |
| 3 | 权限 | 相机/相册权限均已具备，仅扩写相机用途文案 |
| 4 | CloudKit | ChatMessage 加字段（若拍板留存图片）→ schema 增量部署前置（可与在途 InductionRule/RecycleBinBatch 两类型自然补推同车） |
| 5 | 版本排期 | 1.0.2 提审中，本功能落 1.0.3；后端可先行发版（对旧版本客户端无感——新端点没人调用） |
| 6 | 分期口径 | AI 分期记账路径带 Plus 门槛，一期截图识别不做分期，无付费墙交互增量 |

---

## 9. 拍板结果（2026-09-09 东林已定，九点全落）

| # | 拍板点 | 结论 |
|---|---|---|
| 1 | 一期范围 | **只开记账入口**（抽取层仍全做：图型分类+字段抽取一次到位，后续开新入口不用重做识别） |
| 2 | 入口形态 | **聊天输入栏增加图片按钮** |
| 3 | 额度口径 | **先不占用额度**（保留设备级防滥用限流桶）；**上线后测算真实成本再定额度策略——遗留提醒已立项（§10 M3+、记忆档案 vision-extraction-cost-review-pending）** |
| 4 | 端点形态 | **新开独立端点** /v1/ai/vision/extract（备选方案 B 弃用） |
| 5 | 聊天图片留存 | **存缩略图**（本地图+路径入 ChatMessage，接受 CloudKit schema 增量部署前置） |
| 6 | 账户口径 | **默认账户兜底 + 自动识别微信/支付宝**（名称关键词匹配既有账户，卡上可改，见 §3.4） |
| 7 | 外币口径 | **暂不支持**，识别到非 ¥ 拒识引导手填 |
| 8 | 多笔口径 | **支持一张图多笔**，逐笔出确认卡 |
| 9 | 防重口径 | **只提示不阻断**；不动导入指纹机制 |

## 10. 里程碑（拍板后）

1. **M0 评测集+模型选型**（先行，产出选型结论与成本实测）
2. **M1 后端**：端点+purpose 六件套+prompt+env → 发版生产
3. **M2 iOS 一期**：入口/加载/压缩/气泡流/确认卡/拒识拦截防重 → 三语文案 → 单测+UI 测试
4. **M3 验收**：模拟器走查（无窗口铁律）→ 东林真机验收 → 隐私政策披露随版生效
5. **上线后（M3+ 遗留动作）：测算 vision_extraction 真实成本**（ai_call_logs 按 purpose 聚合：日均调用/单均 token/成本/峰值设备），向东林汇报并回顾额度策略——拍板点 3 的明确要求
6. 二期候选：清单/白板→任务批量卡；记账页「拍小票」直达；账户匹配纠错回流学习；分享面板截图直达；图片审核
