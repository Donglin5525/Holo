//
//  HoloAuthSessionStandaloneTests.swift
//  HoloTests
//
//  Apple 登录态模型的独立测试。
//

import Foundation

private func assertEqual(_ actual: String, _ expected: String, _ message: String) {
    guard actual == expected else {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

@main
private enum HoloAuthSessionStandaloneTestRunner {
    static func main() {
        let namedSession = HoloAuthSession(
            userIdentifier: "apple-user-1",
            fullName: "  林夕  ",
            email: "lin@example.com",
            signedInAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertEqual(namedSession.displayName, "林夕", "displayName should trim Apple full name")

        let fallbackSession = HoloAuthSession(
            userIdentifier: "apple-user-2",
            fullName: "   ",
            email: nil,
            signedInAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertEqual(fallbackSession.displayName, "Apple 用户", "displayName should fall back when name is blank")
    }
}
