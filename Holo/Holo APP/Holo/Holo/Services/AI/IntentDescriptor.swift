//
//  IntentDescriptor.swift
//  Holo
//
//  意图注册表：与后端 src/prompts/intents.json 同构的单一事实源。
//  ⚠️ 本文件由 HoloBackend/scripts/generate-intent-descriptors.mjs 程序化生成，不要手改——
//     改后端 intents.json 后重跑生成器；对拍护栏见 HoloBackend/tests/intent-registry-consistency.test.js。
//
//  消费方：
//  - PromptManager.intentRecognition（DEBUG 兜底 prompt：意图字段段+例段+后端骨架镜像）
//  - AIParseBatchValidator（requiredFields 必填字段断言，覆盖全部注册意图）
//

import Foundation

nonisolated struct IntentDescriptor {
    /// 同一行合写的意图 rawValue（如 complete_task / delete_task），与后端 intents.json 的 ids 同构
    let ids: [String]
    /// 一句话定义（进提示词，与后端 summary 逐字节一致）
    let summary: String
    /// 必填 extractedData 字段（供 AIParseBatchValidator；空=无硬性必填）
    let requiredFields: [String]
    /// few-shot 例句（进提示词，与后端 examples 逐字节一致）
    let examples: [String]

    init(ids: [String], summary: String, requiredFields: [String] = [], examples: [String] = []) {
        self.ids = ids
        self.summary = summary
        self.requiredFields = requiredFields
        self.examples = examples
    }
}

