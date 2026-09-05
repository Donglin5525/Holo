//
//  APIRequest.swift
//  Holo
//
//  API 请求构建器
//  Builder 模式构建 URLRequest
//

import Foundation

nonisolated struct APIRequest {
    let baseURL: String
    let path: String
    let method: HTTPMethod
    let headers: [String: String]
    let body: Encodable?

    nonisolated enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    func toURLRequest() throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 60

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // App 实际生效语言随所有后端请求上送（zh-Hans/zh-Hant/en），
        // 后端据此注入 AI 输出语言指令；未声明时回落源语言
        request.setValue(
            Bundle.main.preferredLocalizations.first ?? "zh-Hans",
            forHTTPHeaderField: "x-holo-language"
        )

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        return request
    }
}
