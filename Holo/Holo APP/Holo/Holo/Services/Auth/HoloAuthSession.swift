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

    var displayName: String {
        let trimmedName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "Apple 用户" : trimmedName
    }
}
