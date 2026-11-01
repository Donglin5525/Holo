import Foundation
import CoreData
import CryptoKit
import SQLite3
import os.log

@main
struct CoreDataKnownUpgradeStandaloneTests {
    static let logger = Logger(subsystem: "com.holo.tests", category: "KnownUpgrade")
    static let mode = CommandLine.arguments[1]
    static let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    static var storeURL: URL { directory.appendingPathComponent("HoloDataModel.sqlite") }

    static func expect(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL \(message)\n", stderr); exit(1) }
    }

    static func model(legacy: Bool) -> NSManagedObjectModel {
        let model = CoreDataStack.shared.createDataModel()
        if legacy {
            model.entities = model.entities.filter {
                !CoreDataStoreUpgrade.knowledgeEntityNames.contains($0.name ?? "")
            }
        }
        return model
    }

    static func container(_ model: NSManagedObjectModel, at url: URL) -> NSPersistentContainer {
        let container = UpgradeTestContainer(name: "UpgradeTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        return container
    }

    static func load(_ container: NSPersistentContainer, productionGate: Bool) -> Error? {
        let done = DispatchSemaphore(value: 0)
        var result: Error?
        let finish: (Error?) -> Void = { error in result = error; done.signal() }
        if productionGate {
            CoreDataStack.loadStoreAllowingRecovery(container, logger: logger, onFinish: finish)
        } else {
            container.loadPersistentStores { _, error in finish(error) }
        }
        expect(done.wait(timeout: .now() + 30) == .success, "装载必须到终态")
        return result
    }

    static func normalized(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let data as Data: return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case let id as UUID: return id.uuidString
        case let date as Date: return date.timeIntervalSince1970
        case let number as NSNumber: return number.stringValue
        case let values as [Any]: return values.map { normalized($0) }
        case let text as String: return text
        default: return String(describing: value!)
        }
    }

