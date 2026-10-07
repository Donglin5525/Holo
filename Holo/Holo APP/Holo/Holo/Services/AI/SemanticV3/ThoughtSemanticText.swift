import Foundation
import CryptoKit

/// 按完整字符边界切分，并保留原文 UTF-16 偏移。任何正文长度都不静默丢尾部。
nonisolated enum ThoughtSemanticText {
    static func contentHash(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(normalized.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    struct Chunk: Equatable { let text: String; let offsetUTF16: Int }
    static func chunks(_ text: String, maxUTF16: Int) -> [Chunk] {
        guard maxUTF16 > 0 else { return [] }
        var result: [Chunk] = [], current = "", offset = 0, length = 0
        for character in text {
            let value = String(character), units = value.utf16.count
            if length + units > maxUTF16, !current.isEmpty {
                result.append(.init(text: current, offsetUTF16: offset))
                offset += length; current = ""; length = 0
            }
            // 极端的超长组合字符无法满足服务协议，显式交由调用方报错。
            current += value; length += units
        }
        if !current.isEmpty { result.append(.init(text: current, offsetUTF16: offset)) }
        return result
    }
    static func prefix(_ text: String, maxUTF16: Int) -> String {
        chunks(text, maxUTF16: maxUTF16).first?.text ?? ""
    }
    static func quoteMatches(_ quote: String, text: String, range: [Int]?) -> Bool {
        guard !quote.isEmpty, let range, range.count == 2, range[0] >= 0,
              range[1] > range[0], range[1] <= text.utf16.count else { return false }
        guard let lower = String.Index(utf16Offset: range[0], in: text).samePosition(in: text),
              let upper = String.Index(utf16Offset: range[1], in: text).samePosition(in: text) else { return false }
        return String(text[lower..<upper]) == quote
    }
}
