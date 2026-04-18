//
//  PromptManager.swift
//  Holo
//
//  Prompt 管理器
//  内嵌模板 + 变量替换，不依赖 Bundle 资源文件
//

import Foundation
import os.log

@MainActor
final class PromptManager {

    static let shared = PromptManager()

    private let logger = Logger(subsystem: "com.holo.app", category: "PromptManager")
    private var cache: [PromptType: String] = [:]

    private init() {}

    // MARK: - Prompt Type

    enum PromptType: String, CaseIterable {
        case systemPrompt = "system_prompt"
        case intentRecognition = "intent_recognition"
        case dataExtraction = "data_extraction"
        case clarification = "clarification"
        case insightGeneration = "insight_generation"
        case responseTemplate = "response_template"

        var displayName: String {
            switch self {
            case .systemPrompt: return "系统提示词"
            case .intentRecognition: return "意图识别"
            case .dataExtraction: return "数据提取"
            case .clarification: return "追问澄清"
            case .insightGeneration: return "洞察生成"
            case .responseTemplate: return "回复模板"
            }
        }

        var displayDescription: String {
            switch self {
            case .systemPrompt: return "定义 AI 角色和基本行为规则"
            case .intentRecognition: return "识别用户输入的意图类型"
            case .dataExtraction: return "从用户输入中提取结构化数据"
            case .clarification: return "意图不明确时的追问策略"
            case .insightGeneration: return "数据分析与洞察总结"
            case .responseTemplate: return "操作确认回复的格式规范"
            }
        }

        var icon: String {
            switch self {
            case .systemPrompt: return "brain.head.profile"
            case .intentRecognition: return "target"
            case .dataExtraction: return "doc.text.magnifyingglass"
            case .clarification: return "questionmark.bubble"
            case .insightGeneration: return "chart.xyaxis.line"
            case .responseTemplate: return "text.bubble"
            }
        }
    }

    // MARK: - Load Prompt

    /// 需要版本管理的 prompt 类型及其最低版本
    private static let promptVersions: [PromptType: Int] = [
        .intentRecognition: 2  // v2: batch 输出 + 时间格式
    ]

    /// 加载指定类型的 Prompt，带缓存，优先读取 UserDefaults 自定义
    func loadPrompt(_ type: PromptType) throws -> String {
        if let cached = cache[type] {
            return cached
        }

        let key = Self.userDefaultsKey(for: type)
        let versionKey = "com.holo.prompt.version.\(type.rawValue)"

        // 版本检查：自定义 prompt 版本过低时自动回退默认值
        if let minVersion = Self.promptVersions[type],
           UserDefaults.standard.string(forKey: key) != nil {
            let savedVersion = UserDefaults.standard.integer(forKey: versionKey)
            if savedVersion < minVersion {
                logger.info("Prompt \(type.rawValue) 版本过低 (\(savedVersion) < \(minVersion))，自动回退默认值")
                resetCustomPrompt(type)
                UserDefaults.standard.set(minVersion, forKey: versionKey)
            }
        }

        let raw = UserDefaults.standard.string(forKey: key) ?? templates[type]

        guard let raw = raw else {
            logger.error("Prompt 模板未找到: \(type.rawValue)")
            throw PromptError.fileNotFound(type.rawValue)
        }

        let template = replaceVariables(in: raw)
        cache[type] = template
        return template
    }

    /// 加载原始模板文本（不含变量替换，编辑器显示用）
    func loadRawTemplate(_ type: PromptType) -> String {
        let key = Self.userDefaultsKey(for: type)
        return UserDefaults.standard.string(forKey: key) ?? templates[type] ?? ""
    }

    /// 加载硬编码默认模板（恢复默认用）
    func loadDefaultTemplate(_ type: PromptType) -> String {
        templates[type] ?? ""
    }

    /// 保存自定义 Prompt 到 UserDefaults
    func saveCustomPrompt(_ type: PromptType, content: String) {
        let key = Self.userDefaultsKey(for: type)
        UserDefaults.standard.set(content, forKey: key)
        // 同步更新版本号为当前版本
        if let version = Self.promptVersions[type] {
            let versionKey = "com.holo.prompt.version.\(type.rawValue)"
            UserDefaults.standard.set(version, forKey: versionKey)
        }
        cache.removeValue(forKey: type)
        logger.info("自定义 Prompt 已保存: \(type.rawValue)")
    }