nonisolated enum IntentDescriptorRegistry {

    static let descriptors: [IntentDescriptor] = [
        IntentDescriptor(ids: ["record_expense"], summary: "记支出。填 amount、note、categoryCandidate；明确或相对日期填 transactionDate（YYYY-MM-DD），可选 normalizedCategoryCandidate/semanticCategoryHint。工资+金额走 record_income。", requiredFields: ["amount"], examples: ["\"昨天麦当劳35\" → intent: \"record_expense\", extractedData: { amount: \"35\", note: \"麦当劳\", categoryCandidate: \"麦当劳\", transactionDate: \"2026-06-02\", normalizedCategoryCandidate: \"快餐\", semanticCategoryHint: \"餐饮\" }", "\"给爷爷买了两百块的彩票\" → intent: \"record_expense\", extractedData: { amount: \"200\", note: \"给爷爷买彩票\", categoryCandidate: \"给爷爷买彩票\", semanticCategoryHint: \"人情\" }"]),
        IntentDescriptor(ids: ["record_income"], summary: "记收入。填 amount、note、categoryCandidate；明确或相对日期填 transactionDate（YYYY-MM-DD）。", requiredFields: ["amount"], examples: []),
        IntentDescriptor(ids: ["create_task"], summary: "建待办/提醒。填 title；确定日期填 dueDate（YYYY-MM-DD 或 YYYY-MM-DD HH:mm）；用户说了具体钟点（如晚上10点）必须填 reminderDate 和 dueDate 的 HH:mm，时段换 24 小时制。并列待办填 subtasks，title 概括，description 补充。", requiredFields: ["title"], examples: ["\"明天去山姆买牛奶、鸡蛋和纸巾\" → intent: \"create_task\", extractedData: { title: \"去山姆购物\", subtasks: \"买牛奶,买鸡蛋,买纸巾\" }", "\"提醒我今天晚上10点给猫换水\" → intent: \"create_task\", extractedData: { title: \"给猫换水\", dueDate: \"今天 22:00\", reminderDate: \"今天 22:00\" }"]),
        IntentDescriptor(ids: ["complete_task","delete_task"], summary: "操作已有任务，只填 taskKeyword。", requiredFields: ["taskKeyword"], examples: []),
        IntentDescriptor(ids: ["update_task"], summary: "改已有任务，必填 taskKeyword；改什么填什么——改时间填 dueDate（同 create_task），改标题填 title，改优先级填 priority；未提及字段不填。", requiredFields: ["taskKeyword"], examples: []),
        IntentDescriptor(ids: ["modify_task_items"], summary: "对最近对话提到的任务增删条目（还要买/不买了/换成）。addItems 填新增、removeItems 填删除（逗号分隔；removeItems 须用现有条目确切名称）；替换=删旧+加新。", examples: ["\"（最近任务：去山姆购物）还要买可乐\" → intent: \"modify_task_items\", extractedData: { addItems: \"买可乐\" }", "\"（最近任务：去山姆购物）牛奶不买了，换成酸奶\" → intent: \"modify_task_items\", extractedData: { removeItems: \"买牛奶\", addItems: \"买酸奶\" }"]),
        IntentDescriptor(ids: ["check_in"], summary: "习惯打卡，填 habitName / habitValue。", requiredFields: ["habitName"], examples: []),
        IntentDescriptor(ids: ["update_goal_field"], summary: "改目标字段（标题/截止日期/说明等）。填 goalTitle、field（title/deadline/summary/desiredOutcome/motivation）、value。", requiredFields: ["goalTitle","field","value"], examples: ["\"把英语目标截止日期改成年底\" → intent: \"update_goal_field\", extractedData: { goalTitle: \"英语\", field: \"deadline\", value: \"年底\" }"]),
        IntentDescriptor(ids: ["link_task_to_goal"], summary: "任务关联到目标。填 taskTitle、goalTitle。", requiredFields: ["taskTitle","goalTitle"], examples: []),
        IntentDescriptor(ids: ["toggle_goal_visibility"], summary: "切换目标AI可见性。填 goalTitle、enable（true/false）。", requiredFields: ["goalTitle","enable"], examples: []),
        IntentDescriptor(ids: ["create_note","record_mood","record_weight"], summary: "记录笔记、心情、体重。", requiredFields: ["noteContent","weight"], examples: []),
        IntentDescriptor(ids: ["query_tasks","query_habits"], summary: "查询任务或习惯状态。", examples: []),
        IntentDescriptor(ids: ["flexible_data_query"], summary: "查一个确定的单值——总金额、次数、最近一笔、距今多久、最大/最小一笔、超过N元、关键词花了多少，以及同一批记录的平均每笔/每次/每顿。需要跨时间折算或统计规律的（频率趋势、日均、单位时间花销）不属于本意图。", examples: []),
        IntentDescriptor(ids: ["query_analysis"], summary: "分析、复盘、趋势、结构、占比、总结，以及需要折算/统计规律的——频率、平均每天/每周花多少、日均、单位时间花销。", examples: ["\"帮我分析最近花销\" → intent: \"query_analysis\", extractedData: { analysisDomain: \"finance\", periodLabel: \"最近\" }", "\"最近状态不好，看看睡眠咋样\" → intent: \"query_analysis\", extractedData: { analysisDomain: \"health\", subDomain: \"sleep\", periodLabel: \"最近\" }"]),
        IntentDescriptor(ids: ["weekly_planning"], summary: "每周生活计划：帮我规划这一周、做个本周计划、下周该专注什么。建立单个目标不是本意图。", examples: ["\"帮我规划这一周\" → intent: \"weekly_planning\", extractedData: {}", "\"下周我该专注什么\" → intent: \"weekly_planning\", extractedData: {}"]),
        IntentDescriptor(ids: ["query"], summary: "普通问答或闲聊。", examples: []),
        IntentDescriptor(ids: ["generate_memory_insight"], summary: "记忆回放。", examples: []),
        IntentDescriptor(ids: ["unknown"], summary: "无法判断。", examples: ["\"嗯...\" → intent: \"unknown\", mode: \"unknown\""])
    ]

    /// 渲染「意图字段：」段——与后端 promptRegistry.buildIntentSection() 逐字节一致
    static var intentSectionText: String {
        "意图字段：\n" + descriptors
            .map { "- " + $0.ids.joined(separator: " / ") + "：" + $0.summary }
            .joined(separator: "\n")
    }

    /// 渲染「例：」段——与后端 promptRegistry.buildIntentExamples() 逐字节一致
    static var intentExamplesText: String {
        "例：\n" + descriptors
            .flatMap(\.examples)
            .map { "- " + $0 }
            .joined(separator: "\n")
    }

    static func descriptor(forRawValue rawValue: String) -> IntentDescriptor? {
        descriptors.first { $0.ids.contains(rawValue) }
    }

    static func descriptor(for intent: AIIntent) -> IntentDescriptor? {
        descriptor(forRawValue: intent.rawValue)
    }

    /// 意图必填字段（AIParseBatchValidator 消费；未注册意图返回空）
    static func requiredFields(for intent: AIIntent) -> [String] {
        descriptor(for: intent)?.requiredFields ?? []
    }

    /// 后端 intent_recognition 骨架镜像（含 {{todayDate}}/{{currentTime}} 运行时变量），
    /// 意图段/例段由注册表插值——DEBUG 兜底 prompt 与后端 serve 产物逐字节一致
    static let backendSkeleton: String = "你是短意图 Router。只判断用户要做什么，只输出 JSON。不要解释/闲聊。\n日期：{{todayDate}}\n时：{{currentTime}}\n\n输出 JSON：\n{\n  \"mode\": \"single_action | multi_action | query | clarification | unknown\",\n  \"items\": [{ \"id\": \"1\", \"intent\": \"...\", \"confidence\": 0.0-1.0, \"extractedData\": {} }],\n  \"needsClarification\": false,\n  \"clarificationQuestion\": null\n}\n\n\\(IntentDescriptorRegistry.intentSectionText)\n\n分流：\n- 确定数字类：\"今年收入是多少\"\"本月花了多少钱\"\"今年买烟花花了多少\"\"咖啡一共花了多少\"→ flexible_data_query。\n- 分析总结类：\"分析今年收入结构\"\"复盘本月消费\"\"最近财务状态怎么样\"→ query_analysis。\n- 频率/折算类：\"买烟的频率怎么样\"\"平均一天抽烟花多少钱\"\"每天花多少\"\"多久买一次\"→ query_analysis（需要次数÷时间或总额÷天数，超出单值查询）。\n- 健康状态/睡眠/步数/活动趋势类：\"最近状态不好，看看睡眠咋样\"\"最近睡眠怎么样\"\"这周步数趋势\"→ query_analysis，extractedData 填 analysisDomain: \"health\"，睡眠问题加 subDomain: \"sleep\"。\n- 具体数据查询不要用 query。\n\n规则：\n- 单动作→single_action，多动作→multi_action，纯查询→query，查询+执行混合→clarification，无法识别→unknown。\n- note 是用户可见名称，保留具体对象/关系/场景，不要只写分类；如\"给爷爷买了两百块的彩票\"→note:\"给爷爷买彩票\"。\n- categoryCandidate 始终填用户原始消费语义。normalizedCategoryCandidate 用常识归一品牌/口语，不确定留空。semanticCategoryHint 填一级分类（餐饮、交通、购物、娱乐、居住、医疗、学习、人情、其他）。品牌消费必填，如\"麦当劳\"→\"餐饮\"。\n- title 去掉\"提醒我\"\"帮我\"等套话。日期：今天=当天，昨天=交易日-1，明天=+1；记账日期写入 transactionDate，任务日期写入 dueDate/reminderDate。时间映射：凌晨=00-05，早上/上午=09:00，中午=12:00，下午=15:00，晚上/傍晚=20:00。具体钟点按时段换 24 小时制：晚上N点=N+12（晚上10点=22:00），下午N点=N+12（下午3点=15:00），今晚N点=当天N点，半点=N:30。\n- 明确说\"提醒我明天早上/下午/今晚N点\"时，同时填 reminderDate 和 dueDate（含 HH:mm）。\n- 购物清单：并列物品填 subtasks（逗号分隔），title 概括。只有 1 个事项时不填 subtasks。\n- 多笔记账每项的 note/categoryCandidate 对应各自内容。\n- 查询+执行混合时返回 clarification。不确定就 clarification，不要编造字段。\n- 分期/重复任务由专用 parser 处理，不要输出 installment* / repeat* 字段。\n- 无法判断时输出 intent: \"unknown\", mode: \"unknown\"。\n\n\\(IntentDescriptorRegistry.intentExamplesText)\n\n只回 JSON。"

    /// V23 聚合查询契约（后端 serve 时作为 appendix 追加，兜底 prompt 同步携带）
    static let aggregateContractV23: String = "\n\n[HOLO_QUERY_AGGREGATE_V23]\n“最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱”及同批次数/总额/平均每笔/每次/每顿→flexible_data_query；“吨”按顿。必须输出 single_action，items 仅 1 项，保留 categoryCandidate/periodLabel；不要拆成 multi_action。"

    /// V24 个人状态路由契约（同上）
    static let personalStateContractV24: String = "\n\n[HOLO_PERSONAL_STATE_ROUTING_V24]\n- 个人近期整体状态问法，如‘我最近状态怎么样/如何’‘最近我咋样’‘帮我看看我近期整体情况’‘我最近过得好不好’，必须输出 mode=query、intent=query_analysis、needsClarification=false；不得追问领域，也不得降级为普通 query。extractedData 填 analysisDomain=\"cross_domain\"、analysisScope=\"holistic\"、periodLabel=\"最近\"。\n- 明确单领域的近期状态/趋势问法仍为 query_analysis，analysisDomain 填 finance/health/habit/task/goal/thought；同时涉及两个及以上领域时填 cross_domain。睡眠问法加 subDomain=\"sleep\"。\n- ‘你最近怎么样’‘今天天气怎么样’‘Holo 服务状态怎么样’属于普通 query；查询与执行混合仍走 clarification。"

    /// DEBUG 兜底意图 prompt 全文 = 后端骨架渲染 + V23 + V24
    static var intentRecognitionTemplate: String {
        backendSkeleton + aggregateContractV23 + personalStateContractV24
    }
}
