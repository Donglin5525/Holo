//
//  APIClient.swift
//  Holo
//
//  API 客户端
//  URLSession 封装，支持普通请求和 SSE 流式请求
//

import Foundation
import os.log

nonisolated final class APIClient {

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

    struct Response<Value> {
        let value: Value
        let httpResponse: HTTPURLResponse
    }

    /// 发送普通 API 请求，支持指数退避重试
    func send<T: Decodable>(_ request: APIRequest) async throws -> T {
        let response: Response<T> = try await sendWithResponse(request)
        return response.value
    }

    /// 发送请求并保留响应头，供内部诊断关联 requestId。
    func sendWithResponse<T: Decodable>(_ request: APIRequest) async throws -> Response<T> {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let urlRequest = try request.toURLRequest()

                logger.debug("API 请求: \(request.method.rawValue) \(request.baseURL)\(request.path)")

                let (data, response) = try await urlSession.data(for: urlRequest)

                try validateHTTPResponse(response, data: data)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.networkUnavailable
                }

                let decoded = try JSONDecoder().decode(T.self, from: data)
                return Response(value: decoded, httpResponse: httpResponse)
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
            } catch let urlError as URLError where urlError.code == .timedOut {
                let apiError = APIError.timeout
                lastError = apiError
                if attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt))
                    logger.warning("请求超时，\(delay)秒后重试（第\(attempt + 1)次）")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw apiError
            } catch {
                throw error
            }
        }

        throw lastError ?? APIError.serverError("未知错误")
    }

    // MARK: - SSE 流式请求

    /// 发送 SSE 流式请求，支持超时重试
    /// 网络请求和 SSE 解码在后台 Task 中执行，只将解码后的纯字符串通过 AsyncThrowingStream 传递
    func sendStreaming(
        _ request: APIRequest,
        onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var lastError: Error?

                for attempt in 0...maxRetries {
                    do {
                        let urlRequest = try request.toURLRequest()

                        if attempt > 0 {
                            logger.debug("SSE 流式重试（第\(attempt)次）: \(request.baseURL)\(request.path)")
                        } else {
                            logger.debug("SSE 流式请求: \(request.baseURL)\(request.path)")
                        }

                        let (bytes, response) = try await urlSession.bytes(for: urlRequest)

                        try validateHTTPResponse(response, data: nil)
                        if let httpResponse = response as? HTTPURLResponse {
                            onResponse?(httpResponse)
                        }

                        var parser = SSEParser()

                        for try await line in bytes.lines {
                            if Task.isCancelled { break }

                            if let content = parser.parse(line) {
                                continuation.yield(content)
                            }
                        }

                        continuation.finish()
                        return
                    } catch let error as APIError {
                        lastError = error
                        if error.isRetryable && attempt < maxRetries {
                            let delay = pow(2.0, Double(attempt))
                            logger.warning("SSE 流式失败，\(delay)秒后重试（第\(attempt + 1)次）：\(error.errorDescription ?? "")")
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch let urlError as URLError where urlError.code == .timedOut {
                        let apiError = APIError.timeout
                        lastError = apiError
                        if attempt < maxRetries {
                            let delay = pow(2.0, Double(attempt))
                            logger.warning("SSE 流式超时，\(delay)秒后重试（第\(attempt + 1)次）")
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            continue
                        }
                        continuation.finish(throwing: apiError)
                        return
                    } catch {
                        continuation.finish(throwing: APIError.networkUnavailable)
                        return
                    }
                }

                continuation.finish(throwing: lastError ?? APIError.serverError("未知错误"))
            }
        }
    }

    // MARK: - HTTP 响应验证

    /// 后端错误响应结构
    private struct BackendErrorResponse: Decodable {
        let error: ErrorPayload
        struct ErrorPayload: Decodable {
            let code: String?
            let message: String?
        }
    }

    /// 从响应体中提取后端返回的用户友好消息
    private func extractBackendMessage(from data: Data?) -> String? {
        guard let data else { return nil }
        guard let payload = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) else { return nil }
        return payload.error.message
    }

    private func validateHTTPResponse(_ response: URLResponse?, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkUnavailable
        }

        let backendMessage = extractBackendMessage(from: data)

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 429:
            throw APIError.rateLimited(backendMessage)
        case 401:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "安全校验失败，请重试")
        case 400...499:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "请求参数无效")
        case 500...599:
            throw APIError.serverError(backendMessage ?? "服务暂时不可用，请稍后重试")
        default:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "请求失败，请稍后重试")
        }
    }
}
