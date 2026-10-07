//
//  ThoughtEditorRecoveryStore.swift
//  Holo
//
//  想法编辑器本机恢复日志（2026-10-04 体检 G1「保存可信」）：
//  编辑会话的已确认文本 + 暂存图 staged 文件落在本机目录，进程被杀后可恢复。
//  只存 ID/正文快照/staged 文件名，不做云端草稿实体；恢复范围是本设备。
//

import Foundation
import os.log

/// 一条编辑会话的恢复记录。
/// sessionId 是编辑器会话身份（与 thoughtId 解耦：未落库的草稿没有稳定 thoughtId）。
struct ThoughtEditorRecoveryDraft: Codable, Identifiable, Equatable {
    var id: String { sessionId.uuidString }
    let sessionId: UUID
    /// 关联的想法 ID；nil = 从未落库的纯草稿
    var thoughtId: UUID?
    var content: String
    var richContentJSON: String?
    /// staged 目录内的图片文件名（不含路径）
    var stagedImageFiles: [String]
    var updatedAt: Date
}

/// 编辑器恢复日志存储（actor 串行化磁盘访问）。
/// 目录结构：
///   Application Support/ThoughtEditorRecovery/drafts/<sessionUUID>.json
///   Application Support/ThoughtEditorRecovery/staged/<uuid>.jpg
actor ThoughtEditorRecoveryStore {

    static let shared = ThoughtEditorRecoveryStore()

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtEditorRecovery")
    private let rootDirectory: URL
    private var draftsDirectory: URL { rootDirectory.appendingPathComponent("drafts", isDirectory: true) }
    private var stagedDirectory: URL { rootDirectory.appendingPathComponent("staged", isDirectory: true) }

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootDirectory = base.appendingPathComponent("ThoughtEditorRecovery", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 草稿记录

    /// 原子写入一条恢复记录（tmp + rename，避免半写文件）。
    func save(_ draft: ThoughtEditorRecoveryDraft) {
        let url = draftsDirectory.appendingPathComponent(draft.sessionId.uuidString + ".json")
        do {
            let data = try JSONEncoder().encode(draft)
            let tmp = draftsDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            logger.error("恢复记录写入失败: \(error.localizedDescription)")
        }
    }

    /// 删除一条恢复记录。只删记录文件，不动 staged 图片——图片有独立生命周期
    /// （转正成功即删 / 用户删图即删 / 7 天孤儿对账兜底）；
    /// 「恢复接管」场景新记录还要引用同一批 staged 文件，级联删除会把可恢复的图删掉。
    func clear(sessionId: UUID) {
        let url = draftsDirectory.appendingPathComponent(sessionId.uuidString + ".json")
        try? FileManager.default.removeItem(at: url)
    }

    /// 某条想法关联的恢复记录（按 updatedAt 降序）。
    func drafts(forThoughtId thoughtId: UUID) -> [ThoughtEditorRecoveryDraft] {
        allDrafts().filter { $0.thoughtId == thoughtId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 从未落库的孤儿草稿（新建会话没保存过就被杀），按 updatedAt 降序。
    func orphanDrafts() -> [ThoughtEditorRecoveryDraft] {
        allDrafts().filter { $0.thoughtId == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 读取 staged 图片内容（恢复暂存图用）。
    func stagedImageData(_ fileName: String) -> Data? {
        try? Data(contentsOf: stagedDirectory.appendingPathComponent(fileName))
    }

    /// 写入 staged 图片（选图后立即落盘，先于任何保存动作）。
    func writeStagedImage(_ data: Data, fileName: String) {
        do {
            try data.write(to: stagedDirectory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            logger.error("staged 图片写入失败: \(error.localizedDescription)")
        }
    }

    /// 删除单个 staged 图片文件。
    func removeStagedImage(_ fileName: String) {
        try? FileManager.default.removeItem(at: stagedDirectory.appendingPathComponent(fileName))
    }

    /// 清理孤儿 staged 文件：不被任何恢复记录引用且超过保留期的文件。
    /// App 启动时调用一次即可；不追求即时精确对账，目标是目录不无限膨胀。
    func cleanupOrphans(olderThan maxAge: TimeInterval = 7 * 24 * 3600) {
        let referenced = Set(allDrafts().flatMap { $0.stagedImageFiles })
        let files = (try? FileManager.default.contentsOfDirectory(at: stagedDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files {
            guard referenced.contains(file.lastPathComponent) == false else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Private

    private func allDrafts() -> [ThoughtEditorRecoveryDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { readDraft(at: $0) }
    }

    /// 损坏的记录文件按不存在处理（不抛错、不重建），让问题在上层表现为「没有可恢复草稿」。
    private func readDraft(at url: URL) -> ThoughtEditorRecoveryDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThoughtEditorRecoveryDraft.self, from: data)
    }
}
