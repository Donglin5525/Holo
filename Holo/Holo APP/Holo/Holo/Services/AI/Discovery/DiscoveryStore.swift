//
//  DiscoveryStore.swift
//  Holo
//
//  「HoloAI 一个发现」本机独立 store（02 §9.3）。
//
//  · 程序化 NSManagedObjectModel（仿 CoreDataStack 写法，代码定义，不用 xcdatamodeld）
//  · 独立 NSPersistentContainer，目录 Application Support/Holo/Discovery/，不设任何 CloudKit 选项
//  · 与业务 store 完全隔离：只存发现、反馈、临时索引，不进业务 CloudKit 模型
//  · 文件保护 .completeUntilFirstUserAuthentication
//  · 依赖索引不只存支持来源，也存参与解释的反例/统计基线/版本（角色标记）
//  · 否定反馈只存 HMAC-SHA256 指纹（密钥在本机 Keychain，盐=设备主体常量），
//    不存可逆主题文本；显式重置本功能清理指纹（resetNegativeFeedback）
//  · G0 缺口：HabitRecord 无 updatedAt——sourceRevision 一律用内容摘要
//    （DiscoveryContentDigest.sourceRevision(from:)），摘要哪些字段由 G2 适配器决定
//

import Foundation
import CoreData
import CryptoKit
import Security

// MARK: - 内容摘要工具

/// sourceRevision 的确定性拼接 + SHA-256 工具。
/// G0 盘点结论：三域 updatedAt 是手写 Date 且 HabitRecord/CheckItem 没有——版本语义一律走内容摘要。
nonisolated enum DiscoveryContentDigest {

    /// 确定性拼接：字段以 U+001F（单元分隔符）连接后取 SHA-256（小写 hex）。
    /// 字段顺序与字段集由 G2 适配器按域固定（同一记录类型必须永远用同一字段序列）。
    static func sourceRevision(from fields: [String]) -> String {
        let joined = fields.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - 状态枚举（原始值持久化）

/// 运行状态机（02 §9.1）：disabled → waitingForMaterial → scheduled → preparing → ready/noFinding/backoff；
/// cancelled 单独记终态（不写成模型失败）。disabled 由设置承载，不进 run 状态。
enum DiscoveryRunPhase: String, Codable, CaseIterable, Sendable {
    case waitingForMaterial
    case scheduled
    case preparing
    case ready
    case noFinding
    case backoff
    case cancelled
}

/// 内容状态机（02 §9.1）：candidate → verified → published → viewed；
/// published/viewed 可转 rejected/invalidated/expired；已失效不可直接恢复，必须新批次核验。
enum DiscoveryFindingStatus: String, Codable, CaseIterable, Sendable {
    case published
    case viewed
    case rejected
    case invalidated
    case expired
}

// MARK: - 值记录（store 对外交换的纯值）

/// 运行状态记录
struct DiscoveryRunStateRecord: Equatable, Sendable {
    let runID: String
    let phase: DiscoveryRunPhase
    let freeze: DiscoveryRunFreeze
    let diagnostics: [DiscoveryDiagnosticReasonCode]
    let updatedAt: Date
}

/// 服务端控制快照记录（只存控制/租约/预算元数据，不存记录原文或发现正文）
struct DiscoveryControlSnapshotRecord: Equatable, Sendable {
    let revision: Int
    let payloadJSON: String
    let digest: String
    let fetchedAt: Date
}

/// 来源清单条目（run 冻结的 sourceManifest 对应物）
struct DiscoverySourceManifestEntry: Codable, Equatable, Sendable {
    let sourceRef: String
    let kind: DiscoverySourceKind
    let sourceRevision: String
    let fetchedAt: Date
}

/// 发布发现的依赖来源条目（02 §9.3：反例、统计基线与版本也进索引）
struct DiscoveryFindingDependency: Codable, Equatable, Sendable {
    /// 依赖角色：support=支持来源；counterExample=参与解释的反例；baseline=统计基线；version=版本比对依据
    enum Role: String, Codable, CaseIterable, Sendable {
        case support
        case counterExample
        case baseline
        case version
    }

    let sourceRef: String
    let kind: DiscoverySourceKind
    let sourceRevision: String
    let role: Role
}

/// 失效依赖查询命中：受影响发现 + 命中的依赖角色集合
struct DiscoveryInvalidationHit: Equatable, Sendable {
    let findingID: UUID
    let roles: Set<DiscoveryFindingDependency.Role>
}

/// 受限检索临时索引条目（批次内原文块索引；账号清理时删除）
struct DiscoveryRetrievalIndexEntry: Codable, Equatable, Sendable {
    let evidenceID: String
    let sourceRef: String
    let kind: DiscoverySourceKind
    let sourceRevision: String
    let blockHash: String
}

/// 发布内容（本地组装：已核验 claim 原样 + 程序生成的覆盖/范围说明；不加第三轮润色）
struct DiscoveryPublishedPayload: Codable, Equatable, Sendable {
    struct Citation: Codable, Equatable, Sendable {
        let evidenceID: String
        let quote: String
        /// 指纹命中诊断与回源定位用；不参与模型请求
        let sourceRef: String?
    }

    let candidateID: String
    let type: DiscoveryCandidateType
    /// 标题 claim 原文（必须 supported）
    let title: String
    /// 正文 claim 原文序列（按 bodyClaimIDs 组装，全部 supported）
    let body: [String]
    let citations: [Citation]
    /// 程序生成的覆盖/范围说明（02 §8）
    let coverageNote: String
    let sensitivity: DiscoverySensitivity
    let timeRange: DiscoveryTimeRange
    /// 主题指纹材料：否定反馈据此 HMAC 命中（不含原文正文的规范化主题键）
    let fingerprintMaterial: String
}

/// 发布发现记录
struct DiscoveryPublishedFindingRecord: Equatable, Sendable {
    let id: UUID
    let runID: String
    let payload: DiscoveryPublishedPayload
    let status: DiscoveryFindingStatus
    let publishedAt: Date
    let expiresAt: Date
    let freezeDigest: String
}

// MARK: - 否定反馈指纹

/// HMAC-SHA256 指纹（02 §9.3：禁止上传可逆主题文本或无盐短语 hash）。
/// 密钥在本机 Keychain；盐为设备主体常量（V1 无账号体系，用固定常量；
/// G3 若引入跨设备一致账号主体，换盐并按 saltVersion 重算）。
nonisolated enum DiscoveryFeedbackFingerprint {

    static let algorithm = "hmac-sha256"
    static let saltVersion = "v1"
    static let defaultSalt = "holo.discovery.feedback.tombstone.v1"

    /// fingerprint = HMAC-SHA256(key, salt ⊕ U+001F ⊕ material)，输出小写 hex。
    /// 同输入同指纹；不同盐/不同密钥必得不同指纹。
    static func compute(material: String, key: SymmetricKey, salt: String) -> String {
        var input = Data(salt.utf8)
        input.append(0x1F)
        input.append(contentsOf: Array(material.utf8))
        return HMAC<SHA256>.authenticationCode(for: input, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Keychain 密钥提供（32 字节；首次生成后常驻本机 Keychain，卸载不承诺仍记得否定）
private enum DiscoveryFeedbackKeychain {

    static let service = "holo.discovery.feedback"
    static let account = "hmac-key"
    static let keyByteCount = 32

    static func loadOrCreateKeyData() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if readStatus == errSecSuccess, let data = item as? Data {
            return data
        }
        guard readStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(readStatus),
                          userInfo: [NSLocalizedDescriptionKey: "否定反馈密钥读取失败（Keychain）"])
        }
        var keyData = Data(count: keyByteCount)
        let randomResult = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, keyByteCount, buffer.baseAddress!)
        }
        guard randomResult == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(randomResult),
                          userInfo: [NSLocalizedDescriptionKey: "否定反馈密钥生成失败"])
        }
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = keyData
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus),
                          userInfo: [NSLocalizedDescriptionKey: "否定反馈密钥写入失败（Keychain）"])
        }
        return keyData
    }
}

