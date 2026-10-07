//
//  TaskAnalyticsService.swift
//  Holo
//
//  统计读取服务（方案 §9.2/§9.3）：在主上下文队列读取全部任务 → 唯一副本选择 →
//  纯值快照 → 纯聚合。请求带版本号，快速切换周期时旧响应不覆盖新选择。
//  读失败如实抛出，不返回空数组伪装无数据（方案 §9.4）。
//

import Foundation
import CoreData

@MainActor
final class TaskAnalyticsService {

    /// 注入惯例与 TodoRepository 一致：共享单例
    static let shared = TaskAnalyticsService()

    // MARK: - 请求版本（旧响应作废）

    private(set) var requestVersion: Int = 0

    /// 发起请求前自增并记住，回调比对（§9.3：旧请求结果丢弃）
    func nextRequestVersion() -> Int {
        requestVersion += 1
        return requestVersion
    }

    func isCurrent(_ version: Int) -> Bool {
        version == requestVersion
    }

    // MARK: - 聚合读取

    struct Result {
        let analytics: TaskAnalyticsSnapshot
        /// 明细展示用的记录映射（与聚合同一快照源）
        let recordsByID: [UUID: TaskRecordSnapshot]
    }

    /// 一次统计请求：同一 asOf（请求内冻结时钟）与唯一任务集合产出完整快照 + 记录映射
    func load(
        period: TaskAnalyticsPeriod,
        asOf: Date = Date(),
        calendar: Calendar = TaskAnalyticsPeriod.makeCalendar()
    ) throws -> Result {
        let snapshots = try TaskSnapshotReader.readAllSnapshots(in: CoreDataStack.shared.viewContext)
        let analytics = TaskAnalyticsAggregator.aggregate(
            snapshots: snapshots,
            period: period,
            asOf: asOf,
            calendar: calendar
        )
        return Result(
            analytics: analytics,
            recordsByID: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        )
    }
}
