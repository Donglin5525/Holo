import Foundation

enum HoloAIUserErrorMapper {
    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "AI 响应超时，请稍后重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return "网络不可用，请检查网络连接"
            default:
                return "网络连接异常，请稍后重试"
            }
        }

        guard let apiError = error as? APIError else {
            return "HoloAI 暂时无法处理，请稍后重试"
        }
        switch apiError {
        case .networkUnavailable:
            return "网络不可用，请检查网络连接"
        case .timeout:
            return "AI 响应超时，请稍后重试"
        case .rateLimited:
            return "今天的 AI 使用次数已达上限，稍后再试"
        case .cancelled:
            return "请求已取消"
        case .httpError(let statusCode, _ ) where statusCode == 401 || statusCode == 403:
            return "AI 授权已失效，请重新登录后重试"
        case .serverError(let message) where message.contains("数据处理授权"):
            return "使用 HoloAI 前，请先开启 AI 数据处理授权"
        case .invalidURL, .decodingError, .httpError, .serverError, .backendError:
            return "HoloAI 服务暂时不可用，请稍后重试"
        case .stepInProgress:
            return "相同请求正在处理中，请稍后重试"
        case .stepIdConflict:
            return "请求处理冲突，请稍后重试"
        }
    }
}
