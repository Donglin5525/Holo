import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

final class FinanceBillImportMatrixTests: XCTestCase {
    func testFinanceBillImportMatrix() throws {
        try FinanceBillImportMatrixStandaloneTests.run { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    }

}
#else
@main
private struct HoloStandaloneLauncher {
    static func main() throws {
        try FinanceBillImportMatrixStandaloneTests.run { message, file, line in
            fatalError("\(message) [\(file):\(line)]")
        }
    }
}
#endif

struct FinanceBillImportMatrixStandaloneTests {

    typealias Failure = (_ message: String, _ file: StaticString, _ line: UInt) -> Void

    static func run(using fail: @escaping Failure) throws {
        let root = try fixtureRoot()
        try testWechat(root: root, fail: fail)
        try testAlipay(root: root, fail: fail)
        try testBankManualMapping(root: root, fail: fail)
        try testGenericAndTSV(root: root, fail: fail)
        try testExcelConversion(root: root, fail: fail)
        try testArchiveExtraction(root: root, fail: fail)
        testSoftDuplicateMatching(fail: fail)
        print("Finance bill import matrix passed: 微信、支付宝、银行、CSV、TXT/TSV、XLSX、ZIP、边界金额、日期、状态和重复场景")
    }

    private static func fixtureRoot() throws -> URL {
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = (0..<6).reduce(sourceDir) { url, _ in url.deletingLastPathComponent() }
        let root = repoRoot.appendingPathComponent("docs/finance/fixtures/import-validation")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw NSError(domain: "FinanceBillImportMatrix", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到测试夹具目录：\(root.path)"])
        }
        return root
    }

    private static func fixture(_ root: URL, _ name: String) -> URL {
        if name == "bank-statement.xlsx" {
            let repoRoot = (0..<4).reduce(root) { url, _ in url.deletingLastPathComponent() }
            let generated = repoRoot
                .appendingPathComponent("outputs/finance-import-validation/bank-statement.xlsx")
            if FileManager.default.fileExists(atPath: generated.path) { return generated }
        }
        return root.appendingPathComponent(name)
    }

    private static func testWechat(root: URL, fail: Failure) throws {
        let url = fixture(root, "wechat-bill.csv")
        let summary = try DataImportService.shared.scanCSV(url: url)
        check(summary.detectedTemplate == .wechatBill, "微信文件应识别为微信账单", fail)
        check(summary.totalRows == 6, "微信过滤后应有 6 行（含 1 行零金额）", fail)
        check(summary.parseableCount == 5 && summary.failedCount == 1, "微信应解析 5 行、拒绝 1 行零金额", fail)
        check(summary.billInfo?.skippedNoFlowCount == 1, "微信应跳过 1 行不计收支", fail)
        check(summary.billInfo?.skippedStatusCount == 2, "微信应跳过 2 行退款/关闭状态", fail)
        check(summary.billInfo?.paymentChannels.contains("零钱") == true, "微信应收集零钱支付方式", fail)
        check(summary.billInfo?.paymentChannels.contains("招商银行储蓄卡(1234)") == true, "微信应收集银行卡支付方式", fail)
        check(summary.billInfo?.headerLineIndex == 6, "微信封面后表头行索引应为 6", fail)

        let preview = summary.sampleRows[1]
        let item = try DataImportService.shared.parseRowForStream(
            preview,
            mapping: summary.fieldMapping,
            template: summary.detectedTemplate,
            billSource: .wechat
        )
        check(item.amount == Decimal(string: "128.00"), "微信金额清洗应保留 128.00", fail)
        check(item.type == .expense, "微信支出方向应解析为 expense", fail)
        check(item.sourceRef == "WX-002", "微信交易单号应落入 sourceRef", fail)
        check(item.note?.contains("蔬菜,水果") == true && item.note?.contains("周末采购,含优惠") == true, "微信引号内逗号字段不能被截断", fail)
    }

