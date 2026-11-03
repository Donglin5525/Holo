//
//  DiscoverySettings.swift
//  Holo
//
//  「HoloAI 一个发现」功能开关与许可状态（01 设置迁移 / 02 §9.2 localGrantEpoch）。
//
//  单设备本地一份（无账号体系，不做按账号隔离命名）；切换账号/注销通过
//  handleSignOut() 钩子清理（store 侧数据清理由调用方配合 DiscoveryStore.clearAllForAccount 完成）。
//  运行期 UI 状态（waitingForMaterial/scheduled/preparing/ready/noFinding/backoff）
//  存 DiscoveryRunStateMO，不在这里；本文件只存用户决定的原始值。
//

import Foundation

extension Notification.Name {
    /// 「一个发现」设置变化（开启/关闭/范围调整）。userInfo: enabled: Bool。
    /// 调度器据此重新排队或取消在途批次（G6 接入）。
    static let holoDiscoverySettingsDidChange = Notification.Name("holoDiscoverySettingsDidChange")
}

/// 设置快照（纯值，供 DiscoveryAccessPolicy 注入判定）
struct DiscoverySettingsSnapshot: Equatable, Sendable {
    var isEnabled: Bool = false
    var allowedDomains: Set<DiscoverySourceDomain> = []
    /// 关闭→开启递增；旧 epoch 的冻结结果即使已返回也不可复活（02 §9.2）
    var localGrantEpoch: Int = 0
}

enum DiscoverySettingsError: Error, Equatable, Sendable {
    /// 至少选择一类来源（01：用户必须显式选择范围，不允许空范围开启）
    case emptyScope
}

/// 「一个发现」本地设置。UserDefaults 键前缀 holo.discovery.。
final class DiscoverySettings {

    static let shared = DiscoverySettings()

    private let defaults: UserDefaults

    private enum Keys {
        static let prefix = "holo.discovery."
        static let enabled = "holo.discovery.enabled"
        static let allowedDomains = "holo.discovery.allowedDomains"
        static let localGrantEpoch = "holo.discovery.localGrantEpoch"
        /// 首次明确同意开启的时间戳（说明文案「开启即同意必要片段交外部 AI 处理」的依据记录）
        static let consentRecordedAt = "holo.discovery.consentRecordedAt"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 读取

    func snapshot() -> DiscoverySettingsSnapshot {
        let domains = (defaults.stringArray(forKey: Keys.allowedDomains) ?? [])
            .compactMap { DiscoverySourceDomain(rawValue: $0) }
        return DiscoverySettingsSnapshot(
            isEnabled: defaults.bool(forKey: Keys.enabled),
            allowedDomains: Set(domains),
            localGrantEpoch: defaults.integer(forKey: Keys.localGrantEpoch)
        )
    }

    var localGrantEpoch: Int {
        defaults.integer(forKey: Keys.localGrantEpoch)
    }

    // MARK: - 写入

    /// 开启（首次或再次开启）。至少一类来源；关闭→开启时 localGrantEpoch 递增，
    /// 使上一代授权周期冻结的所有在途/已缓存结果全部作废。
    func enable(domains: Set<DiscoverySourceDomain>) throws {
        guard !domains.isEmpty else { throw DiscoverySettingsError.emptyScope }
        let wasEnabled = defaults.bool(forKey: Keys.enabled)
        let nextEpoch = wasEnabled
            ? defaults.integer(forKey: Keys.localGrantEpoch)
            : defaults.integer(forKey: Keys.localGrantEpoch) + 1
        defaults.set(true, forKey: Keys.enabled)
        defaults.set(domains.map(\.rawValue).sorted(), forKey: Keys.allowedDomains)
        defaults.set(nextEpoch, forKey: Keys.localGrantEpoch)
        if defaults.object(forKey: Keys.consentRecordedAt) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Keys.consentRecordedAt)
        }
        postChange(enabled: true)
    }

    /// 关闭。epoch 不清零（保持单调递增），停新请求/拒绝采纳迟到结果由门控与调度负责。
    func disable() {
        guard defaults.bool(forKey: Keys.enabled) else { return }
        defaults.set(false, forKey: Keys.enabled)
        postChange(enabled: false)
    }

    /// 开启状态下调整来源范围（关闭状态调用同样生效，下次开启沿用）。
    /// 空范围拒绝：范围收窄到零等价于关闭，应显式走 disable()。
    func updateAllowedDomains(_ domains: Set<DiscoverySourceDomain>) throws {
        guard !domains.isEmpty else { throw DiscoverySettingsError.emptyScope }
        guard domains != snapshot().allowedDomains else { return }
        defaults.set(domains.map(\.rawValue).sorted(), forKey: Keys.allowedDomains)
        postChange(enabled: defaults.bool(forKey: Keys.enabled))
    }

    // MARK: - 账号/注销清理钩子

    /// 注销、切换账号或撤回总授权时调用：关闭开关、清空范围并递增 epoch
    /// （作废旧代数结果）。注意本方法**只管设置**；候选、摘录、索引、在途数据
    /// 与否定指纹的清理由调用方执行 DiscoveryStore.clearAllForAccount /
    /// resetNegativeFeedback（02 §9.3：注销清候选与摘录、保留按账号隔离的否定指纹）。
    func handleSignOut() {
        let wasEnabled = defaults.bool(forKey: Keys.enabled)
        defaults.set(false, forKey: Keys.enabled)
        defaults.removeObject(forKey: Keys.allowedDomains)
        defaults.set(defaults.integer(forKey: Keys.localGrantEpoch) + 1, forKey: Keys.localGrantEpoch)
        if wasEnabled {
            postChange(enabled: false)
        }
    }

    // MARK: - 重置

    /// 显式重置本功能设置（回到默认关闭、无范围；epoch 归零）。
    /// 供「重置本功能」入口使用；否定指纹的重置走 DiscoveryStore.resetNegativeFeedback。
    func resetAll() {
        let wasEnabled = defaults.bool(forKey: Keys.enabled)
        defaults.removeObject(forKey: Keys.enabled)
        defaults.removeObject(forKey: Keys.allowedDomains)
        defaults.removeObject(forKey: Keys.localGrantEpoch)
        defaults.removeObject(forKey: Keys.consentRecordedAt)
        if wasEnabled {
            postChange(enabled: false)
        }
    }

    // MARK: - 私有

    private func postChange(enabled: Bool) {
        NotificationCenter.default.post(
            name: .holoDiscoverySettingsDidChange,
            object: nil,
            userInfo: ["enabled": enabled]
        )
    }
}
