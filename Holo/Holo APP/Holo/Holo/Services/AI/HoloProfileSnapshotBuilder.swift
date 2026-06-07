//
//  HoloProfileSnapshotBuilder.swift
//  Holo
//
//  从 HoloProfile.md Markdown 解析结构化 Snapshot
//  首版重点解析 preferredName，其余按 section 标题提取
//

import Foundation
import os.log

// MARK: - HoloProfileSnapshotBuilder

/// 从 HoloProfile.md 的 Markdown 文本解析结构化 Snapshot
///
/// 解析策略：
/// - 模板字段优先（如"希望称呼：东林"）
/// - 轻量正则补充常见自然语言写法
/// - 解析不确定时不写入结构化字段，只保留 raw Markdown
/// - 记录每个字段的解析置信度
enum HoloProfileSnapshotBuilder {

    private static let logger = Logger(subsystem: "com.holo.app", category: "ProfileSnapshotBuilder")

    // MARK: - Section 名称映射

    /// Section 标题 → 对应的 snapshot 字段类别
    private enum SectionTarget {
        case identity       // 关于我 / 基本信息
        case communication  // 沟通偏好
        case focus          // 当前关注 / 关注领域
        case health         // 健康与习惯目标
        case boundaries     // 边界 / 禁忌话题
        case roles          // 角色与身份
        case other
    }

    /// 标题关键词 → Section 分类
    private static let sectionMapping: [(keywords: [String], target: SectionTarget)] = [
        (keywords: ["沟通偏好", "沟通风格", "回复偏好"], target: .communication),
        (keywords: ["当前关注", "关注领域", "关注主题", "当前重点"], target: .focus),
        (keywords: ["健康与习惯", "健康", "习惯目标"], target: .health),
        (keywords: ["边界", "禁忌话题", "不要", "限制"], target: .boundaries),
        (keywords: ["角色与身份", "身份", "职业"], target: .roles),
        (keywords: ["关于我", "基本信息", "个人简介"], target: .identity),
    ]

    // MARK: - Preferred Name 模式

    /// 匹配"希望称呼"类字段的模式
    private static let preferredNamePatterns: [(pattern: String, extractGroup: Int)] = [
        // 模板格式："希望称呼：东林" / "昵称：东林"
        (pattern: "(?:希望称呼|昵称|称呼我为|名字|称呼)\\s*[:：]\\s*(.+)", 1),
        // 自然语言："叫我东林就好" / "叫我东林"
        (pattern: "叫(?:我|作)\\s*([^，。,\\.\\s]{1,10})(?:就好|就行|吧|好了)?(?:[，。,.\\s]|$)", 1),
        // 自然语言："我是东林"
        (pattern: "我(?:是|叫)\\s*([^，。,\\.\\s]{1,10})(?:[，。,.\\s]|$)", 1),
        // 英文："Call me Donglin"
        (pattern: "(?:call\\s+me|name(?:d)?(?:\\s+is)?)\\s+([\\w\\s]{1,20}?)(?:[,.]|$)", 1),
    ]

    // MARK: - Public API

    /// 从 Markdown 文本构建 Snapshot
    ///
    /// - Parameter markdown: HoloProfile.md 的原始内容
    /// - Returns: 解析后的 Snapshot，解析失败的字段为 nil/空
    static func build(from markdown: String) -> HoloProfileSnapshot {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空内容直接返回空 snapshot
        guard !trimmed.isEmpty else {
            return .empty()
        }

        // 按标题分 section
        let sections = parseSections(from: trimmed)

        // 解析各字段
        var confidence: [String: Bool] = [:]

        let preferredName = extractPreferredName(from: trimmed, sections: sections)
        confidence["preferredName"] = preferredName != nil

        let language = extractField(
            from: sections,
            targets: [.identity],
            keywords: ["回复语言", "常用语言", "语言", "language"],
            singleValue: true
        )
        confidence["language"] = language != nil

        let timezone = extractField(
            from: sections,
            targets: [.identity],
            keywords: ["时区", "timezone"],
            singleValue: true
        )
        confidence["timezone"] = timezone != nil

        let city = extractField(
            from: sections,
            targets: [.identity],
            keywords: ["所在城市", "城市", "city"],
            singleValue: true
        )
        confidence["city"] = city != nil

        let profession = extractField(
            from: sections,
            targets: [.roles, .identity],
            keywords: ["职业", "日常角色", "当前角色", "profession"],
            singleValue: true
        )
        confidence["profession"] = profession != nil

        let communicationStyle = extractSectionLines(from: sections, target: .communication)
        confidence["communicationStyle"] = !communicationStyle.isEmpty

        let currentFocus = extractSectionLines(from: sections, target: .focus)
        confidence["currentFocus"] = !currentFocus.isEmpty

        let lifeContext: [String] = []
        confidence["lifeContext"] = false

        let healthHabitContext = extractSectionLines(from: sections, target: .health)
        confidence["healthHabitContext"] = !healthHabitContext.isEmpty

        let sensitiveBoundaries = extractSectionLines(from: sections, target: .boundaries)
        confidence["sensitiveBoundaries"] = !sensitiveBoundaries.isEmpty

        let parsedCount = confidence.values.filter { $0 }.count
        logger.debug("Profile snapshot 解析完成：\(parsedCount)/\(confidence.count) 字段成功，sections=\(sections.count)")

        return HoloProfileSnapshot(
            rawMarkdown: trimmed,
            preferredName: preferredName,
            language: language,
            timezone: timezone,
            city: city,
            profession: profession,
            communicationStyle: communicationStyle,
            currentFocus: currentFocus,
            lifeContext: lifeContext,
            healthHabitContext: healthHabitContext,
            sensitiveBoundaries: sensitiveBoundaries,
            parseConfidence: confidence,
            updatedAt: Date()
        )
    }

