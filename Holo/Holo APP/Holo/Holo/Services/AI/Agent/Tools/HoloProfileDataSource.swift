//
//  HoloProfileDataSource.swift
//  Holo
//

import Foundation

struct HoloDefaultProfileDataSource: HoloProfileDataSource {

    func snapshot() async -> HoloProfileToolSnapshot? {
        await MainActor.run {
            // 优先用结构化 snapshot，但即使结构化为空也要保留 rawMarkdown 供工具兜底
            if let profile = HoloProfileService.shared.loadSnapshot() {
                guard !profile.isEmpty else { return nil }
                return HoloProfileToolSnapshot(
                    preferredName: profile.preferredName,
                    language: profile.language,
                    timezone: profile.timezone,
                    city: profile.city,
                    profession: profile.profession,
                    communicationStyle: profile.communicationStyle,
                    currentFocus: profile.currentFocus,
                    lifeContext: profile.lifeContext,
                    healthHabitContext: profile.healthHabitContext,
                    sensitiveBoundaries: profile.sensitiveBoundaries,
                    rawMarkdown: profile.rawMarkdown
                )
            }
            // Feature flag 关闭时，从 raw markdown 构造（仅含原文，无结构化字段）
            let raw = HoloProfileService.shared.loadProfile()
            guard !raw.isEmpty else { return nil }
            return HoloProfileToolSnapshot(
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
                rawMarkdown: raw
            )
        }
    }
}
