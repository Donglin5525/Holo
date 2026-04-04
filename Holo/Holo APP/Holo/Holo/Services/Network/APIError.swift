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
    case rateLimited
    case timeout
    case cancelled
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .networkUnavailable:
            return "网络不可用，请检查网络连接"
        case .httpError(let statusCode, let message):
            return "请求失败（\(statusCode)）：\(message)"
        case .decodingError(let error):
            return "数据解析失败：\(error.localizedDescription)"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .timeout:
            return "请求超时，请稍后重试"
        case .cancelled:
            return "请求已取消"
        case .serverError(let message):
            return "服务器错误：\(message)"
        }
    }

    /// 是否可重试
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .serverError:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500 || statusCode == 429
        default:
            return false
        }
    }
}
