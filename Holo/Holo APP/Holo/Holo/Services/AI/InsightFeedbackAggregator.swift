//
//  InsightFeedbackAggregator.swift
//  Holo
//
//  洞察反馈聚合器
//  将原始反馈聚合为弱信号和稳定偏好，更新 InsightPreferenceProfile
//

import Foundation
import CoreData
import os.log

final class InsightFeedbackAggregator {
    static let shared = InsightFeedbackAggregator()

    private static let logger = Logger(subsystem: "com.holo.app", category: "InsightFeedbackAggregator")

    /// 弱信号过期天数
    private let weakSignalExpiryDays = 30

    /// 升级为稳定偏好的最小同类反馈次数
    private let stableThreshold = 2

    private init() {}

    /// 聚合未消费的反馈，更新偏好画像
    /// - Parameter context: Core Data context
    func aggregate(in context: NSManagedObjectContext) {
        let feedbacks = MemoryInsightFeedback.fetchUnconsumed(in: context)
        guard !feedbacks.isEmpty else { return }

        Self.logger.info("开始聚合 \(feedbacks.count) 条未消费反馈")

        let profileService = InsightPreferenceProfileService.shared

        // 按类型分组处理
        var moduleAdjustments: [InsightModuleKey: (weight: Double, count: Int)] = [:]
        var patternPenalties: [String: (penalty: Double, count: Int, reason: String?)] = [:]
        var toneSignals: [InsightTonePreference: Int] = [:]
        var dataWrongCount = 0

        let now = Date()

        for feedback in feedbacks {
            // dataWrong 不进入画像
            if feedback.reasonType == FeedbackReasonType.dataWrong.rawValue {
                dataWrongCount += 1
                feedback.markConsumed()
                continue
            }

            // 处理准确性反馈
            if let accuracyStr = feedback.accuracyRating,
               let accuracy = AccuracyRating(rawValue: accuracyStr) {

                switch accuracy {
                case .accurate:
                    // 升权对应模块
                    if let moduleKey = feedback.module.flatMap({ InsightModuleKey(rawValue: $0) }) {
                        var adj = moduleAdjustments[moduleKey] ?? (weight: 0.1, count: 0)
                        adj.count += 1
                        moduleAdjustments[moduleKey] = adj
                    }

                case .inaccurate:
                    // 按原因分类处理
                    if let reasonStr = feedback.reasonType,
                       let reason = FeedbackReasonType(rawValue: reasonStr) {
                        switch reason {
                        case .dataWrong:
                            dataWrongCount += 1
                        case .priorityWrong:
                            if let moduleKey = feedback.module.flatMap({ InsightModuleKey(rawValue: $0) }) {
                                var adj = moduleAdjustments[moduleKey] ?? (weight: -0.1, count: 0)
                                adj.count += 1
                                moduleAdjustments[moduleKey] = adj
                            }
                        case .relationWrong:
                            if let pattern = feedback.patternType ?? feedback.module {
                                var pen = patternPenalties[pattern] ?? (penalty: 0.2, count: 0, reason: nil)
                                pen.count += 1
                                pen.reason = feedback.userCorrection
                                patternPenalties[pattern] = pen
                            }
                        case .suggestionWrong:
                            break // Phase 6 补充
                        case .toneWrong:
                            toneSignals[.gentle, default: 0] += 0 // 后续根据具体反馈调整
                        }
                    }
                }
            }

            // 处理价值感反馈
            if let valueStr = feedback.valueRating,
               let value = ValueRating(rawValue: valueStr) {
                if let moduleKey = feedback.module.flatMap({ InsightModuleKey(rawValue: $0) }) {
                    var adj = moduleAdjustments[moduleKey] ?? (weight: 0, count: 0)
                    if value == .useful {
                        adj.weight += 0.05
                    } else {
                        adj.weight -= 0.05
                    }
                    adj.count += 1
                    moduleAdjustments[moduleKey] = adj
                }
            }

            feedback.markConsumed()
        }

        // 保存反馈消费状态
        do {
            try context.save()
        } catch {
            Self.logger.error("反馈消费状态保存失败：\(error.localizedDescription)")
        }

        // 更新偏好画像
        profileService.updateProfile { profile in
            // 清理过期的弱信号
            profile.moduleWeights.removeAll { pref in
                !pref.isStable && isExpired(pref: pref, now: now)
            }
            profile.dislikedPatterns.removeAll { pref in
                !pref.isStable && isExpired(pref: pref, now: now)
            }

            // 应用模块权重调整
            for (module, adj) in moduleAdjustments {
                applyModuleWeight(
                    profile: &profile,
                    module: module,
                    weightDelta: adj.weight,
                    evidenceCount: adj.count,
                    now: now
                )
            }

            // 应用模式惩罚
            for (pattern, pen) in patternPenalties {
                applyPatternPenalty(
                    profile: &profile,
                    patternType: pattern,
                    penaltyDelta: pen.penalty,
                    evidenceCount: pen.count,
                    reason: pen.reason,
                    now: now
                )
            }
        }

        Self.logger.info("聚合完成：module=\(moduleAdjustments.count), pattern=\(patternPenalties.count), dataWrong=\(dataWrongCount)")
    }

