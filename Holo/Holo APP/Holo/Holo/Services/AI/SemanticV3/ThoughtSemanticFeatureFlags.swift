//
//  ThoughtSemanticFeatureFlags.swift
//  Holo
//
//  V3 feature flags（方案 §19）。开启顺序固定：index shadow → relation shadow
//  → 内部评测 → relation 小流量 → 新 UI → discovery → resurfacing。
//  回滚只切 flag，不删数据。全部默认 off。
//

import Foundation

enum ThoughtSemanticFeatureFlags {

    private static let prefix = "thought_semantic_v3_"

    enum TriState: String {
        case off
        case shadow
        case on
    }

    /// 本地语义索引（embedding 生成与本机 ANN）。shadow = 只写不消费。
    static var index: TriState {
        get { triState("index") } set { setTriState(newValue, "index") }
    }

    /// 既有 Topic 自动关联。shadow = 只记录决策结果，不改用户可见数据。
    static var relation: TriState {
        get { triState("relation") } set { setTriState(newValue, "relation") }
    }

    /// 新 UI（想法|主题 双核心）。
    static var ui: Bool {
        get { UserDefaults.standard.bool(forKey: prefix + "ui") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "ui") }
    }

    /// 新 UI 生效判定：显式设置永远优先；未设置时 Debug 构建默认开（开发与真机验收
    /// 通道），Release 默认关（= 小流量闸门：生产放量只需改默认值或远端下发）。
    static var uiEnabled: Bool {
        if UserDefaults.standard.object(forKey: prefix + "ui") != nil { return ui }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 新 Topic 候选簇建议。
    static var discovery: TriState {
        get { triState("discovery") } set { setTriState(newValue, "discovery") }
    }

    /// 建议卡生效判定（与 uiEnabled 同纪律）：显式设置优先；未设置时 Debug 默认开
    /// （真机验收通道），Release 默认关（灰度放量闸门）。
    static var discoveryEnabled: Bool {
        if UserDefaults.standard.object(forKey: prefix + "discovery") != nil {
            return triState("discovery") == .on
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 引擎可跑判定：建议卡开启、或显式 shadow（只落库不出卡）。
    static var clusterEngineActive: Bool {
        discoveryEnabled || discovery == .shadow
    }

    /// 旧想法重新遇见（Topic 详情相关旧想法 + 看板卡）。
    static var resurfacing: Bool {
        get { UserDefaults.standard.bool(forKey: prefix + "resurfacing") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "resurfacing") }
    }

    // MARK: - 授权代数（方案 §5.3）

    /// 单调递增：用户撤回 AI 数据处理授权时 +1，旧 generation 的迟到结果落库前作废。
    static var consentGeneration: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: prefix + "consent_generation")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: prefix + "consent_generation") }
    }

    // MARK: - 私有

    private static func triState(_ name: String) -> TriState {
        TriState(rawValue: UserDefaults.standard.string(forKey: prefix + name) ?? "") ?? .off
    }

    private static func setTriState(_ value: TriState, _ name: String) {
        UserDefaults.standard.set(value.rawValue, forKey: prefix + name)
    }
}
