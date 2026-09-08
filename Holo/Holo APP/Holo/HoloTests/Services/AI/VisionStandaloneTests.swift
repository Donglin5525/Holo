//
//  VisionStandaloneTests.swift
//  Holo
//
//  截图识别记账单元测试：图片管线 / 缩略图存储 / 理解单 DTO 解码 /
//  第二段拼装 / 拒识文案映射（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §4）
//

import Foundation
import UIKit

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

final class VisionStandaloneTests: XCTestCase {

    // MARK: - 图片管线

    func testCompressedJPEGKeepsUnderBudgetAndDecodable() throws {
        // 生成 3600×2700 噪声图（PNG 压不动的类型，逼真模拟相机原图）
        let width = 3600, height = 2700
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let big = renderer.image { context in
            for x in stride(from: 0, to: width, by: 24) {
                for y in stride(from: 0, to: height, by: 24) {
                    let color = UIColor(red: CGFloat(x % 255) / 255, green: CGFloat(y % 255) / 255, blue: 0.4, alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: 24, height: 24))
                }
            }
        }
        let rawData = big.jpegData(compressionQuality: 0.95)!
        let compressed = try XCTUnwrap(HoloVisionImagePipeline.compressedJPEG(from: rawData))
        XCTAssertLessThanOrEqual(compressed.count, FeedbackImageCompressor.maxBytes, "压缩后必须 ≤1MB 上行承诺")
        XCTAssertNotNil(UIImage(data: compressed), "压缩产物必须可解码")
        let longestSide = max(UIImage(data: compressed)!.size.width, UIImage(data: compressed)!.size.height) * UIImage(data: compressed)!.scale
        XCTAssertLessThanOrEqual(longestSide, 2401, "最长边降采样到 2400")
    }

    // MARK: - 缩略图存储

    func testVisionImageStoreRoundtrip() {
        let messageID = UUID()
        defer { try? FileManager.default.removeItem(at: VisionImageStore.thumbnailURL(for: messageID) ?? URL(fileURLWithPath: "/nonexistent")) }
        XCTAssertNil(VisionImageStore.thumbnailURL(for: messageID), "未保存前探测必须为 nil")
        let data = Data("vision-test-jpeg".utf8)
        VisionImageStore.save(data, messageID: messageID)
        let url = VisionImageStore.thumbnailURL(for: messageID)
        XCTAssertNotNil(url, "保存后必须能探测到")
        XCTAssertEqual(try? Data(contentsOf: url!), data, "落盘内容必须一致")
        XCTAssertNil(VisionImageStore.thumbnailURL(for: UUID()), "其他消息 ID 必须为 nil")
    }

    // MARK: - 理解单 DTO 解码

    private func decode(_ json: String) throws -> HoloVisionExtractionResponse {
        try JSONDecoder().decode(HoloVisionExtractionResponse.self, from: Data(json.utf8))
    }

    func testUnderstandingDecodeWithGuards() throws {
        let json = """
        {"ok":true,"understanding":{"imageType":"receipt","confidence":0.9,"summary":"盒马","merchant":"盒马鲜生","paidAt":"2026-09-01","paymentChannel":"支付宝","currency":"CNY","amountOriginalText":"¥98.60","items":[{"name":"菠菜","amount":6.9}],"transactions":[{"type":"expense","amount":98.6,"note":"盒马鲜生","date":"2026-09-01"}],"rejectReason":null},"guards":[{"field":"transactions","reason":"foreign_currency_forced_reject"}]}
        """
        let response = try decode(json)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.understanding.isBillable)
        XCTAssertEqual(response.understanding.transactions.first?.amount, 98.6)
        XCTAssertEqual(response.guards?.first?.reason, "foreign_currency_forced_reject")
    }

    func testUnderstandingNonBillableAndIncomeDecode() throws {
        let json = """
        {"ok":true,"understanding":{"imageType":"transfer_screenshot","confidence":0.95,"summary":null,"merchant":"张三","paidAt":null,"paymentChannel":null,"amountOriginalText":"¥500.00","items":[],"transactions":[],"rejectReason":"资金流转"},"guards":[]}
        """
        let response = try decode(json)
        XCTAssertFalse(response.understanding.isBillable)
        XCTAssertTrue(response.understanding.transactions.isEmpty)
    }

    // MARK: - 第二段拼装

    private func makeReceipt() throws -> HoloVisionUnderstanding {
        let json = """
        {"ok":true,"understanding":{"imageType":"receipt","confidence":0.92,"summary":"瑞幸","merchant":"瑞幸咖啡","paidAt":"2026-08-28","paymentChannel":"微信支付","currency":"CNY","amountOriginalText":"¥19.90","items":[{"name":"生椰拿铁","amount":9.9}],"transactions":[{"type":"expense","amount":19.9,"note":"瑞幸咖啡","date":"2026-08-28"}],"rejectReason":null},"guards":[]}
        """
        return try decode(json).understanding
    }

    @MainActor
    func testStage2TextCarriesAmountMerchantChannelAndCaption() throws {
        let text = HoloVisionExtractionService.shared.stage2Text(for: try makeReceipt(), caption: "昨天买的")
        XCTAssertTrue(text.contains("¥19.90"), "金额必须出现")
        XCTAssertTrue(text.contains("瑞幸咖啡"), "商户必须出现")
        XCTAssertTrue(text.contains("微信支付"), "支付通道必须出现（账户自动匹配依据）")
        XCTAssertTrue(text.contains("2026-08-28"), "日期必须出现")
        XCTAssertTrue(text.contains("昨天买的"), "随图附言必须出现")
        XCTAssertTrue(text.contains("生椰拿铁"), "明细必须出现")
    }

    // MARK: - 拒识文案映射

    @MainActor
    func testRejectionForNonBillableTypes() throws {
        let transfer = """
        {"ok":true,"understanding":{"imageType":"transfer_screenshot","confidence":0.95,"summary":null,"merchant":null,"paidAt":null,"paymentChannel":null,"amountOriginalText":null,"items":[],"transactions":[],"rejectReason":null},"guards":[]}
        """
        let rejection = HoloVisionExtractionService.shared.rejectionText(for: try decode(transfer).understanding)
        XCTAssertNotNil(rejection)
        XCTAssertTrue(rejection?.contains("转账") == true, "转账截图必须拒识并说明资金流转")

        let foreign = """
        {"ok":true,"understanding":{"imageType":"foreign_currency","confidence":0.9,"summary":null,"merchant":null,"paidAt":null,"paymentChannel":null,"amountOriginalText":"$14.47","items":[],"transactions":[],"rejectReason":null},"guards":[]}
        """
        let foreignRejection = HoloVisionExtractionService.shared.rejectionText(for: try decode(foreign).understanding)
        XCTAssertNotNil(foreignRejection)
        XCTAssertTrue(foreignRejection?.contains("外币") == true, "外币必须拒识并说明仅支持人民币")
    }

    @MainActor
    func testNoRejectionForBillableWithTransactions() throws {
        let service = HoloVisionExtractionService.shared
        XCTAssertNil(service.rejectionText(for: try makeReceipt()), "可记账且低置信达标 → 不拒识")
    }

    @MainActor
    func testLowConfidenceBillableIsRejected() throws {
        let json = """
        {"ok":true,"understanding":{"imageType":"receipt","confidence":0.3,"summary":null,"merchant":null,"paidAt":null,"paymentChannel":null,"amountOriginalText":null,"items":[],"transactions":[{"type":"expense","amount":12,"note":null,"date":null}],"rejectReason":null},"guards":[]}
        """
        let rejection = HoloVisionExtractionService.shared.rejectionText(for: try decode(json).understanding)
        XCTAssertNotNil(rejection, "低置信红线：金额不确定必须拒识引导重拍")
    }
}

#else
@main
private struct HoloVisionStandaloneLauncher {
    static func main() async throws {
        VisionStandaloneTests().testCompressedJPEGKeepsUnderBudgetAndDecodable()
        VisionStandaloneTests().testVisionImageStoreRoundtrip()
    }
}
#endif
