//
//  HoloAuthSession.swift
//  Holo
//
//  Holo 通过 Apple 登录后的本地登录态。
//

import Foundation

struct HoloAuthSession: Codable, Equatable {
    let userIdentifier: String
    let fullName: String?
    let email: String?
    let signedInAt: Date
    /// 登录时拿到的 Apple identity token（JWT 字符串）。
    /// 账号删除时用它调后端撤销 Sign in with Apple 凭证（App Store Guideline 5.1.1v）。
    /// 可选：旧版本登录的用户存档里没有该字段，解码为 nil。
    let identityToken: String?

    var displayName: String {
        let trimmedName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "Apple 用户" : trimmedName
    }
}
