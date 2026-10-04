//
//  ReceiptAttachmentTests.swift
//  HoloTests
//
//  账票根（交易照片附件）存储层单测（2026-09-27 账票根方案 §5）：
//  - attach/detach 往返与 sortOrder 递增
//  - 满 3 张护栏（模型不封死，仓库层拦截）
//  - 清理识图票根只删 receiptBooking，交易与手动票根不动
//  - 删除交易附件级联即净；软删标记不断关系（恢复即回）
//  - 票头文案（识图凭证不带时间）
//

import XCTest
import CoreData
import UIKit
@testable import Holo

@MainActor
final class ReceiptAttachmentTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var account: Account!
    private var category: Holo.Category!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(
            context,
            ["Transaction", "TransactionAttachment", "Category", "Account", "Budget", "FinanceProject"]
        )

        repo = FinanceRepository(context: context)
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

    /// 纯色小图 JPEG（过压缩管线用）
    private func makeImageData(hue: CGFloat = 0.06) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let image = renderer.image { ctx in
            UIColor(hue: hue, saturation: 0.8, brightness: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    @discardableResult
    private func makeTransaction() async throws -> Transaction {
        try await repo.addTransaction(amount: 35, type: .expense, category: category, account: account)
    }

    // MARK: - 贴/撕往返

    func testAttachAndDetach() async throws {
        let tx = try await makeTransaction()
        let first = try await repo.attachReceipt(to: tx, imageData: try makeImageData(), source: .camera)
        let second = try await repo.attachReceipt(to: tx, imageData: try makeImageData(hue: 0.5), source: .photoLibrary)

        XCTAssertEqual(tx.receiptAttachments.count, 2)
        XCTAssertEqual(tx.receiptAttachments.map(\.id), [first.id, second.id], "旧→新排序")
        XCTAssertEqual(tx.receiptAttachments.map(\.sortOrder), [0, 1], "sortOrder 从 0 递增")
        XCTAssertNotNil(first.imageData, "原图走 2048 压缩管线落库")
        XCTAssertNotNil(first.thumbnailData, "300px 缩略图双存")
        XCTAssertEqual(first.transaction?.id, tx.id)

        try repo.detachReceipt(first)
        XCTAssertEqual(tx.receiptAttachments.map(\.id), [second.id], "撕掉后剩后贴的")
        XCTAssertNil(first.managedObjectContext, "附件删除即净，无孤儿")
    }

    func testReceiptLimitGuard() async throws {
        let tx = try await makeTransaction()
        for _ in 0..<Transaction.maxReceiptCount {
            _ = try await repo.attachReceipt(to: tx, imageData: try makeImageData(), source: .camera)
        }
        do {
            _ = try await repo.attachReceipt(to: tx, imageData: try makeImageData(), source: .camera)
            XCTFail("第 4 张应被仓库层拦截")
        } catch FinanceError.receiptLimitReached {
            // 预期：满 3 张护栏
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        XCTAssertEqual(tx.receiptAttachments.count, Transaction.maxReceiptCount)
    }

    // MARK: - 清理识图票根

    func testPurgeReceiptBookingOnly() async throws {
        let manualTx = try await makeTransaction()
        let bookingTx = try await makeTransaction()
        _ = try await repo.attachReceipt(to: manualTx, imageData: try makeImageData(), source: .photoLibrary)
        _ = try await repo.attachReceipt(to: bookingTx, imageData: try makeImageData(), source: .receiptBooking)
        _ = try await repo.attachReceipt(to: bookingTx, imageData: try makeImageData(hue: 0.9), source: .receiptBooking)

        XCTAssertEqual(repo.receiptBookingReceiptCount(), 2)

        let purged = try repo.purgeReceiptBookingReceipts()
        XCTAssertEqual(purged, 2)
        XCTAssertEqual(manualTx.receiptAttachments.count, 1, "手动贴的票根不动")
        XCTAssertEqual(bookingTx.receiptAttachments.count, 0, "识图票根全清")
        XCTAssertFalse(bookingTx.isDeleted, "交易本身不动")
        XCTAssertEqual(repo.receiptBookingReceiptCount(), 0)
    }

    // MARK: - 生命周期

    func testCascadeDeleteWithTransaction() async throws {
        let tx = try await makeTransaction()
        let attachment = try await repo.attachReceipt(to: tx, imageData: try makeImageData(), source: .camera)
        try await repo.deleteTransaction(tx)

        XCTAssertNil(attachment.managedObjectContext, "交易删除附件级联即净")
        let request = TransactionAttachment.fetchRequest()
        XCTAssertEqual(try context.count(for: request), 0)
    }

    func testSoftDeleteKeepsAttachmentRelation() async throws {
        let tx = try await makeTransaction()
        let attachment = try await repo.attachReceipt(to: tx, imageData: try makeImageData(), source: .camera)
        tx.deletedAt = Date()
        try context.save()

        XCTAssertEqual(attachment.transaction?.id, tx.id, "软删标记不断关系，恢复交易票根随行")
        XCTAssertEqual(tx.receiptAttachments.count, 1)
    }

    // MARK: - 票头文案

    func testReceiptCaptionBySource() async throws {
        let tx = try await makeTransaction()
        let camera = try await repo.attachReceipt(to: tx, imageData: try makeImageData(), source: .camera)
        let booking = try await repo.attachReceipt(to: tx, imageData: try makeImageData(hue: 0.3), source: .receiptBooking)

        XCTAssertTrue(camera.receiptCaption.hasPrefix("拍照 · "), "拍照来源带时间：\(camera.receiptCaption)")
        XCTAssertEqual(booking.receiptCaption, "识图凭证", "识图凭证不带时间（归档时刻≠拍照时刻）")
    }

    // MARK: - 全屏查看解码

    func testFullyDecodedImageKeepsOriginalSizeAndSmallImageNotUpscaled() throws {
        // 2048×1536 像素图（scale=1 固定，pt=px）：强制解码后尺寸不变（不降采样）
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1536), format: format)
        let big = renderer.image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
        }
        let bigData = try XCTUnwrap(big.jpegData(compressionQuality: 0.8))
        let decoded = try XCTUnwrap(AttachmentFileManager.fullyDecodedImage(from: bigData))
        XCTAssertEqual(decoded.size.width, 2048, accuracy: 4, "强制解码不降采样，保持原图尺寸")
        XCTAssertEqual(decoded.size.height, 1536, accuracy: 4)
        XCTAssertNotNil(decoded.cgImage, "像素数据已就绪（立即解码）")

        // 小图（40×30 像素）：不被放大到 maxPixelSize 上限
        let smallRenderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format)
        let small = smallRenderer.image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let smallData = try XCTUnwrap(small.jpegData(compressionQuality: 0.8))
        let decodedSmall = try XCTUnwrap(AttachmentFileManager.fullyDecodedImage(from: smallData))
        XCTAssertEqual(decodedSmall.size.width, 40, accuracy: 2, "小图不放大")
        XCTAssertEqual(decodedSmall.size.height, 30, accuracy: 2)
    }
}
