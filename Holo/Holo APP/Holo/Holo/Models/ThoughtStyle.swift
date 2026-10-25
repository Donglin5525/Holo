import Foundation

/// 样式只描述呈现；旧版样式映射到新模板，不改动正文或落库原值。
nonisolated enum ThoughtStyle: String, CaseIterable, Identifiable, Sendable {
    case plain, post, field, ticket, calendar, fold, film, bookmark, dots

    var id: String { rawValue }
    init(storedValue: String?) {
        switch storedValue {
        case "journal", "midnight": self = .post
        case "book": self = .bookmark
        case "archive": self = .field
        default: self = storedValue.flatMap(Self.init(rawValue:)) ?? .plain
        }
    }
    var storedValue: String? { self == .plain ? nil : rawValue }

    var title: String {
        switch self {
        case .plain: String(localized: "原样")
        case .post: String(localized: "远行邮笺")
        case .field: String(localized: "晴日观察")
        case .ticket: String(localized: "生活票根")
        case .calendar: String(localized: "一日一页")
        case .fold: String(localized: "对折手记")
        case .film: String(localized: "光影胶片")
        case .bookmark: String(localized: "页边书签")
        case .dots: String(localized: "点阵便笺")
        }
    }

    var caption: String {
        switch self {
        case .plain: String(localized: "Holo 默认外观")
        case .post: String(localized: "把片刻寄给自己")
        case .field: String(localized: "收下日常的小发现")
        case .ticket: String(localized: "留存生活的入场券")
        case .calendar: String(localized: "记住普通的一天")
        case .fold: String(localized: "沿着纸页慢慢写")
        case .film: String(localized: "让照片先说一句话")
        case .bookmark: String(localized: "把喜欢的念头夹好")
        case .dots: String(localized: "随手记下一个点子")
        }
    }

    var symbol: String {
        switch self {
        case .plain: "text.alignleft"
        case .post: "envelope"
        case .field: "leaf"
        case .ticket: "ticket"
        case .calendar: "calendar"
        case .fold: "book.closed"
        case .film: "film"
        case .bookmark: "bookmark"
        case .dots: "square.grid.3x3"
        }
    }

    var shortTitle: String {
        switch self {
        case .plain: String(localized: "原样")
        case .post: String(localized: "邮笺")
        case .field: String(localized: "观察")
        case .ticket: String(localized: "票根")
        case .calendar: String(localized: "日历")
        case .fold: String(localized: "对折")
        case .film: String(localized: "胶片")
        case .bookmark: String(localized: "书签")
        case .dots: String(localized: "点阵")
        }
    }

    var fontRole: ThoughtFontRole {
        switch self {
        case .plain, .ticket, .film, .dots: .system
        case .calendar, .bookmark: .serif
        case .post, .field, .fold: .handwritten
        }
    }

    var photosLead: Bool { self == .film }
}

nonisolated enum ThoughtFontRole: String, Sendable {
    case system, serif, handwritten
}