// MARK: - 实体（NSManagedObject 子类）

@objc(DiscoveryControlSnapshotMO)
final class DiscoveryControlSnapshotMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var revision: Int64
    @NSManaged var payloadJSON: String
    @NSManaged var digest: String
    @NSManaged var fetchedAt: Date
}

@objc(DiscoveryRunStateMO)
final class DiscoveryRunStateMO: NSManagedObject {
    @NSManaged var runID: String
    @NSManaged var phaseRaw: String
    @NSManaged var freezeJSON: String
    /// 逗号连接的 DiscoveryDiagnosticReasonCode rawValue（只存枚举）
    @NSManaged var diagnosticsRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(DiscoverySourceManifestMO)
final class DiscoverySourceManifestMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var runID: String
    @NSManaged var sourceRef: String
    @NSManaged var kindRaw: String
    @NSManaged var sourceRevision: String
    @NSManaged var fetchedAt: Date
}

@objc(DiscoverySourceDependencyIndexMO)
final class DiscoverySourceDependencyIndexMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var findingID: UUID
    @NSManaged var sourceRef: String
    @NSManaged var kindRaw: String
    @NSManaged var sourceRevision: String
    @NSManaged var roleRaw: String
    @NSManaged var createdAt: Date
}

@objc(DiscoveryPublishedFindingMO)
final class DiscoveryPublishedFindingMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var runID: String
    @NSManaged var payloadJSON: String
    @NSManaged var statusRaw: String
    @NSManaged var publishedAt: Date
    @NSManaged var expiresAt: Date
    @NSManaged var freezeDigest: String
    @NSManaged var updatedAt: Date
}

@objc(DiscoveryFeedbackTombstoneMO)
final class DiscoveryFeedbackTombstoneMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var fingerprint: String
    @NSManaged var algorithmRaw: String
    @NSManaged var saltVersion: String
    @NSManaged var createdAt: Date
}

@objc(DiscoveryBoundedRetrievalIndexMO)
final class DiscoveryBoundedRetrievalIndexMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var runID: String
    @NSManaged var evidenceID: String
    @NSManaged var sourceRef: String
    @NSManaged var kindRaw: String
    @NSManaged var sourceRevision: String
    @NSManaged var blockHash: String
    @NSManaged var createdAt: Date
}

