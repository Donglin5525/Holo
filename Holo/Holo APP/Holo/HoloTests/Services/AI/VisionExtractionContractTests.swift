//
//  VisionExtractionContractTests.swift
//  HoloTests
//
//  截图识别记账 /v1/ai/vision/extract 跨端契约回归（2026-11-06 转账/红包开放随案设立）。
//  本文件用**后端真实响应形状的 JSON 字面量**走 JSONDecoder 真实解码对拍 iOS 模型。
//  字面量唯一真源 = HoloBackend/src/app.js（:1810 识图路由 context.json 返回体）与
//  HoloBackend/src/vision/understandingContract.js（normalizeUnderstanding 输出；下列
//  字面量为该函数在四个代表输入上的实测输出原文，生成于 2026-11-06）。capabilities
//  请求字段真源 = 同文件 resolveVisionCapabilities（老后端 readJson 忽略未知字段）。
//
//  ⚠️ 变更义务：改任何一端，必须同步改另一端与本文件；禁止为了让测试变绿而
//  单方面修改这里的字面量去迁就 iOS 模型。
//

import XCTest
@testable import Holo

final class VisionExtractionContractTests: XCTestCase {

    private func decode(_ json: String) throws -> HoloVisionExtractionResponse {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(HoloVisionExtractionResponse.self, from: data)
    }

    // MARK: - 响应包（app.js :1810：ok + understanding + guards + automationPolicy）

    private static let allowedPendingTransfer = """
    {"ok":true,"understanding":{"schemaVersion":4,"imageType":"personal_transfer","confidence":0.94,"paymentStatus":"completed","paymentStatusOriginalText":"待王小明确认收款","summary":"微信转账给王小明200元，待对方收款","merchant":"王小明","paidAt":"2026-11-02","paymentChannel":"微信零钱","currency":"CNY","amountOriginalText":"¥200.00","items":[],"transactions":[{"type":"expense","amount":200,"note":"生活费","date":"2026-11-02","amountOriginalText":"¥200.00","paymentChannel":"微信零钱","confidence":{"amount":0.98,"direction":0.95,"paymentStatus":0.9,"date":0.9,"merchant":0.95,"paymentChannel":0.9},"categoryCandidate":"王小明","normalizedCategoryCandidate":"生活费","semanticCategoryHint":"其他","transfer":{"kind":"transfer","counterparty":"王小明","counterpartyAccount":null,"awaitingReceipt":true}}],"rejectReason":null},"guards":[],"automationPolicy":{"autoCommitAllowed":false,"policyVersion":"v1"}}
    """

    func testAllowedTransferDecodesWithTransferObject() throws {
        // 客户端声明能力且总闸开：personal_transfer 放行，待收款(pending)被后端钳成
        // completed+awaitingReceipt=true（领域口径，无 guard）
        let r = try decode(Self.allowedPendingTransfer)
        XCTAssertTrue(r.ok)
        let u = r.understanding
        XCTAssertTrue(u.isBillable, "personal_transfer 是可记账图型")
        XCTAssertEqual(u.imageType, "personal_transfer")
        XCTAssertEqual(u.schemaVersion, 4)
        XCTAssertEqual(u.paymentStatus, "completed")
        let tx = try XCTUnwrap(u.transactions.first)
        XCTAssertEqual(tx.amount, 200)
        XCTAssertFalse(tx.isIncome)
        XCTAssertEqual(tx.effectivePaymentChannel(fallback: nil), "微信零钱")
        let transfer = try XCTUnwrap(tx.transfer, "转账对象必须解码出（transfer 键恒在）")
        XCTAssertEqual(transfer.kind, "transfer")
        XCTAssertEqual(transfer.counterparty, "王小明")
        XCTAssertNil(transfer.counterpartyAccount)
        XCTAssertTrue(transfer.awaitingReceipt, "待对方收款：后端已钳成 awaitingReceipt=true")
        XCTAssertNil(r.guards?.first, "待收款不是异常，不产生 guard")
        XCTAssertEqual(r.automationPolicy?.autoCommitAllowed, false)
        XCTAssertEqual(r.automationPolicy?.policyVersion, "v1")
    }

