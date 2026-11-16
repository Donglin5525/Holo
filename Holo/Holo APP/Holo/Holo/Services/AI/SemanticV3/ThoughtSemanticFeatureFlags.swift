import Foundation

/// 进程内服务端闸（W1 类别规则层）：schema 4 请求被服务端拒后停发新版请求，
/// 本次进程内所有样本回落 legacy；恢复旧策略的定向回滚归 W4，不在闸上自动探测。
/// nonisolated：工程默认 MainActor 隔离，闸要被 nonisolated 的策略函数同步读取。
nonisolated private final class ThoughtCategoryRulesServerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return !rejected
    }
    func markRejected() {
        lock.lock(); defer { lock.unlock() }
        rejected = true
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        rejected = false
    }
}

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

    // MARK: - 类别规则层三模式（W1，2026-11-16 方案 §4 A2）

    /// schema 4 客户端模式：legacy 运行旧逻辑（schema 3，默认）；shadow 只在隔离
    /// 评测样本保存诊断、不写任何正式关系；live 才提交新版差量结果。
    enum CategoryRulesMode: String { case legacy, shadow, live }

    private static let categoryRulesModeKey = prefix + "category_rules_mode"
    private static let categoryRulesPilotKey = prefix + "category_rules_pilot_samples"
    private static let categoryRulesServerGate = ThoughtCategoryRulesServerGate()

    /// 当前类别规则层模式；未配置一律 legacy（生产默认不开新版）。
    static func categoryRulesMode(in defaults: UserDefaults = .standard) -> CategoryRulesMode {
        CategoryRulesMode(rawValue: defaults.string(forKey: categoryRulesModeKey) ?? "") ?? .legacy
    }
    /// 模式切换按设置变化处理：递增授权代数并在途任务作废，禁止旧模式的迟到结果落库。
    static func setCategoryRulesMode(_ mode: CategoryRulesMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: categoryRulesModeKey)
        settingsChanged()
    }

    /// W1 隔离评测样本（固定笔记 ID 清单 + 角色标注，仅供诊断归类）：只有这组
    /// 笔记在 shadow/live 模式下使用 schema 4，其余一律按 schema 3。生产默认为空。
    struct CategoryRulesPilotSample: Equatable {
        let thoughtID: UUID
        let role: String
    }
    static func categoryRulesPilotSamples(in defaults: UserDefaults = .standard) -> [CategoryRulesPilotSample] {
        (defaults.stringArray(forKey: categoryRulesPilotKey) ?? []).compactMap { raw in
            guard let separator = raw.firstIndex(of: "|"),
                  let id = UUID(uuidString: String(raw[raw.startIndex..<separator])) else { return nil }
            return CategoryRulesPilotSample(thoughtID: id, role: String(raw[raw.index(after: separator)...]))
        }
    }
    static func setCategoryRulesPilotSamples(_ samples: [CategoryRulesPilotSample]) {
        UserDefaults.standard.set(samples.map { "\($0.thoughtID.uuidString)|\($0.role)" },
                                  forKey: categoryRulesPilotKey)
    }

    /// 服务端闸：schema 4 被服务端拒（协议错误/灰度关闭）后进程内停发新版请求。
    /// 已选样本不立即补发旧协议、不重写已有关系；后续任务经闸回落 legacy。
    static var schema4ServerAvailable: Bool { categoryRulesServerGate.available }
    static func markSchema4ServerRejected() { categoryRulesServerGate.markRejected() }
    /// 仅测试复位用：生产不存在自动恢复路径（恢复旧策略走 W4 定向回滚）。
    static func resetSchema4ServerGateForTesting() { categoryRulesServerGate.reset() }

    // MARK: - 想法脉络核对试点（W2，2026-11-16 方案 §5 B1 / §6 C2）

    private static let followupPilotKey = prefix + "followup_pilot_enabled"
    private static let followupPilotTopicKey = prefix + "followup_pilot_topic_id"

    /// 首次开启通道：启动参数 `-followupPilotTopic <主题UUID>`（不落盘、重启即回默认关）。
    /// 试点没有产品化的开启入口（设置页诊断组只在开启后显示），首次开启/联调验收统一走
    /// 启动参数，符合「验收工具走启动参数、App 内不加调试口子」的项目规矩（2026-11-14）。
    /// 设置页「关闭脉络试点」在启动参数态不生效，重启后自然回到默认关。
    private static let launchPilotTopic: UUID? = {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-followupPilotTopic"),
              flag + 1 < args.count,
              let id = UUID(uuidString: args[flag + 1]) else { return nil }
        return id
    }()

    /// 脉络核对试点开关：默认关（生产全静默，§5 B1「生产配置默认为空」）。
    /// 与其他开关相反的缺省方向——未显式开启一律视为关。
    static func followupPilotEnabled(in defaults: UserDefaults = .standard) -> Bool {
        launchPilotTopic != nil
            || (defaults.object(forKey: followupPilotKey) == nil ? false : defaults.bool(forKey: followupPilotKey))
    }

    /// 唯一稳定试点主题 ID；默认空 = 全静默。主题改名继承同 ID；
    /// 隐藏、合并或删除由协调器按主题有效性检查停止处理（§5 B1）。
    static func followupPilotTopicID(in defaults: UserDefaults = .standard) -> UUID? {
        launchPilotTopic ?? defaults.string(forKey: followupPilotTopicKey).flatMap(UUID.init(uuidString:))
    }

    /// 设置/诊断切换试点范围。切换同样递增授权代数：旧范围的在途任务立即作废，
    /// 迟到结果不得落库（§2 A08）；显式算法升级只重算受影响锚点。
    static func setFollowupPilot(enabled: Bool, topicID: UUID?) {
        UserDefaults.standard.set(enabled, forKey: followupPilotKey)
        if let topicID {
            UserDefaults.standard.set(topicID.uuidString, forKey: followupPilotTopicKey)
        } else {
            UserDefaults.standard.removeObject(forKey: followupPilotTopicKey)
        }
        settingsChanged()
    }

    /// 本机开关面的试点范围（§5 B1）：试点开关开启且 pilotTopicID 非空才返回范围 ID。
    /// AI 处理授权、智能整理总开关、自动成主题开关与服务器能力由协调器在调用侧
    /// 串联成全链资格（与刷新、投影共用同一函数，消费者读同一状态）。
    static func followupPilotScope(in defaults: UserDefaults = .standard) -> UUID? {
        guard followupPilotEnabled(in: defaults) else { return nil }
        return followupPilotTopicID(in: defaults)
    }

    /// 模式与能力检查用同一策略函数（队列去重 hasRelationRecord 与验证器共用）：
    /// 返回该想法当前应使用的 schema 4 模式；nil = legacy（schema 3 旧逻辑）。
    static func categoryRulesCoverage(thoughtID: UUID, in defaults: UserDefaults = .standard) -> CategoryRulesMode? {
        guard schema4ServerAvailable else { return nil }
        let mode = categoryRulesMode(in: defaults)
        guard mode != .legacy,
              categoryRulesPilotSamples(in: defaults).contains(where: { $0.thoughtID == thoughtID }) else { return nil }
        return mode
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
