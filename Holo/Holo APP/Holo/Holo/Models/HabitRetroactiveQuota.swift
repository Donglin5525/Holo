//
//  HabitRetroactiveQuota.swift
//  Holo
//
//  习惯补签的额度记账（本地）
//  规则：Plus 无限补签；免费用户每自然月 3 次（所有习惯共享），每月 1 日自动重置
//  习惯数据本就存于本地 Core Data，补签配额同样本地记账即可，无需服务端校验
//

import Foundation

// MARK: - 策略常量

enum HabitRetroactivePolicy {
    /// 免费用户每自然月补签次数（全局所有习惯共享）
    static let freeMonthlyQuota = 3
    /// 可补签的回溯窗口：仅最近 N 天内的过去日期（不含今天）
    static let lookbackDays = 7
}

// MARK: - 额度记账

/// 免费补签额度记账。key 内嵌当前月份（yyyy-MM），跨月读取自动落到新 key，
/// 旧月计数自然失效，无需清理任务。
enum HabitRetroactiveQuota {

    private static let keyPrefix = "habitRetroactiveQuota.used."

    private static var currentKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return keyPrefix + formatter.string(from: Date())
    }

    /// 本月已用补签次数
    static func usedCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: currentKey)
    }

    /// 本月剩余免费次数
    static func remaining(defaults: UserDefaults = .standard) -> Int {
        max(HabitRetroactivePolicy.freeMonthlyQuota - usedCount(defaults: defaults), 0)
    }

    /// 消耗一次额度（仅写入成功后调用）
    static func consume(defaults: UserDefaults = .standard) {
        defaults.set(usedCount(defaults: defaults) + 1, forKey: currentKey)
    }

    /// 调试/测试用：清空当月计数
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: currentKey)
    }
}
