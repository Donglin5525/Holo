//
//  ThoughtTagEmojiStore.swift
//  Holo
//
//  标签 Emoji 图标存储（2026-09-26，参考 flomo 的标签自定义图标）
//
//  一期实现口径：UserDefaults 本机映射（标签归一化 key → emoji 字符），不进
//  CoreData/CloudKit 模型——emoji 是装饰性表达，一期先零迁移上线；多设备不同步
//  是已知边界，后续若要跨设备再评估入模型（可选字段 + CloudKit 增量部署）。
//
//  读取全部走内存字典：侧栏标签树与卡片 chip 每行都会问一次，不能逐次打 UserDefaults。
//

import Foundation

enum ThoughtTagEmojiStore {

    private static let defaultsKey = "thoughts.tag_emoji_v1"

    private static let queue = DispatchQueue(label: "com.holo.tagEmoji")

    /// 内存缓存：首次访问时从 UserDefaults 一次性读入
    private static var cachedMap: [String: String]? = nil

    /// 变更通知（侧栏/列表监听刷新；不与 thoughtDataDidChange 混用——
    /// emoji 变更不需要全量重查数据库，只刷显示层）
    static let didChangeNotification = Notification.Name("thoughtTagEmojiDidChange")

    private static var map: [String: String] {
        queue.sync {
            if let cachedMap { return cachedMap }
            let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
            let value = raw ?? [:]
            cachedMap = value
            return value
        }
    }

    /// 标签的 emoji 图标（未设置返回 nil）
    static func emoji(forKey tagKey: String) -> String? {
        let key = ThoughtTagNormalizer.key(tagKey)
        return map[key]
    }

    /// 设置 emoji；空串/纯空白视为移除。
    /// 注意：sync 块内严禁访问 `map` getter——它内部再次 queue.sync，
    /// 同一串行队列同步嵌套同步必死锁（2026-09-26 模拟器走查 100% 复现闪退后修正）
    static func setEmoji(_ emoji: String, forKey tagKey: String) {
        let key = ThoughtTagNormalizer.key(tagKey)
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            var value = cachedMap
                ?? (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])
                ?? [:]
            if trimmed.isEmpty {
                value.removeValue(forKey: key)
            } else {
                value[key] = trimmed
            }
            cachedMap = value
            UserDefaults.standard.set(value, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func removeEmoji(forKey tagKey: String) {
        setEmoji("", forKey: tagKey)
    }
}
