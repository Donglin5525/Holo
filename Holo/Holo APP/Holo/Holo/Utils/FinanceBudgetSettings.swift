//
//  FinanceBudgetSettings.swift
//  Holo
//
//  严格预算模式开关（账户粒度）
//
//  开关按账户独立开启，开启时间（Date）同时是该账户的结转起算点：
//  开启当期不受开启前超支影响、当期超支从下一期开始传导；关闭后立即恢复原额度。
//  存储格式：UserDefaults JSON [UUID字符串: 开启时间戳]。
//

import SwiftUI
import Combine

@MainActor
final class FinanceBudgetSettings: ObservableObject {

    // MARK: - Singleton

    static let shared = FinanceBudgetSettings()

    // MARK: - Keys

    private nonisolated static let enabledAtByAccountKey = "financeBudgetStrictModeEnabledAtByAccount"

    // MARK: - Properties

    /// 各账户的开启时间（accountId → 开启时间）
    @Published private(set) var enabledAtByAccount: [UUID: Date]

    // MARK: - Init

    private init() {
        enabledAtByAccount = Self.loadStored()
    }

    // MARK: - Queries

    func isEnabled(for accountId: UUID) -> Bool {
        enabledAtByAccount[accountId] != nil
    }

    func enabledAt(for accountId: UUID) -> Date? {
        enabledAtByAccount[accountId]
    }

    // MARK: - Actions

    func enable(for accountId: UUID) {
        enabledAtByAccount[accountId] = Date()
        persist()
    }

    func disable(for accountId: UUID) {
        enabledAtByAccount.removeValue(forKey: accountId)
        persist()
    }

    // MARK: - Storage

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: enabledAtByAccount.map {
            ($0.key.uuidString, $0.value.timeIntervalSince1970)
        })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.enabledAtByAccountKey)
            // 同步上行 iCloud：开关时间同时是结转起算点，影响预算数字，卸载即丢不可接受
            if let json = String(data: data, encoding: .utf8) {
                UserPreferenceRepository.shared.set(json, forKey: Self.cloudBackupKey)
            }
        }
    }

    // MARK: - iCloud 备份恢复

    nonisolated static let cloudBackupKey = "financeBudget.strictMode.v1"

    /// 本次安装没动过开关时，从云端快照恢复（重装找回场景）
    @discardableResult
    func restoreFromCloudIfClean() -> Bool {
        if UserDefaults.standard.data(forKey: Self.enabledAtByAccountKey) != nil {
            // 本地已有数据：老用户首次升级且云端尚无快照时，主动建立云备份
            if UserPreferenceRepository.shared.value(forKey: Self.cloudBackupKey) == nil,
               let data = UserDefaults.standard.data(forKey: Self.enabledAtByAccountKey),
               let json = String(data: data, encoding: .utf8) {
                UserPreferenceRepository.shared.set(json, forKey: Self.cloudBackupKey)
            }
            return false
        }
        guard let json = UserPreferenceRepository.shared.value(forKey: Self.cloudBackupKey),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return false
        }
        var restored: [UUID: Date] = [:]
        for (uuidString, interval) in raw {
            guard let uuid = UUID(uuidString: uuidString) else { continue }
            restored[uuid] = Date(timeIntervalSince1970: interval)
        }
        guard !restored.isEmpty else { return false }
        enabledAtByAccount = restored
        return true
    }

    private nonisolated static func loadStored() -> [UUID: Date] {
        guard let data = UserDefaults.standard.data(forKey: enabledAtByAccountKey),
              let raw = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { uuidString, interval in
            guard let uuid = UUID(uuidString: uuidString) else { return nil }
            return (uuid, Date(timeIntervalSince1970: interval))
        })
    }
}
