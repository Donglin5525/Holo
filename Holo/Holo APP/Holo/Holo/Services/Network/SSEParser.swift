//
//  SSEParser.swift
//  Holo
//
//  SSE 行解析器
//  解析 Server-Sent Events 格式的流式数据
//

import Foundation

struct SSEParser {

    /// 解析单行 SSE 数据
    /// - Parameter line: 一行 SSE 文本
    /// - Returns: 解析出的内容文本，如果该行不含有效数据则返回 nil
    mutating func parse(_ line: String) -> String? {
        // 跳过空行
        guard !line.isEmpty else { return nil }

        // 跳过注释行（以冒号开头）
        guard !line.hasPrefix(":") else { return nil }

        // 处理 data: 前缀
        if line.hasPrefix("data: ") {
            let jsonString = String(line.dropFirst(6))

            // 检查结束标记
            if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                return nil
            }

            // 解码 SSEChunk 提取 content
            guard let jsonData = jsonString.data(using: .utf8) else { return nil }

            do {
                let chunk = try JSONDecoder().decode(SSEChunk.self, from: jsonData)
                if let content = chunk.choices?.first?.delta?.content {
                    return content
                }
            } catch {
                // JSON 解码失败，忽略该行
                return nil
            }
        }

        return nil
    }
}