    /// 重置 Prompt 为硬编码默认值
    func resetCustomPrompt(_ type: PromptType) {
        let key = Self.userDefaultsKey(for: type)
        UserDefaults.standard.removeObject(forKey: key)
        // 同步更新版本号
        if let version = Self.promptVersions[type] {
            let versionKey = "com.holo.prompt.version.\(type.rawValue)"
            UserDefaults.standard.set(version, forKey: versionKey)
        }
        cache.removeValue(forKey: type)
        logger.info("Prompt 已重置为默认: \(type.rawValue)")
    }

    /// 检查是否有自定义覆盖
    func isCustomized(_ type: PromptType) -> Bool {
        let key = Self.userDefaultsKey(for: type)
        return UserDefaults.standard.string(forKey: key) != nil
    }

    /// 获取当前变量解析值（变量预览用）
    static func currentVariableValues() -> [String: String] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"

        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"

        return [
            "{{todayDate}}": dateFormatter.string(from: Date()),
            "{{currentYear}}": yearFormatter.string(from: Date())
        ]
    }

    /// 清除缓存
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Inline Templates

    private let templates: [PromptType: String] = [
        .systemPrompt: """
        你是 Holo AI 助手，专注于帮用户管理个人数据。用户每次对话都应包含明确指令。

        你的核心能力：
        1. 记账（收入/支出）
        2. 创建/完成/更新/删除任务
        3. 习惯打卡
        4. 记笔记
        5. 查询任务/习惯状态
        6. 数据分析

        今天是 {{todayDate}}。

        规则：
        - 用中文回复
        - 简洁友好，不要过于冗长
        - 当用户输入不含明确指令时，简短提示可用的操作类型
        - 金额相关的数字要精确，不要随意更改
        - 使用 Markdown 格式让回复更易读
        - **禁止假装执行操作**：你无法直接记账、创建任务、打卡或记录心情。如果用户想要执行这些操作，请回复"我暂时无法执行此操作，请重试或使用快捷入口"。绝对不要回复"已记录""已创建""已打卡"等暗示操作已完成的表述
        """,

        .intentRecognition: """
        你是 Holo AI 助手的意图识别模块。分析用户输入，判断意图并提取结构化数据。
        支持从一句话中识别多个动作，也支持单动作。
        只识别操作指令，不进行闲聊。

        当前日期：{{todayDate}}

        ## 可选意图（按类别分组）

        ### 记账类
        - record_expense: 记录支出（花了钱、买了东西、吃饭等）
        - record_income: 记录收入（收到钱、工资等）

        ### 任务类
        - create_task: 创建待办任务（要做什么、提醒我）
        - complete_task: 完成任务（完成了、做完了、搞定了）
        - update_task: 更新任务（改成、修改、调整）
        - delete_task: 删除任务（删除任务、不要了、取消）

        ### 习惯类
        - check_in: 习惯打卡（打卡、签到）

        ### 笔记类
        - create_note: 记笔记（记一下、笔记、备忘）

        ### 健康类
        - record_mood: 记录心情/想法
        - record_weight: 记录体重

        ### 查询类
        - query_tasks: 查询任务列表（有什么任务、待办、今天要做什么）
        - query_habits: 查询习惯状态（习惯完成了吗、打卡了吗）
        - query: 分析型查询（分析开销、本月花了多少、统计）

        ### 兜底
        - unknown: 无法识别为以上任何意图

        ## 科目体系

        当意图为 record_expense 或 record_income 时，必须根据用户描述匹配到具体的一级科目和二级科目。

        ### 支出科目（record_expense）

        | 一级科目 | 二级科目 |
        |---------|---------|
        | 餐饮 | 早餐、午餐、晚餐、夜宵、零食、咖啡、外卖、饮品、水果、酒水、超市 |
        | 交通 | 地铁、打车、公交、单车、加油、停车、火车、机票、旅行、过路费 |
        | 购物 | 服饰、数码、日用、美妆、家具、书籍、运动、礼物 |
        | 娱乐 | 电影、游戏、视频、音乐、KTV、旅游、健身 |
        | 居住 | 房租、房贷、水费、电费、燃气、物业、网费、家电、装修 |
        | 医疗 | 就医、药品、体检、健身房、保健品、牙齿保健、医疗用品 |
        | 学习 | 课程、教材、考试、文具、订阅 |
        | 人情 | 红包礼金、请客、送礼、探望、其他 |
        | 其他 | 社交、宠物、理发、洗衣、话费、烟酒、维修、保险、还款、转账、捐赠 |

        ### 收入科目（record_income）

        | 一级科目 | 二级科目 |
        |---------|---------|
        | 投资理财 | 利息、股票、房租收入、其他投资 |
        | 工资收入 | 工资、奖金、兼职、报销、退款 |
        | 人情来往 | 红包、礼物、中奖、转入 |
        | 其他收入 | 借入、还款收入、退货、公积金、出闲置 |

        ## JSON 输出格式

        始终输出 batch 格式，即使只有一个动作也放在 items 数组中。

        ```json
        {
          "mode": "single_action 或 multi_action 或 query 或 clarification 或 unknown",
          "items": [
            {
              "id": "1",
              "intent": "意图名称",
              "confidence": 0.95,
              "extractedData": {
                "amount": "金额（纯数字）",
                "note": "简洁备注（如：午饭、打车去公司）",
                "primaryCategory": "一级科目名称（记账时必填）",
                "subCategory": "二级科目名称（记账时必填）",
                "title": "任务标题（create_task 时使用）",
                "taskKeyword": "任务关键词（complete_task/update_task/delete_task 时必填，用于匹配已有任务）",
                "priority": "优先级 0-3（0=低 1=中 2=高 3=紧急，create_task 可选）",
                "dueDate": "截止日期（yyyy-MM-dd，create_task 可选）",
                "tags": "标签（逗号分隔，create_task/create_note 可选）",
                "description": "任务描述（create_task 可选）",
                "noteContent": "笔记正文（create_note 必填）",
                "habitName": "习惯名称（check_in 时使用）",
                "habitValue": "习惯数值（Double 类型，如"跑了 5 公里"→ habitValue: "5.0"，配合 habitName 使用）",
                "mood": "心情标签",
                "weight": "体重数值",
                "date": "日期（yyyy-MM-dd）"
              },
              "responseText": "该动作的确认消息"
            }
          ],
          "needsClarification": false,
          "clarificationQuestion": null,
          "fallbackResponseText": null
        }
        ```

        ## mode 判断规则

        - 只有一个执行动作 → mode: "single_action"
        - 有两个或以上执行动作 → mode: "multi_action"
        - 只有查询意图（query/query_tasks/query_habits） → mode: "query"
        - 同时包含查询和执行动作 → needsClarification: true, mode: "clarification"
        - 无法识别 → mode: "unknown"

        ## 多动作拆分规则

        - 用户一句话中用逗号/分号分隔的多个动作，应拆分为多个 items
        - 每个 item 必须有独立的 id、intent、confidence、extractedData
        - 无法可靠拆分时，宁可返回 clarification，不要猜测执行
        - 如果某个片段无法识别，该项 intent 设为 unknown

        ## 日期解析规则

        - 今天/今日/今天 → 当天日期
        - 明天/明日 → 当天+1
        - 后天 → 当天+2
        - 下周一/下周二... → 计算对应日期
        - 本月X日 → 当月X号
        - 日期格式：yyyy-MM-dd（如 2026-04-20）
        - 如果用户指定了具体时间（如"早上9点""下午3点""晚上8点半"），dueDate 格式为 yyyy-MM-dd HH:mm（如 2026-04-20 09:00）
        - 没有指定时间时，dueDate 只输出日期部分 yyyy-MM-dd
        - 时间表达映射：凌晨=00-05, 早上/上午=06-11, 中午=12, 下午=13-17, 晚上/傍晚=18-22, 半夜/深夜=23

        ## 意图判断规则

        - 明确包含花钱/买东西 → record_expense
        - 明确包含收钱/工资 → record_income
        - "创建任务"/"提醒我"/"待办" → create_task
        - "完成了"/"做完了"/"搞定了" → complete_task
        - "改成"/"修改任务" → update_task
        - "删除任务"/"不要了" → delete_task
        - "打卡"/"签到" → check_in
        - "记一下"/"笔记"/"备忘" → create_note
        - "有什么任务"/"待办列表" → query_tasks
        - "习惯状态"/"打卡了吗" → query_habits
        - "分析"/"统计"/"本月花了多少" → query
        - 不匹配任何以上意图 → unknown

        ## 科目匹配规则

        - 根据用户描述的**整体消费场景**归类，不要拆解物品名称中的单个字词
        - 示例：「一杯咖啡 50 元」→ primaryCategory: "餐饮", subCategory: "咖啡"
        - 示例：「打车去公司 30」→ primaryCategory: "交通", subCategory: "打车"
        - 示例：「买了件衣服 399」→ primaryCategory: "购物", subCategory: "服饰"
        - 示例：「买了一个椅子的扶手 40」→ primaryCategory: "居住", subCategory: "家具"
        - 示例：「买了把椅子 200」→ primaryCategory: "居住", subCategory: "家具"
        - 示例：「发了工资」→ primaryCategory: "工资收入", subCategory: "工资"
        - 家居用品（家具、家电、装修材料、家居配件）统一归入 居住 > 家具
        - 如果无法确定具体二级科目，选择该一级科目下最接近的；如果连一级科目都无法确定，primaryCategory 和 subCategory 都不填

        只回复 JSON，不要添加其他内容。
        """,

        .dataExtraction: """
        从用户输入中提取结构化数据。

        当前日期：{{todayDate}}

        请提取以下信息（如适用）：
        - amount: 金额（数字，不含货币符号）
        - note: 备注说明
        - type: expense 或 income
        - title: 任务/事件标题
        - date: 日期（yyyy-MM-dd 格式）
        - mood: 心情标签
        - weight: 体重数值
        - habitName: 习惯名称

        请以 JSON 格式回复：
        ```json
        {
          "amount": "35",
          "note": "午饭",
          "type": "expense"
        }
        ```

        只回复 JSON。如果某个字段无法提取，则不包含该字段。
        """,

        .clarification: """
        用户意图不明确，需要追问以获取更多信息。

        请根据以下情况简短追问：
        - 记账：缺少金额或分类信息
        - 创建任务：缺少任务标题
        - 习惯打卡：缺少习惯名称

        追问规则：
        - 只问一个关键问题
        - 提供选项示例
        - 保持友好和简洁

        示例：
        - 「记了一笔消费，金额是多少呢？」
        - 「要创建什么任务？比如：买牛奶、开会、写报告」
        - 「要给哪个习惯打卡？」
        """,

        .insightGeneration: """
        你是数据分析助手。基于用户的个人数据生成洞察和总结。

        当前日期：{{todayDate}}

        规则：
        - 用中文回复
        - 使用 Markdown 格式
        - 数据要准确，不要编造数字
        - 给出实用的建议
        - 语气积极正面
        - 控制在 200 字以内
        """,

        .responseTemplate: """
        根据操作结果生成友好的确认回复。

        规则：
        - 用中文回复
        - 简洁明了，一句话确认操作
        - 如果操作成功，给予积极反馈
        - 如果操作失败，说明原因并建议下一步
        - 支持使用表情符号增加亲和力

        示例回复：
        - 记账成功：「已记录支出 ¥35（午饭）」
        - 创建任务：「已创建任务：买牛奶」
        - 打卡成功：「今日打卡完成」
        - 记录心情：「已记录你的心情」
        """
    ]

    // MARK: - Private

    private static func userDefaultsKey(for type: PromptType) -> String {
        "com.holo.prompt.custom.\(type.rawValue)"
    }

    private func replaceVariables(in template: String) -> String {
        var result = template

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"
        result = result.replacingOccurrences(of: "{{todayDate}}", with: dateFormatter.string(from: Date()))

        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        result = result.replacingOccurrences(of: "{{currentYear}}", with: yearFormatter.string(from: Date()))

        return result
    }
}

// MARK: - Prompt Error

enum PromptError: LocalizedError {
    case fileNotFound(String)
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Prompt 文件未找到：\(name).json"
        case .invalidFormat(let name):
            return "Prompt 文件格式错误：\(name)"
        }
    }
}