    static func snapshot(_ container: NSPersistentContainer) throws -> Data {
        let context = container.viewContext
        var rows: [String: Any] = [:]
        // 夹具专用合成实体（wide-additive 模式追加）不参与内容比对
        let skippedNames = CoreDataStoreUpgrade.knowledgeEntityNames.union(["UnsupportedNewEntity"])
        for entity in container.managedObjectModel.entities where !skippedNames.contains(entity.name ?? "") {
            let name = entity.name!
            let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
            rows[name] = objects.map { object -> [String: Any] in
                var values = entity.attributesByName.mapValues { normalized(object.value(forKey: $0.name)) }
                values["_objectURI"] = object.objectID.uriRepresentation().absoluteString
                for relation in entity.relationshipsByName.values {
                    if relation.isToMany {
                        let linked = (object.value(forKey: relation.name) as? NSSet)?.allObjects as? [NSManagedObject] ?? []
                        values[relation.name] = linked.map { $0.objectID.uriRepresentation().absoluteString }.sorted()
                    } else {
                        values[relation.name] = (object.value(forKey: relation.name) as? NSManagedObject)?.objectID.uriRepresentation().absoluteString ?? "nil"
                    }
                }
                return values
            }.sorted { String(describing: $0["_objectURI"]) < String(describing: $1["_objectURI"]) }
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    }

    static func seed(_ container: NSPersistentContainer) throws {
        let context = container.viewContext
        var objects: [String: NSManagedObject] = [:]
        for entity in container.managedObjectModel.entities {
            let name = entity.name!
            let object = NSEntityDescription.insertNewObject(forEntityName: name, into: context)
            objects[name] = object
            for attribute in entity.attributesByName.values {
                if attribute.isOptional && attribute.attributeType != .binaryDataAttributeType { continue }
                let value: Any?
                switch attribute.attributeType {
                case .UUIDAttributeType: value = UUID()
                case .dateAttributeType: value = Date(timeIntervalSince1970: 1_793_030_400)
                case .stringAttributeType: value = attribute.defaultValue ?? "fixture-\(name)-\(attribute.name)"
                case .binaryDataAttributeType: value = Data(repeating: 73, count: attribute.allowsExternalBinaryDataStorage ? 2_000_000 : 23)
                case .decimalAttributeType: value = NSDecimalNumber(string: "123.45")
                case .booleanAttributeType: value = attribute.defaultValue ?? false
                case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: value = attribute.defaultValue ?? 1
                case .doubleAttributeType, .floatAttributeType: value = attribute.defaultValue ?? 1.25
                default: value = attribute.defaultValue
                }
                if let value { object.setValue(value, forKey: attribute.name) }
            }
        }
        for (name, object) in objects {
            for relationship in object.entity.relationshipsByName.values where !relationship.isOptional && !relationship.isToMany {
                if let target = objects[relationship.destinationEntity?.name ?? ""] { object.setValue(target, forKey: relationship.name) }
            }
            if name == "Thought", let tags = object.entity.relationshipsByName["tags"], let tag = objects[tags.destinationEntity?.name ?? ""] {
                object.mutableSetValue(forKey: "tags").add(tag)
            }
            if name == "Transaction" {
                if let category = objects["Category"] { object.setValue(category, forKey: "category") }
                if let account = objects["Account"] { object.setValue(account, forKey: "account") }
            }
        }
        try context.save()
    }

    static func digest(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    static func main() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if mode == "seed" || mode == "seed-new" {
            let legacy = mode == "seed"
            let model = model(legacy: legacy)
            expect(model.entities.count == (legacy ? 63 : 65), "必须使用真实 63→65 实体模型")
            let container = container(model, at: storeURL)
            expect(load(container, productionGate: false) == nil, "合成旧库必须成功建立")
            try seed(container)
            try snapshot(container).write(to: directory.appendingPathComponent("snapshot.json"))
            let support = directory.appendingPathComponent(".HoloDataModel_SUPPORT")
            expect(FileManager.default.fileExists(atPath: support.path), "必须确实覆盖外置 BLOB")
            // 仍有打开的 Core Data 连接时做快照，覆盖 WAL 尚未合并的保存。
            let walBackup = try CoreDataStoreUpgrade.makeBackup(of: storeURL)
            try walBackup.path.write(to: directory.appendingPathComponent("wal-backup.txt"), atomically: true, encoding: .utf8)
            print("PASS \(mode): \(model.entities.count) 实体均有保存记录、关联与外置 BLOB，WAL 快照完成")
            return
        }
        if mode == "verify-backup" {
            let path = try String(contentsOf: directory.appendingPathComponent("backup-to-verify.txt"), encoding: .utf8)
            let container = container(model(legacy: true), at: URL(fileURLWithPath: path))
            expect(load(container, productionGate: false) == nil, "备份应能以旧模型独立打开")
            expect(try snapshot(container) == Data(contentsOf: directory.appendingPathComponent("snapshot.json")), "备份必须保留全部字段、关联、对象身份与附件内容")
            print("PASS 旧模型独立读取备份，全部原始记录一致")
            return
        }
        var lockedDatabase: OpaquePointer?
        if mode == "locked-wal" {
            expect(sqlite3_open(storeURL.path, &lockedDatabase) == SQLITE_OK, "测试连接必须打开")
            expect(sqlite3_exec(lockedDatabase, "PRAGMA journal_mode=WAL; PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE Z_METADATA SET Z_VERSION=Z_VERSION; COMMIT;", nil, nil, nil) == SQLITE_OK, "必须实际持有 WAL 独占锁")
            expect(CoreDataStack.readStoreModelVersionHashes(at: storeURL) == nil, "无法读取实时 WAL 时不能退回可能过期的 immutable 指纹")
        }
        defer { sqlite3_close(lockedDatabase) }
        let isDowngrade = mode == "downgrade"
        let currentModel = model(legacy: isDowngrade)
        if mode == "wide-additive" {
            // 多跳加表升级（2026-10-31 S1）：比白名单时代多出的第三张新表也必须放行
            let extra = NSEntityDescription(); extra.name = "UnsupportedNewEntity"; extra.managedObjectClassName = "NSManagedObject"
            currentModel.entities.append(extra)
        }
        if mode == "unknown" {
            // 非加表差异（改已有实体）必须照旧拒开：给存量实体加一个可选属性使版本哈希变化
            guard let victim = currentModel.entities.first(where: { !CoreDataStoreUpgrade.knowledgeEntityNames.contains($0.name ?? "") }) else {
                fatalError("模型必须有存量实体")
            }
            let tweak = NSAttributeDescription()
            tweak.name = "UnsupportedTweak"
            tweak.attributeType = .stringAttributeType
            tweak.isOptional = true
            victim.properties.append(tweak)
        }
        if mode == "backup-failure" {
            let backupRoot = directory.appendingPathComponent("StoreUpgradeBackups")
            // 在独立失败用例目录内，用普通文件模拟无法创建备份目录的实际 I/O 错误。
            try Data("blocked".utf8).write(to: backupRoot)
        }
        let before = try digest(storeURL)
        let container = container(currentModel, at: storeURL)
        let error = load(container, productionGate: true)
        if ["downgrade", "unknown", "backup-failure", "locked-wal"].contains(mode) {
            expect(error != nil, "不支持的差异或备份失败必须拒绝打开")
            expect(container.persistentStoreCoordinator.persistentStores.isEmpty, "失败不能假装装载成功")
            expect(try digest(storeURL) == before, "拒绝时原库字节不能改变")
            print("PASS \(mode): 明确失败，原库字节原样保留")
            return
        }
        if let error { throw error }
        expect(try snapshot(container) == Data(contentsOf: directory.appendingPathComponent("snapshot.json")), "升级前后全部原始字段、关联、对象 URI 与 BLOB 必须一致")
        let expectedEntities = (mode == "wide-additive") ? 66 : 65
        expect(container.managedObjectModel.entities.count == expectedEntities, "升级后必须真正注册全部新表")
        for name in CoreDataStoreUpgrade.knowledgeEntityNames {
            let row = NSEntityDescription.insertNewObject(forEntityName: name, into: container.viewContext)
            row.setValue("upgrade-probe", forKey: "propositionID")
        }
        try container.viewContext.save()
        print("PASS \(mode): 63→\(expectedEntities)，全部旧记录与对象身份一致，新表可保存")
    }
}

final class UpgradeTestContainer: NSPersistentContainer, @unchecked Sendable {
    override class func defaultDirectoryURL() -> URL { CoreDataKnownUpgradeStandaloneTests.directory }
}
