//
//  ThoughtSemanticCalibration.swift
//  Holo
//
//  决策阈值配置（语义图谱 V3 Phase 3，方案 §10.2）
//
//  数值阈值不散落代码：统一于此带版本管理。当前种子配置仅用于候选召回；
//  召回优化配置可由开发集校准后固化为带版本的 ThoughtSemanticCalibration.json——
//  未校准时使用种子召回参数；正式归属由 V2 双侧原文证据协议核对，不以向量分数直接写入。
//

import Foundation

nonisolated struct ThoughtSemanticCalibration: Codable, Equatable {

    /// 配置版本与适配的 embedding 模型；任一不符即视为未校准
    var calibrationVersion: Int
    var modelVersion: String

    /// centroid/近邻召回的 cosine 下限（低于此值不进入候选）
    var recallMinCosine: Float
    /// 第一与第二候选的 margin 下限（区分度不足=歧义）
    var marginMinDelta: Float
    /// 近邻投票的最小票数
    var neighborVoteMinCount: Int
    /// 影子记录有效期（天）；过期候选由后续 compact 清理
    var candidateExpiryDays: Int
    /// topic-name 候选标题上限（UTF-16，Phase 5 消费）
    var suggestedTitleMaxUTF16: Int

    /// 未完成召回质量校准时的起始参数；不作为直接归属的证据。
    static let seed = ThoughtSemanticCalibration(
        calibrationVersion: 1,
        modelVersion: ThoughtSemanticStore.defaultModelVersion,
        recallMinCosine: 0.55,
        marginMinDelta: 0.05,
        neighborVoteMinCount: 2,
        candidateExpiryDays: 14,
        suggestedTitleMaxUTF16: 12
    )

    /// 当前生效配置：优先加载 Bundle 内 ThoughtSemanticCalibration.json；
    /// 无文件/版本不匹配 → 使用种子召回参数；返回值用于标记尚未做真实留出集校准。
    static func current(bundle: Bundle = .main) -> (config: ThoughtSemanticCalibration, isCalibrated: Bool) {
        if let url = bundle.url(forResource: "ThoughtSemanticCalibration", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(ThoughtSemanticCalibration.self, from: data),
           loaded.modelVersion == ThoughtSemanticStore.defaultModelVersion {
            return (loaded, true)
        }
        return (seed, false)
    }
}