    // MARK: - Private Helpers

    private func isExpired(pref: InsightModulePreference, now: Date) -> Bool {
        guard !pref.isStable else { return false }
        let calendar = Calendar.current
        let daysSinceUpdate = calendar.dateComponents([.day], from: pref.updatedAt, to: now).day ?? 0
        return daysSinceUpdate > weakSignalExpiryDays
    }

    private func isExpired(pref: InsightPatternPreference, now: Date) -> Bool {
        guard !pref.isStable else { return false }
        let calendar = Calendar.current
        let daysSinceUpdate = calendar.dateComponents([.day], from: pref.updatedAt, to: now).day ?? 0
        return daysSinceUpdate > weakSignalExpiryDays
    }

    private func applyModuleWeight(
        profile: inout InsightPreferenceProfile,
        module: InsightModuleKey,
        weightDelta: Double,
        evidenceCount: Int,
        now: Date
    ) {
        if let index = profile.moduleWeights.firstIndex(where: { $0.module == module }) {
            profile.moduleWeights[index].weight = clamp(
                profile.moduleWeights[index].weight + weightDelta,
                min: 0.0, max: 2.0
            )
            profile.moduleWeights[index].evidenceCount += evidenceCount
            profile.moduleWeights[index].updatedAt = now
            if profile.moduleWeights[index].evidenceCount >= stableThreshold {
                profile.moduleWeights[index].isStable = true
            }
        } else {
            let pref = InsightModulePreference(
                module: module,
                weight: clamp(1.0 + weightDelta, min: 0.0, max: 2.0),
                evidenceCount: evidenceCount,
                isStable: evidenceCount >= stableThreshold,
                updatedAt: now
            )
            profile.moduleWeights.append(pref)
        }
    }

    private func applyPatternPenalty(
        profile: inout InsightPreferenceProfile,
        patternType: String,
        penaltyDelta: Double,
        evidenceCount: Int,
        reason: String?,
        now: Date
    ) {
        if let index = profile.dislikedPatterns.firstIndex(where: { $0.patternType == patternType }) {
            profile.dislikedPatterns[index].penalty = clamp(
                profile.dislikedPatterns[index].penalty + penaltyDelta,
                min: 0.0, max: 1.0
            )
            profile.dislikedPatterns[index].evidenceCount += evidenceCount
            profile.dislikedPatterns[index].updatedAt = now
            if profile.dislikedPatterns[index].evidenceCount >= stableThreshold {
                profile.dislikedPatterns[index].isStable = true
            }
        } else {
            let pref = InsightPatternPreference(
                patternType: patternType,
                penalty: clamp(penaltyDelta, min: 0.0, max: 1.0),
                reason: reason,
                evidenceCount: evidenceCount,
                isStable: evidenceCount >= stableThreshold,
                updatedAt: now
            )
            profile.dislikedPatterns.append(pref)
        }
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }
}
