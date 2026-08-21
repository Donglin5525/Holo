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
        let period: String?
        let upgradeAvailable: Bool?
        let maxSeconds: Double?
        let actualSeconds: Double?
    }

    let error: Payload
}

nonisolated enum HoloQuotaError: Error, Equatable, LocalizedError {
    case quotaExceeded(payload: HoloQuotaErrorResponse.Payload)
    case asrDurationExceeded(payload: HoloQuotaErrorResponse.Payload)

    var payload: HoloQuotaErrorResponse.Payload {
        switch self {
        case .quotaExceeded(let payload), .asrDurationExceeded(let payload):
            return payload
        }
    }

    var code: String {
        payload.code
    }

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
            // 深度洞察与对话是两个独立额度池（免费 2/天 vs 15/天），
            // 文案必须指明是哪个池用完，否则用户无从判断。
            case "deepAnalysis": feature = "深度分析"
            case "chat": feature = "对话"
            case "lifePlan": feature = "周计划"
            default: feature = "HoloAI"
            }
            // 兼容旧版后端：记忆洞察免费额度原本按周、Plus 按日。
            let period = payload.period ?? (
                payload.quotaType == "memoryInsight" && payload.tier == "free" ? "week" : "day"
            )
            let periodLabel: String
            switch period {
            case "week": periodLabel = "本周"
            case "month": periodLabel = "本月"
            case "day": periodLabel = "今天"
            default: periodLabel = "当前"
            }
            return upgradeAvailable
                ? "\(periodLabel)的免费\(feature)额度已用完，升级 Holo Plus 可继续使用"
                : "\(periodLabel)的\(feature)额度已用完，请在额度重置后再试"
        case .asrDurationExceeded(let payload):
            let seconds = Int(payload.maxSeconds ?? 0)
            return upgradeAvailable
                ? "免费版单次最多识别 \(seconds) 秒，升级 Holo Plus 可识别更长语音"
                : "单次语音最长可识别 \(seconds) 秒，请缩短录音后重试"
        }
    }

    /// 面向日志的完整诊断信息；用户提示使用 userMessage，避免丢失额度周期和重置时间。
    var diagnosticDescription: String {
        let resetAt = payload.resetAt ?? "unknown"
        return "\(payload.code) quotaType=\(payload.quotaType ?? "unknown") tier=\(payload.tier ?? "unknown") period=\(payload.period ?? "unknown") used=\(payload.used ?? -1)/\(payload.limit ?? -1) remaining=\(payload.remaining ?? -1) resetAt=\(resetAt)"
    }

    var errorDescription: String? {
        userMessage
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

    /// 发起前预检的本地额度文案（未发生后端拦截、无 payload 时使用，
    /// 与 quotaExceeded 的 userMessage 口径一致）。
    static func deepAnalysisExhaustedMessage(isPlusActive: Bool) -> String {
        isPlusActive
            ? "今天的深度分析额度已用完，请在额度重置后再试"
            : "今天的免费深度分析额度已用完，升级 Holo Plus 可继续使用"
    }

    /// 洞察额度预检文案：免费版按周（1 次/周）、Plus 按日（1 次/天），周期措辞随之不同。
    static func memoryInsightExhaustedMessage(isPlusActive: Bool) -> String {
        isPlusActive
            ? "今天的记忆洞察额度已用完，请在额度重置后再试"
            : "本周的免费记忆洞察额度已用完，升级 Holo Plus 可继续使用"
    }

    /// 语音识别（asr 池，免费 20 次/天、Plus 50 次/天）预检文案。
    static func asrExhaustedMessage(isPlusActive: Bool) -> String {
        isPlusActive
            ? "今天的语音识别额度已用完，请在额度重置后再试"
            : "今天的免费语音识别额度已用完，升级 Holo Plus 可继续使用"
    }

    /// 对话额度（chat 池，免费 15/天、Plus 30/天）预检文案。
    static func chatExhaustedMessage(isPlusActive: Bool) -> String {
        isPlusActive
            ? "今天的对话额度已用完，请在额度重置后再试"
            : "今天的免费对话额度已用完，升级 Holo Plus 可继续使用"
    }

    /// 目标规划预检文案：目标规划与日常对话共用 chat 池，
    /// 须点明这层关系，否则「点目标规划却提示对话额度」用户无从理解。
    static func goalPlanningExhaustedMessage(isPlusActive: Bool) -> String {
        isPlusActive
            ? "今天的对话额度已用完（目标规划也使用对话额度），请在额度重置后再试"
            : "今天的免费对话额度已用完（目标规划也使用对话额度），升级 Holo Plus 可继续使用"
    }
}
