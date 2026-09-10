//
//  ThoughtSemanticCalibration.swift
//  Holo
//
//  决策阈值配置（语义图谱 V3 Phase 3，方案 §10.2）
//
//  数值阈值不散落代码：统一于此带版本管理。当前为仅供 shadow 的种子配置；
//  生产配置须由开发集校准后固化为带版本的 ThoughtSemanticCalibration.json——
//  文件缺失或 modelVersion 不匹配时，自动可见关联强制关闭（只留 shadow/搜索候选）。
//

import Foundation

struct ThoughtSemanticCalibration: Codable, Equatable {

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

    /// 种子配置（仅供 shadow；生产可见关联开启前必须由真实留出集校准替换）
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
    /// 无文件/版本不匹配 → 回落种子配置并将 isCalibrated 置 false（强制 shadow）。
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
