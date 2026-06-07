//
//  HoloProfileSnapshot.swift
//  Holo
//
//  HoloProfile 结构化解析结果
//  从 HoloProfile.md 解析出的结构化摘要，供 HoloProfilePromptRenderer 使用
//

import Foundation

// MARK: - HoloProfileSnapshot

/// HoloProfile.md 的结构化解析结果
///
/// 由 `HoloProfileSnapshotBuilder` 从 Markdown 解析生成，
/// 供 `HoloProfilePromptRenderer` 渲染为稳定的 AI prompt 文本。
///
/// 设计原则：
/// - 不可变结构体，解析后不再修改
/// - `parseConfidence` 标记每个字段的解析成功/失败，便于诊断
/// - 解析失败的字段为 nil 或空数组，不影响 AI 正常工作
struct HoloProfileSnapshot: Codable, Equatable {
    /// 原始 Markdown 内容
    let rawMarkdown: String

    // MARK: 身份与称呼

    /// 用户希望被如何称呼（如"东林"）
    let preferredName: String?

    /// 用户常用语言（如"中文"）
    let language: String?

    /// 用户所在时区（如"Asia/Shanghai"）
    let timezone: String?

    /// 用户所在城市（如"北京"）
    let city: String?

    /// 职业/角色（如"独立开发者"）
    let profession: String?

    // MARK: 沟通与偏好

    /// 沟通偏好列表（如"先讲结论"、"直接指出风险"）
    let communicationStyle: [String]

    // MARK: 关注与目标

    /// 当前关注主题（如"Holo 上架"、"减少抽烟"）
    let currentFocus: [String]

    /// 生活上下文（如人生阶段、日常角色描述）
    let lifeContext: [String]

    /// 健康/习惯相关目标上下文
    let healthHabitContext: [String]

    // MARK: 边界

    /// 敏感边界列表（如"不要在无关场景提健康信息"）
    let sensitiveBoundaries: [String]

    // MARK: 元数据

    /// 每个字段的解析置信度，key 为字段名，value 为是否成功解析
    let parseConfidence: [String: Bool]

    /// 解析时间
    let updatedAt: Date

    // MARK: - Computed

    /// 内容指纹，用于日志和缓存比较
    var contentFingerprint: String {
        "\(rawMarkdown.utf8.count)-\(String(rawMarkdown.prefix(64)).stableHash)"
    }

    /// 是否有任何结构化字段被成功解析
    var hasStructuredData: Bool {
        preferredName != nil
            || language != nil
            || !communicationStyle.isEmpty
            || !currentFocus.isEmpty
            || !healthHabitContext.isEmpty
            || !sensitiveBoundaries.isEmpty
    }

    /// 是否为空档案（raw markdown 也为空）
    var isEmpty: Bool {
        rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Factory

    /// 创建空 snapshot（无档案时使用）
    static func empty(from rawMarkdown: String = "") -> HoloProfileSnapshot {
        HoloProfileSnapshot(
            rawMarkdown: rawMarkdown,
            preferredName: nil,
            language: nil,
            timezone: nil,
            city: nil,
            profession: nil,
            communicationStyle: [],
            currentFocus: [],
            lifeContext: [],
            healthHabitContext: [],
            sensitiveBoundaries: [],
            parseConfidence: [:],
            updatedAt: Date()
        )
    }
}

// MARK: - String Extension (Stable Hash)

extension String {
    /// 简单的 DJB2 哈希，跨进程稳定，用于内容指纹
    var stableHash: Int {
        var hash: UInt64 = 5381
        for byte in self.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return Int(hash)
    }
}
