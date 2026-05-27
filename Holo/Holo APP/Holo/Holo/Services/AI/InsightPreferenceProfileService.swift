//
//  InsightPreferenceProfileService.swift
//  Holo
//
//  洞察偏好画像持久化服务
//  JSON 文件存储，原子写入，损坏回退默认画像
//

import Foundation
import os.log

final class InsightPreferenceProfileService {
    static let shared = InsightPreferenceProfileService()

    private static let logger = Logger(subsystem: "com.holo.app", category: "InsightPreferenceProfile")

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo", isDirectory: true)
        return dir.appendingPathComponent("InsightPreferenceProfile.json")
    }()

    private(set) var currentProfile: InsightPreferenceProfile

    private init() {
        currentProfile = Self.loadFromDisk(fileURL: fileURL) ?? .default()
    }

    /// 读取当前画像
    func loadProfile() -> InsightPreferenceProfile {
        currentProfile
    }

    /// 更新画像并持久化
    func updateProfile(_ update: (inout InsightPreferenceProfile) -> Void) {
        update(&currentProfile)
        currentProfile.updatedAt = Date()
        currentProfile.lastDataActivityDate = Date()
        saveToDisk()
    }

    /// 重置为默认画像
    func resetToDefault() {
        currentProfile = .default()
        saveToDisk()
        Self.logger.info("偏好画像已重置为默认")
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(currentProfile) else {
            Self.logger.error("偏好画像编码失败")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("偏好画像写入失败：\(error.localizedDescription)")
        }
    }

    private static func loadFromDisk(fileURL: URL) -> InsightPreferenceProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(InsightPreferenceProfile.self, from: data)
        } catch {
            logger.error("偏好画像加载失败，回退默认画像：\(error.localizedDescription)")
            return nil
        }
    }
}