// MARK: - 程序化模型

/// 程序化模型工厂。全进程只允许一份 NSManagedObjectModel 实例：
/// 多份实例（即使内容相同）会让 NSManagedObject 子类→实体映射全局歧义，
/// 装载次数一多触发 134020（教训见 CoreDataStack.sharedDataModel 注释）。
private enum DiscoveryStoreModelFactory {

    static let entityNames = [
        "DiscoveryControlSnapshotMO",
        "DiscoveryRunStateMO",
        "DiscoverySourceManifestMO",
        "DiscoverySourceDependencyIndexMO",
        "DiscoveryPublishedFindingMO",
        "DiscoveryFeedbackTombstoneMO",
        "DiscoveryBoundedRetrievalIndexMO",
    ]

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [
            makeControlSnapshotEntity(),
            makeRunStateEntity(),
            makeSourceManifestEntity(),
            makeSourceDependencyIndexEntity(),
            makePublishedFindingEntity(),
            makeFeedbackTombstoneEntity(),
            makeBoundedRetrievalIndexEntity(),
        ]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        return attribute
    }

    private static func makeControlSnapshotEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoveryControlSnapshotMO"
        entity.managedObjectClassName = "Holo.DiscoveryControlSnapshotMO"
        let id = attribute("id", .UUIDAttributeType, defaultValue: UUID())
        let revision = attribute("revision", .integer64AttributeType, defaultValue: 0)
        let payloadJSON = attribute("payloadJSON", .stringAttributeType, defaultValue: "")
        let digest = attribute("digest", .stringAttributeType, defaultValue: "")
        let fetchedAt = attribute("fetchedAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [id, revision, payloadJSON, digest, fetchedAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "revision": revision])
        return entity
    }

    private static func makeRunStateEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoveryRunStateMO"
        entity.managedObjectClassName = "Holo.DiscoveryRunStateMO"
        let runID = attribute("runID", .stringAttributeType, defaultValue: "")
        let phaseRaw = attribute("phaseRaw", .stringAttributeType, defaultValue: DiscoveryRunPhase.waitingForMaterial.rawValue)
        let freezeJSON = attribute("freezeJSON", .stringAttributeType, defaultValue: "{}")
        let diagnosticsRaw = attribute("diagnosticsRaw", .stringAttributeType, defaultValue: "")
        let createdAt = attribute("createdAt", .dateAttributeType, defaultValue: Date())
        let updatedAt = attribute("updatedAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [runID, phaseRaw, freezeJSON, diagnosticsRaw, createdAt, updatedAt]
        CoreDataStack.applyIndexes(to: entity, on: ["runID": runID, "phaseRaw": phaseRaw])
        return entity
    }

    private static func makeSourceManifestEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoverySourceManifestMO"
        entity.managedObjectClassName = "Holo.DiscoverySourceManifestMO"
        let id = attribute("id", .UUIDAttributeType, defaultValue: UUID())
        let runID = attribute("runID", .stringAttributeType, defaultValue: "")
        let sourceRef = attribute("sourceRef", .stringAttributeType, defaultValue: "")
        let kindRaw = attribute("kindRaw", .stringAttributeType, defaultValue: DiscoverySourceKind.thought.rawValue)
        let sourceRevision = attribute("sourceRevision", .stringAttributeType, defaultValue: "")
        let fetchedAt = attribute("fetchedAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [id, runID, sourceRef, kindRaw, sourceRevision, fetchedAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "runID": runID, "sourceRef": sourceRef])
        return entity
    }

    private static func makeSourceDependencyIndexEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoverySourceDependencyIndexMO"
        entity.managedObjectClassName = "Holo.DiscoverySourceDependencyIndexMO"
        let id = attribute("id", .UUIDAttributeType, defaultValue: UUID())
        let findingID = attribute("findingID", .UUIDAttributeType, defaultValue: UUID())
        let sourceRef = attribute("sourceRef", .stringAttributeType, defaultValue: "")
        let kindRaw = attribute("kindRaw", .stringAttributeType, defaultValue: DiscoverySourceKind.thought.rawValue)
        let sourceRevision = attribute("sourceRevision", .stringAttributeType, defaultValue: "")
        let roleRaw = attribute("roleRaw", .stringAttributeType, defaultValue: DiscoveryFindingDependency.Role.support.rawValue)
        let createdAt = attribute("createdAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [id, findingID, sourceRef, kindRaw, sourceRevision, roleRaw, createdAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "findingID": findingID, "sourceRef": sourceRef])
        return entity
    }

    private static func makePublishedFindingEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoveryPublishedFindingMO"
        entity.managedObjectClassName = "Holo.DiscoveryPublishedFindingMO"
        let id = attribute("id", .UUIDAttributeType, defaultValue: UUID())
        let runID = attribute("runID", .stringAttributeType, defaultValue: "")
        let payloadJSON = attribute("payloadJSON", .stringAttributeType, defaultValue: "{}")
        let statusRaw = attribute("statusRaw", .stringAttributeType, defaultValue: DiscoveryFindingStatus.published.rawValue)
        let publishedAt = attribute("publishedAt", .dateAttributeType, defaultValue: Date())
        let expiresAt = attribute("expiresAt", .dateAttributeType, defaultValue: Date())
        let freezeDigest = attribute("freezeDigest", .stringAttributeType, defaultValue: "")
        let updatedAt = attribute("updatedAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [id, runID, payloadJSON, statusRaw, publishedAt, expiresAt, freezeDigest, updatedAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "statusRaw": statusRaw, "expiresAt": expiresAt])
        return entity
    }

    private static func makeFeedbackTombstoneEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoveryFeedbackTombstoneMO"
        entity.managedObjectClassName = "Holo.DiscoveryFeedbackTombstoneMO"
        let id = attribute("id", .UUIDAttributeType, defaultValue: UUID())
        let fingerprint = attribute("fingerprint", .stringAttributeType, defaultValue: "")
        let algorithmRaw = attribute("algorithmRaw", .stringAttributeType, defaultValue: DiscoveryFeedbackFingerprint.algorithm)
        let saltVersion = attribute("saltVersion", .stringAttributeType, defaultValue: DiscoveryFeedbackFingerprint.saltVersion)
        let createdAt = attribute("createdAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [id, fingerprint, algorithmRaw, saltVersion, createdAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "fingerprint": fingerprint])
        return entity
    }

    private static func makeBoundedRetrievalIndexEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DiscoveryBoundedRetrievalIndexMO"
        entity.managedObjectClassName = "Holo.DiscoveryBoundedRetrievalIndexMO"
        let id = attribute("id", .UUIDAttributeType, defaultValue: UUID())
        let runID = attribute("runID", .stringAttributeType, defaultValue: "")
        let evidenceID = attribute("evidenceID", .stringAttributeType, defaultValue: "")
        let sourceRef = attribute("sourceRef", .stringAttributeType, defaultValue: "")
        let kindRaw = attribute("kindRaw", .stringAttributeType, defaultValue: DiscoverySourceKind.thought.rawValue)
        let sourceRevision = attribute("sourceRevision", .stringAttributeType, defaultValue: "")
        let blockHash = attribute("blockHash", .stringAttributeType, defaultValue: "")
        let createdAt = attribute("createdAt", .dateAttributeType, defaultValue: Date())
        entity.properties = [id, runID, evidenceID, sourceRef, kindRaw, sourceRevision, blockHash, createdAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "runID": runID, "sourceRef": sourceRef])
        return entity
    }
}

