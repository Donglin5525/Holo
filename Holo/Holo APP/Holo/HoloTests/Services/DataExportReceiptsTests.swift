//
//  DataExportReceiptsTests.swift
//  HoloTests
//
//  导出含小票图片（2026-10-03）：
//  - CSV「小票」列：表头、多张分号、同分钟撞名防冲突、无小票行为空
//  - 不带小票时保持既有 10 列格式（导入模板零回归）
//  - ZIP 产物：数据文件 + receipts/ 图片，用 ZIPFoundation 读回逐字节比对
//  - 范围内无小票时退回纯数据文件（行为与不勾选一致）
//  - JSON receipts 字段 + 旧版 JSON（无该字段）解码兼容
//  - imageData 未下载（nil）的附件跳过
//

import XCTest
import CoreData
import UIKit
import ZIPFoundation
@testable import Holo

@MainActor
final class DataExportReceiptsTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var service: DataExportService!
    private var account: Account!
    private var category: Holo.Category!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(
            context,
            ["Transaction", "TransactionAttachment", "Category", "Account", "Budget", "FinanceProject"]
        )

        repo = FinanceRepository(context: context)
        service = DataExportService(context: context)
        account = try repo.addAccount(name: "现金", type: .cash, initialBalance: 0)

        let parentCategory = Holo.Category.create(
            in: context, name: "餐饮", icon: "fork.knife", color: "#FF9500",
            type: TransactionType.expense.rawValue
        )
        category = Holo.Category.create(
            in: context, name: "午餐", icon: "fork.knife", color: "#FF9500",
            type: TransactionType.expense.rawValue, parentId: parentCategory.id
        )
        try? context.save()
    }

    // MARK: - Helpers

    private func makeImageData(hue: CGFloat = 0.06) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let image = renderer.image { ctx in
            UIColor(hue: hue, saturation: 0.8, brightness: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    @discardableResult
    private func makeTransaction(date: Date, note: String? = nil) async throws -> Transaction {
        try await repo.addTransaction(amount: 35, type: .expense, category: category, account: account,
                                      date: date, note: note)
    }

    /// 本地时区固定时刻（与导出端 DateFormatter 默认本地时区一致）
    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = hh; comps.minute = mm
        return Calendar.current.date(from: comps)!
    }

    // MARK: - CSV「小票」列

    func testCSVIncludesReceiptColumnAndFileNames() async throws {
        let txA = try await makeTransaction(date: date(2026, 10, 2, 14, 30), note: "A")
        _ = try await repo.attachReceipt(to: txA, imageData: try makeImageData(hue: 0.1), source: .camera)
        _ = try await repo.attachReceipt(to: txA, imageData: try makeImageData(hue: 0.2), source: .photoLibrary)

        let txB = try await makeTransaction(date: date(2026, 10, 2, 14, 30), note: "B")
        _ = try await repo.attachReceipt(to: txB, imageData: try makeImageData(hue: 0.3), source: .receiptBooking)

        let txC = try await makeTransaction(date: date(2026, 10, 2, 15, 0), note: "C")

        let plan = try await service.makeReceiptPlan()
        let csv = try await service.exportToCSV(dateRange: nil, receiptPlan: plan)

        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix(",小票"), "表头应以「小票」列结尾：\(lines[0])")
        let lineA = try XCTUnwrap(lines.first { $0.contains("A") })
        XCTAssertTrue(lineA.contains("receipt_20261002_1430_1.jpg;receipt_20261002_1430_2.jpg"),
                      "同笔多张按序分号分隔：\(lineA)")
        let lineB = try XCTUnwrap(lines.first { $0.contains("B") })
        XCTAssertTrue(lineB.contains("receipt_20261002_1430_1_2.jpg"),
                      "同分钟撞名自动加后缀：\(lineB)")
        let lineC = try XCTUnwrap(lines.first { $0.contains("C") })
        XCTAssertTrue(lineC.hasSuffix(","), "无小票行小票列为空：\(lineC)")
    }

    func testCSVWithoutPlanKeepsLegacyHeader() async throws {
        _ = try await makeTransaction(date: date(2026, 10, 2, 14, 30))
        let csv = try await service.exportToCSV(dateRange: nil)
        let header = csv.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(header, "日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签,分期",
                      "不勾选小票时保持既有 10 列（导入模板零回归）")
    }

    // MARK: - ZIP 产物

    func testGenerateArchiveWithReceiptsProducesValidZip() async throws {
        let txA = try await makeTransaction(date: date(2026, 10, 2, 14, 30))
        _ = try await repo.attachReceipt(to: txA, imageData: try makeImageData(hue: 0.4), source: .camera)
        _ = try await repo.attachReceipt(to: txA, imageData: try makeImageData(hue: 0.5), source: .camera)
        let txB = try await makeTransaction(date: date(2026, 10, 3, 9, 5))
        _ = try await repo.attachReceipt(to: txB, imageData: try makeImageData(hue: 0.6), source: .receiptBooking)

        let zipURL = try await service.generateExportFile(format: .csv, dateRange: nil, includeReceipts: true)
        XCTAssertEqual(zipURL.pathExtension, "zip")

        let archive = try XCTUnwrap(Archive(url: zipURL, accessMode: .read))
        var paths: [String] = []
        for entry in archive { paths.append(entry.path) }

        XCTAssertEqual(paths.count, 4, "1 个数据文件 + 3 张小票：\(paths)")
        XCTAssertEqual(paths.filter { $0.hasSuffix(".csv") }.count, 1, "数据文件在压缩包根目录")
        XCTAssertEqual(paths.filter { $0.hasPrefix("receipts/") }.count, 3, "图片收纳在 receipts/ 目录")

        // 逐图读回，与落库 imageData 逐字节一致
        let expected = (txA.receiptAttachments + txB.receiptAttachments).compactMap(\.imageData)
        XCTAssertEqual(expected.count, 3)
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt_export_check_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        for imagePath in paths.filter({ $0.hasPrefix("receipts/") }) {
            let entry = try XCTUnwrap(archive[imagePath])
            let dest = extractDir.appendingPathComponent((imagePath as NSString).lastPathComponent)
            _ = try archive.extract(entry, to: dest)
            let roundTrip = try Data(contentsOf: dest)
            XCTAssertTrue(expected.contains(roundTrip), "zip 内图片应与落库数据逐字节一致：\(imagePath)")
        }

        // 数据文件读回含「小票」表头
        let csvEntry = try XCTUnwrap(archive[paths.first { $0.hasSuffix(".csv") } ?? ""])
        let csvDest = extractDir.appendingPathComponent("data.csv")
        _ = try archive.extract(csvEntry, to: csvDest)
        let csvText = String(data: try Data(contentsOf: csvDest), encoding: .utf8) ?? ""
        XCTAssertTrue(csvText.contains(",小票"), "zip 内 CSV 应带小票列")
    }

    func testGenerateExportFileFallsBackWithoutReceipts() async throws {
        _ = try await makeTransaction(date: date(2026, 10, 2, 14, 30))
        let url = try await service.generateExportFile(format: .csv, dateRange: nil, includeReceipts: true)
        XCTAssertEqual(url.pathExtension, "csv", "范围内没有小票时退回纯数据文件（与不勾选一致）")
    }

    func testGenerateArchiveWithJSONFormatContainsReceipts() async throws {
        let tx = try await makeTransaction(date: date(2026, 10, 2, 14, 30))
        _ = try await repo.attachReceipt(to: tx, imageData: try makeImageData(hue: 0.7), source: .camera)

        let zipURL = try await service.generateExportFile(format: .json, dateRange: nil, includeReceipts: true)
        XCTAssertEqual(zipURL.pathExtension, "zip")

        let archive = try XCTUnwrap(Archive(url: zipURL, accessMode: .read))
        let jsonPath = try XCTUnwrap(archive.map(\.path).first { $0.hasSuffix(".json") })
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("check_\(UUID().uuidString).json")
        _ = try archive.extract(try XCTUnwrap(archive[jsonPath]), to: dest)
        defer { try? FileManager.default.removeItem(at: dest) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(HoloBackup.self, from: Data(contentsOf: dest))
        XCTAssertEqual(backup.transactions.count, 1)
        XCTAssertEqual(backup.transactions.first?.receipts?.count, 1)
        XCTAssertTrue(backup.transactions.first?.receipts?.first?.hasPrefix("receipt_20261002_1430") == true)
    }

    // MARK: - 兼容与边界

    func testOldJSONWithoutReceiptsFieldDecodes() throws {
        let legacy = """
        {"id":"X","amount":35,"type":"expense","categoryName":"餐饮","accountName":"现金",
        "date":"2026-10-02T14:30:00Z","createdAt":"2026-10-02T14:30:00Z","updatedAt":"2026-10-02T14:30:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(TransactionDTO.self, from: Data(legacy.utf8))
        XCTAssertNil(dto.receipts, "旧版备份无 receipts 字段解码为 nil")
    }

    func testSkipsAttachmentsWithoutImageData() async throws {
        let tx = try await makeTransaction(date: date(2026, 10, 2, 14, 30))
        let attachment = TransactionAttachment(context: context)
        attachment.id = UUID()
        attachment.fileName = "stub.jpeg"
        attachment.thumbnailFileName = "stub_thumb.jpeg"
        attachment.sortOrder = 0
        attachment.sourceType = TransactionAttachment.AttachmentSource.photoLibrary.rawValue
        attachment.createdAt = Date()
        attachment.imageData = nil
        attachment.transaction = tx
        try context.save()

        let plan = try await service.makeReceiptPlan()
        XCTAssertTrue(plan.isEmpty, "imageData 未下载（CloudKit 大文件延迟同步形态）不进包")

        let csv = try await service.exportToCSV(dateRange: nil, receiptPlan: plan)
        let line = csv.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        XCTAssertTrue(line.hasSuffix(","), "小票列为空")
    }
}
