//
//  HoloVisionExtractionService.swift
//  Holo
//
//  截图识别记账 · 视觉抽取客户端（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §4）
//  两段式架构的第一段：图片 → /v1/ai/vision/extract → 图片理解单。
//  第二段（理解单 + 随图文字 → 现有 intent 管道）由 ChatViewModel 视图分支承接。
//
//  契约要点：
//  - 图片本地压缩 ≤1MB、剥 EXIF/GPS（与反馈截图同一管线标准），服务端识别完即弃。
//  - 拒识判定（外币/转账/未支付等）以服务端理解单为准；服务端有确定性护栏
//    （amountOriginalText 外币符号强制拒识），客户端不再重复实现。
//  - 账户匹配（拍板 6）：微信/支付宝/尾号关键词匹配既有账户，匹配不到落默认账户。
//

import Foundation
import CoreData
import os.log
import UIKit

// MARK: - DTO

struct HoloVisionExtractionRequest: Encodable {
    /// base64 编码的 JPEG（≤1.5MB，服务端校验魔数）
    let image: String
    /// 用户随图附言（可空）
    let text: String?
}

struct HoloVisionExtractionResponse: Decodable {
    let ok: Bool
    let understanding: HoloVisionUnderstanding
    /// 服务端护栏改写记录（观测用）
    let guards: [HoloVisionGuard]?
}

struct HoloVisionUnderstanding: Decodable {
    let imageType: String
    let confidence: Double
    let summary: String?
    let merchant: String?
    let paidAt: String?
    let paymentChannel: String?
    let amountOriginalText: String?
    let items: [HoloVisionItem]?
    let transactions: [HoloVisionTransaction]
    let rejectReason: String?

    /// 可记账图型（其余图型一律拒识，与后端 BILLABLE_TYPES 对齐）
    var isBillable: Bool {
        imageType == HoloVisionUnderstanding.receipt || imageType == HoloVisionUnderstanding.paymentScreenshot
    }

    static let receipt = "receipt"
    static let paymentScreenshot = "payment_screenshot"
}

struct HoloVisionItem: Decodable {
    let name: String?
    let amount: Double?
}

struct HoloVisionTransaction: Decodable {
    /// "expense" | "income"
    let type: String?
    let amount: Double
    let note: String?
    let date: String?

    var isIncome: Bool { type == "income" }
}

struct HoloVisionGuard: Decodable {
    let field: String?
    let reason: String?
}

// MARK: - 图片管线

enum HoloVisionImagePipeline {

    /// 上行标准：与反馈截图一致——降采样最长边 2400 + 循环降质 ≤1MB，
    /// 重绘剥离 EXIF/GPS（隐私红线：不上传位置元数据）。
    static func compressedJPEG(from rawData: Data) -> Data? {
        guard UIImage(data: rawData) != nil else { return nil }
        var quality: CGFloat = 0.75
        var output = AttachmentFileManager.compressImage(UIImage(data: rawData)!, maxDimension: 2400, quality: quality)
        while let current = output, current.count > FeedbackImageCompressor.maxBytes, quality > 0.3 {
            quality -= 0.15
            output = AttachmentFileManager.compressImage(UIImage(data: rawData)!, maxDimension: 2400, quality: quality)
        }
        return output
    }
}

// MARK: - 聊天图片缩略图存储（拍板 5：聊天里存缩略图）
//
// 缩略图不进 Core Data：以「消息 ID → 确定性路径」落盘（Documents/ChatVisionImages/），
// 避免为 ChatMessage 加字段触发 CloudKit schema 增量部署（可与 1.0.3 后续一起做）。
// 气泡渲染时按路径探测，文件不存在（如换设备同步的历史）就不显示图。

enum VisionImageStore {

