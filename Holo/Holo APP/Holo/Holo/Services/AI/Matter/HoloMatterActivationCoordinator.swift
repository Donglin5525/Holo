//
//  HoloMatterActivationCoordinator.swift
//  Holo
//
//  Context Plan → Matter 激活协调器（方案 §11.1/§11.3/§13.1）
//
//  两步走：
//  1. prepare：激活前预检（同来源幂等命中 / 同名重复提示 / 正常新建）
//  2. confirm：用户校对标题与日期后确认，原子创建
//
//  不出现项目管理表单；标题默认取方案 goalSummary 的凝练，日期仅当方案给出确认日期时预填。
//

import Foundation
import os.log

@MainActor
final class HoloMatterActivationCoordinator {

    nonisolated enum Preparation: Equatable {
        /// 同一来源方案卡已激活过 → UI 直接显示「已加入」+ 查看。
        case alreadyActivated(matterID: UUID)
        /// 正常可新建；带建议标题与日期（用户可改）。
        case ready(proposedTitle: String, proposedTargetDate: Date?)
        /// 命中已有同名 Matter → UI 主按钮变「更新到已有」，次按钮「仍新建」。
        case possibleDuplicate(existingMatterID: UUID, existingTitle: String, proposedTitle: String, proposedTargetDate: Date?)
    }

    nonisolated struct ActivationError: Error, Equatable {
        let message: String
    }

    private let repository: HoloMatterRepository
    private let logger = Logger(subsystem: "com.holo.app", category: "MatterActivation")

    init(repository: HoloMatterRepository = .shared) {
        self.repository = repository
    }

    // MARK: - 预检

    /// 激活前预检。纯读操作，可在渲染方案卡时调用。
    func prepare(
        contextPlanMessageID: UUID,
        draft: HoloContextPlanDraft
    ) -> Preparation {
        // 幂等闸门：同来源已激活。
        if let existing = repository.findMatterActivated(from: contextPlanMessageID) {
            return .alreadyActivated(matterID: existing.id)
        }

        let proposedTitle = Self.proposeTitle(from: draft)
        let proposedDate = Self.proposeTargetDate(from: draft)

        // 重复检测：标准化标题相同且同为 active/completed 的既有 Matter（方案 §11.3）。
        let recent = repository.matters(lifecycles: [.active, .completed]).prefix(20)
        let normalized = Self.normalizeTitle(proposedTitle)
        for candidate in recent {
            if Self.normalizeTitle(candidate.title) == normalized {
                return .possibleDuplicate(
                    existingMatterID: candidate.id,
                    existingTitle: candidate.title,
                    proposedTitle: proposedTitle,
                    proposedTargetDate: proposedDate
                )
            }
        }

        return .ready(proposedTitle: proposedTitle, proposedTargetDate: proposedDate)
    }

    // MARK: - 确认激活

    /// 用户校对标题/日期并确认后调用。返回 receipt 供卡片原位回执。
    @discardableResult
    func confirm(
        contextPlanMessageID: UUID,
        userMessageID: UUID?,
        draft: HoloContextPlanDraft,
        confirmedTitle: String,
        confirmedTargetDate: Date?,
        existingMatterID: UUID?
    ) async throws -> HoloMatterActivationReceipt {
        let request = HoloMatterActivationRequest(
            draft: draft,
            contextPlanMessageID: contextPlanMessageID,
            userMessageID: userMessageID,
            confirmedTitle: confirmedTitle,
            confirmedTargetDate: confirmedTargetDate,
            existingMatterID: existingMatterID
        )
        let receipt = try await repository.activateMatter(request: request)

        // 立即构建确定性投影（AI 润色在 M2 对账链路补上）。
        let loops = repository.openLoops(matterID: receipt.matterID).map {
            HoloMatterAttentionPolicy.LoopInput(
                title: $0.title, state: $0.state, epistemic: $0.epistemic, targetDate: $0.targetDate
            )
        }
        if let matter = repository.matter(id: receipt.matterID) {
            let snapshot = HoloMatterProjectionBuilder.MatterSnapshot(
                matterID: matter.id,
                title: matter.title,
                revision: matter.revision,
                targetDate: matter.targetDate,
                phase: matter.phase
            )
            let projection = HoloMatterProjectionBuilder.buildDeterministic(from: snapshot, loops: loops)
            try? await repository.saveProjection(matterID: receipt.matterID, projection: projection)
        }

        // 任务先创建、Matter 后激活的补链（§8.3 顺序 2）：按同一来源消息的 V2 回执把既有任务链入。
        // 仅新建场景需要（幂等命中说明激活早已发生，创建时即时链已覆盖）；失败不影响激活结果。
        if receipt.created {
            let receipts = ContextPlanUserDefaultsReceipts().loadReceiptsV2()
            let _ = try? await HoloMatterLinkingCoordinator.linkExistingTasksFromReceipts(
                matterID: receipt.matterID,
                contextPlanMessageID: contextPlanMessageID,
                taskFinder: { TodoRepository.shared.findTask(by: $0) },
                aiSourceFinder: { TodoRepository.shared.findTaskByAISource(messageId: $0, itemId: $1) },
                receipts: receipts
            )
        }

        logger.info("Matter 激活完成：\(receipt.matterID.uuidString, privacy: .public) created=\(receipt.created)")
        return receipt
    }

    // MARK: - 标题/日期提案

    /// 从方案 goalSummary 凝练默认标题（截短，用户在确认弹层可改）。
    nonisolated static func proposeTitle(from draft: HoloContextPlanDraft) -> String {
        let raw = draft.goalSummary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return String(localized: "未命名事项") }
        return String(raw.prefix(24))
    }

    /// 方案 items 里用户选中的、日期最早且已确认的那条作为目标日期提案；未知即 nil（禁止默认今天）。
    nonisolated static func proposeTargetDate(from draft: HoloContextPlanDraft) -> Date? {
        draft.items
            .compactMap(\.confirmedDate)
            .filter { $0 > Date() }
            .min()
    }

    /// 标题标准化：去空白/标点、小写，供重复检测比较。
    nonisolated static func normalizeTitle(_ raw: String) -> String {
        String(
            raw.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        )
    }
}
