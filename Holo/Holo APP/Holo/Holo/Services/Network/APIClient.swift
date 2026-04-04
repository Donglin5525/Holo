//
//  APIClient.swift
//  Holo
//
//  API 客户端
//  URLSession 封装，支持普通请求和 SSE 流式请求
//

import Foundation
import os.log

@MainActor
final class APIClient {

    static let shared = APIClient()

    private let logger = Logger(subsystem: "com.holo.app", category: "APIClient")
    private let urlSession: URLSession
    private let maxRetries = 2

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - 普通请求

    /// 发送普通 API 请求，支持指数退避重试
    func send<T: Decodable>(_ request: APIRequest) async throws -> T {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let urlRequest = try request.toURLRequest()

                logger.debug("API 请求: \(request.method.rawValue) \(request.baseURL)\(request.path)")

                let (data, response) = try await urlSession.data(for: urlRequest)

                try validateHTTPResponse(response, data: data)

                let decoded = try JSONDecoder().decode(T.self, from: data)
                return decoded
            } catch let error as APIError {
                lastError = error

                // 仅对可重试的错误进行重试
                if error.isRetryable && attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt))
                    logger.warning("请求失败，\(delay)秒后重试（第\(attempt + 1)次）：\(error.errorDescription ?? "")")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? APIError.serverError("未知错误")
    }

    // MARK: - SSE 流式请求

    /// 发送 SSE 流式请求
    /// 网络请求和 SSE 解码在后台 Task 中执行，只将解码后的纯字符串通过 AsyncThrowingStream 传递
    func sendStreaming(_ request: APIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let urlRequest = try request.toURLRequest()

                    logger.debug("SSE 流式请求: \(request.baseURL)\(request.path)")

                    let (bytes, response) = try await urlSession.bytes(for: urlRequest)

                    try validateHTTPResponse(response, data: nil)

                    var parser = SSEParser()

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        if let content = parser.parse(line) {
                            continuation.yield(content)
                        }
                    }

                    continuation.finish()
                } catch let error as APIError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: APIError.networkUnavailable)
                }
            }
        }
    }

    // MARK: - HTTP 响应验证

    private func validateHTTPResponse(_ response: URLResponse?, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkUnavailable
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 429:
            throw APIError.rateLimited
        case 401:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: "API Key 无效或已过期")
        case 400...499:
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "客户端错误"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        case 500...599:
            throw APIError.serverError("服务器内部错误（\(httpResponse.statusCode)）")
        default:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: "未知 HTTP 错误")
        }
    }
}
