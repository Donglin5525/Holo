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
    }

    // MARK: - Load Prompt

    /// 加载指定类型的 Prompt，带缓存
    func loadPrompt(_ type: PromptType) throws -> String {
        if let cached = cache[type] {
            return cached
        }

        guard let raw = templates[type] else {
            logger.error("Prompt 模板未找到: \(type.rawValue)")
            throw PromptError.fileNotFound(type.rawValue)
        }

        let template = replaceVariables(in: raw)
        cache[type] = template
        return template
    }

    /// 清除缓存
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Inline Templates

    private let templates: [PromptType: String] = [
        .systemPrompt: """
        你是 Holo AI 助手，一个聪明、友好且实用的个人数据管理助手。

        你的核心能力：
        1. 帮用户快速记账（收入/支出）
        2. 创建待办任务
        3. 记录心情和想法
        4. 习惯打卡
        5. 查看数据分析
        6. 日常闲聊

        今天是 {{todayDate}}。

        规则：
        - 用中文回复
        - 简洁友好，不要过于冗长
        - 当用户的意图明确时，直接执行操作
        - 当意图不明确时，简短追问
        - 金额相关的数字要精确，不要随意更改
        - 使用 Markdown 格式让回复更易读
        """,

        .intentRecognition: """
        你是一个意图识别系统。分析用户的输入，判断其意图并提取相关数据。

        当前日期：{{todayDate}}

        可选意图：
        - record_expense: 记录支出（用户说花了钱、买了东西、吃饭等）
        - record_income: 记录收入（用户说收到钱、工资等）
        - create_task: 创建待办任务（用户说要做什么、提醒等）
        - record_mood: 记录心情/想法
        - record_weight: 记录体重
        - check_in: 习惯打卡
        - query: 查询数据（查账单、统计等）
        - chat: 普通闲聊
        - unknown: 无法判断

        请以 JSON 格式回复：
        ```json
        {
          "intent": "意图名称",
          "confidence": 0.95,
          "extractedData": {
            "amount": "金额",
            "note": "备注",
            "type": "类型",
            "title": "任务标题"
          },
          "needsClarification": false,
          "clarificationQuestion": null,
          "responseText": "确认消息"
        }
        ```

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
