//
//  APIError.swift
//  Holo
//
//  API 错误枚举
//  统一的网络请求错误类型
//

import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case networkUnavailable
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case rateLimited(String?)
    case timeout
    case cancelled
    case serverError(String)
    case backendError(statusCode: Int, code: String?, message: String, requestId: String?)
    /// §8.2：409 STEP_IN_PROGRESS——后端同一 step 正在处理中，幂等协议退避重试
    case stepInProgress(String?)
    /// §8.2：409 STEP_ID_CONFLICT——同一 stepID 提交了不同 payload（终态协议错误，不重试）
    case stepIdConflict(String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .networkUnavailable:
            return "网络不可用，请检查网络连接"
        case .httpError(_, let message):
            return message
        case .decodingError(let error):
            return "数据解析失败：\(error.localizedDescription)"
        case .rateLimited(let message):
            return message ?? "今天的 AI 使用次数已达上限，稍后再试"
        case .timeout:
            return "请求超时，请稍后重试"
        case .cancelled:
            return "请求已取消"
        case .serverError(let message):
            return message
        case .backendError(_, _, let message, _):
            return message
        case .stepInProgress(let message):
            return message ?? "相同请求正在后端处理中，稍后重试"
        case .stepIdConflict(let message):
            return message ?? "请求步标识冲突：同一 step 提交了不同内容"
        }
    }

    /// 是否可重试
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .serverError:
            return true
        case .backendError(let statusCode, let code, _, _):
            // 模型输出结构/流完整性问题不能在 HTTP 层拿同一 payload 盲重放：
            // Agent runtime 会把它计为一轮，生成带纠错上下文的新 step，再按用户轮数预算继续。
            // 洞察类同理，后端已做过其自身的受控重试。
            let outputContractCodes = [
                "EMPTY_MODEL_RESPONSE",
                "TRUNCATED_MODEL_RESPONSE",
                "INVALID_INSIGHT_JSON",
                "INVALID_AGENT_JSON",
                "UPSTREAM_SSE_INVALID_FRAME",
                "UPSTREAM_SSE_INCOMPLETE"
            ]
            return statusCode >= 500 && !outputContractCodes.contains(code ?? "")
        case .httpError(let statusCode, _):
            return statusCode >= 500 || statusCode == 429
        default:
            return false
        }
    }

    var diagnosticCategory: String {
        switch self {
        case .backendError(_, let code, _, _): return code ?? "BACKEND_ERROR"
        case .timeout: return "TIMEOUT"
        case .networkUnavailable: return "NETWORK_UNAVAILABLE"
        case .rateLimited: return "RATE_LIMITED"
        case .cancelled: return "CANCELLED"
        case .decodingError: return "DECODING_ERROR"
        case .httpError(let statusCode, _): return "HTTP_\(statusCode)"
        case .invalidURL: return "INVALID_URL"
        case .serverError: return "SERVER_ERROR"
        case .stepInProgress: return "STEP_IN_PROGRESS"
        case .stepIdConflict: return "STEP_ID_CONFLICT"
        }
    }

    var requestId: String? {
        if case .backendError(_, _, _, let requestId) = self { return requestId }
        return nil
    }
}
