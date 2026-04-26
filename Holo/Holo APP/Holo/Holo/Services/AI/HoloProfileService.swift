//
//  HoloProfileService.swift
//  Holo
//
//  个人档案管理服务
//  读写 HoloProfile.md，8KB 上限，缓存机制
//

import Foundation
import Combine
import os.log

// MARK: - Notification

extension Notification.Name {
    static let profileDidChange = Notification.Name("com.holo.profileDidChange")
}

// MARK: - HoloProfileService

@MainActor
final class HoloProfileService: ObservableObject {

    static let shared = HoloProfileService()
    static let maxFileSize = 8192  // 8KB

    @Published private(set) var profileContent: String = ""
    @Published private(set) var isLoaded: Bool = false

    var hasProfile: Bool { !profileContent.isEmpty }

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloProfileService")
    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let holoDir = appSupport.appendingPathComponent("Holo", isDirectory: true)
        return holoDir.appendingPathComponent("HoloProfile.md")
    }

    private init() {}

    // MARK: - Default Template

    static let defaultTemplate = """
    # 关于我

    - 昵称：
    - 所在城市：
    - 时区：Asia/Shanghai

    ## 角色与身份

    - 职业：
    - 日常角色：

    ## 生活节奏

    - 工作日作息：9:00 - 22:00
    - 周末偏好：

    ## 关注领域

    （每行一个关注领域）

    ## 消费习惯

    - 常见餐饮：
    - 交通方式：
    - 月度预算关注：

    ## 沟通偏好

    - 回复语言：中文
    - 回复风格：简洁友好
    - 禁忌话题：无

    ## 健康与习惯目标

    - 关注的习惯：
    - 健康提醒偏好：当发现不健康的消费模式时，温和地提出改善建议
    """

    // MARK: - Load

    /// 加载档案内容，带缓存
    func loadProfile() -> String {
        if isLoaded {
            return profileContent
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            profileContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            isLoaded = true
            return profileContent
        } catch {
            // 文件不存在是正常情况（首次使用），不报错
            if FileManager.default.fileExists(atPath: fileURL.path) {
                logger.error("读取个人档案失败：\(error.localizedDescription)")
            }
            profileContent = ""
            isLoaded = true
            return ""
        }
    }

    // MARK: - Save

    /// 保存档案内容，校验大小上限
    func saveProfile(_ content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8) else {
            throw ProfileError.encodingFailed
        }

        guard data.count <= Self.maxFileSize else {
            throw ProfileError.exceedsSizeLimit(
                current: Double(data.count) / 1024.0,
                limit: Double(Self.maxFileSize) / 1024.0
            )
        }

        // 确保目录存在
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try data.write(to: fileURL, options: .atomic)
        profileContent = trimmed
        isLoaded = true

        NotificationCenter.default.post(name: .profileDidChange, object: nil)
        logger.info("个人档案已保存 (\(data.count) bytes)")
    }

    // MARK: - Reset

    /// 重置为默认模板
    func resetToTemplate() throws {
        try saveProfile(Self.defaultTemplate)
    }

    // MARK: - Preview

    /// 获取档案预览文本（前两行非空内容）
    var previewText: String {
        let lines = profileContent
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        return lines.prefix(2).joined(separator: "，")
    }
}

// MARK: - Profile Error

enum ProfileError: LocalizedError {
    case exceedsSizeLimit(current: Double, limit: Double)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .exceedsSizeLimit(let current, let limit):
            return String(format: "档案大小 %.1f KB 超过上限 %.1f KB", current, limit)
        case .encodingFailed:
            return "档案内容编码失败"
        }
    }
}
