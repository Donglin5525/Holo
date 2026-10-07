//
//  CloudRepullService.swift
//  Holo
//
//  从 iCloud 重新拉取全部数据（P2，2026-10-06）
//
//  场景：换机/重装/本机数据可疑时，以云端为准重建本机库。
//  机制：备份本机三件套 → 重建空库 → CloudKit mirroring 自动从云端全量导入
//  （等同新设备首连）→ 计数稳定探测判定完成 → 前后计数对照报告。
//  护栏：备份完整性先行（失败即原样回滚）；全程可一键恢复备份；10 分钟超时如实报告。
//

import Foundation
import CoreData
import Combine
import OSLog

private let logger = Logger(subsystem: "com.tangyuxuan.Holo", category: "CloudRepull")

@MainActor
final class CloudRepullService: ObservableObject {
    static let shared = CloudRepullService()

    // MARK: - 状态

    enum Phase: Equatable {
        case idle
        /// 备份本机库 + 重置（此时还没有可显示的计数）
        case backingUp
        /// 空库重建完成，云端数据流入中（实时计数）
        case importing(counts: [EntityCount])
        /// 完成：前后计数对照 + 备份文件（可恢复）
        case finished(report: RepullReport)
        /// 失败/超时：message 描述现状与出路
        case failed(message: String)
    }

    struct EntityCount: Equatable, Identifiable {
        let entity: String
        let displayName: String
        let count: Int
        var id: String { entity }
    }

    struct RepullReport: Equatable {
        let before: [EntityCount]
        let after: [EntityCount]
    }

    /// 追踪的主要实体（报告口径）：覆盖各域核心数据
    nonisolated static let trackedEntities: [(entity: String, displayName: String)] = [
        ("Transaction", String(localized: "交易")),
        ("Thought", String(localized: "想法")),
        ("Habit", String(localized: "习惯")),
        ("HabitRecord", String(localized: "习惯打卡")),
        ("CheckItem", String(localized: "清单项")),
        ("Goal", String(localized: "目标")),
        ("ChatMessage", String(localized: "对话消息")),
        ("Category", String(localized: "分类")),
        ("Account", String(localized: "账户")),
    ]

    @Published private(set) var phase: Phase = .idle
    /// 当前可回滚的备份文件（拉取进行中/完成后均可恢复）
    @Published private(set) var backupFiles: [URL] = []

    private var beforeCounts: [EntityCount] = []
    private var importCompleted = false
    private var observer: NSObjectProtocol?
    /// 恢复备份进行中（恢复操作本身也有落盘过程，界面据此显示状态）
    @Published private(set) var isRestoring = false

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import,
                  event.endDate != nil,
                  event.error == nil else { return }
            MainActor.assumeIsolated {
                self?.importCompleted = true
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isRunning: Bool {
        if case .idle = phase { return false }
        return true
    }

    // MARK: - 主流程

    func start() async {
        switch phase {
        case .idle, .finished, .failed:
            break  // 首次开始 / 完成后再次拉取
        case .backingUp, .importing:
            return  // 进行中不可重入
        }
        phase = .backingUp
        importCompleted = false

        do {
            let before = await Self.snapshotCounts()
            beforeCounts = before
            let files = try await CoreDataStack.shared.backupAndRebuildStoreForCloudRepull()
            backupFiles = files
            logger.notice("Cloud 重拉：备份完成（\(files.count) 个文件），开始等待云端导入")
            await waitForCloudImport(initialCounts: before)
        } catch {
            logger.error("Cloud 重拉启动失败：\(error.localizedDescription)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// 恢复备份：把重拉前的本机库放回原位（回滚整个拉取）
    func restoreBackup() async {
        guard !backupFiles.isEmpty, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await CoreDataStack.shared.restoreStoreFromCloudRepullBackup(backupFiles)
            backupFiles = []
            phase = .idle
            logger.notice("Cloud 重拉：备份已恢复，回到拉取前状态")
        } catch {
            // 恢复失败是最严重状态：如实报告并保留备份文件信息，不吞错
            logger.fault("Cloud 重拉恢复备份失败：\(error.localizedDescription)")
            phase = .failed(message: String(localized: "恢复备份失败：") + error.localizedDescription)
        }
    }

    /// 关闭报告页回到常态（备份保留，仍可从入口再次进入时提示可恢复）
    func dismiss() {
        guard canDismiss else { return }
        phase = .idle
    }

    /// 能否关闭流程页（完成/失败后才可以；进行中全屏锁定）
    var canDismiss: Bool {
        switch phase {
        case .finished, .failed: return true
        default: return false
        }
    }

    // MARK: - 云端导入完成探测

    /// 轮询本地计数：收到过至少一次 import 成功事件后，连续 3 次计数完全相同即判定完成；
    /// 10 分钟总超时如实报告（已收到的数据保留，可等待或恢复备份）。
    private func waitForCloudImport(initialCounts: [EntityCount]) async {
        phase = .importing(counts: initialCounts)
        var history: [[EntityCount]] = []
        let deadline = Date().addingTimeInterval(600)

        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            // 流程已被接管（恢复备份等）即退出探测
            if case .importing = phase {} else { return }
            let counts = await Self.snapshotCounts()
            phase = .importing(counts: counts)
            history.append(counts)

            if Self.importStreamStabilized(history: history, importCompleted: importCompleted) {
                let report = RepullReport(before: beforeCounts, after: counts)
                logger.notice("Cloud 重拉完成：\(report.after.map { "\($0.displayName)=\($0.count)" }.joined(separator: " "))")
                phase = .finished(report: report)
                return
            }
        }

        phase = .failed(
            message: String(localized: "等待云端数据超时（10 分钟）。已收到的数据保留在本机；可以稍后再试一次拉取，或恢复拉取前的备份。")
        )
    }

    /// 稳定判定纯函数（单测入口）：传输已开始（收到过 import 成功）且连续 N 次计数一致。
    /// 未收到过 import 事件时绝不判稳——空库「稳定」只是传输还没开始。
    static func importStreamStabilized(
        history: [[EntityCount]],
        importCompleted: Bool,
        requiredRepeats: Int = 3
    ) -> Bool {
        guard importCompleted, history.count >= requiredRepeats else { return false }
        let recent = history.suffix(requiredRepeats)
        guard let first = recent.first else { return false }
        return recent.allSatisfy { $0 == first }
    }

    // MARK: - 计数快照

    /// 当前库主要实体计数（后台上下文执行，不阻塞主线程）
    nonisolated static func snapshotCounts() async -> [EntityCount] {
        let entities = trackedEntities
        return (try? await CoreDataStack.shared.performBackgroundTask { context in
            entities.map { entity in
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity.entity)
                let count = (try? context.count(for: request)) ?? 0
                return EntityCount(entity: entity.entity, displayName: entity.displayName, count: count)
            }
        }) ?? []
    }
}
