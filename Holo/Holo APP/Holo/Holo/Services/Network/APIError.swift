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
        }
    }

    /// 是否可重试
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .serverError:
            return true
        case .backendError(let statusCode, let code, _, _):
            // 洞察空响应/截断已在后端重试过一次，客户端不再放大调用次数。
            let terminalInsightCodes = [
                "EMPTY_MODEL_RESPONSE",
                "TRUNCATED_MODEL_RESPONSE",
                "INVALID_INSIGHT_JSON"
            ]
            return statusCode >= 500 && !terminalInsightCodes.contains(code ?? "")
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
        }
    }

    var requestId: String? {
        if case .backendError(_, _, _, let requestId) = self { return requestId }
        return nil
    }
}
