//
//  DiscoveryCanonicalJSON.swift
//  Holo
//
//  「一个发现」双端确定性序列化（实施包 03 §3.4）。
//  与 HoloBackend/src/discovery/discoveryCanonicalJson.js 逐一对应：
//  对象键按 UTF-16 码元升序、数组保序、字符串 JSON 最小转义、整数十进制、
//  -0 归一为 0；非整数小数双端表示可能有别，本协议 candidates 数组不含自由小数
//  （时间均为字符串），如未来引入需先补跨端向量。
//

import Foundation
import CryptoKit

/// 无类型 JSON 值：阶段请求里 data 与候选回显都需要「原样 JSON」——
/// 严格 DTO（DiscoveryModels）负责校验语义，本类型负责字节级回显与 hash。
enum DiscoveryJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(DiscoveryJSONNumber)
    case string(String)
    indirect case array([DiscoveryJSONValue])
    indirect case object([(String, DiscoveryJSONValue)])

    // 元组不满足 Equatable，合成失败——显式实现（object 按序逐对比较，
    // canonical 输出键有序，语义上顺序即内容）。
    static func == (lhs: DiscoveryJSONValue, rhs: DiscoveryJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.0 != y.0 || x.1 != y.1 {
                return false
            }
            return true
        default: return false
        }
    }
}

/// 整数与有限小数。canonical 输出：整数直接十进制；小数用 Swift 最短十进制表示
/// （与 JS Number.prototype.toString 对常见值一致，极端指数形式未对齐——本协议不使用）。
enum DiscoveryJSONNumber: Sendable, Equatable {
    case int(Int64)
    case double(Double)

    var canonicalText: String {
        switch self {
        case .int(let value): return String(value)
        case .double(let value):
            if value == 0 { return "0" } // -0 归一
            return String(value)
        }
    }
}

enum DiscoveryCanonicalJSON {

    /// 跨端一致性向量（由 JS 实现 canonicalSha256 生成，2026-10-23）：
    /// 含中文/emoji/嵌套/空数组的 two_episodes 候选。
    /// 锁定双端 hash 不可漂移；改任何一端序列化规则必须重新生成并双侧更新。
    static let parityVectorSHA256 = "57493966e32f42b9bbc6b2da20e72b2a5bbe569ea83d861b32147f81aaa8c048"

