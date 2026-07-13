//
//  HoloMemoryDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.3 生产记忆数据源
//  包裹真实 Store（HoloLongTermMemoryStore / HoloEpisodicMemoryStore），
//  转为 MemoryTool 所需的中性数据结构。三个 Store 均为同步读取，这里 async 适配协议。
//  本文件依赖真实记忆系统，仅随 app 编译（xcodebuild），不进入 standalone 测试。
//

import Foundation

struct HoloDefaultMemoryDataSource: HoloMemoryDataSource {

    /// 长期确认记忆（confirmed + silentlyAccepted，Store 已排除过期）。
    func longTermConfirmed() async -> [HoloMemoryToolRecord] {
        HoloLongTermMemoryStore.queryConfirmed().map {
            HoloMemoryToolRecord(id: $0.id, title: $0.title, summary: $0.displaySummary, occurredAt: $0.updatedAt)
        }
    }

    /// 情景活跃记忆（active + suggested）。
    func episodicActive() async -> [HoloMemoryToolRecord] {
        HoloEpisodicMemoryStore.shared.queryActive().map {
            HoloMemoryToolRecord(id: $0.id, title: $0.title, summary: $0.summary,
                                 occurredAt: $0.lastHitAt ?? $0.updatedAt)
        }
    }

    /// 生效中的抑制规则（Store 已自动过滤过期）。
    func suppressionRules() async -> [HoloMemoryToolSuppression] {
        HoloEpisodicMemoryStore.shared.loadSuppressionRules().map {
            HoloMemoryToolSuppression(id: $0.id, originalSummary: $0.originalMemorySummary)
        }
    }
}
