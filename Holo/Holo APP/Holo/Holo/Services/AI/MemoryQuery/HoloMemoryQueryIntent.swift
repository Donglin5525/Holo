//
//  HoloMemoryQueryIntent.swift
//  Holo
//
//  统一描述记忆查询、明细回退和模型可使用边界。
//

import Foundation

enum HoloMemoryQueryRoute: String, Codable, Equatable, Sendable {
    case detail
    case domainMemory
    case holisticMemory
    case planningHybrid
}

enum HoloMemoryAnswerAuthority: String, Codable, Equatable, Sendable {
    case backgroundOnly
    case answerMaterial
}

enum HoloMemorySemanticOperation: String, Codable, Equatable, Sendable {
    case exactDetail
    case summary
    case holistic
    case planning
}

struct HoloMemoryQueryTimeRange: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
}

struct HoloMemoryQuerySemanticContext: Codable, Equatable, Sendable {
    var operation: HoloMemorySemanticOperation
    var domains: [HoloMemoryDomain]
    var claimKinds: [HoloMemoryClaimKind]
    var anchors: [HoloMemoryAnchorRef]
    var timeRange: HoloMemoryQueryTimeRange?
}

struct HoloMemoryQueryIntent: Codable, Equatable, Sendable {
    var route: HoloMemoryQueryRoute
    var requestedDomains: [HoloMemoryDomain]
    var requestedClaimKinds: [HoloMemoryClaimKind]
    var requestedAnchors: [HoloMemoryAnchorRef]
    var timeRange: HoloMemoryQueryTimeRange?
    var includeProfile: Bool
    var includeCrossDomain: Bool
    var requiresDetailData: Bool
    var answerAuthority: HoloMemoryAnswerAuthority
}
