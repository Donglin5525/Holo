//
//  SyncErrorLog.swift
//  Holo
//
//  iCloud 同步错误流水：只存本机（UserDefaults），最多保留最近 20 条，
//  供设置页「同步诊断」排查用户报障使用。
//

import Foundation

struct SyncErrorRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    /// 事件方向原始值：export（本机→iCloud）/ import（iCloud→本机）/ setup
    let direction: String
    /// 最深层 CloudKit 错误码（如 25 = quotaExceeded）；非 CloudKit 错误为 nil
    let ckErrorCode: Int?
    /// 错误原文（系统语言），仅诊断展示
    let message: String
}

enum SyncErrorLog {
    static let recordLimit = 20
    private static let storageKey = "iCloudSyncStatusService.errorHistory"

    static func load(from defaults: UserDefaults = .standard) -> [SyncErrorRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([SyncErrorRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// 追加一条并截断到上限，返回新列表
    @discardableResult
    static func append(_ record: SyncErrorRecord, to defaults: UserDefaults = .standard) -> [SyncErrorRecord] {
        var records = load(from: defaults)
        records.append(record)
        if records.count > recordLimit {
            records = Array(records.suffix(recordLimit))
        }
        save(records, to: defaults)
        return records
    }

    static func save(_ records: [SyncErrorRecord], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