// MARK: - Store

/// performAndWait 同步取回结果的一次性盒子。
/// @unchecked 依据：performAndWait 同步执行——闭包跑完才回到调用线程读 box，无并发访问窗口。
nonisolated private final class DiscoverySyncBox<T>: @unchecked Sendable {
    var value: Result<T, Error>!
}

/// 「一个发现」本机 store。所有写入走 performWrite（perform 块内事务，失败回滚不写半截）。
/// 同步接口（performAndWait）：数据量小（候选 ≤3、发现最多 1 条），调用方在后台队列使用。
nonisolated final class DiscoveryStore {

    enum StoreError: Error {
        case loadFailed(underlying: Error)
        case payloadCoding(underlying: Error)
    }

    /// 配置。feedbackKey 注入则用注入值（测试）；nil = Keychain 加载/生成。
    struct Configuration: Sendable {
        /// nil = 默认 Application Support/Holo/Discovery/
        var directory: URL?
        var inMemory: Bool
        /// 32 字节 HMAC 密钥
        var feedbackKey: Data?
        var feedbackSalt: String

        init(
            directory: URL? = nil,
            inMemory: Bool = false,
            feedbackKey: Data? = nil,
            feedbackSalt: String = DiscoveryFeedbackFingerprint.defaultSalt
        ) {
            self.directory = directory
            self.inMemory = inMemory
            self.feedbackKey = feedbackKey
            self.feedbackSalt = feedbackSalt
        }
    }

    /// 默认目录（02 §9.3：Application Support/Holo/Discovery/）
    static let defaultDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Holo/Discovery", isDirectory: true)
    }()

    /// 全进程唯一模型实例（理由见 DiscoveryStoreModelFactory 注释）
    private static let sharedModel: NSManagedObjectModel = DiscoveryStoreModelFactory.makeModel()

    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let feedbackKey: SymmetricKey
    private let feedbackSalt: String

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(configuration: Configuration = Configuration()) throws {
        // 模型必须在容器创建前就绪；sharedModel 保证唯一
        let container = NSPersistentContainer(name: "HoloDiscoveryModel", managedObjectModel: Self.sharedModel)
        let description: NSPersistentStoreDescription
        if configuration.inMemory {
            description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            description.type = NSInMemoryStoreType
        } else {
            let directory = configuration.directory ?? Self.defaultDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            description = NSPersistentStoreDescription(
                url: directory.appendingPathComponent("HoloDiscoveryModel.sqlite")
            )
            description.type = NSSQLiteStoreType
            // 02 §9.3：正文缓存文件保护（锁屏后首次解锁前不可读）
            description.setOption(
                FileProtectionType.completeUntilFirstUserAuthentication.rawValue as NSString,
                forKey: NSPersistentStoreFileProtectionKey
            )
        }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            throw StoreError.loadFailed(underlying: loadError)
        }

        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.container = container
        self.context = context
        self.feedbackSalt = configuration.feedbackSalt

        if let injectedKey = configuration.feedbackKey {
            self.feedbackKey = SymmetricKey(data: injectedKey)
        } else {
            do {
                self.feedbackKey = SymmetricKey(data: try DiscoveryFeedbackKeychain.loadOrCreateKeyData())
            } catch {
                // Keychain 不可用（极少数托管环境）：派生进程内临时密钥。
                // 后果＝指纹不跨启动持久，注销“不承诺仍记得否定”，可接受且不阻塞功能。
                var temporary = Data(count: DiscoveryFeedbackKeychain.keyByteCount)
                _ = temporary.withUnsafeMutableBytes { buffer in
                    SecRandomCopyBytes(kSecRandomDefault, DiscoveryFeedbackKeychain.keyByteCount, buffer.baseAddress!)
                }
                self.feedbackKey = SymmetricKey(data: temporary)
            }
        }
    }

    // MARK: - 事务

    /// 原子写入：perform 块内执行，body 抛错或 save 失败即整体回滚，绝不写半截。
    func performWrite<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let box = DiscoverySyncBox<T>()
        context.performAndWait { [context] in
            do {
                let result = try body(context)
                if context.hasChanges {
                    try context.save()
                }
                box.value = .success(result)
            } catch {
                context.rollback()
                box.value = .failure(error)
            }
        }
        return try box.value!.get()
    }

    /// 只读查询（同上下文串行，保证与写入一致的世界观）。
    func performRead<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let box = DiscoverySyncBox<T>()
        context.performAndWait { [context] in
            box.value = Result { try body(context) }
        }
        return try box.value!.get()
    }

    // MARK: - 控制快照

    func upsertControlSnapshot(_ record: DiscoveryControlSnapshotRecord) throws {
        try performWrite { context in
            let mo: DiscoveryControlSnapshotMO
            if let existing = try Self.fetchSingle(DiscoveryControlSnapshotMO.self, entityName: "DiscoveryControlSnapshotMO", context: context) {
                mo = existing
            } else {
                mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoveryControlSnapshotMO", into: context) as! DiscoveryControlSnapshotMO
            }
            mo.revision = Int64(record.revision)
            mo.payloadJSON = record.payloadJSON
            mo.digest = record.digest
            mo.fetchedAt = record.fetchedAt
        }
    }

    func latestControlSnapshot() throws -> DiscoveryControlSnapshotRecord? {
        try performRead { context in
            guard let mo = try Self.fetchSingle(DiscoveryControlSnapshotMO.self, entityName: "DiscoveryControlSnapshotMO", context: context) else {
                return nil
            }
            return DiscoveryControlSnapshotRecord(
                revision: Int(mo.revision),
                payloadJSON: mo.payloadJSON,
                digest: mo.digest,
                fetchedAt: mo.fetchedAt
            )
        }
    }

    // MARK: - 运行状态

    func upsertRunState(freeze: DiscoveryRunFreeze, phase: DiscoveryRunPhase, now: Date) throws {
        let freezeJSON = String(data: try Self.jsonEncoder.encode(freeze), encoding: .utf8) ?? ""
        try performWrite { context in
            let mo = try Self.fetchOrCreateRunState(runID: freeze.runID, context: context)
            mo.phaseRaw = phase.rawValue
            mo.freezeJSON = freezeJSON
            mo.updatedAt = now
        }
    }

    func updateRunPhase(runID: String, phase: DiscoveryRunPhase, diagnostics: [DiscoveryDiagnosticReasonCode], now: Date) throws {
        try performWrite { context in
            let mo = try Self.fetchOrCreateRunState(runID: runID, context: context)
            mo.phaseRaw = phase.rawValue
            mo.diagnosticsRaw = diagnostics.map(\.rawValue).joined(separator: ",")
            mo.updatedAt = now
        }
    }

    func runState(runID: String) throws -> DiscoveryRunStateRecord? {
        try performRead { context in
            guard let mo = try Self.fetchRunState(runID: runID, context: context) else { return nil }
            return try Self.record(from: mo)
        }
    }

    /// 在途运行（未到终态的），供关闭/撤权时取消判断
    func activeRuns() throws -> [DiscoveryRunStateRecord] {
        try performRead { context in
            let request = NSFetchRequest<DiscoveryRunStateMO>(entityName: "DiscoveryRunStateMO")
            request.predicate = NSPredicate(
                format: "phaseRaw IN %@",
                [DiscoveryRunPhase.waitingForMaterial, .scheduled, .preparing].map(\.rawValue)
            )
            return try context.fetch(request).map { try Self.record(from: $0) }
        }
    }

    // MARK: - 来源清单

    /// 记录一次运行的来源清单（同 runID 整体替换）
    func recordSourceManifest(runID: String, entries: [DiscoverySourceManifestEntry]) throws {
        try performWrite { context in
            let request = NSFetchRequest<DiscoverySourceManifestMO>(entityName: "DiscoverySourceManifestMO")
            request.predicate = NSPredicate(format: "runID == %@", runID)
            for existing in try context.fetch(request) {
                context.delete(existing)
            }
            for entry in entries {
                let mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoverySourceManifestMO", into: context) as! DiscoverySourceManifestMO
                mo.runID = runID
                mo.sourceRef = entry.sourceRef
                mo.kindRaw = entry.kind.rawValue
                mo.sourceRevision = entry.sourceRevision
                mo.fetchedAt = entry.fetchedAt
            }
        }
    }

    func sourceManifest(runID: String) throws -> [DiscoverySourceManifestEntry] {
        try performRead { context in
            let request = NSFetchRequest<DiscoverySourceManifestMO>(entityName: "DiscoverySourceManifestMO")
            request.predicate = NSPredicate(format: "runID == %@", runID)
            request.sortDescriptors = [NSSortDescriptor(key: "sourceRef", ascending: true)]
            return try context.fetch(request).map {
                DiscoverySourceManifestEntry(
                    sourceRef: $0.sourceRef,
                    kind: DiscoverySourceKind(rawValue: $0.kindRaw) ?? .thought,
                    sourceRevision: $0.sourceRevision,
                    fetchedAt: $0.fetchedAt
                )
            }
        }
    }

    /// 来源清单确定性摘要（进 DiscoveryRunFreeze.sourceManifestDigest）
    func sourceManifestDigest(runID: String) throws -> String {
        let entries = try sourceManifest(runID: runID)
        return DiscoveryContentDigest.sourceRevision(
            from: ["discovery.manifest.v1"]
                + entries.map { "\($0.sourceRef)=\($0.sourceRevision)" }
        )
    }

    // MARK: - 发布（当前有效最多一条）

    /// 发布发现：写入新发现 + 依赖索引；同时删除旧的活跃发现（published/viewed）。
    /// V1 只持久化最终一条（02 §8），旧条整体删除（含摘录，隐私优先）。
    /// 有效期初值 14 天由调用方算出 expiresAt 传入。
    @discardableResult
    func publishFinding(
        runID: String,
        payload: DiscoveryPublishedPayload,
        dependencies: [DiscoveryFindingDependency],
        publishedAt: Date,
        expiresAt: Date,
        freezeDigest: String
    ) throws -> UUID {
        let payloadJSON = String(data: try Self.jsonEncoder.encode(payload), encoding: .utf8) ?? ""
        return try performWrite { context in
            // 替换旧条：当前有效发现最多一条
            let activeRequest = NSFetchRequest<DiscoveryPublishedFindingMO>(entityName: "DiscoveryPublishedFindingMO")
            activeRequest.predicate = NSPredicate(
                format: "statusRaw IN %@",
                [DiscoveryFindingStatus.published, .viewed].map(\.rawValue)
            )
            for existing in try context.fetch(activeRequest) {
                Self.deleteDependencies(ofFinding: existing.id, context: context)
                context.delete(existing)
            }

            let findingID = UUID()
            let mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoveryPublishedFindingMO", into: context) as! DiscoveryPublishedFindingMO
            mo.id = findingID
            mo.runID = runID
            mo.payloadJSON = payloadJSON
            mo.statusRaw = DiscoveryFindingStatus.published.rawValue
            mo.publishedAt = publishedAt
            mo.expiresAt = expiresAt
            mo.freezeDigest = freezeDigest
            mo.updatedAt = publishedAt

            for dependency in dependencies {
                let index = NSEntityDescription.insertNewObject(forEntityName: "DiscoverySourceDependencyIndexMO", into: context) as! DiscoverySourceDependencyIndexMO
                index.findingID = findingID
                index.sourceRef = dependency.sourceRef
                index.kindRaw = dependency.kind.rawValue
                index.sourceRevision = dependency.sourceRevision
                index.roleRaw = dependency.role.rawValue
                index.createdAt = publishedAt
            }
            return findingID
        }
    }

    /// 当前有效发现（published/viewed 且未过期；过期不在此处改状态，展示门控会拒）
    func activeFinding(now: Date) throws -> DiscoveryPublishedFindingRecord? {
        try performRead { context in
            let request = NSFetchRequest<DiscoveryPublishedFindingMO>(entityName: "DiscoveryPublishedFindingMO")
            request.predicate = NSPredicate(
                format: "statusRaw IN %@ AND expiresAt >= %@",
                [DiscoveryFindingStatus.published, .viewed].map(\.rawValue),
                now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "publishedAt", ascending: false)]
            request.fetchLimit = 1
            return try context.fetch(request).first.map { try Self.record(from: $0) }
        }
    }

    /// 标记发现状态（viewed/rejected/invalidated/expired；已失效不可恢复）
    func markFinding(id: UUID, status: DiscoveryFindingStatus, now: Date) throws {
        try performWrite { context in
            let request = NSFetchRequest<DiscoveryPublishedFindingMO>(entityName: "DiscoveryPublishedFindingMO")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let mo = try context.fetch(request).first else { return }
            mo.statusRaw = status.rawValue
            mo.updatedAt = now
        }
    }

    // MARK: - 失效依赖查询

    /// 给定 sourceRef 集合 → 受影响的活跃 PublishedFinding（含参与反例/统计基线/版本
    /// 的依赖，单独标记角色）。02 §9.3：排除/删除触发以依赖集失效；
    /// 无法保证精确范围时调用方应保守撤销全部当前发现（保守撤销策略在 G2 适配器/协调器）。
    func findingsAffected(bySourceRefs sourceRefs: Set<String>) throws -> [DiscoveryInvalidationHit] {
        guard !sourceRefs.isEmpty else { return [] }
        return try performRead { context in
            let activeRequest = NSFetchRequest<DiscoveryPublishedFindingMO>(entityName: "DiscoveryPublishedFindingMO")
            activeRequest.predicate = NSPredicate(
                format: "statusRaw IN %@",
                [DiscoveryFindingStatus.published, .viewed].map(\.rawValue)
            )
            let activeFindings = try context.fetch(activeRequest)
            guard !activeFindings.isEmpty else { return [] }
            let activeIDs = Set(activeFindings.map(\.id))

            let indexRequest = NSFetchRequest<DiscoverySourceDependencyIndexMO>(entityName: "DiscoverySourceDependencyIndexMO")
            indexRequest.predicate = NSPredicate(format: "sourceRef IN %@", sourceRefs)
            var hits: [UUID: Set<DiscoveryFindingDependency.Role>] = [:]
            for index in try context.fetch(indexRequest) where activeIDs.contains(index.findingID) {
                let role = DiscoveryFindingDependency.Role(rawValue: index.roleRaw) ?? .support
                hits[index.findingID, default: []].insert(role)
            }
            return hits
                .map { DiscoveryInvalidationHit(findingID: $0.key, roles: $0.value) }
                .sorted { $0.findingID.uuidString < $1.findingID.uuidString }
        }
    }

    /// 失效一个发现的全部依赖行（发现被删除/撤销时）
    func invalidateFinding(id: UUID, now: Date) throws {
        try performWrite { context in
            let request = NSFetchRequest<DiscoveryPublishedFindingMO>(entityName: "DiscoveryPublishedFindingMO")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            for mo in try context.fetch(request) {
                mo.statusRaw = DiscoveryFindingStatus.invalidated.rawValue
                mo.updatedAt = now
            }
        }
    }

    // MARK: - 否定反馈（HMAC 指纹）

    /// 记录否定反馈：立即撤下由调用方配合 markFinding(.rejected)；
    /// 这里只落不可逆指纹（同输入幂等）。
    func recordNegativeFeedback(fingerprintMaterial: String, now: Date) throws {
        let fingerprint = DiscoveryFeedbackFingerprint.compute(material: fingerprintMaterial, key: feedbackKey, salt: feedbackSalt)
        try performWrite { context in
            let request = NSFetchRequest<DiscoveryFeedbackTombstoneMO>(entityName: "DiscoveryFeedbackTombstoneMO")
            request.predicate = NSPredicate(format: "fingerprint == %@", fingerprint)
            if try context.fetch(request).first != nil { return }
            let mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoveryFeedbackTombstoneMO", into: context) as! DiscoveryFeedbackTombstoneMO
            mo.fingerprint = fingerprint
            mo.algorithmRaw = DiscoveryFeedbackFingerprint.algorithm
            mo.saltVersion = DiscoveryFeedbackFingerprint.saltVersion
            mo.createdAt = now
        }
    }

    /// 主题指纹是否已命中否定
    func hasNegativeFeedback(fingerprintMaterial: String) throws -> Bool {
        let fingerprint = DiscoveryFeedbackFingerprint.compute(material: fingerprintMaterial, key: feedbackKey, salt: feedbackSalt)
        return try performRead { context in
            let request = NSFetchRequest<DiscoveryFeedbackTombstoneMO>(entityName: "DiscoveryFeedbackTombstoneMO")
            request.predicate = NSPredicate(format: "fingerprint == %@", fingerprint)
            return try context.fetch(request).first != nil
        }
    }

    /// 显式重置本功能：清理否定指纹（02 §9.3）
    func resetNegativeFeedback() throws {
        try performWrite { context in
            let request = NSFetchRequest<DiscoveryFeedbackTombstoneMO>(entityName: "DiscoveryFeedbackTombstoneMO")
            for mo in try context.fetch(request) {
                context.delete(mo)
            }
        }
    }

    // MARK: - 受限检索临时索引

    /// 记录批次原文块索引（同 runID 整体替换）
    func recordRetrievalIndex(runID: String, entries: [DiscoveryRetrievalIndexEntry]) throws {
        try performWrite { context in
            let request = NSFetchRequest<DiscoveryBoundedRetrievalIndexMO>(entityName: "DiscoveryBoundedRetrievalIndexMO")
            request.predicate = NSPredicate(format: "runID == %@", runID)
            for existing in try context.fetch(request) {
                context.delete(existing)
            }
            for entry in entries {
                let mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoveryBoundedRetrievalIndexMO", into: context) as! DiscoveryBoundedRetrievalIndexMO
                mo.runID = runID
                mo.evidenceID = entry.evidenceID
                mo.sourceRef = entry.sourceRef
                mo.kindRaw = entry.kind.rawValue
                mo.sourceRevision = entry.sourceRevision
                mo.blockHash = entry.blockHash
            }
        }
    }

    func retrievalIndex(runID: String) throws -> [DiscoveryRetrievalIndexEntry] {
        try performRead { context in
            let request = NSFetchRequest<DiscoveryBoundedRetrievalIndexMO>(entityName: "DiscoveryBoundedRetrievalIndexMO")
            request.predicate = NSPredicate(format: "runID == %@", runID)
            request.sortDescriptors = [NSSortDescriptor(key: "evidenceID", ascending: true)]
            return try context.fetch(request).map {
                DiscoveryRetrievalIndexEntry(
                    evidenceID: $0.evidenceID,
                    sourceRef: $0.sourceRef,
                    kind: DiscoverySourceKind(rawValue: $0.kindRaw) ?? .thought,
                    sourceRevision: $0.sourceRevision,
                    blockHash: $0.blockHash
                )
            }
        }
    }

    // MARK: - 账号清理

    /// 注销/切账号/撤总授权/关闭功能：清掉候选、原文摘录、索引与在途数据（含当前发现），
    /// **保留否定反馈指纹**（02 §9.3；指纹的显式清理走 resetNegativeFeedback）。
    /// V1 单设备一份本地库，不按账号拆库；引入账号体系后此 API 带 subject 参数。
    func clearAllForAccount(now: Date) throws {
        try performWrite { context in
            try Self.deleteAll(entityName: "DiscoveryRunStateMO", context: context)
            try Self.deleteAll(entityName: "DiscoverySourceManifestMO", context: context)
            try Self.deleteAll(entityName: "DiscoveryBoundedRetrievalIndexMO", context: context)
            try Self.deleteAll(entityName: "DiscoverySourceDependencyIndexMO", context: context)
            try Self.deleteAll(entityName: "DiscoveryPublishedFindingMO", context: context)
        }
    }

    // MARK: - 私有取数/映射

    private static func fetchSingle<T: NSManagedObject>(
        _ type: T.Type,
        entityName: String,
        context: NSManagedObjectContext
    ) throws -> T? {
        let request = NSFetchRequest<T>(entityName: entityName)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func fetchRunState(runID: String, context: NSManagedObjectContext) throws -> DiscoveryRunStateMO? {
        let request = NSFetchRequest<DiscoveryRunStateMO>(entityName: "DiscoveryRunStateMO")
        request.predicate = NSPredicate(format: "runID == %@", runID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func fetchOrCreateRunState(runID: String, context: NSManagedObjectContext) throws -> DiscoveryRunStateMO {
        if let existing = try fetchRunState(runID: runID, context: context) {
            return existing
        }
        let mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoveryRunStateMO", into: context) as! DiscoveryRunStateMO
        mo.runID = runID
        mo.phaseRaw = DiscoveryRunPhase.waitingForMaterial.rawValue
        mo.diagnosticsRaw = ""
        let now = Date()
        mo.createdAt = now
        mo.updatedAt = now
        return mo
    }

    private static func deleteDependencies(ofFinding findingID: UUID, context: NSManagedObjectContext) {
        let request = NSFetchRequest<DiscoverySourceDependencyIndexMO>(entityName: "DiscoverySourceDependencyIndexMO")
        request.predicate = NSPredicate(format: "findingID == %@", findingID as CVarArg)
        if let rows = try? context.fetch(request) {
            for row in rows {
                context.delete(row)
            }
        }
    }

    private static func deleteAll(entityName: String, context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        for mo in try context.fetch(request) {
            context.delete(mo)
        }
    }

    private static func record(from mo: DiscoveryRunStateMO) throws -> DiscoveryRunStateRecord {
        guard let freezeData = mo.freezeJSON.data(using: .utf8) else {
            throw StoreError.payloadCoding(underlying: DiscoverySchemaError(issues: [
                DiscoverySchemaIssue(code: .malformedDocument, path: "$.freezeJSON", detail: "freezeJSON 非UTF-8")
            ]))
        }
        let freeze = try jsonDecoder.decode(DiscoveryRunFreeze.self, from: freezeData)
        let diagnostics = mo.diagnosticsRaw
            .split(separator: ",")
            .compactMap { DiscoveryDiagnosticReasonCode(rawValue: String($0)) }
        return DiscoveryRunStateRecord(
            runID: mo.runID,
            phase: DiscoveryRunPhase(rawValue: mo.phaseRaw) ?? .waitingForMaterial,
            freeze: freeze,
            diagnostics: diagnostics,
            updatedAt: mo.updatedAt
        )
    }

    private static func record(from mo: DiscoveryPublishedFindingMO) throws -> DiscoveryPublishedFindingRecord {
        guard let payloadData = mo.payloadJSON.data(using: .utf8) else {
            throw StoreError.payloadCoding(underlying: DiscoverySchemaError(issues: [
                DiscoverySchemaIssue(code: .malformedDocument, path: "$.payloadJSON", detail: "payloadJSON 非UTF-8")
            ]))
        }
        let payload = try jsonDecoder.decode(DiscoveryPublishedPayload.self, from: payloadData)
        return DiscoveryPublishedFindingRecord(
            id: mo.id,
            runID: mo.runID,
            payload: payload,
            status: DiscoveryFindingStatus(rawValue: mo.statusRaw) ?? .published,
            publishedAt: mo.publishedAt,
            expiresAt: mo.expiresAt,
            freezeDigest: mo.freezeDigest
        )
    }
}
