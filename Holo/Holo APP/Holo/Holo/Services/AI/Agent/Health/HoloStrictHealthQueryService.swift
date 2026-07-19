//
//  HoloStrictHealthQueryService.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 3（§7.1，修 P0-4）
//  Agent 专用严格健康查询：HealthKit 回调 error 必须显式分类，
//  锁屏（errorDatabaseInaccessible）不得伪装成 0 步、0 睡眠或空样本。
//  不改变现有 UI best-effort 读取语义（HealthRepository 旧方法保持原样回落）。
//

import Foundation
import HealthKit

/// 严格健康查询错误（§7.1）。
enum HoloHealthQueryError: Error, Equatable, Sendable {
    /// HealthKit 权限被拒绝（需用户授权，不可自动恢复）
    case authorizationDenied
    /// 暂时性系统/网络错误（可恢复）
    case recoverable(String)
}

/// 严格健康查询结果（§7.1）：真实零值走 `.value`，无样本走 `.noData`，
/// 锁屏走 `.waitingForUnlock`（调用方必须等待解锁，禁止当作 0/空）。
enum HoloHealthQueryOutcome<Value: Sendable>: Sendable {
    /// 查询成功且有数据（含真实零值，调用方可见覆盖信息）
    case value(Value)
    /// 查询成功但无样本
    case noData
    /// 设备锁定，HealthKit 数据库暂不可读（HKError.errorDatabaseInaccessible）
    case waitingForUnlock
    /// 权限拒绝或暂时性错误
    case unavailable(HoloHealthQueryError)
}

extension HoloHealthQueryOutcome: Equatable where Value: Equatable {}

extension HoloHealthQueryOutcome {
    /// 仅对 `.value` 应用变换，其余分支原样传递。
    func map<Other: Sendable>(_ transform: (Value) -> Other) -> HoloHealthQueryOutcome<Other> {
        switch self {
        case .value(let value): return .value(transform(value))
        case .noData: return .noData
        case .waitingForUnlock: return .waitingForUnlock
        case .unavailable(let error): return .unavailable(error)
        }
    }
}

/// HK 回调 error 分类器（§7.1）：把 HealthKit 错误映射为严格 outcome 分支。
enum HoloStrictHealthQueryService {

    /// HK 查询回调的 error → 严格 outcome；nil 表示无错误可继续解析样本。
    static func failure<T: Sendable>(from error: Error?) -> HoloHealthQueryOutcome<T>? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == HKError.errorDomain {
            if nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
                return .waitingForUnlock
            }
            if nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
                || nsError.code == HKError.Code.errorAuthorizationNotDetermined.rawValue {
                return .unavailable(.authorizationDenied)
            }
        }
        return .unavailable(.recoverable(nsError.localizedDescription))
    }

    /// 逐日严格结果聚合为范围结果（§7.1）：
    /// 任一天锁屏 → 整体 waitingForUnlock；任一天不可用 → 整体 unavailable（首个）；
    /// 全部无样本 → noData；否则返回有数据的天（真实零值天保留）。
    static func fold<Record: Sendable>(
        _ daily: [HoloHealthQueryOutcome<Record>]
    ) -> HoloHealthQueryOutcome<[Record]> {
        var records: [Record] = []
        for outcome in daily {
            switch outcome {
            case .waitingForUnlock:
                return .waitingForUnlock
            case .unavailable(let error):
                return .unavailable(error)
            case .value(let record):
                records.append(record)
            case .noData:
                continue
            }
        }
        return records.isEmpty ? .noData : .value(records)
    }
}
