import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

final class InstallmentImportTests: XCTestCase {
    func testInstallmentImport() throws {
        try InstallmentImportStandaloneTests.run { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    }
}
#else
@main
private struct HoloStandaloneLauncher {
    static func main() throws {
        try InstallmentImportStandaloneTests.run { message, file, line in
            fatalError("\(message) [\(file):\(line)]")
        }
    }
}
#endif

struct InstallmentImportStandaloneTests {

    typealias Failure = (_ message: String, _ file: StaticString, _ line: UInt) -> Void

    static func run(using fail: @escaping Failure) throws {
        testNoteSignalParsing(fail: fail)
        testColumnValueParsing(fail: fail)
        testStrongGroupingFull(fail: fail)
        testStrongGroupingPartial(fail: fail)
        testStrongGroupingIndexConflictDegrades(fail: fail)
        testDifferentAmountsFormSeparateGroups(fail: fail)
        testTailDifferenceMerges(fail: fail)
        testTotalOnlyColumnInfersIndexByDate(fail: fail)
        testDateOrderValidation(fail: fail)
        testSingleSignalRowAndBadTotal(fail: fail)
        testSuspectedSequenceDetection(fail: fail)
        testConfirmedSuspectedAssignments(fail: fail)
        testFingerprintInstallmentSuffix(fail: fail)
        try testScanCSVRoundTrip(fail: fail)
        print("Installment import passed: 备注写法、列值解析、强信号归组、冲突降级、尾差合并、序列疑似组、指纹后缀、HOLO 往返")
    }

    // MARK: - Helpers

    private static func check(_ condition: Bool, _ message: String, _ fail: Failure,
                              file: StaticString = #filePath, line: UInt = #line) {
        if !condition { fail(message, file, line) }
    }

    private static let calendar = Calendar.current

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func candidate(
        row: Int, _ year: Int, _ month: Int, _ day: Int,
        amount: Decimal = 333, account: String = "信用卡",
        signal: InstallmentImportRecognizer.Signal? = nil
    ) -> InstallmentImportRecognizer.CandidateRow {
        InstallmentImportRecognizer.CandidateRow(
            row: row, date: date(year, month, day), type: .expense,
            amount: amount, accountName: account, signal: signal
        )
    }

    // MARK: - 备注文本信号

    private static func testNoteSignalParsing(fail: Failure) {
        let cases: [(String, Int?, Int?)] = [
            ("信用卡还款 3/12期", 3, 12),
            ("第3/12期", 3, 12),
            ("第3期/共12期", 3, 12),
            ("第3期共12期", 3, 12),
            ("[分期 3/12]", 3, 12),
            ("分期3/12", 3, 12),
            ("第3期", 3, nil),
            ("共12期", nil, 12),
            ("手机12期免息", nil, 12),
        ]
        for (text, index, total) in cases {
            let signal = InstallmentImportRecognizer.parseSignal(from: text)
            check(signal != nil, "备注「\(text)」应识别出分期信号", fail)
            check(signal?.index == index && signal?.total == total,
                  "备注「\(text)」应解析为 (\(index ?? -1), \(total ?? -1))，实际 (\(signal?.index ?? -1), \(signal?.total ?? -1))", fail)
        }

        // 裸 x/y 不带「期」/「分期」字样：中文语境更像日期，不认
        for text in ["3/12", "2026/03/14", "买了手机", "第一期还完了"] {
            check(InstallmentImportRecognizer.parseSignal(from: text) == nil,
                  "备注「\(text)」不应误识别为分期", fail)
        }
    }

    // MARK: - 列值解析

    private static func testColumnValueParsing(fail: Failure) {
        let cases: [(String, Int?, Int?)] = [
            ("3/12", 3, 12),
            ("3-12", 3, 12),
            ("3／12", 3, 12),
            ("12", nil, 12),
            ("12期", nil, 12),
            ("第3期/共12期", 3, 12),
        ]
        for (raw, index, total) in cases {
            let signal = InstallmentImportRecognizer.parseColumnValue(raw)
            check(signal?.index == index && signal?.total == total,
                  "列值「\(raw)」应解析为 (\(index ?? -1), \(total ?? -1))，实际 (\(signal?.index ?? -1), \(signal?.total ?? -1))", fail)
        }
        check(InstallmentImportRecognizer.parseColumnValue("") == nil, "空列值不应解析出信号", fail)
        check(InstallmentImportRecognizer.parseColumnValue("免息") == nil, "非数字列值不应解析出信号", fail)
    }

