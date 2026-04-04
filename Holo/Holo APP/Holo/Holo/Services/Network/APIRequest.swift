//
//  APIRequest.swift
//  Holo
//
//  API 请求构建器
//  Builder 模式构建 URLRequest
//

import Foundation

struct APIRequest {
    let baseURL: String
    let path: String
    let method: HTTPMethod
    let headers: [String: String]
    let body: Encodable?

    enum HTTPMethod: String {
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

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        return request
    }
}
