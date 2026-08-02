//
//  NetWorthSnapshotService.swift
//  Holo
//
//  净资产快照服务 - 每月记录净资产，用于绘制历史曲线
//

import Foundation
import CoreData
import OSLog

private let snapshotLogger = Logger(subsystem: "com.holo.app", category: "NetWorthSnapshot")

/// 净资产快照服务
///
/// 每月记录一条净资产快照（资产/负债/净值），用于在账户页展示净资产历史曲线。
/// 策略：App 启动时检查"当前月是否已有快照"，没有则补齐当月；首次升级时回填历史月份。
final class NetWorthSnapshotService {
    static let shared = NetWorthSnapshotService()
    private init() {}

    private var context: NSManagedObjectContext { FinanceRepository.shared.context }

    // MARK: - 公开方法

    /// 捕获当前净资产快照（当月已有则更新，无则新建）。幂等。
    @discardableResult
    func captureCurrentSnapshot() -> NetWorthSnapshot? {
        let now = Date()
        let monthStart = startOfMonth(now)

        // 查当月是否已有快照
        let existing = fetchSnapshot(monthStart: monthStart)
        let netWorth = FinanceRepository.shared.getTotalNetWorth()

        let snapshot = existing ?? NetWorthSnapshot(context: context)
        snapshot.id = existing?.id ?? UUID()
        snapshot.monthStart = monthStart
        snapshot.assets = NSDecimalNumber(decimal: netWorth.assets)
        snapshot.liabilities = NSDecimalNumber(decimal: netWorth.liabilities)
        snapshot.netWorth = NSDecimalNumber(decimal: netWorth.netWorth)
        if existing == nil { snapshot.createdAt = now }

        do {
            try context.save()
            return snapshot
        } catch {
            snapshotLogger.warning("净资产快照保存失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 首次升级时回填历史月份快照（最多回填 12 个月）。
    /// 用 getCumulativeBalance(before:) 估算历史净资产。
    func backfillHistory() {
        let calendar = Calendar.current
        let now = Date()
        let maxMonths = 12

        for i in stride(from: maxMonths, through: 1, by: -1) {
            guard let monthDate = calendar.date(byAdding: .month, value: -i, to: now) else { continue }
            let monthStart = startOfMonth(monthDate)
            // 跳过已有快照的月份
            if fetchSnapshot(monthStart: monthStart) != nil { continue }

            // 用该月末的累计余额估算净资产
            guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { continue }
            let estimatedNetWorth = FinanceRepository.shared.getCumulativeBalance(before: monthEnd)

            let snapshot = NetWorthSnapshot(context: context)
            snapshot.id = UUID()
            snapshot.monthStart = monthStart
            // 历史回填时无法精确拆分资产/负债，统一记到 netWorth
            if estimatedNetWorth >= 0 {
                snapshot.assets = NSDecimalNumber(decimal: estimatedNetWorth)
                snapshot.liabilities = NSDecimalNumber(value: 0)
            } else {
                snapshot.assets = NSDecimalNumber(value: 0)
                snapshot.liabilities = NSDecimalNumber(decimal: abs(estimatedNetWorth))
            }
            snapshot.netWorth = NSDecimalNumber(decimal: estimatedNetWorth)
            snapshot.createdAt = now
        }

        do {
            try context.save()
            snapshotLogger.info("净资产历史回填完成")
        } catch {
            snapshotLogger.warning("净资产历史回填失败：\(error.localizedDescription)")
        }
    }

    /// 获取所有快照（按月份升序），用于绘制曲线
    func fetchAllSnapshots() -> [NetWorthSnapshot] {
        let request = NetWorthSnapshot.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "monthStart", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// 获取最近 N 个月的快照
    func fetchRecentSnapshots(months: Int = 6) -> [NetWorthSnapshot] {
        let all = fetchAllSnapshots()
        guard all.count > months else { return all }
        return Array(all.suffix(months))
    }

    // MARK: - 内部

    private func startOfMonth(_ date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func fetchSnapshot(monthStart: Date) -> NetWorthSnapshot? {
        let request = NetWorthSnapshot.fetchRequest()
        request.predicate = NSPredicate(format: "monthStart == %@", monthStart as NSDate)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}