    // MARK: - 强信号归组

    private static func testStrongGroupingFull(fail: Failure) {
        var rows: [InstallmentImportRecognizer.CandidateRow] = []
        for i in 1...12 {
            rows.append(candidate(row: i, 2026, i, 5, signal: .init(index: i, total: 12)))
        }
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.count == 1, "12 行完整信号应成 1 组，实际 \(outcome.groups.count)", fail)
        check(outcome.assignments.count == 12, "12 行都应有赋值，实际 \(outcome.assignments.count)", fail)
        check(outcome.groups.first?.total == 12 && outcome.groups.first?.rowCount == 12, "组摘要应为 12 期 12 笔", fail)
        check(outcome.suspected.isEmpty, "强信号行不应进入疑似组", fail)
        // 组内同 groupId
        let groupIds = Set(outcome.assignments.values.map(\.groupId))
        check(groupIds.count == 1, "全组应共用一个 groupId", fail)
        check(outcome.assignments[7]?.index == 7, "第 7 行应为第 7 期", fail)
    }

    private static func testStrongGroupingPartial(fail: Failure) {
        // 银行流水常见：只导出了近几期（第 3-5 期），总 12 期
        let rows = [
            candidate(row: 1, 2026, 3, 5, signal: .init(index: 3, total: 12)),
            candidate(row: 2, 2026, 4, 5, signal: .init(index: 4, total: 12)),
            candidate(row: 3, 2026, 5, 5, signal: .init(index: 5, total: 12)),
        ]
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.count == 1, "3 行部分期次应成 1 组", fail)
        check(outcome.groups.first?.total == 12, "组总数应沿用信号的 12", fail)
        check(outcome.groups.first?.firstIndex == 3 && outcome.groups.first?.lastIndex == 5, "组期次范围应为 3-5", fail)
    }

    private static func testStrongGroupingIndexConflictDegrades(fail: Failure) {
        // 同账户同金额出现两个「第3期」——同月两笔同额分期，信号矛盾，整组保守降级
        let rows = [
            candidate(row: 1, 2026, 3, 5, signal: .init(index: 3, total: 12)),
            candidate(row: 2, 2026, 4, 5, signal: .init(index: 4, total: 12)),
            candidate(row: 3, 2026, 4, 5, signal: .init(index: 3, total: 12)),
        ]
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.isEmpty, "期次冲突应整组降级", fail)
        check(outcome.assignments.isEmpty, "降级组不应有赋值", fail)
        check(outcome.ungroupedSignalCount == 3, "3 行都应计入未归组，实际 \(outcome.ungroupedSignalCount)", fail)
    }

    private static func testDifferentAmountsFormSeparateGroups(fail: Failure) {
        // 两个不同商品的分期在同一账户：金额不同，各自成组
        var rows: [InstallmentImportRecognizer.CandidateRow] = []
        for i in 1...3 {
            rows.append(candidate(row: i, 2026, i, 5, amount: 333, signal: .init(index: i, total: 12)))
        }
        for i in 1...3 {
            rows.append(candidate(row: 10 + i, 2026, i, 6, amount: 555, signal: .init(index: i, total: 12)))
        }
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.count == 2, "不同金额的两组分期应各自成组，实际 \(outcome.groups.count)", fail)
        check(outcome.assignments.count == 6, "6 行都应有赋值", fail)
    }

    private static func testTailDifferenceMerges(fail: Failure) {
        // 末期吸收尾差：333×3 + 末期 334（差 1 < 容忍带 2）应合并为一组
        let rows = [
            candidate(row: 1, 2026, 1, 5, amount: 333, signal: .init(index: 1, total: 4)),
            candidate(row: 2, 2026, 2, 5, amount: 333, signal: .init(index: 2, total: 4)),
            candidate(row: 3, 2026, 3, 5, amount: 333, signal: .init(index: 3, total: 4)),
            candidate(row: 4, 2026, 4, 5, amount: 334, signal: .init(index: 4, total: 4)),
        ]
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.count == 1, "尾差金额应合并进同一组，实际 \(outcome.groups.count)", fail)
        check(outcome.assignments[4]?.index == 4, "末期行应保留第 4 期赋值", fail)
    }

    private static func testTotalOnlyColumnInfersIndexByDate(fail: Failure) {
        // 列值只有总数（"12"）：整组无期次，按日期序补推
        let rows = [
            candidate(row: 1, 2026, 2, 5, signal: .init(index: nil, total: 12)),
            candidate(row: 2, 2026, 3, 5, signal: .init(index: nil, total: 12)),
            candidate(row: 3, 2026, 4, 5, signal: .init(index: nil, total: 12)),
        ]
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.count == 1, "只有总数的行应按日期序成组", fail)
        check(outcome.assignments[1]?.index == 1 && outcome.assignments[3]?.index == 3, "期次应按日期序 1-3", fail)
        check(outcome.assignments[1]?.total == 12, "总数应沿用信号的 12", fail)
    }

    private static func testDateOrderValidation(fail: Failure) {
        // 期次与日期矛盾（第3期晚于第5期）——整组降级
        let rows = [
            candidate(row: 1, 2026, 5, 5, signal: .init(index: 3, total: 12)),
            candidate(row: 2, 2026, 3, 5, signal: .init(index: 5, total: 12)),
        ]
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        check(outcome.groups.isEmpty, "日期顺序矛盾的组应降级", fail)
    }

    private static func testSingleSignalRowAndBadTotal(fail: Failure) {
        // 单行信号不成组；total=1 无意义；total 超 36 不归
        let single = [
            candidate(row: 1, 2026, 1, 5, signal: .init(index: 3, total: 12)),
        ]
        check(InstallmentImportRecognizer.resolve(candidates: single).groups.isEmpty, "单行信号不应成组", fail)

        let totalOne = (1...3).map {
            candidate(row: $0, 2026, $0, 5, signal: .init(index: $0, total: 1))
        }
        check(InstallmentImportRecognizer.resolve(candidates: totalOne).groups.isEmpty, "total=1 不应成组", fail)

        let totalHuge = (1...3).map {
            candidate(row: $0, 2026, $0, 5, signal: .init(index: $0, total: 48))
        }
        check(InstallmentImportRecognizer.resolve(candidates: totalHuge).groups.isEmpty, "total=48 超上限不应成组", fail)
    }

    // MARK: - 弱信号序列检测

    private static func testSuspectedSequenceDetection(fail: Failure) {
        // 无信号行：同账户同金额按月出现 3 次 → 疑似组（不自动归组）
        let monthly = (0..<3).map { offset -> InstallmentImportRecognizer.CandidateRow in
            let month = 1 + offset
            return candidate(row: offset + 1, 2026, month, 15, amount: 1200, signal: nil)
        }
        let outcome = InstallmentImportRecognizer.resolve(candidates: monthly)
        check(outcome.suspected.count == 1, "月度同额 3 行应检出 1 个疑似组，实际 \(outcome.suspected.count)", fail)
        check(outcome.assignments.isEmpty, "疑似组不确认不应有赋值", fail)
        check(outcome.suspected.first?.rows.count == 3, "疑似组应含 3 行", fail)

        // 周度订阅（间隔 7 天）不误报
        let weekly = (0..<4).map { offset in
            candidate(row: offset + 1, 2026, 2, 1 + offset * 7, amount: 25, signal: nil)
        }
        check(InstallmentImportRecognizer.resolve(candidates: weekly).suspected.isEmpty, "周度同额行不应报疑似分期", fail)

        // 强信号行不参与序列检测
        let mixed: [InstallmentImportRecognizer.CandidateRow] = [
            candidate(row: 1, 2026, 1, 5, signal: .init(index: 1, total: 3)),
            candidate(row: 2, 2026, 2, 5, signal: .init(index: 2, total: 3)),
            candidate(row: 3, 2026, 3, 5, signal: .init(index: 3, total: 3)),
        ]
        check(InstallmentImportRecognizer.resolve(candidates: mixed).suspected.isEmpty, "强信号行不应进疑似检测", fail)
    }

    private static func testConfirmedSuspectedAssignments(fail: Failure) {
        let rows = (0..<3).map { offset in
            candidate(row: offset + 1, 2026, 1 + offset, 15, amount: 1200, signal: nil)
        }
        let outcome = InstallmentImportRecognizer.resolve(candidates: rows)
        guard let suspected = outcome.suspected.first else {
            check(false, "应检出疑似组", fail)
            return
        }
        let assignments = InstallmentImportRecognizer.assignments(forConfirmed: suspected)
        check(assignments.count == 3, "确认后 3 行都应有赋值", fail)
        check(assignments[1]?.index == 1 && assignments[3]?.index == 3, "确认后期次按日期序 1-3", fail)
        check(assignments.values.allSatisfy { $0.total == 3 }, "确认后总数应为行数 3", fail)
        check(Set(assignments.values.map(\.groupId)).count == 1, "确认后应共用 groupId", fail)
    }

    // MARK: - 指纹后缀

    private static func testFingerprintInstallmentSuffix(fail: Failure) {
        let base = DataImportService.makeFingerprint(
            date: date(2026, 3, 14), amount: 333, type: .expense,
            primaryCategory: "购物", subCategory: "数码", accountName: "信用卡"
        )
        let withInstallment = DataImportService.makeFingerprint(
            date: date(2026, 3, 14), amount: 333, type: .expense,
            primaryCategory: "购物", subCategory: "数码", accountName: "信用卡",
            installment: (index: 3, total: 12)
        )
        check(base != withInstallment, "分期行指纹应与非分期指纹不同", fail)
        check(withInstallment.hasSuffix("|I3/12"), "分期指纹应以 |I3/12 结尾，实际 \(withInstallment)", fail)
        check(withInstallment.hasPrefix(base), "分期指纹应保留基础部分", fail)
    }

    // MARK: - scanCSV 集成（HOLO 往返 + 备注识别）

    private static func testScanCSVRoundTrip(fail: Failure) throws {
        // HOLO 新导出格式：末列「分期」，值 "x/y"
        let csv = """
        日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签,分期
        2026/01/05,12:00,支出,333.00,购物,数码,信用卡,手机,,1/12
        2026/02/05,12:00,支出,333.00,购物,数码,信用卡,手机,,2/12
        2026/03/05,12:00,支出,333.00,购物,数码,信用卡,手机,,3/12
        2026/03/14,12:30,支出,35.50,餐饮,午餐,微信,公司食堂,工作餐,
        """
        let summary = try scan(csv: csv, fileName: "holo-roundtrip.csv")
        check(summary.detectedTemplate == .holo, "含一级/二级分类应识别为 HOLO 模板", fail)
        check(summary.fieldMapping.installmentIndex == 9, "HOLO 模板应映射「分期」列（索引 9）", fail)
        guard let info = summary.installmentInfo else {
            check(false, "分期列信号应产出 installmentInfo", fail)
            return
        }
        check(info.groups.count == 1, "3 行分期列信号应成 1 组，实际 \(info.groups.count)", fail)
        check(info.assignments[1]?.index == 1 && info.assignments[3]?.index == 3, "往返后期次应为 1-3", fail)
        check(info.assignments[3]?.total == 12, "往返后总数应为 12", fail)

        // 旧 HOLO 格式（无分期列）：表头少一列，不应崩、无分期信息
        let legacyCSV = """
        日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签
        2026/03/14,12:30,支出,35.50,餐饮,午餐,微信,公司食堂,工作餐
        """
        let legacy = try scan(csv: legacyCSV, fileName: "holo-legacy.csv")
        check(legacy.fieldMapping.installmentIndex == nil, "旧格式无分期列应映射为 nil", fail)
        check(legacy.installmentInfo == nil || legacy.installmentInfo?.groups.isEmpty == true,
              "旧格式无分期信号不应成组", fail)

        // 银行流水风格：备注列带「x/12期」文字（generic 模板模糊映射）
        let bankCSV = """
        交易日期,交易金额,收支,备注,账户
        2026/01/05,333.00,支出,信用卡分期 1/12期,招行信用卡
        2026/02/05,333.00,支出,信用卡分期 2/12期,招行信用卡
        2026/03/05,333.00,支出,信用卡分期 3/12期,招行信用卡
        """
        let bank = try scan(csv: bankCSV, fileName: "bank-notes.csv")
        guard let bankInfo = bank.installmentInfo else {
            check(false, "备注分期写法应产出 installmentInfo", fail)
            return
        }
        check(bankInfo.groups.count == 1, "备注「x/12期」3 行应成 1 组", fail)
        check(bankInfo.assignments.count == 3, "3 行都应获得赋值", fail)
    }

    /// 写临时 CSV 后走完整 scanCSV 管线（含表头探测、模板识别、列对齐）
    private static func scan(csv: String, fileName: String) throws -> ImportScanSummary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("installment-tests-\(fileName)")
        try csv.data(using: .utf8)?.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DataImportService.shared.scanCSV(url: url)
    }
}