    // MARK: - Section 解析

    /// Markdown 按标题分 section
    private struct MarkdownSection {
        let title: String
        let content: String
        let target: SectionTarget
    }

    private static func parseSections(from markdown: String) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        let lines = markdown.components(separatedBy: .newlines)

        var currentTitle = ""
        var currentLines: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("#") {
                // 遇到新标题，保存上一个 section
                if !currentTitle.isEmpty || !currentLines.isEmpty {
                    let content = currentLines.joined(separator: "\n")
                    let target = classifySection(currentTitle)
                    sections.append(MarkdownSection(title: currentTitle, content: content, target: target))
                }
                // 提取标题文本（去掉 # 符号）
                currentTitle = trimmedLine
                    .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        // 保存最后一个 section
        if !currentTitle.isEmpty || !currentLines.isEmpty {
            let content = currentLines.joined(separator: "\n")
            let target = classifySection(currentTitle)
            sections.append(MarkdownSection(title: currentTitle, content: content, target: target))
        }

        return sections
    }

    /// 根据 section 标题判断类别
    private static func classifySection(_ title: String) -> SectionTarget {
        let lowerTitle = title.lowercased()
        for mapping in sectionMapping {
            if mapping.keywords.contains(where: { lowerTitle.contains($0.lowercased()) }) {
                return mapping.target
            }
        }
        return .other
    }

    // MARK: - Preferred Name 提取

    /// 从全文和 identity section 中提取称呼
    private static func extractPreferredName(
        from fullText: String,
        sections: [MarkdownSection]
    ) -> String? {
        // 策略 1：全文正则匹配（覆盖自然语言写法）
        for (pattern, group) in preferredNamePatterns {
            if let match = firstMatch(in: fullText, pattern: pattern, group: group) {
                let cleaned = cleanExtractedValue(match)
                if !cleaned.isEmpty && cleaned.count <= 10 {
                    return cleaned
                }
            }
        }

        // 策略 2：从 identity section 中按 key-value 提取
        let identitySections = sections.filter { $0.target == .identity }
        for section in identitySections {
            if let name = extractFieldFromContent(
                section.content,
                keywords: ["希望称呼", "昵称", "称呼我为", "名字", "称呼"],
                singleValue: true
            ) {
                return name
            }
        }

        return nil
    }

    // MARK: - 通用字段提取

    /// 从匹配 target 的 sections 中按关键词提取单值
    private static func extractField(
        from sections: [MarkdownSection],
        targets: [SectionTarget],
        keywords: [String],
        singleValue: Bool
    ) -> String? {
        let matchedSections = sections.filter { targets.contains($0.target) }
        for section in matchedSections {
            if let value = extractFieldFromContent(section.content, keywords: keywords, singleValue: singleValue) {
                return value
            }
        }
        return nil
    }

    /// 从 section 内容中按 key-value 提取
    private static func extractFieldFromContent(
        _ content: String,
        keywords: [String],
        singleValue: Bool
    ) -> String? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 去掉列表前缀 "- " 或 "• "
            let cleaned = trimmed
                .replacingOccurrences(of: "^[-•*]\\s+", with: "", options: .regularExpression)

            for keyword in keywords {
                if cleaned.hasPrefix(keyword) {
                    let afterKeyword = cleaned.dropFirst(keyword.count)
                    let value = afterKeyword
                        .trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                    if !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return nil
    }

    /// 提取 section 中的所有列表项
    private static func extractSectionLines(
        from sections: [MarkdownSection],
        target: SectionTarget
    ) -> [String] {
        let matchedSections = sections.filter { $0.target == target }
        var results: [String] = []

        for section in matchedSections {
            let lines = section.content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 提取列表项
                let cleaned = trimmed
                    .replacingOccurrences(of: "^[-•*]\\s+", with: "", options: .regularExpression)
                let final = cleaned
                    .replacingOccurrences(of: "[:：]$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)

                // 过滤空行和占位符
                if !final.isEmpty
                    && final != "（每行一个关注领域）"
                    && !final.hasPrefix("（")
                    && final != "无"
                    && final != "暂无" {
                    results.append(final)
                }
            }
        }

        return results
    }

    // MARK: - 正则工具

    /// 正则匹配第一个 group
    private static func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.range(at: group).location != NSNotFound,
              let swiftRange = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    /// 清理提取的值（去标点、去多余空格）
    private static func cleanExtractedValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，,.")
                .union(.whitespaces))
    }
}
