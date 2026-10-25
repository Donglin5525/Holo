//
//  HoloMemoryCenterRollout.swift
//  Holo
//
//  「Holo 记忆」管理页灰度开关（方案 §14.3 / M11）
//
//  2026-10-25 起**默认开启**（东林拍板随版对用户可见）；保留回退位：
//  `holo_memory_center_disabled_v1` = true 时退回旧「设置中转页」入口。
//  回退只影响 UI 入口，不回退用户已生效的控制结果。
//

import Foundation

enum HoloMemoryCenterRollout {
    private static let disabledKey = "holo_memory_center_disabled_v1"

    /// 新管理页是否启用（发版默认开；回退位仅供诊断/应急）。
    static var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: disabledKey)
    }

    /// 仅供诊断页/灰度演练回退使用；不提供面向用户的开关 UI。
    static func setDisabled(_ disabled: Bool) {
        UserDefaults.standard.set(disabled, forKey: disabledKey)
    }
}
