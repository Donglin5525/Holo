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

    /// 测试注入用（§8.2 step 幂等重试验证：配 MockURLProtocol 的 session）。
    init(urlSession: URLSession) {
        self.urlSession = urlSession
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
    /// 重试归并（Phase 4 任务5）：APIClient 是唯一 HTTP 重试层；
    /// 409 STEP_IN_PROGRESS 是幂等协议的一部分，走独立退避计数（不挤占普通重试预算）。
    func sendWithResponse<T: Decodable>(_ request: APIRequest) async throws -> Response<T> {
        var attempt = 0
        var stepInProgressRetries = 0
        let maxStepInProgressRetries = 3

        while true {
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
                // §8.2：STEP_IN_PROGRESS——后端正在处理同一 step，独立退避重试同一请求
                if case .stepInProgress = error, stepInProgressRetries < maxStepInProgressRetries {
                    stepInProgressRetries += 1
                    let delay = pow(2.0, Double(stepInProgressRetries))
                    logger.warning("后端 step 处理中，\(delay)秒后重试同一请求（第\(stepInProgressRetries)次）")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // 仅对可重试的错误进行重试
                if error.isRetryable && attempt < maxRetries {
                    attempt += 1
                    let delay = pow(2.0, Double(attempt - 1))
                    logger.warning("请求失败，\(delay)秒后重试（第\(attempt)次）：\(error.errorDescription ?? "")")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch let urlError as URLError where urlError.code == .timedOut {
                if attempt < maxRetries {
                    attempt += 1
                    let delay = pow(2.0, Double(attempt - 1))
                    logger.warning("请求超时，\(delay)秒后重试（第\(attempt)次）")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw APIError.timeout
            } catch {
                throw error
            }
        }
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

    /// 从响应体中提取后端错误码与用户友好消息。
    private func extractBackendError(from data: Data?) -> BackendErrorResponse.ErrorPayload? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(BackendErrorResponse.self, from: data).error
    }

    private func validateHTTPResponse(_ response: URLResponse?, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkUnavailable
        }

        let backendError = extractBackendError(from: data)
        let backendMessage = backendError?.message
        let requestId = httpResponse.value(forHTTPHeaderField: "X-Holo-Request-Id")

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 409:
            // §8.2：step 幂等协议错误——按后端 code 映射为 typed error
            switch backendError?.code {
            case "STEP_IN_PROGRESS":
                throw APIError.stepInProgress(backendMessage)
            case "STEP_ID_CONFLICT":
                throw APIError.stepIdConflict(backendMessage)
            default:
                throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "请求冲突，请稍后重试")
            }
        case 429:
            throw APIError.rateLimited(backendMessage)
        case 401:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "安全校验失败，请重试")
        case 400...499:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "请求参数无效")
        case 500...599:
            throw APIError.backendError(
                statusCode: httpResponse.statusCode,
                code: backendError?.code,
                message: backendMessage ?? "服务暂时不可用，请稍后重试",
                requestId: requestId
            )
        default:
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: backendMessage ?? "请求失败，请稍后重试")
        }
    }
}