    private static func testAlipay(root: URL, fail: Failure) throws {
        let url = fixture(root, "alipay-bill.csv")
        let summary = try DataImportService.shared.scanCSV(url: url)
        check(summary.detectedTemplate == .alipayBill, "支付宝文件应识别为支付宝账单", fail)
        check(summary.totalRows == 5, "支付宝过滤后应有 5 行（含 1 行零金额）", fail)
        check(summary.parseableCount == 4 && summary.failedCount == 1, "支付宝应解析 4 行、拒绝 1 行零金额", fail)
        check(summary.billInfo?.skippedStatusCount == 2, "支付宝应跳过退款成功和交易关闭", fail)

        let income = try DataImportService.shared.parseRowForStream(
            summary.sampleRows[1],
            mapping: summary.fieldMapping,
            template: summary.detectedTemplate,
            billSource: .alipay
        )
        check(income.type == .income && income.amount == Decimal(string: "8500.00"), "支付宝收入金额和方向应正确", fail)
        check(income.sourceRef == "ALI-002", "支付宝交易号应落入 sourceRef", fail)

        let bracket = try DataImportService.shared.parseRowForStream(
            summary.sampleRows[0],
            mapping: summary.fieldMapping,
            template: summary.detectedTemplate,
            billSource: .alipay
        )
        check(bracket.amount == Decimal(string: "128.50") && bracket.type == .expense, "支付宝全角会计括号金额应解析为支出绝对值", fail)
    }

    private static func testBankManualMapping(root: URL, fail: Failure) throws {
        let url = fixture(root, "bank-statement.csv")
        let auto = try DataImportService.shared.scanCSV(url: url)
        check(auto.detectedTemplate == .generic, "银行未知表头应先落入通用模板", fail)
        check(auto.billInfo?.source == .bank && auto.billInfo?.bankName == "招商银行", "银行名应从封面说明提取", fail)
        check(auto.fieldMapping.amountIndex == nil, "银行分列金额不应误认成单金额列", fail)
        check(auto.parseableCount == 0 && auto.failedCount == 6, "银行未完成列映射时应明确暴露 6 行缺金额失败", fail)

        let mapping = bankSplitMapping()
        let mapped = try DataImportService.shared.scanCSV(url: url, fieldMapping: mapping)
        check(mapped.totalRows == 6, "银行手动映射后应扫描 6 行", fail)
        check(mapped.parseableCount == 5 && mapped.failedCount == 1, "银行手动映射后应解析 5 行、拒绝 1 行零金额", fail)
        check(mapped.billInfo?.bankName == "招商银行", "银行手动映射后仍应保留银行来源", fail)

        let salary = try DataImportService.shared.parseRowForStream(
            mapped.sampleRows[0], mapping: mapping, template: mapped.detectedTemplate, billSource: .bank
        )
        let payment = try DataImportService.shared.parseRowForStream(
            mapped.sampleRows[1], mapping: mapping, template: mapped.detectedTemplate, billSource: .bank
        )
        check(salary.type == .income && salary.amount == Decimal(string: "18000.00"), "银行收入列应解析为 income", fail)
        check(payment.type == .expense && payment.amount == Decimal(string: "128.50"), "银行支出列应解析为 expense", fail)
    }

    static func bankSplitMapping() -> FieldMapping {
        FieldMapping(
            dateIndex: 0,
            timeIndex: nil,
            typeIndex: nil,
            amountIndex: nil,
            primaryCategoryIndex: nil,
            subCategoryIndex: nil,
            accountIndex: nil,
            noteIndex: 1,
            descriptionIndex: nil,
            merchantIndex: nil,
            tagsIndex: nil,
            counterpartyIndex: nil,
            statusIndex: 7,
            refIndex: 6,
            incomeAmountIndex: 3,
            expenseAmountIndex: 2
        )
    }

