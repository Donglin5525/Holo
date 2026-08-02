//
//  NetWorthSnapshot.swift
//  Holo
//
//  净资产月末快照 - 用于绘制净资产历史曲线
//

import Foundation
import CoreData

/// 净资产快照：每月记录一条，用于展示净资产随时间变化的趋势曲线。
@objc(NetWorthSnapshot)
public class NetWorthSnapshot: NSManagedObject {

    @NSManaged public var id: UUID
    /// 快照所属月份的第一天（按自然月对齐，用于按月去重）
    @NSManaged public var monthStart: Date
    @NSManaged public var assets: NSDecimalNumber
    @NSManaged public var liabilities: NSDecimalNumber
    @NSManaged public var netWorth: NSDecimalNumber
    @NSManaged public var createdAt: Date

    var assetsDecimal: Decimal { assets as Decimal }
    var liabilitiesDecimal: Decimal { liabilities as Decimal }
    var netWorthDecimal: Decimal { netWorth as Decimal }
}

extension NetWorthSnapshot {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<NetWorthSnapshot> {
        return NSFetchRequest<NetWorthSnapshot>(entityName: "NetWorthSnapshot")
    }
}

extension NetWorthSnapshot: Identifiable {}
extension NetWorthSnapshot: @unchecked Sendable {}