    private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChatVisionImages", isDirectory: true)
    }

    static func save(_ jpegData: Data, messageID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? jpegData.write(to: url(for: messageID))
    }

    static func thumbnailURL(for messageID: UUID) -> URL? {
        let url = url(for: messageID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func url(for messageID: UUID) -> URL {
        directory.appendingPathComponent("\(messageID.uuidString).jpg")
    }
}

// MARK: - 服务

@MainActor
final class HoloVisionExtractionService {

    static let shared = HoloVisionExtractionService()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloVisionExtraction")

    /// 识别失败的统一错误（ChatViewModel 落为失败气泡）
    struct VisionError: LocalizedError {
        let userMessage: String
        var errorDescription: String? { userMessage }
    }

    /// 一次识别的完整产物（理解单 + 账户匹配 + 防重提示）
    struct ExtractionOutcome {
        let understanding: HoloVisionUnderstanding
        /// 拒识文案（imageType 不可记账或低置信时非 nil）
        let rejectionText: String?
        /// 防重软提示（拍板 9：只提示不阻断）
        let duplicateHints: [String]
        /// 支付通道匹配到的账户（拍板 6：确认后归位；nil = 落默认账户）
        let matchedAccount: Account?
    }

    private let apiClient = APIClient.shared

    /// 上传识别。调用方已压缩好的 JPEG 直接传；rawData 也可（内部走压缩管线）。
    func extract(rawImageData: Data, caption: String?) async throws -> ExtractionOutcome {
        guard let jpeg = HoloVisionImagePipeline.compressedJPEG(from: rawImageData) else {
            throw VisionError(userMessage: String(localized: "图片读取失败，请换一张试试"))
        }

        let request = APIRequest(
            baseURL: HoloBackendEnvironment.baseURL,
            path: "/v1/ai/vision/extract",
            method: .post,
            headers: [
                "Content-Type": "application/json",
                "X-Holo-Device-Id": HoloBackendDeviceIdentity.shared.deviceId,
            ],
            body: HoloVisionExtractionRequest(
                image: jpeg.base64EncodedString(),
                text: caption?.isEmpty == false ? caption : nil
            )
        )
        let response: HoloVisionExtractionResponse = try await apiClient.send(request)
        let understanding = response.understanding

        let rejection = rejectionText(for: understanding)
        let hints = rejection == nil ? await duplicateHints(for: understanding) : []
        let account = rejection == nil ? matchedAccount(for: understanding) : nil

        return ExtractionOutcome(
            understanding: understanding,
            rejectionText: rejection,
            duplicateHints: hints,
            matchedAccount: account
        )
    }

    // MARK: 拒识文案（拍板 1/7 + 方案 §3.3：宁可问不瞎猜落库）
    // internal 供单测锁定图型→文案映射

    func rejectionText(for understanding: HoloVisionUnderstanding) -> String? {
        // 低置信红线：金额都不确定就不出确认卡，引导重拍或手填
        if understanding.isBillable && understanding.confidence < 0.45 {
            return String(localized: "这张图我不太看得清金额，不敢替你记。重新拍一张清楚的，或者手动记一笔？")
        }
        guard !understanding.isBillable || understanding.transactions.isEmpty else { return nil }
        if understanding.isBillable && !understanding.transactions.isEmpty { return nil }

        switch understanding.imageType {
        case HoloVisionUnderstanding.receipt, HoloVisionUnderstanding.paymentScreenshot:
            // 可记账图型但没有可解析的交易
            return String(localized: "图里像是消费凭证，但我没能可靠地认出金额。重新拍一张，或手动记一笔？")
        case "transfer_screenshot":
            return String(localized: "这是转账/还款类截图，属于资金流转，我不把它记成消费。")
        case "wealth_screenshot":
            return String(localized: "这是理财/余额页面，没有需要记的账。")
        case "list_note":
            return String(localized: "这是一份清单。清单转任务功能还在路上，辛苦先手动建任务。")
        case "foreign_currency":
            return String(localized: "这是外币消费，目前只支持人民币记账，可以换算后手动记一笔。")
        case "pending_order":
            return String(localized: "订单还没支付。支付完成后再拍给我，我帮你记。")
        default:
            return String(localized: "这张图里我没找到能记的账。拍张小票或支付截图试试？")
        }
    }

    // MARK: 第二段拼装：理解单 → 自然语言（走现有 intent 管道，零改动）

    func stage2Text(for understanding: HoloVisionUnderstanding, caption: String?) -> String {
        var lines: [String] = [String(localized: "【图片记账】请把图片里识别出的以下交易记下来：")]
        for (index, transaction) in understanding.transactions.enumerated() {
            let direction = transaction.isIncome
                ? String(localized: "收入")
                : String(localized: "支出")
            let merchant = transaction.note ?? understanding.merchant ?? understanding.summary
            var line = "\(index + 1). \(direction)¥\(formatAmount(transaction.amount))"
            if let merchant, !merchant.isEmpty {
                line += String(localized: "，商户「\(merchant)」")
            }
            if let date = transaction.date {
                line += String(localized: "，日期 \(date)")
            }
            lines.append(line)
        }
        if let channel = understanding.paymentChannel {
            lines.append(String(localized: "支付方式：\(channel)"))
        }
        let itemNames = (understanding.items ?? []).compactMap { item -> String? in
            guard let name = item.name else { return nil }
            return "\(name) ¥\(formatAmount(item.amount ?? 0))"
        }
        if !itemNames.isEmpty {
            lines.append(String(localized: "明细：\(itemNames.joined(separator: "；"))"))
        }
        if let caption, !caption.isEmpty {
            lines.append(String(localized: "用户附言：「\(caption)」"))
        }
        return lines.joined(separator: "\n")
    }

    private func formatAmount(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    // MARK: 账户匹配（拍板 6：自动识别微信/支付宝，卡上可改）

    private func matchedAccount(for understanding: HoloVisionUnderstanding) -> Account? {
        guard let channel = understanding.paymentChannel, !channel.isEmpty else { return nil }
        let accounts = FinanceRepository.shared.getAccounts()
        guard !accounts.isEmpty else { return nil }

        // 尾号优先：支付通道是 4 位数字时按账户名含尾号匹配
        if let tail = channel.firstMatch(of: /\d{4}/)?.output {
            if let hit = accounts.first(where: { $0.name.contains(String(tail)) == true }) {
                return hit
            }
        }
        // 通道名关键词：账户名含「微信」「支付宝」「现金」等
        let keywords = [String(localized: "微信"), String(localized: "支付宝"), String(localized: "现金")]
        for keyword in keywords where channel.contains(keyword) {
            if let hit = accounts.first(where: { $0.name.contains(keyword) == true }) {
                return hit
            }
        }
        return nil
    }

    // MARK: 防重软检测（拍板 9：只提示不阻断，借鉴 BillDuplicateDetector 口径）

    private func duplicateHints(for understanding: HoloVisionUnderstanding) async -> [String] {
        let calendar = Calendar.current
        let now = Date()
        guard let from = calendar.date(byAdding: .day, value: -2, to: now) else { return [] }
        let recent = (try? await FinanceRepository.shared.getTransactions(from: from, to: now)) ?? []

        var hints: [String] = []
        for transaction in understanding.transactions.prefix(3) {
            let amount = Decimal(transaction.amount)
            let hit = recent.first { existing in
                guard existing.isReconciliationAdjustment == false else { return false }
                let existingAmount = existing.amount.decimalValue
                let sameDirection = (transaction.isIncome && existing.type == "income")
                    || (!transaction.isIncome && existing.type == "expense")
                return abs(existingAmount - amount) < Decimal(string: "0.005")! && sameDirection
            }
            if let hit {
                let dayText = DateFormatter.localizedString(from: hit.date, dateStyle: .short, timeStyle: .none)
                hints.append(String(localized: "提醒：这笔可能已经记过（\(dayText) ¥\(formatAmount(transaction.amount))），确认前请留意，避免重复。"))
            }
        }
        return hints
    }
}

// MARK: - 确认后账户归位（拍板 6）

extension FinanceRepository {

    /// 截图记账确认后把交易搬到匹配账户：IntentRouter 落库走默认账户，
    /// 识别出的支付通道匹配到更合适账户时只换 account 关系，
    /// 不动分类/金额/统计口径（对余额与统计的影响与用户手动改账户一致）。
    func moveTransactionToAccount(transactionId: UUID, accountId: UUID) async throws {
        guard let transaction = findTransactions(by: [transactionId]).first,
              let account = findAccount(by: accountId) else { return }
        transaction.account = account
        transaction.updatedAt = Date()
        try context.save()
    }
}
