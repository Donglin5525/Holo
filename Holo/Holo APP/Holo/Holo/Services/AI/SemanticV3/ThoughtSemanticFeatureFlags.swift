import Foundation

/// 用户设置是唯一启用依据；开发灰度开关保留供诊断，缺省全部启用。
nonisolated enum ThoughtSemanticFeatureFlags {
    static let automaticKey = "thoughts.automaticOrganization.enabled"
    static let newTopicsKey = "thoughts.automaticTopics.enabled"
    static let relatedKey = "thoughts.relatedNotes.enabled"
    static let settingsDidChange = Notification.Name("thoughtsOrganizationSettingsDidChange")
    private static let prefix = "thought_semantic_v3_"
    enum TriState: String { case off, shadow, on }

    static func enabled(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        if key == automaticKey, defaults.object(forKey: key) == nil,
           let previous = defaults.object(forKey: "isThoughtAutoOrganizationEnabled") as? Bool { return previous }
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
    static var automaticEnabled: Bool { enabled(automaticKey) }
    static var index: TriState {
        get { automaticEnabled ? triState("index") : .off }
        set { setTriState(newValue, "index") }
    }
    static var relation: TriState {
        get { automaticEnabled ? triState("relation") : .off }
        set { setTriState(newValue, "relation") }
    }
    static var ui: Bool {
        get { true }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "ui") }
    }
    static var uiEnabled: Bool { true }
    static func uiEnabled(in defaults: UserDefaults) -> Bool { true }
    static var discovery: TriState {
        get { automaticEnabled && enabled(newTopicsKey) ? triState("discovery") : .off }
        set { setTriState(newValue, "discovery") }
    }
    static var discoveryEnabled: Bool { discovery == .on }
    static var clusterEngineActive: Bool { discovery != .off }
    static var resurfacing: Bool {
        get { enabled(relatedKey) }
        set { UserDefaults.standard.set(newValue, forKey: relatedKey) }
    }
    static var resurfacingEnabled: Bool { automaticEnabled && resurfacing }
    /// 开关变化与撤回授权都递增，禁止已关闭功能的迟到结果落库。
    static var consentGeneration: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: prefix + "consent_generation")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: prefix + "consent_generation") }
    }
    static func settingsChanged() {
        consentGeneration += 1
        NotificationCenter.default.post(name: settingsDidChange, object: nil)
    }
    private static func triState(_ name: String) -> TriState {
        // 产品版本不继承开发期 off/shadow；用户关闭由上面的持久化设置管理。
        TriState(rawValue: UserDefaults.standard.string(forKey: prefix + "runtime_" + name) ?? "") ?? .on
    }
    private static func setTriState(_ value: TriState, _ name: String) {
        UserDefaults.standard.set(value.rawValue, forKey: prefix + "runtime_" + name)
    }
}
