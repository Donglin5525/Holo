import Foundation
import CoreData

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

/// T01 财务语义统一回归（方案 docs/finance/plans/2026-10-17-HoloAI深度洞察升级与财务试评/05 T01）
/// 同一笔对账调整：统计行源（AI 行源/云端快照/固定聚合）必须排除；余额视图必须保留。
/// 写测试宿主 App 库（模拟器本地，无 iCloud 账号）。
final class FinanceSemanticsUnificationTests: XCTestCase {
    func testAdjustmentExcludedFromStatisticsRowsButKeptInBalance() async throws {
        // 强制加载持久库，再清空交易实体（重跑幂等）
        _ = try? await FinanceRepository.shared.getAllTransactions()
        let bg = CoreDataStack.shared.newBackgroundContext()

        let normalAmount = Decimal(string: "66.60")!
        let adjustmentAmount = Decimal(string: "77.70")!
        var normalID: UUID?
        var adjustmentID: UUID?
        try bg.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            for obj in try bg.fetch(req) { bg.delete(obj) }
            try bg.save()

            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let today = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            @discardableResult
            func insert(amount: Decimal, adjustment: Bool) -> UUID {
                let obj = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: bg)
                let id = UUID()
                obj.setValue(id, forKey: "id")
                obj.setValue(today, forKey: "date")
                obj.setValue(amount, forKey: "amount")
                obj.setValue("expense", forKey: "type")
                obj.setValue(adjustment, forKey: "isReconciliationAdjustment")
                return id
            }
            normalID = insert(amount: normalAmount, adjustment: false)
            adjustmentID = insert(amount: adjustmentAmount, adjustment: true)
            try bg.save()
        }

        // 1. AI 行源（云端快照 finance.transactions / 财务工具 / 发现工具同源）排除调整行
        let rows = await HoloDefaultFinanceDataSource().queryRows(timeRange: nil, parameters: [:])
        let rowAmounts = rows.compactMap { row -> String? in
            if case .number(let n)? = row.fields["amount"] { return String(format: "%.2f", n) }
            return nil
        }
        let adjustmentStr = String(format: "%.2f", NSDecimalNumber(decimal: adjustmentAmount).doubleValue)
        let normalStr = String(format: "%.2f", NSDecimalNumber(decimal: normalAmount).doubleValue)
        XCTAssertFalse(rowAmounts.contains(adjustmentStr),
                       "统计行源不得含对账调整行（实际金额集 \(rowAmounts)）")
        XCTAssertTrue(rowAmounts.contains(normalStr), "统计行源应含普通支出行")

        // 2. 固定聚合统计读源排除调整行
        let cal = Calendar.current
        let stats = try await FinanceRepository.shared.getStatisticsTransactions(
            from: cal.startOfDay(for: Date()),
            to: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!)
        XCTAssertFalse(stats.contains { $0.id == adjustmentID },
                       "getStatisticsTransactions 不得返回对账调整行")
        XCTAssertTrue(stats.contains { $0.id == normalID }, "getStatisticsTransactions 应返回普通支出行")

        // 3. 余额视图（getAllTransactions）保留调整行——调整参与余额对账
        let all = try await FinanceRepository.shared.getAllTransactions()
        XCTAssertTrue(all.contains { $0.id == adjustmentID },
                      "余额视图必须保留对账调整行（否则对账失去意义）")

        // 4. 清理演练数据
        try bg.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            for obj in try bg.fetch(req) { bg.delete(obj) }
            try bg.save()
        }
    }
}
#endif
