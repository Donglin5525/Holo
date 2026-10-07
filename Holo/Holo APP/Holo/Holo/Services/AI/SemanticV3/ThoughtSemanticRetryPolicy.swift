import Foundation

nonisolated enum ThoughtSemanticRetryPolicy {
    static func code(_ error: Error) -> String {
        if case APIError.backendError(_, let code, _, _) = error { return code ?? "NETWORK_UNAVAILABLE" }
        if case APIError.rateLimited = error { return "RATE_LIMITED" }
        if error is ThoughtTopicVerifierError || error is ThoughtSemanticExecutorError { return "INVALID_AI_RESULT" }
        if case APIError.decodingError = error { return "INVALID_AI_RESULT" }
        return "NETWORK_UNAVAILABLE"
    }

    static func userMessage(for code: String) -> String {
        switch code {
        case "PRIVACY_ROUTE_UNVERIFIED": return "AI 整理服务尚未开放，笔记已保留，服务可用后继续。"
        case "BUDGET_EXCEEDED": return "今日整理额度已用完，明天自动继续，笔记都在。"
        case "RATE_LIMITED": return "整理请求稍密，稍候自动继续。"
        case "INVALID_AI_RESULT": return "AI 返回结果未通过核对，未更改主题，可重试。"
        default: return "网络或服务暂不可用，稍后自动继续，笔记都在。"
        }
    }
    static func isTerminal(_ error: Error) -> Bool {
        if error is ThoughtTopicVerifierError { return true }
        if error is ThoughtSemanticExecutorError { return true }
        if case APIError.backendError(let status, _, _, _) = error { return (400...428).contains(status) && status != 409 }
        if case APIError.httpError(let status, _) = error { return (400...428).contains(status) && status != 409 }
        if case APIError.decodingError = error { return true }
        return false
    }
    static func delay(_ error: Error, attempt: Int) -> TimeInterval {
        if case APIError.rateLimited = error { return 3_600 }
        if case APIError.backendError(let status, let code, _, _) = error {
            if code == "BUDGET_EXCEEDED" { return 86_400 }
            if status == 429 { return 3_600 }
            if status == 503 { return 900 }
        }
        return min(60 * pow(2, Double(min(attempt, 6))), 3_600)
    }
}