    private static func testGenericAndTSV(root: URL, fail: Failure) throws {
        let csvURL = fixture(root, "generic-edge-cases.csv")
        let summary = try DataImportService.shared.scanCSV(url: csvURL)
        check(summary.detectedTemplate == .generic, "英文边界 CSV 应识别为通用模板", fail)
        check(summary.totalRows == 7, "通用 CSV 应忽略尾部空行并保留 7 行数据", fail)
        check(summary.parseableCount == 5 && summary.failedCount == 2, "通用 CSV 应解析 5 行并拒绝零金额/缺失金额", fail)
        check(summary.warnings.contains(where: { $0.severity == .blocking && $0.field == "日期" }), "非法日期应生成 blocking 警告", fail)
        check(summary.warnings.contains(where: { $0.severity == .advisory && $0.field == "类型" }), "空类型应生成 advisory 警告", fail)

        let parsed = try DataImportService.shared.parseCSV(url: csvURL)
        let first = try DataImportService.shared.parseRowForStream(parsed.rows[0], mapping: parsed.fieldMapping, template: parsed.detectedTemplate)
        check(abs(NSDecimalNumber(decimal: first.amount).doubleValue - 1234.56) < 0.001 && first.note?.contains("电器,带逗号") == true, "UTF-8 BOM、千分位和引号逗号应正确解析", fail)
        check(first.tags == ["大额", "家电"], "分号标签应拆分", fail)

        let withoutConfirmation = DataImportService.shared.convertToImportItems(data: parsed, mapping: parsed.fieldMapping)
        check(withoutConfirmation.0.count == 4 && withoutConfirmation.1.count == 2, "非法日期未确认时不应进入 items", fail)
        let withConfirmation = DataImportService.shared.convertToImportItems(data: parsed, mapping: parsed.fieldMapping, confirmedFallbackDateRows: [3])
        check(withConfirmation.0.count == 5 && withConfirmation.1.count == 2, "确认日期兜底后应多导入 1 行", fail)

        let tsv = try DataImportService.shared.scanCSV(url: fixture(root, "tsv-edge-cases.txt"))
        check(tsv.detectedTemplate == .generic && tsv.totalRows == 5 && tsv.parseableCount == 5, "TXT 扩展名 TSV 应被完整扫描", fail)
        let tsvParsed = try DataImportService.shared.parseCSV(url: fixture(root, "tsv-edge-cases.txt"))
        let euro = try DataImportService.shared.parseRowForStream(tsvParsed.rows[3], mapping: tsvParsed.fieldMapping, template: tsvParsed.detectedTemplate)
        check(euro.amount == Decimal(string: "35.50") && euro.type == .expense, "欧式小数逗号应解析为 35.50 支出", fail)
    }

    private static func testExcelConversion(root: URL, fail: Failure) throws {
        let xlsx = fixture(root, "bank-statement.xlsx")
        check(FileManager.default.fileExists(atPath: xlsx.path), "应存在由表格工具生成的 xlsx 夹具", fail)
        let csv = try BillExcelReader.convertToCSV(url: xlsx)
        let text = try String(contentsOf: csv, encoding: .utf8)
        check(text.contains("交易日期") && text.contains("BNK-X003"), "xlsx 应选取交易明细 Sheet 并转成 CSV", fail)
        check(text.contains("2026-08-13"), "Excel 日期单元格应转成可识别日期文本", fail)

        let summary = try DataImportService.shared.scanCSV(url: csv, fieldMapping: bankSplitMapping())
        check(summary.billInfo?.bankName == "招商银行", "xlsx 转 CSV 后应保留银行封面和银行名识别", fail)
        check(summary.parseableCount == 5 && summary.failedCount == 1, "xlsx 转 CSV 后银行分列金额规则应与 CSV 一致", fail)
    }

    private static func testArchiveExtraction(root: URL, fail: Failure) throws {
        let repoRoot = (0..<4).reduce(root) { url, _ in url.deletingLastPathComponent() }
        let archive = repoRoot
            .appendingPathComponent("outputs/finance-import-validation/bill-bundle.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            check(false, "应存在无密码 ZIP 账单夹具", fail)
            return
        }
        let extracted = try BillArchiveExtractor.extract(archiveURL: archive)
        check(extracted.pathExtension == "csv", "ZIP 应提取第一个支持的 CSV 文件", fail)
        check(FileManager.default.fileExists(atPath: extracted.path), "ZIP 提取文件应落盘", fail)
        let summary = try DataImportService.shared.scanCSV(url: extracted)
        check(summary.detectedTemplate == .wechatBill && summary.parseableCount == 5, "ZIP 提取出的微信账单应可继续进入扫描管线", fail)
    }

    private static func testSoftDuplicateMatching(fail: Failure) {
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let incoming: [(row: Int, amount: Decimal, type: TransactionType, date: Date)] = [
            (1, Decimal(string: "35.00")!, .expense, day),
            (2, Decimal(string: "35.00")!, .expense, day),
        ]
        let existing = [BillDuplicateDetector.ExistingEntry(
            amount: Decimal(string: "35.00")!, type: .expense, date: day, note: "咖啡", importSource: nil
        )]
        let result = BillDuplicateDetector.detect(incoming: incoming, existing: existing)
        check(result.autoSkipRowIndices.count == 1, "同额同向同日已有手动记录时应只自动跳过一条", fail)
        check(result.reviewRowIndices.count == 1, "同额同向重复但配不齐的另一条应进入人工确认", fail)
        check(result.autoSkipRowIndices.union(result.reviewRowIndices) == Set([1, 2]), "软重复检测不能丢掉任一真实行", fail)
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        _ fail: Failure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition() { fail(message, file, line) }
    }
}
