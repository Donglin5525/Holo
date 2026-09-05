//
//  ThoughtIndexV2Policy.swift
//  Holo
//
//  想法自动整理 V2 纯策略（2026-09-05 方案 §2.3/§5.4/§6.1）
//
//  上传前的确定性脱敏、本地跳过判定、协议版本常量。
//  脱敏只减少暴露（邮箱/手机/证件样式占位），不是匿名化；不引入外部服务。
//

import Foundation

nonisolated enum ThoughtIndexV2Policy {

    /// 引擎版本（与服务端 policyVersion 对齐；升级引擎时递增并决定旧结果去留）
    static let engineVersion = "thought_index_v2.1"

    /// 协议版本（请求 schemaVersion）
    static let schemaVersion = 2

    /// 正文上限（UTF-16 单位，与服务端 ORGANIZE_LIMITS 一致；超出本地即终态跳过）
    static let textMaxUTF16Length = 8_000

    // MARK: - 上传前脱敏（方案 §2.3：规则明确的样式占位，保留本地映射不必回填）

    private static let emailPattern = try? NSRegularExpression(
        pattern: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
    )
    private static let phonePattern = try? NSRegularExpression(
        pattern: #"1[3-9]\d{9}"#
    )
    /// 15-18 位连续数字（身份证样式）；10 位以上长数字串（账号/证件/密钥样式）
    private static let longNumberPattern = try? NSRegularExpression(
        pattern: #"\d{10,18}"#
    )

    static func redactedText(forUpload text: String) -> String {
        var result = text
        func replace(_ regex: NSRegularExpression?, with placeholder: String) {
            guard let regex else { return }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: placeholder
            )
        }
        replace(emailPattern, with: "[email]")
        replace(phonePattern, with: "[phone]")
        replace(longNumberPattern, with: "[number]")
        return result
    }

    // MARK: - 本地跳过判定（方案 §5.4）

    /// 纯空白 / 仅 # 标签与标点 / 无任何可分析内容的文本不发请求（方案 §5.4）。
    /// 「#标签」是用户手动标签（关系已落库），不算待分析正文——只有它时无需再调模型。
    /// 注意：短文本（如"GLM5.3发布了"）不再按固定 10 字门槛拒绝——由模型判断。
    static func shouldSkipLocally(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // 先整体移除 #标签 token（# + 紧随的非空白词），再判剩余是否有实质内容
        let withoutTags = trimmed.replacingOccurrences(
            of: #"[#＃][^\s#＃]+"#,
            with: "",
            options: .regularExpression
        )
        let removable = CharacterSet(charactersIn: "#、，。！？.,!?;；:：·~～…—-()（）[]【】 ")
            .union(.whitespacesAndNewlines)
        let meaningful = withoutTags.unicodeScalars.filter { !removable.contains($0) }
        return meaningful.isEmpty
    }

    /// 正文超限：本地直接终态（不发请求、不截断后假装完整理解）
    static func isTooLarge(_ content: String) -> Bool {
        content.utf16.count > textMaxUTF16Length
    }

    // MARK: - 修订号

    /// textRevision：正文版本标记（脱敏后文本的 hash 短版，仅用于响应对照，不含正文）
    static func textRevision(forRedactedText text: String) -> String {
        "r-" + ThoughtTagIndexProjection.textHash(text)
    }

    /// catalogRevision：目录版本标记（词条数 + 内容指纹短版）
    static func catalogRevision(entryCount: Int, fingerprint: String) -> String {
        "c-\(entryCount)-" + String(ThoughtTagIndexProjection.textHash(fingerprint).prefix(8))
    }
}
