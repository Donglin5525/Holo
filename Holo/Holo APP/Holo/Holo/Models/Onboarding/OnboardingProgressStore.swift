//
//  OnboardingProgressStore.swift
//  Holo
//
//  V1 轻量引导之后所有「一次性引导」的统一落盘（首页导览、各页首访欢迎条等）。
//  每个引导只维护一个 UserDefaults Bool，key 集中在此注册，避免散落各视图。
//  与 LightweightOnboardingSettings（首启 4 页全屏引导）分开维护，互不依赖。
//

import Foundation

enum OnboardingProgressStore {

    /// 首页三步导览（V1 引导结束后立即播放，或设置页手动重看）
    static let homeCoachTourKey = "holo_coach_home_tour_v1_seen"

    /// 记忆长廊首访欢迎条
    static let memoryGalleryWelcomeKey = "holo_welcome_memory_gallery_v1_seen"

    /// 首页「第一步行动卡」手动关闭态（产生首条记录的自动消失不落盘，仅记录用户点 ×）
    static let firstStepCardDismissedKey = "holo_first_step_card_dismissed_v1"

    /// 首次记录庆祝已展示（一次即封，老用户不触发）
    static let firstRecordCelebrationShownKey = "holo_first_record_celebration_shown_v1"

    static func hasSeen(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func markSeen(_ key: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
