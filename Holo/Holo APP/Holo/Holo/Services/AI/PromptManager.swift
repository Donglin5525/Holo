//
//  PromptManager.swift
//  Holo
//
//  Prompt 管理器
//  从 Bundle 加载 JSON Prompt 文件，支持模板变量替换
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

        let filename = type.rawValue
        guard let url = Bundle.main.url(forResource: filename, withExtension: "json", subdirectory: "Prompts") else {
            logger.error("Prompt 文件未找到: \(filename).json")
            throw PromptError.fileNotFound(filename)
        }

        let data = try Data(contentsOf: url)
        let promptFile = try JSONDecoder().decode(PromptFile.self, from: data)

        var template = promptFile.template

        // 替换模板变量
        template = replaceVariables(in: template)

        cache[type] = template
        return template
    }

    /// 清除缓存
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func replaceVariables(in template: String) -> String {
        var result = template

        // {{todayDate}}
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"
        result = result.replacingOccurrences(of: "{{todayDate}}", with: dateFormatter.string(from: Date()))

        // {{currentYear}}
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        result = result.replacingOccurrences(of: "{{currentYear}}", with: yearFormatter.string(from: Date()))

        return result
    }
}

// MARK: - Prompt File Model

private struct PromptFile: Codable {
    let version: Int
    let template: String
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
