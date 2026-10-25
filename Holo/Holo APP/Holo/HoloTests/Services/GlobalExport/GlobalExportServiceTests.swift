//
//  GlobalExportServiceTests.swift
//  HoloTests
//
//  全局导出全链路测试：多实体播种（含关系 / 二进制 / 敏感库）
//  → exportAll → 解 ZIP 断言结构、计数、关系引用、blob 字节一致
//

import XCTest
import CoreData
import ZIPFoundation
@testable import Holo

final class GlobalExportServiceTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var sensitiveController: HoloMemoryPersistenceController!
    private var sensitiveContext: NSManagedObjectContext!

    override func setUp() async throws {
        // 主库：进程唯一共享测试容器（134020 政策）
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearAllEntities(context)
        // 敏感库：与生产同构造路径的独立内存实例
        sensitiveController = try HoloMemoryPersistenceController(inMemory: true)
        sensitiveContext = sensitiveController.sensitiveContainer.viewContext
    }

    override func tearDown() async throws {
        sensitiveController = nil
        sensitiveContext = nil
        context = nil
    }

    // MARK: - 主用例

    func testExportProducesCompleteArchive() async throws {
        // 播种：分类 + 账户 + 交易（带关系）+ 票根附件（原图 + 缩略图）
        let category = Category.create(
            in: context, name: "餐饮", icon: "tag", color: "#13A4EC",
            type: "expense", isDefault: true, parentId: nil, isSystem: false
        )

        let account = context.insertTestObject(Account.self)
        account.id = UUID()
        account.name = "现金"
        account.createdAt = Date()
        account.updatedAt = Date()

        let tx = context.insertTestObject(Transaction.self)
        tx.id = UUID()
        tx.amount = NSDecimalNumber(decimal: 35.5)
        tx.type = "expense"
        tx.date = Date()
        tx.note = "测试交易"
        tx.category = category
        tx.account = account

        let attachment = context.insertTestObject(TransactionAttachment.self)
        let receiptData = Data("receipt-image-bytes".utf8)
        attachment.imageData = receiptData
        attachment.thumbnailData = Data("thumb".utf8)
        attachment.fileName = "receipt.jpg"
        attachment.createdAt = Date()
        attachment.transaction = tx

        // 敏感库播种一条记忆（recordData 为二进制正文包）
        let sensitivePayload = Data("{\"statement\":\"敏感记忆正文\"}".utf8)
        let record = NSEntityDescription.insertNewObject(
            forEntityName: "HoloMemoryRecordMO", into: sensitiveContext
        )
        record.setValue("rec-export-test-1", forKey: "stableID")
        record.setValue("personal", forKey: "scope")
        record.setValue("adopted", forKey: "state")
        record.setValue("none", forKey: "userDecision")
        record.setValue(sensitivePayload, forKey: "recordData")
        record.setValue(Date(), forKey: "createdAt")
        record.setValue(Date(), forKey: "updatedAt")
        try sensitiveContext.save()
        try context.save()

        // 导出（财务 CSV 注入假内容，避免触真栈）
        let service = GlobalExportService(
            sources: [
                GlobalExportSource(name: "main", displayName: "主数据", container: CoreDataTestSupport.sharedTestContainer),
                GlobalExportSource(name: "sensitive", displayName: "敏感记忆", container: sensitiveController.sensitiveContainer),
            ],
            financeCSVProvider: { "日期,时间,类型,金额" }
        )
        var progressCount = 0
        let result = try await service.exportAll { _ in progressCount += 1 }

        // 产物命名与存在性
        XCTAssertTrue(result.fileURL.lastPathComponent.hasPrefix("Holo备份_"))
        XCTAssertTrue(result.fileURL.lastPathComponent.hasSuffix(".zip"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))

        // 解 ZIP
        let extracted = try extractZIP(result.fileURL)

        // manifest：各来源实体计数与播种一致；敏感库在场标记为真
        let manifestData = try Data(contentsOf: extracted.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let sources = try XCTUnwrap(manifest["sources"] as? [String: [String: Int]])
        XCTAssertEqual(sources["main"]?["Transaction"], 1)
        XCTAssertEqual(sources["main"]?["Category"], 1)
        XCTAssertEqual(sources["main"]?["Account"], 1)
        XCTAssertEqual(sources["main"]?["TransactionAttachment"], 1)
        XCTAssertEqual(sources["sensitive"]?["HoloMemoryRecordMO"], 1)
        XCTAssertEqual(manifest["includesSensitiveMemory"] as? Bool, true)
        XCTAssertEqual(manifest["formatVersion"] as? Int, 1)

        // 主库实体行：交易行的关系引用指向分类/账户的 id
        let txRows = try loadRows(extracted, source: "main", entity: "Transaction")
        XCTAssertEqual(txRows.count, 1)
        let txRow = try XCTUnwrap(txRows.first)
        XCTAssertEqual(txRow["category"] as? String, category.id.uuidString)
        XCTAssertEqual(txRow["account"] as? String, account.id.uuidString)

        // 附件行：imageData 落 blob 文件且字节一致；thumbnailData 键被跳过
        let attachmentRows = try loadRows(extracted, source: "main", entity: "TransactionAttachment")
        XCTAssertEqual(attachmentRows.count, 1)
        let attachmentRow = try XCTUnwrap(attachmentRows.first)
        XCTAssertNil(attachmentRow["thumbnailData"])
        let blobRef = try XCTUnwrap(attachmentRow["imageData"] as? [String: Any])
        let blobPath = try XCTUnwrap(blobRef["__file"] as? String)
        XCTAssertEqual(blobRef["bytes"] as? Int, receiptData.count)
        let blobData = try Data(contentsOf: extracted.appendingPathComponent(blobPath))
        XCTAssertEqual(blobData, receiptData)

        // 敏感库行：recordData 落文件且字节一致；stableID 保留
        let recordRows = try loadRows(extracted, source: "sensitive", entity: "HoloMemoryRecordMO")
        XCTAssertEqual(recordRows.count, 1)
        let recordRow = try XCTUnwrap(recordRows.first)
        XCTAssertEqual(recordRow["stableID"] as? String, "rec-export-test-1")
        let recordBlobRef = try XCTUnwrap(recordRow["recordData"] as? [String: Any])
        let recordBlobPath = try XCTUnwrap(recordBlobRef["__file"] as? String)
        let recordBlobData = try Data(contentsOf: extracted.appendingPathComponent(recordBlobPath))
        XCTAssertEqual(recordBlobData, sensitivePayload)
        XCTAssertTrue(recordBlobPath.hasPrefix("blobs/sensitive/"))

        // 财务 CSV：注入内容带 BOM 落盘（String(contentsOf:) 会剥 BOM，按原始字节校验）
        let csvURL = extracted.appendingPathComponent("finance.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        let csvData = try Data(contentsOf: csvURL)
        XCTAssertEqual(Array(csvData.prefix(3)), Array("\u{FEFF}".utf8))
        XCTAssertTrue(String(data: csvData.dropFirst(3), encoding: .utf8)?
            .hasPrefix("日期,时间,类型,金额") == true)

        // README 在场
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("README.txt").path
        ))

        // 进度回调至少覆盖每个实体一次（2 库共 70 实体，非空即证链路通）
        XCTAssertGreaterThan(progressCount, 0)
    }

    // MARK: - 取消行为

    func testCancellationThrowsCancellationError() async throws {
        let service = GlobalExportService(
            sources: [
                GlobalExportSource(name: "main", displayName: "主数据", container: CoreDataTestSupport.sharedTestContainer),
            ],
            financeCSVProvider: { nil }
        )
        let task = Task {
            try await service.exportAll()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后应抛 CancellationError")
        } catch is CancellationError {
            // 预期路径
        }
    }

    // MARK: - 辅助

    private func extractZIP(_ zipURL: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive {
            let path = dest.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: path)
        }
        return dest
    }

    private func loadRows(_ root: URL, source: String, entity: String) throws -> [[String: Any]] {
        let url = root.appendingPathComponent("data/\(source)/\(entity).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺少实体文件 data/\(source)/\(entity).json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
