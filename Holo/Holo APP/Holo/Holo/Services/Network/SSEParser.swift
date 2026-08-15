//
//  SSEParser.swift
//  Holo
//
//  SSE 行解析器
//  解析 Server-Sent Events 格式的流式数据
//

import Foundation
import os

nonisolated struct SSEParser {

    private static let logger = Logger(subsystem: "com.holo.app", category: "SSEParser")

    /// 解析单行 SSE 数据
    /// - Parameter line: 一行 SSE 文本
    /// - Returns: 解析出的内容文本，如果该行不含有效数据则返回 nil
    mutating func parse(_ line: String) -> String? {
        // 跳过空行
        guard !line.isEmpty else { return nil }

        // 跳过注释行（以冒号开头）
        guard !line.hasPrefix(":") else { return nil }

        // 处理 data: 前缀（SSE 规范允许 "data:" 与 "data: " 两种写法）
        let jsonString: Substring
        if line.hasPrefix("data: ") {
            jsonString = line.dropFirst(6)
        } else if line.hasPrefix("data:") {
            jsonString = line.dropFirst(5)
        } else {
            return nil
        }

        // 检查结束标记
        if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return nil
        }

        // 解码 SSEChunk 提取 content
        guard let jsonData = String(jsonString).data(using: .utf8) else { return nil }

        do {
            let chunk = try JSONDecoder().decode(SSEChunk.self, from: jsonData)
            if let content = chunk.choices?.first?.delta?.content {
                return content
            }
        } catch {
            // 坏行不再静默丢弃：上游格式变化时会无声丢内容，这里留日志便于诊断
            Self.logger.warning("SSE 行 JSON 解码失败：\(String(jsonString.prefix(200)), privacy: .public)")
            return nil
        }

        return nil
    }
}
