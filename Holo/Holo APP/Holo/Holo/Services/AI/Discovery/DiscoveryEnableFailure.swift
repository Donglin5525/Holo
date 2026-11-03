// 开启失败的产品反馈：保留原因，避免把传输、协议或保存失败伪装成用户取消。
import Foundation

enum DiscoveryEnableFailure: Sendable, Equatable {
    case networkUnavailable, timeout, authorization, serverUnavailable
    case conflict, incompatibleResponse, localSave, rateLimited, unknown

    var message: String {
        switch self {
        case .networkUnavailable: return "无法连接 Holo 服务，请检查网络后重试。一个发现尚未开启。"
        case .timeout: return "连接 Holo 服务超时，请在网络稳定后重试。一个发现尚未开启。"
        case .authorization: return "本设备的安全校验未通过，请重新打开 App 后重试。一个发现尚未开启。"
        case .serverUnavailable: return "Holo 的发现服务暂时不可用，请稍后重试。一个发现尚未开启。"
        case .conflict: return "发现设置刚刚在其他设备发生变化，请重试以读取最新状态。"
        case .incompatibleResponse: return "当前 App 无法读取发现服务返回的数据，请更新 App；若已是最新版，请反馈给我们。一个发现尚未开启。"
        case .localSave: return "发现设置未能保存到本机，已保持关闭。请重试；若仍失败，请重新打开 App。"
        case .rateLimited: return "开启尝试过于频繁，请稍后重试。一个发现尚未开启。"
        case .unknown: return "开启过程发生异常，一个发现尚未开启。请重试；若仍失败，请反馈给我们。"
        }
    }

    static func from(_ error: Error) -> Self {
        if error is DecodingError { return .incompatibleResponse }
        if let error = error as? URLError {
            return error.code == .timedOut ? .timeout : .networkUnavailable
        }
        guard let error = error as? APIError else { return .unknown }
        switch error {
        case .networkUnavailable: return .networkUnavailable
        case .timeout: return .timeout
        case .deviceSessionRejected: return .authorization
        case .decodingError: return .incompatibleResponse
        case .rateLimited: return .rateLimited
        case .httpError(let status, _), .backendError(let status, _, _, _):
            switch status {
            case 401, 403: return .authorization
            case 404: return .serverUnavailable
            case 409: return .conflict
            case 429: return .rateLimited
            case 500...599: return .serverUnavailable
            default: return .unknown
            }
        case .serverError: return .serverUnavailable
        default: return .unknown
        }
    }
}
