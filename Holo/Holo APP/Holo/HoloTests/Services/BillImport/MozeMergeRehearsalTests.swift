import Foundation
import CoreData

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

/// Moze→Holo 融合导入演练（2026-10-17 代理拍板版）
/// 通道：进程内直调 scanCSV/streamImportTransactions，写测试宿主 App 库（模拟器本地，
/// 无 iCloud 账号，不触 CloudKit；真机日用库零接触）。
/// 演练流：清库 → 基线导入 HOLO_2026-10-12.csv（复刻东林真机账）→ 正式版
/// moze_cleaned.csv 导入 → 终态对账（总数/154个月逐分/指纹唯一/分期组/未来行）。
/// CSV 路径默认从 #filePath 推导（~/Desktop/moze-holo-merge），可用 TEST_RUNNER_MOZE_CSV
/// 与 TEST_RUNNER_MOZE_BASELINE 覆盖（真机导入日二次对账复用本测试）。
final class MozeMergeRehearsalTests: XCTestCase {
    func testMozeMergeRehearsal() async throws {
        try await MozeMergeRehearsal.run { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    }
}
#endif

enum MozeMergeRehearsal {
    typealias Failure = (_ message: String, _ file: StaticString, _ line: UInt) -> Void

    // 演练口径冻结值（与 拍板-2026-10-17.md / report/07 恒等式一致）
    static let expectedBaselineRows = 708      // HOLO_2026-10-12.csv 数据行
    static let expectedBaselineKept = 698      // 同指纹压行后入库（10-12 演练实值）
    static let expectedBaselineCompressed = 10
    static let expectedMozeRows = 12442        // moze_cleaned.csv 数据行（12,437 + 拍板②导入5）
    static let expectedFinalTotal = 13140      // 698 + 12442
    static let futureCutoff: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23, minute: 59, second: 59))!
    }()
    static let expectedFutureRows = 83         // moze 44 + baseline 39（相对 2026-10-17）

    static func run(using fail: @escaping Failure) async throws {
        let env = ProcessInfo.processInfo.environment
        let repoRoot = (0..<6).reduce(URL(fileURLWithPath: #filePath).deletingLastPathComponent()) { url, _ in
            url.deletingLastPathComponent()
        }
        let desktop = repoRoot.deletingLastPathComponent().deletingLastPathComponent()
        let mozeURL = URL(fileURLWithPath: env["MOZE_CSV"] ?? desktop.appendingPathComponent("moze-holo-merge/moze_cleaned.csv").path)
        let baselineURL = URL(fileURLWithPath: env["MOZE_BASELINE"] ?? desktop.appendingPathComponent("moze-holo-merge/HOLO_2026-10-12.csv").path)
        guard FileManager.default.fileExists(atPath: mozeURL.path) else {
            fail("找不到 moze_cleaned.csv：\(mozeURL.path)", #filePath, #line); return
        }
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            fail("找不到基线 HOLO_2026-10-12.csv：\(baselineURL.path)", #filePath, #line); return
        }

        // 1. 触发仓储初始化加载持久库（防「no stores loaded」时清理空转），再清空测试宿主库交易（模拟器本地演练库，重跑幂等）
        _ = try? await FinanceRepository.shared.getAllTransactions()
        let bg = CoreDataStack.shared.newBackgroundContext()
        try bg.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            for obj in try bg.fetch(req) { bg.delete(obj) }
            try bg.save()
        }

        // 2. 基线导入（复刻真机账本）
        let baselineSummary = try DataImportService.shared.scanCSV(url: baselineURL)
        check(baselineSummary.totalRows == expectedBaselineRows,
              "基线扫描应 \(expectedBaselineRows) 行，实际 \(baselineSummary.totalRows)", fail)
        check(baselineSummary.parseableCount == expectedBaselineRows,
              "基线应全部可解析，实际 parseable=\(baselineSummary.parseableCount) failed=\(baselineSummary.failedCount)", fail)
        let baselineResult = await FinanceRepository.shared.streamImportTransactions(
            url: baselineURL,
            fieldMapping: baselineSummary.fieldMapping,
            detectedTemplate: baselineSummary.detectedTemplate,
            headers: baselineSummary.headers,
            expectedTotalRows: baselineSummary.totalRows,
            duplicatePolicy: .skipDuplicates,
            billInfo: baselineSummary.billInfo,
            installmentAssignments: baselineSummary.installmentInfo?.assignments ?? [:]
        ) { _, _ in }
        check(baselineResult.successCount == expectedBaselineKept,
              "基线导入应成功 \(expectedBaselineKept)，实际 \(baselineResult.successCount)", fail)
        check(baselineResult.skippedDuplicateCount == expectedBaselineCompressed,
              "基线压行应 \(expectedBaselineCompressed)，实际 \(baselineResult.skippedDuplicateCount)", fail)
        check(baselineResult.failedItems.isEmpty, "基线导入不应有失败行：\(baselineResult.failedItems.prefix(3))", fail)

        // 3. 正式版导入
        let mozeSummary = try DataImportService.shared.scanCSV(url: mozeURL)
        check(mozeSummary.totalRows == expectedMozeRows,
              "moze_cleaned 扫描应 \(expectedMozeRows) 行，实际 \(mozeSummary.totalRows)", fail)
        check(mozeSummary.parseableCount == expectedMozeRows,
              "moze_cleaned 应全部可解析，实际 parseable=\(mozeSummary.parseableCount) failed=\(mozeSummary.failedCount)", fail)
        let mozeResult = await FinanceRepository.shared.streamImportTransactions(
            url: mozeURL,
            fieldMapping: mozeSummary.fieldMapping,
            detectedTemplate: mozeSummary.detectedTemplate,
            headers: mozeSummary.headers,
            expectedTotalRows: mozeSummary.totalRows,
            duplicatePolicy: .skipDuplicates,
            billInfo: mozeSummary.billInfo,
            installmentAssignments: mozeSummary.installmentInfo?.assignments ?? [:]
        ) { _, _ in }
        check(mozeResult.successCount == expectedMozeRows,
              "moze_cleaned 导入应成功 \(expectedMozeRows)（一行不吞），实际 \(mozeResult.successCount)", fail)
        check(mozeResult.skippedDuplicateCount == 0,
              "moze_cleaned 不应有跳过重复（离线已对账），实际 \(mozeResult.skippedDuplicateCount)", fail)
        check(mozeResult.failedItems.isEmpty, "moze_cleaned 不应有失败行：\(mozeResult.failedItems.prefix(3))", fail)

        // 4. 终态对账
        let expected = try expectedMonthlySums(baselineURL: baselineURL, mozeURL: mozeURL, fail: fail)
        try bg.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            req.includesSubentities = false
            let all = try bg.fetch(req)
            check(all.count == expectedFinalTotal,
                  "终态交易应 \(expectedFinalTotal)，实际 \(all.count)", fail)

            // 154 个月逐分对平（expense/income 分开）
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var actualExpense: [String: Decimal] = [:]
            var actualIncome: [String: Decimal] = [:]
            var futureCount = 0
            var installmentTotals: [Int: Int] = [:]
            var fingerprints: [String: Int] = [:]
            for case let txn as NSManagedObject in all {
                let date = txn.value(forKey: "date") as! Date
                let amount = txn.value(forKey: "amount") as! Decimal
                let type = txn.value(forKey: "type") as! String
                let key = monthKey(date, cal)
                if type == "expense" { actualExpense[key, default: 0] += amount }
                else { actualIncome[key, default: 0] += amount }
                if date > futureCutoff { futureCount += 1 }
                if let total = txn.value(forKey: "installmentTotal") as? Int {
                    installmentTotals[total, default: 0] += 1
                }
                if let fp = txn.value(forKey: "importFingerprint") as? String {
                    fingerprints[fp, default: 0] += 1
                }
            }
            check(futureCount == expectedFutureRows,
                  "未来行（>2026-10-17）应 \(expectedFutureRows)，实际 \(futureCount)", fail)
            check(installmentTotals[60] == 60,
                  "model3 车贷 60 期应成组 60 行，实际 \(installmentTotals[60] ?? 0)", fail)
            let dupFps = fingerprints.values.filter { $0 > 1 }.count
            check(dupFps == 0, "入库指纹应全量唯一，重复指纹组 \(dupFps)", fail)

            var monthsChecked = 0
            for (key, exp) in expected {
                let actE = actualExpense[key] ?? 0
                let actI = actualIncome[key] ?? 0
                check(actE == exp.expense && actI == exp.income,
                      "月 \(key) 不平：expense 库=\(actE) 期望=\(exp.expense)；income 库=\(actI) 期望=\(exp.income)", fail)
                monthsChecked += 1
            }
            check(monthsChecked >= 154, "应至少对平 154 个月，实际 \(monthsChecked)", fail)
            // 收入月份数只比非零月（期望表按月并集生成，43 个月收入为 0 属正常）
            let expectedIncomeMonths = expected.values.filter { $0.income > 0 }.count
            check(actualIncome.count == expectedIncomeMonths,
                  "收入月份数应一致：库 \(actualIncome.count) 期望非零 \(expectedIncomeMonths)", fail)
            check(actualExpense.count == expected.values.filter { $0.expense > 0 }.count,
                  "支出月份数应一致：库 \(actualExpense.count)", fail)
        }
        print("Moze 合并演练通过：基线 698+10 压行、正式版 12,442 零吞、终态 13,140、154+ 个月逐分对平、指纹唯一、车贷 60 期成组、未来 83 行")
    }

    // MARK: - 预期月度合计（从两份 CSV 自算；基线按 App 指纹同口径压行）

    struct MonthSum { var expense: Decimal; var income: Decimal }

    static func expectedMonthlySums(baselineURL: URL, mozeURL: URL, fail: Failure) throws -> [String: MonthSum] {
        var result: [String: MonthSum] = [:]
        func add(_ key: String, _ type: String, _ amount: Decimal) {
            var s = result[key] ?? MonthSum(expense: 0, income: 0)
            if type == "支出" { s.expense += amount } else { s.income += amount }
            result[key] = s
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm"
        df.timeZone = cal.timeZone

        // 基线：同指纹（App 同口径）只留首行——与导入压行语义一致
        var seen = Set<String>()
        var baselineDropped = 0
        for row in try parseCSV(baselineURL) {
            guard let date = df.date(from: "\(row["日期"]!) \(row["时间"]!)") else {
                fail("基线日期不可解析：\(row["日期"]!)", #filePath, #line); continue
            }
            let amount = Decimal(string: row["金额"]!)!
            let fp = DataImportService.makeFingerprint(
                date: date, amount: amount,
                type: row["类型"]! == "支出" ? .expense : .income,
                primaryCategory: row["一级分类"]!, subCategory: row["二级分类"]!,
                accountName: row["账户"]!,
                installment: nil)
            if seen.contains(fp) { baselineDropped += 1; continue }
            seen.insert(fp)
            add(monthKey(date, cal), row["类型"]!, amount)
        }
        check(baselineDropped == expectedBaselineCompressed,
              "测试内基线压行推演应 \(expectedBaselineCompressed)，实际 \(baselineDropped)（指纹口径漂移）", fail)

        for row in try parseCSV(mozeURL) {
            guard let date = df.date(from: "\(row["日期"]!) \(row["时间"]!)") else {
                fail("moze 日期不可解析：\(row["日期"]!)", #filePath, #line); continue
            }
            add(monthKey(date, cal), row["类型"]!, Decimal(string: row["金额"]!)!)
        }
        return result
    }

    static func parseCSV(_ url: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [[String: String]] = []
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        let headers = lines[0].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            var row: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < cells.count { row[h] = cells[i] }
            rows.append(row)
        }
        return rows
    }

    static func monthKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func check(_ condition: Bool, _ message: String, _ fail: Failure,
                      file: StaticString = #filePath, line: UInt = #line) {
        if !condition { fail(message, file, line) }
    }
}