    static func canonicalString(_ value: DiscoveryJSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .number(let number):
            return number.canonicalText
        case .string(let string):
            return Self.escape(string)
        case .array(let items):
            return "[" + items.map(canonicalString).joined(separator: ",") + "]"
        case .object(let pairs):
            // 键按 UTF-16 码元升序（JS Array.prototype.sort 默认序）
            let sorted = pairs.sorted { lhs, rhs in
                Self.isLessUTF16(lhs.0, rhs.0)
            }
            return "{" + sorted.map { key, value in
                Self.escape(key) + ":" + canonicalString(value)
            }.joined(separator: ",") + "}"
        }
    }

    static func canonicalSha256(_ value: DiscoveryJSONValue) -> String {
        let data = Data(canonicalString(value).utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// JSON 最小转义（对齐 JSON.stringify）：仅 " \ 与控制字符；
    /// \b \t \n \f \r 用短形式，其余控制字符 \u00XX。
    static func escape(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case UnicodeScalar(0x08): out += "\\b"
            case UnicodeScalar(0x0C): out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// UTF-16 码元序比较（JS 字符串默认比较语义）。
    private static func isLessUTF16(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf16)
        let b = Array(rhs.utf16)
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }

    // MARK: - JSONValue 解析

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> DiscoveryJSONValue {
            skipWhitespace()
            guard index < bytes.count else { throw ParseError.unexpectedEnd }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseObject() throws -> DiscoveryJSONValue {
            index += 1 // {
            var pairs: [(String, DiscoveryJSONValue)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError.expectedColon }
                index += 1
                let value = try parseValue()
                pairs.append((key, value))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(pairs)
                }
                throw ParseError.expectedCommaOrBrace
            }
        }

        mutating func parseArray() throws -> DiscoveryJSONValue {
            index += 1 // [
            var items: [DiscoveryJSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                let value = try parseValue()
                items.append(value)
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                }
                throw ParseError.expectedCommaOrBracket
            }
        }

        mutating func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError.expectedString }
            index += 1
            var scalars = String.UnicodeScalarView()
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1 // 越过反斜杠
                    guard index < bytes.count else { throw ParseError.unexpectedEnd }
                    let escape = bytes[index]
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\""); index += 1
                    case UInt8(ascii: "\\"): scalars.append("\\"); index += 1
                    case UInt8(ascii: "/"): scalars.append("/"); index += 1
                    case UInt8(ascii: "b"): scalars.append(UnicodeScalar(0x08)); index += 1
                    case UInt8(ascii: "f"): scalars.append(UnicodeScalar(0x0C)); index += 1
                    case UInt8(ascii: "n"): scalars.append("\n"); index += 1
                    case UInt8(ascii: "r"): scalars.append("\r"); index += 1
                    case UInt8(ascii: "t"): scalars.append("\t"); index += 1
                    case UInt8(ascii: "u"):
                        // 进入时 index 指向 'u'，离开时越过最后一个 hex（含代理对）
                        let scalar = try parseUnicodeEscape()
                        scalars.append(scalar)
                    default: throw ParseError.invalidEscape
                    }
                    continue
                }
                if byte < 0x20 { throw ParseError.controlCharInString }
                // 原样收集该 UTF-8 字节，最后统一 decode（多字节字符由后续字节拼齐）
                index += 1
                // 逐字节收集太慢且复杂——直接从原始 Data 切片 decode
                if byte < 0x80 {
                    scalars.append(UnicodeScalar(byte))
                } else {
                    // 回退一个字节，切出完整 UTF-8 序列
                    index -= 1
                    let start = index
                    var length = 1
                    if byte & 0xE0 == 0xC0 { length = 2 } else if byte & 0xF0 == 0xE0 { length = 3 } else { length = 4 }
                    index += length
                    guard index <= bytes.count else { throw ParseError.unexpectedEnd }
                    let slice = Data(bytes[start..<index])
                    guard let text = String(data: slice, encoding: .utf8) else { throw ParseError.invalidUTF8 }
                    scalars.append(contentsOf: text.unicodeScalars)
                }
            }
            throw ParseError.unexpectedEnd
        }

        /// 进入时 index 指向 'u'；离开时越过最后一个 hex（代理对含低半段）。
        mutating func parseUnicodeEscape() throws -> UnicodeScalar {
            func readHex4(_ base: Int) throws -> UInt32 {
                // hex 在 base+1 ... base+4
                guard base + 4 < bytes.count else { throw ParseError.unexpectedEnd }
                var value: UInt32 = 0
                for offset in 1...4 {
                    let hex = bytes[base + offset]
                    let digit: UInt32
                    switch hex {
                    case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(hex - UInt8(ascii: "0"))
                    case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(hex - UInt8(ascii: "a")) + 10
                    case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(hex - UInt8(ascii: "A")) + 10
                    default: throw ParseError.invalidEscape
                    }
                    value = value << 4 | digit
                }
                return value
            }
            var code = try readHex4(index)
            var consumed = 5 // u + 4 hex
            if (0xD800...0xDBFF).contains(code) {
                guard index + 6 < bytes.count,
                      bytes[index + 5] == UInt8(ascii: "\\"),
                      bytes[index + 6] == UInt8(ascii: "u") else { throw ParseError.loneSurrogate }
                let low = try readHex4(index + 6)
                guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.loneSurrogate }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                consumed = 11 // \uXXXX\uYYYY
            }
            guard let scalar = UnicodeScalar(code) else { throw ParseError.invalidScalar }
            index += consumed
            return scalar
        }

        mutating func parseNumber() throws -> DiscoveryJSONValue {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            while index < bytes.count {
                let byte = bytes[index]
                if (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: ".")
                    || byte == UInt8(ascii: "e")
                    || byte == UInt8(ascii: "E")
                    || byte == UInt8(ascii: "+")
                    || byte == UInt8(ascii: "-") {
                    index += 1
                } else {
                    break
                }
            }
            guard index > start else { throw ParseError.invalidNumber }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if let int = Int64(text) {
                return .number(.int(int))
            }
            guard let double = Double(text), double.isFinite else { throw ParseError.invalidNumber }
            return .number(.double(double))
        }

        mutating func expectLiteral(_ literal: String) throws {
            for char in literal.utf8 {
                guard index < bytes.count, bytes[index] == char else { throw ParseError.unexpectedEnd }
                index += 1
            }
        }

        enum ParseError: Error { case unexpectedEnd, expectedColon, expectedCommaOrBrace, expectedCommaOrBracket, expectedString, invalidEscape, controlCharInString, invalidUTF8, loneSurrogate, invalidScalar, invalidNumber }
    }

    /// 解析任意 JSON 为无类型值（供 data 组装与候选回显；不做 schema 校验）。
    /// 尾部多余内容拒绝（与严格解码口径一致）。
    static func parse(_ data: Data) throws -> DiscoveryJSONValue {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw Parser.ParseError.unexpectedEnd
        }
        return value
    }
}
