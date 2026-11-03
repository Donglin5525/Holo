import Foundation
import CoreData

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

/// S2 融合版台账生成器回归（方案 06 §2 台账三防线）：
/// 方向箭头行文 / 家族归并 / 分期全景+未知利率声明 / 已确认事实与已知风险段。
/// 写测试宿主 App 库（模拟器本地，无 iCloud 账号）。
final class FinanceEvidenceLedgerBuilderTests: XCTestCase {
    func testLedgerContainsArrowLinesFamilyMergeAndFacts() async throws {
        _ = try? await FinanceRepository.shared.getAllTransactions()
        let bg = CoreDataStack.shared.newBackgroundContext()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!

        try bg.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            for obj in try bg.fetch(req) { bg.delete(obj) }
            try bg.save()

            @discardableResult
            func insert(day: Int, hour: Int, minute: Int, amount: String, type: String,
                        category: String?, installmentIndex: Int16 = 0, installmentTotal: Int16 = 0,
                        note: String? = nil) -> NSManagedObject {
                let obj = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: bg)
                obj.setValue(UUID(), forKey: "id")
                obj.setValue(cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)), forKey: "date")
                obj.setValue(Decimal(string: amount)!, forKey: "amount")
                obj.setValue(type, forKey: "type")
                obj.setValue(note, forKey: "note")
                obj.setValue(Int16(installmentIndex), forKey: "installmentIndex")
                obj.setValue(Int16(installmentTotal), forKey: "installmentTotal")
                _ = category
                return obj
            }
            // 本期：餐饮家族两套一级（晚餐原生 + 餐饮/晚餐缺关系时用 null category 走「未分类」）
            // 分类关系挂接成本高，本测聚焦方向/分期/风险段，分类归并用 familyName 纯函数单测覆盖
            insert(day: 5, hour: 0, minute: 0, amount: "30.00", type: "expense", category: nil)          // 00:00 补记
            insert(day: 6, hour: 13, minute: 0, amount: "20.00", type: "expense", category: nil,
                   note: "咖啡和三明治（当日2笔合并）")                                                    // 合并行
            insert(day: 7, hour: 9, minute: 30, amount: "2000.00", type: "expense", category: nil)      // 大额
            insert(day: 8, hour: 10, minute: 0, amount: "5000.00", type: "income", category: nil)
            // 上期（2026-04，超出本期窗口）
            insert(day: -150, hour: 11, minute: 0, amount: "100.00", type: "expense", category: nil)
            // 分期：60期 × 2533.33，两期已发生 + 一期未来
            insert(day: 10, hour: 8, minute: 0, amount: "2533.33", type: "expense", category: nil, installmentIndex: 21, installmentTotal: 60)
            insert(day: -40, hour: 8, minute: 0, amount: "2533.33", type: "expense", category: nil, installmentIndex: 20, installmentTotal: 60)
            insert(day: 40, hour: 8, minute: 0, amount: "2533.33", type: "expense", category: nil, installmentIndex: 22, installmentTotal: 60) // 未来
            try bg.save()
        }

        guard let built = await FinanceEvidenceLedgerBuilder.build(now: now) else {
            return XCTFail("台账不应为空")
        }
        let ledger = built.ledger
        // 方向箭头行文：程序写死方向
        XCTAssertTrue(ledger.contains("从上期的"), "总览必须是「从上期X变为本期Y」箭头行文")
        XCTAssertTrue(ledger.contains("增加") || ledger.contains("减少"), "方向词必须由程序给出")
        // 分期全景 + 未知利率声明（不假设利率）
        XCTAssertTrue(ledger.contains("60期×2533.33"), "分期全景应含 60期×2533.33 组")
        XCTAssertTrue(ledger.contains("不得假设利息成本"), "必须声明利率未提供不得假设")
        // 已确认事实与已知风险段
        XCTAssertTrue(ledger.contains("【已确认事实与已知风险】"), "风险段必须在")
        XCTAssertTrue(ledger.contains("00:00"), "00:00 补记占比风险应在（本期1/4≥5%）")
        XCTAssertTrue(ledger.contains("当日多笔合并"), "合并行风险应在")
        XCTAssertTrue(ledger.contains("未来分期承诺"), "未来行风险应在")
        XCTAssertTrue(ledger.contains("不得宣称超预算"), "预算未提供声明应在")
        // financeSemantics
        XCTAssertEqual(built.semantics["futureRowCount"], "1")
        XCTAssertEqual(built.semantics["mergedRowCount"], "1")

        // familyName 家族归并纯函数
        XCTAssertEqual(FinanceEvidenceLedgerBuilder.familyName("晚餐"), "餐饮")
        XCTAssertEqual(FinanceEvidenceLedgerBuilder.familyName("餐饮"), "餐饮")
        XCTAssertEqual(FinanceEvidenceLedgerBuilder.familyName("交通"), "交通")

        // 清理
        try bg.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            for obj in try bg.fetch(req) { bg.delete(obj) }
            try bg.save()
        }
    }
}
#endif