    func testDowngradedResponseMatchesLegacyTransferScreenshot() throws {
        // 老客户端/总闸关：降级为 transfer_screenshot + 清空交易 + guard（v3 老口径）
        let payload = """
        {"ok":true,"understanding":{"schemaVersion":4,"imageType":"transfer_screenshot","confidence":0.94,"paymentStatus":"pending","paymentStatusOriginalText":"待王小明确认收款","summary":"微信转账给王小明200元，待对方收款","merchant":"王小明","paidAt":"2026-11-02","paymentChannel":"微信零钱","currency":"CNY","amountOriginalText":"¥200.00","items":[],"transactions":[],"rejectReason":"这是还款、提现或理财这类资金挪动，不计入收支"},"guards":[{"field":"imageType","reason":"personal_transfer_not_enabled","from":"personal_transfer","to":"transfer_screenshot"}],"automationPolicy":{"autoCommitAllowed":false,"policyVersion":"v1"}}
        """
        let r = try decode(payload)
        let u = r.understanding
        XCTAssertFalse(u.isBillable, "老口径下 transfer_screenshot 不可记账")
        XCTAssertEqual(u.imageType, "transfer_screenshot")
        XCTAssertTrue(u.transactions.isEmpty)
        XCTAssertEqual(r.guards?.first?.reason, "personal_transfer_not_enabled")
    }

    func testReturnedTransferKeepsImageTypeAndRejects() throws {
        // 已退回：交易被清空但图型保持 personal_transfer（客户端说「已退回」而不是「未支付」）
        let payload = """
        {"ok":true,"understanding":{"schemaVersion":4,"imageType":"personal_transfer","confidence":0.94,"paymentStatus":"refunded","paymentStatusOriginalText":"已退还","summary":"微信转账给王小明200元，待对方收款","merchant":"王小明","paidAt":"2026-11-02","paymentChannel":"微信零钱","currency":"CNY","amountOriginalText":"¥200.00","items":[],"transactions":[],"rejectReason":"这笔转账或红包已经退回、过期或没有完成，不用记账"},"guards":[{"field":"transactions","reason":"transfer_not_completed_cleared","paymentStatus":"refunded"}],"automationPolicy":{"autoCommitAllowed":false,"policyVersion":"v1"}}
        """
        let r = try decode(payload)
        XCTAssertEqual(r.understanding.imageType, "personal_transfer")
        XCTAssertTrue(r.understanding.transactions.isEmpty)
        XCTAssertEqual(r.guards?.first?.reason, "transfer_not_completed_cleared")
    }

    func testReceiptCarriesNullTransferKey() throws {
        // 普通小票：transfer 键恒在但为 null（非转账图型强制 null）
        let payload = """
        {"ok":true,"understanding":{"schemaVersion":4,"imageType":"receipt","confidence":0.95,"paymentStatus":"completed","paymentStatusOriginalText":"支付成功","summary":"瑞幸咖啡微信支付小票","merchant":"瑞幸咖啡","paidAt":"2026-09-14","paymentChannel":"微信支付","currency":"CNY","amountOriginalText":"¥19.90","items":[{"name":"生椰拿铁","amount":19.9}],"transactions":[{"type":"expense","amount":19.9,"note":"瑞幸咖啡","date":"2026-09-14","amountOriginalText":"¥19.90","paymentChannel":"微信支付","confidence":{"amount":0.99,"direction":0.99,"paymentStatus":0.98,"date":0.94,"merchant":0.96,"paymentChannel":0.97},"categoryCandidate":"瑞幸咖啡","normalizedCategoryCandidate":"咖啡","semanticCategoryHint":"餐饮","transfer":null}],"rejectReason":null},"guards":[],"automationPolicy":{"autoCommitAllowed":false,"policyVersion":"v1"}}
        """
        let r = try decode(payload)
        XCTAssertEqual(r.understanding.imageType, "receipt")
        let tx = try XCTUnwrap(r.understanding.transactions.first)
        XCTAssertNil(tx.transfer, "非转账交易的 transfer 必须是 null")
        XCTAssertEqual(tx.categoryCandidate, "瑞幸咖啡")
    }

    // MARK: - 请求包（HoloVisionExtractionRequest：能力声明字段）

    func testRequestEncodesCapabilityDeclaration() throws {
        let request = HoloVisionExtractionRequest(image: "<jpeg>", text: nil)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"capabilities\":[\"personal_transfer\"]"),
                      "新版客户端必须声明 personal_transfer 能力（老后端忽略未知字段）")
        XCTAssertFalse(json.contains("\"text\""), "可选 text 为 nil 时不出现（既有行为不变）")
    }
}
