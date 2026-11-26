//
//  SubscriptionBrandIconCatalog.swift
//  Holo
//
//  常用订阅服务品牌图标目录（36 个高频品牌，对应 Assets.xcassets/SubscriptionIcons/sub_*.imageset）
//  支持按分组浏览与输入名称自动匹配推荐图标。
//

import Foundation

nonisolated struct SubscriptionBrandIcon: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: Category
    let keywords: [String]

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case aiAndProductivity = "AI 与效率工具"
        case domesticMedia = "国内影音与音乐"
        case globalMedia = "国际影音与流媒体"
        case lifestyleAndGames = "生活、电商与游戏"

        var id: String { rawValue }
    }
}

nonisolated enum SubscriptionBrandIconCatalog {

    static let all: [SubscriptionBrandIcon] = [
        // MARK: AI 与效率工具
        .init(id: "sub_chatgpt", name: "ChatGPT", category: .aiAndProductivity,
              keywords: ["chatgpt", "chat gpt", "openai", "gpt plus", "gpt pro", "gpt"]),
        .init(id: "sub_claude", name: "Claude", category: .aiAndProductivity,
              keywords: ["claude", "anthropic", "克劳德", "claude pro", "claude max"]),
        .init(id: "sub_gemini", name: "Google Gemini", category: .aiAndProductivity,
              keywords: ["gemini", "google gemini", "谷歌ai", "google ai pro", "google ai ultra"]),
        .init(id: "sub_cursor", name: "Cursor", category: .aiAndProductivity,
              keywords: ["cursor", "cursor pro"]),
        .init(id: "sub_midjourney", name: "Midjourney", category: .aiAndProductivity,
              keywords: ["midjourney", "mid journey", "mj"]),
        .init(id: "sub_github", name: "GitHub", category: .aiAndProductivity,
              keywords: ["github", "github copilot", "copilot", "github pro"]),
        .init(id: "sub_notion", name: "Notion", category: .aiAndProductivity,
              keywords: ["notion", "notion ai", "notion plus"]),
        .init(id: "sub_1password", name: "1Password", category: .aiAndProductivity,
              keywords: ["1password", "one password", "1 password"]),
        .init(id: "sub_wps", name: "WPS 会员", category: .aiAndProductivity,
              keywords: ["wps", "wps office", "金山办公", "金山文档", "wps会员"]),
        .init(id: "sub_icloud", name: "iCloud+", category: .aiAndProductivity,
              keywords: ["icloud", "icloud+", "icloud plus", "苹果云", "苹果云盘"]),
        .init(id: "sub_baidunetdisk", name: "百度网盘", category: .aiAndProductivity,
              keywords: ["百度网盘", "百度云", "百度云盘", "baidu netdisk", "baidunetdisk"]),
        .init(id: "sub_aliyundrive", name: "阿里云盘", category: .aiAndProductivity,
              keywords: ["阿里云盘", "阿里网盘", "aliyundrive", "alipan"]),

        // MARK: 国内影音与音乐
        .init(id: "sub_iqiyi", name: "爱奇艺", category: .domesticMedia,
              keywords: ["爱奇艺", "iqiyi", "奇艺"]),
        .init(id: "sub_tencentvideo", name: "腾讯视频", category: .domesticMedia,
              keywords: ["腾讯视频", "tencent video"]),
        .init(id: "sub_youku", name: "优酷", category: .domesticMedia,
              keywords: ["优酷", "youku"]),
        .init(id: "sub_bilibili", name: "哔哩哔哩", category: .domesticMedia,
              keywords: ["哔哩哔哩", "bilibili", "b站", "大会员", "哔站"]),
        .init(id: "sub_mangotv", name: "芒果TV", category: .domesticMedia,
              keywords: ["芒果tv", "mango tv", "mangotv", "芒果会员"]),
        .init(id: "sub_qqmusic", name: "QQ音乐", category: .domesticMedia,
              keywords: ["qq音乐", "qq music", "qqmusic", "绿钻"]),
        .init(id: "sub_neteasemusic", name: "网易云音乐", category: .domesticMedia,
              keywords: ["网易云音乐", "网易云", "netease music", "黑胶vip", "黑胶会员"]),
        .init(id: "sub_ximalaya", name: "喜马拉雅", category: .domesticMedia,
              keywords: ["喜马拉雅", "ximalaya"]),
        .init(id: "sub_weread", name: "微信读书", category: .domesticMedia,
              keywords: ["微信读书", "weread", "微信阅读", "无限卡"]),

        // MARK: 国际影音与流媒体
        .init(id: "sub_netflix", name: "Netflix", category: .globalMedia,
              keywords: ["netflix", "网飞", "奈飞"]),
        .init(id: "sub_youtube", name: "YouTube Premium", category: .globalMedia,
              keywords: ["youtube", "youtube premium", "油管", "youtube music"]),
        .init(id: "sub_spotify", name: "Spotify", category: .globalMedia,
              keywords: ["spotify", "声破天"]),
        .init(id: "sub_applemusic", name: "Apple Music", category: .globalMedia,
              keywords: ["apple music", "苹果音乐", "applemusic"]),
        .init(id: "sub_disneyplus", name: "Disney+", category: .globalMedia,
              keywords: ["disney+", "disney plus", "disneyplus", "迪士尼+", "迪士尼plus"]),
        .init(id: "sub_appleone", name: "Apple One", category: .globalMedia,
              keywords: ["apple one", "appleone", "苹果全家桶", "苹果一站式"]),

        // MARK: 生活、电商与游戏
        .init(id: "sub_jdplus", name: "京东 PLUS", category: .lifestyleAndGames,
              keywords: ["京东plus", "京东会员", "jd plus", "jdplus", "京东"]),
        .init(id: "sub_taobao88vip", name: "淘宝 88VIP", category: .lifestyleAndGames,
              keywords: ["88vip", "88会员", "淘宝88vip", "天猫88vip", "淘宝", "taobao"]),
        .init(id: "sub_meituan", name: "美团会员", category: .lifestyleAndGames,
              keywords: ["美团", "meituan", "神会员"]),
        .init(id: "sub_eleme", name: "饿了么", category: .lifestyleAndGames,
              keywords: ["饿了么", "eleme", "ele.me", "吃货卡"]),
        .init(id: "sub_keep", name: "Keep", category: .lifestyleAndGames,
              keywords: ["keep", "keep会员", "keep运动"]),
        .init(id: "sub_dedao", name: "得到", category: .lifestyleAndGames,
              keywords: ["得到", "dedao", "罗辑思维"]),
        .init(id: "sub_psplus", name: "PlayStation Plus", category: .lifestyleAndGames,
              keywords: ["playstation plus", "playstation", "ps plus", "psplus", "psn", "ps+"]),
        .init(id: "sub_nintendo", name: "Switch Online", category: .lifestyleAndGames,
              keywords: ["nintendo switch online", "nintendo", "任天堂", "nso", "switch会员"]),
        .init(id: "sub_steam", name: "Steam", category: .lifestyleAndGames,
              keywords: ["steam", "蒸汽平台"])
    ]

    private static let byID: [String: SubscriptionBrandIcon] = Dictionary(
        all.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func brand(for id: String) -> SubscriptionBrandIcon? {
        byID[id]
    }

    static func sections(matching query: String = "") -> [(category: SubscriptionBrandIcon.Category, items: [SubscriptionBrandIcon])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [SubscriptionBrandIcon]
        if trimmed.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { brand in
                brand.name.lowercased().contains(trimmed)
                    || brand.keywords.contains { $0.lowercased().contains(trimmed) }
            }
        }
        return SubscriptionBrandIcon.Category.allCases.compactMap { category in
            let items = filtered.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    /// 根据用户输入的订阅名称自动匹配最合适的品牌图标（最长关键词优先）
    static func match(for input: String) -> SubscriptionBrandIcon? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let compact = normalized.replacingOccurrences(of: " ", with: "")

        var bestMatch: (brand: SubscriptionBrandIcon, score: Int)?
        for brand in all {
            for keyword in brand.keywords {
                let key = keyword.lowercased()
                let keyCompact = key.replacingOccurrences(of: " ", with: "")
                let matched = normalized.contains(key) || (keyCompact.count >= 3 && compact.contains(keyCompact))
                if matched {
                    let score = keyCompact.count
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (brand, score)
                    }
                }
            }
        }
        return bestMatch?.brand
    }
}
