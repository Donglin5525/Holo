//
//  HoloQuotaError.swift
//  Holo
//
//  后端付费额度错误的统一客户端类型。
//

import Foundation

nonisolated struct HoloQuotaErrorResponse: Decodable, Error {
    nonisolated struct Payload: Decodable, Equatable {
        let code: String
        let message: String
        let quotaType: String?
        let tier: String?
        let limit: Int?
        let used: Int?
        let remaining: Int?
        let resetAt: String?
        let upgradeAvailable: Bool?
        let maxSeconds: Double?
        let actualSeconds: Double?
    }

    let error: Payload
}

nonisolated enum HoloQuotaError: Error, Equatable {
    case quotaExceeded(payload: HoloQuotaErrorResponse.Payload)
    case asrDurationExceeded(payload: HoloQuotaErrorResponse.Payload)

    var upgradeAvailable: Bool {
        switch self {
        case .quotaExceeded(let payload), .asrDurationExceeded(let payload):
            return payload.upgradeAvailable ?? false
        }
    }

    var userMessage: String {
        switch self {
        case .quotaExceeded(let payload):
            let feature: String
            switch payload.quotaType {
            case "asr": feature = "语音识别"
            case "naturalLanguageFinance": feature = "智能记账"
            case "naturalLanguageTask": feature = "智能任务"
            case "memoryInsight": feature = "记忆洞察"
            default: feature = "HoloAI"
            }
            return upgradeAvailable
                ? "今天的免费\(feature)额度已用完，升级 Holo Plus 可继续使用"
                : "今天的 \(feature)额度已用完，请在额度重置后再试"
        case .asrDurationExceeded(let payload):
            let seconds = Int(payload.maxSeconds ?? 0)
            return upgradeAvailable
                ? "免费版单次最多识别 \(seconds) 秒，升级 Holo Plus 可识别更长语音"
                : "单次语音最长可识别 \(seconds) 秒，请缩短录音后重试"
        }
    }

    static func decode(from data: Data) -> HoloQuotaError? {
        guard let response = try? JSONDecoder().decode(HoloQuotaErrorResponse.self, from: data) else {
            return nil
        }

        switch response.error.code {
        case "QUOTA_EXCEEDED":
            return .quotaExceeded(payload: response.error)
        case "ASR_DURATION_EXCEEDED":
            return .asrDurationExceeded(payload: response.error)
        default:
            return nil
        }
    }
}
