# 工作记录

2026-10-18：开始只读核对与实施方案编写。

已核对报告档案、周期洞察、记忆模型/证据、生命周期和检索入口。开始撰写完整方案。
路径探索时有数个假定文件不存在，已用文件清单定位实际文件；未据此推断功能缺失。

方案交付完成：README 主方案、验收与测试用例、源码核对记录和工作计划。定义 V1 核心 30 场景、后续扩展 12 场景及成对效果评估。Markdown 本地链接、代码围栏、尾部空白检查无错误；git diff --check 通过。新增 local-only 忽略规则。未修改业务实现或后端，未运行业务测试、真实模型、App 构建、真机/双设备或部署。

2026-10-18 主会话评审修订：对 findings 关键声明逐条抽查（8 证实 / 1 修正 / 1 新发现），按评审结论修订三份文档，改动点以 🔧 标注——README 修订1–9（预算缺口升格 P0 修复项、新增 §6.6 日常萃取同命题合并、S2 T03 承接 ADR-08、重复调用放量门槛、P2 拆分 P2a/P2b、场景数 32、三项待拍板），验收文档修订A–C（R31/R32、HoloTests 事实修正、重复占比统计），findings 增补评审核对节。仍未改业务代码。

2026-10-19：完成 GLM 九项澄清及 A–C 配套修订复审。接受同命题合并、名称勘误、32 场景及 P2 拆分；实质修正预算 purpose/worker 主体/回落路径、增量价值判据、共享接口依赖、工程与效果交付边界和测试桥接。新增 03 复审记录与 B01–B06 预算验收专项；财务 05/06 仅同步 T03 共享接口说明。未修改业务代码或部署。

本轮检查：8 份相关 Markdown 本地链接与代码围栏有效、方案目录无尾部空白；R=32、X=12、B=6 无重复；git diff --check 通过。未执行业务测试。财务 05 仅新增 T03 说明两行；06 仅调整背景投影任务行，保留其他在途内容。

2026-10-20 P0–P2a 实施（东林批准开工「做完再同步验收」）：

- P0：基线与冻结契约落档 04-P0基线与冻结契约.md（五条轨道归一/字段冻结/预算修复规格/增量五分类口径/测试通道）。
- P1：新链路全量落地 `Services/AI/ReportUnderstanding/`（Contract/Ledger/SourceAdapter/FindingExtractor/EvidenceResolver/Coordinator 六文件）——确定性提取（数字三对核验/防循环/主体守卫/suggestion 拒入）、本地 JSON 台账幂等+指数退避+重扫、删除对账撤销、锚点与日常萃取同词表（financeCategory 等实体锚）。
- 接线：HoloApp 启动注册；agentReportDidFinalize 通知自 ChatMessageRepository.finalizeAgentMessage 统一发出；云端深度分析随消息持久化结构化信封（HoloRenderedAgentResult.reportUnderstanding 新可选字段，旧消息解码 nil）；旧回放观察器写入权防御（该观察器经查全工程无启动点、为死代码，防御仍加）。
- P2a：HoloUnderstandingContextBuilder（PersonalSituationBrief ≤8 条事实型，ADR-08 S2 T03 唯一实现）+ 快照新可选字段 personalSituationBrief；聊天/回放消费经既有统一查询服务天然生效。
- 后端预算端到端修复（代码+测试，**未部署**）：BACKGROUND_PURPOSES 增 replayDigest（直调真实 purpose）；守卫新增 reserveDirect/settleDirect（云端 worker purpose 无关显式预留通道）；cloudAnalysisExecutor replay_digest 从任务归属建主体+逐次预留+失败原因携带错误码；app.js 注入 backgroundBudget；iOS 摘要云端预算拒绝(429/426)不回落直调（B03）。
- 测试：后端 replay-digest-budget.test.js B01–B06 全绿（相关三套件 76/76）；iOS ReportUnderstandingTests 37 断言全绿（R01/02/03/05/06/07/08/09/10/11/12/13/15/16/17/19/20/25/28/30/31/32；R18/R21-24/R26/R27/R29 由既有仓库测试与开关门控覆盖），pbxproj 四锚点挂载+桥接重生成。
- 开关全默认关：reportUnderstandingExtraction / Answering / Shadow（UserDefaults 键，受用户记忆总开关最高约束）。
- 后端 chat.test.js 一处失败为并行会话在途 v33 提示词改动（intent_recognition 32→33），与本链路无关。
