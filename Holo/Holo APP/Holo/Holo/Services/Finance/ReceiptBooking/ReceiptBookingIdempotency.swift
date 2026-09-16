//
//  ReceiptBookingIdempotency.swift
//  Holo
//
//  图片快捷指令自动记账 · 精确幂等（2026-09-14 完整方案 §9.1/§24.4）
//  红线：同一张图无论连按、系统重试还是回执丢失，只能产生一笔交易。
//
//  来源键复用 Transaction.aiSourceMessageId + aiSourceItemId，不新增 CloudKit 字段：
//    aiSourceMessageId = vision:v2:<SHA256(规范化JPEG)>
//    aiSourceItemId    = transaction:<条目序号>
//  摘要基于「压缩后实际上传的规范化 JPEG」——同一原图多次压缩结果确定一致
//  （同参数重绘管线），不同裁剪的同一笔由语义重复检测兜底。
//

import Foundation
import CryptoKit

enum ReceiptBookingIdempotency {

    /// 规范化 JPEG 数据摘要 → 稳定来源键。contractVersion 跟随后端理解单契约版本。
    static func sourceKey(forNormalizedJPEG data: Data, contractVersion: Int = 2) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "vision:v\(contractVersion):\(hex)"
    }

    /// 交易条目键（方案 §24.4：M1 自动提交只允许单笔，条目固定 transaction:0）
    static func itemKey(index: Int) -> String {
        "transaction:\(index)"
    }
}
