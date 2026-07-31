//
//  HoloSubscriptionProducts.swift
//  Holo
//
//  Holo Plus 商品与会员档位的唯一客户端定义。
//

import Foundation

enum HoloSubscriptionProduct: String, CaseIterable, Identifiable {
    case plusMonthly = "com.tangyuxuan.holo.plus.monthly"
    case plusYearly = "com.tangyuxuan.holo.plus.yearly"

    var id: String { rawValue }
}

enum HoloSubscriptionTier: String, Decodable {
    case free
    case plus
}

enum HoloAcceptanceMode: String, Equatable {
    case free
    case plus
    case followPurchase
}

enum HoloEntitlementSource: Equatable {
    case backend
    case acceptance

    var acceptanceDescription: String {
        switch self {
        case .backend:
            return "服务端会员状态"
        case .acceptance:
            return "服务端真机验收状态"
        }
    }
}
