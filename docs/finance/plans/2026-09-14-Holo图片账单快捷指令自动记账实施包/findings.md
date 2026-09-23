# Findings: Holo 图片账单快捷指令自动记账

## Requirements

- 交付 GLM 可以直接执行的完整实施方案。
- 允许用户选择不同账户和财务项目，但默认操作必须保持极简。
- 充分利用 iOS 操作按钮、快捷指令、分享页、轻点背面和系统结果回执。
- 自动入账必须有财务安全门禁、幂等、防重、复核和撤销。

## Research Findings

- Holo 已有视觉抽取服务、生产视觉端点、聊天图片入口、分类学习、账户匹配和确认卡，不应重建识图链。
- 当前分类核心藏在 IntentRouter 私有方法中；快捷指令需要公共草案解析器。
- 当前截图识别先按默认账户创建交易，再二次搬到匹配账户；自动后台路径应改为一次原子写入。
- 当前视觉入口只检查 AI 数据处理授权，没有图片记账专属付费墙；后端使用独立设备限流（当前默认 5/分钟、20/天）。首版应保持现有权益口径，不在后台路径临时弹付费墙。
- Transaction 已有 aiSourceMessageId 和 aiSourceItemId，可作为首版幂等来源键，避免新增 CloudKit 字段。
- Holo 数据库已进入 App Group；现有小组件 App Intent 证明扩展进程可访问共享库，但本功能首版应只在主 App target 执行，减少跨进程写入竞争。
- App 主目录是 Xcode 文件系统同步组，新建主 App Swift 文件通常自动入 target；HoloTests 与 Widget 仍需显式核对 target membership。
- 待复核必须跨进程退出后可恢复，但不值得新增 CloudKit schema：使用 App Group 内的本地 JSON + 受保护 JPEG，处理完成或 7 天后清理。
- 苹果操作按钮可运行快捷指令；App Intent 可用 IntentFile 接收图片并配置前后台模式。
- Locked Camera Capture Extension 在锁屏环境不能联网，因此相机控制不能直接完成云端识别和记账。

## Technical Decisions

| Decision | Rationale |
|---|---|
| 外层快捷指令只做截屏/拍照和传图 | 识别、分类、账户、项目和安全规则保持在 Holo 单一事实源 |
| 高置信自动写入，风险场景转复核 | 同时保留一步完成和财务可信度 |
| 账户与项目采用“默认自动 + 可选固定 + 需要时询问” | 用户可定制，但不会把每次运行变成表单 |
| App Intent 不调用 ChatViewModel | 后台运行与聊天 UI 生命周期解耦 |
| 写入来源字段与交易在同一次 save 完成 | 消除写入成功但来源标记丢失导致的重试重复 |
| 通用快捷指令默认“账户自动识别、项目不挂靠” | 账户通常可从支付渠道或卡尾号判断；项目若靠猜测误挂，后续报表污染更难发现 |
| 固定账户/项目保存在每条快捷指令的参数中 | 用户可分别建立“日常消费”“工作报销”“东京旅行”，配置一次后每次仍是一键 |
| “每次询问”复用快捷指令系统原生变量 | 不在 Holo 再造一层账户/项目模式选择器，降低配置复杂度 |
| 快捷记账不继承手工页的上次账户/上次项目 | 后台运行时隐含状态不可见，会造成连续静默错账 |
| 项目自动匹配仅接受显式文字命中唯一进行中项目 | 不根据商户或分类推测项目；未命中就不挂，误挂比漏挂成本更高 |
| 用户固定选择的账户被归档或项目已结束时转复核 | 不得静默换成其他账户或项目，避免违背用户显式配置 |
| 项目参数只对支出自动生效 | 当前 Holo 项目产品语义与手工 UI 都是支出归组；固定项目遇到退款/收入时转复核，不静默忽略 |
| 附言不能覆盖金额、币种、支付状态和收支方向 | 这些必须来自图片证据；附言只可补日期、备注和显式项目名，冲突时转复核 |
| 自动成功不保存原图，待复核才本地暂存压缩证据 | 同时满足隐私最小化和复核可解释性 |

## Issues Encountered

| Issue | Resolution |
|---|---|
| 当前总方案的账户/项目可配置不足 | 本轮补 AppEntity、默认策略、参数摘要和设置页规则 |
| 仓库存在大量并行脏改 | 只修改本轮方案与实施包，不触碰代码或现有脏文件 |

## Resources

- `docs/finance/plans/2026-09-14-Holo图片账单快捷指令自动记账完整方案.md`
- `docs/plans/2026-09-09-screenshot-receipt-billing-plan.md`
- `docs/plans/2026-09-09-vision-acceptance-guide.md`
- `Holo/Holo APP/Holo/Holo/Services/AI/Vision/HoloVisionExtractionService.swift`
- `Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift`
- `Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift`
- `Holo/Holo APP/Holo/HoloWidgets/HoloWidgetIntents.swift`

## Visual/Browser Findings

- 同类产品普遍采用“系统快捷指令截屏 → App 识别并写账”，而不是把业务规则塞进用户的快捷指令。
- 市面高频问题集中在重复写账、账户余额重复变化、后台失败、通知权限耦合和识别错误，而不是有没有 OCR。
