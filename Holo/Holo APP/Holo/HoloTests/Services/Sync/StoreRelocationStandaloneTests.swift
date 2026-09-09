import CoreData
import Foundation
import SQLite3

@main struct StoreRelocationStandaloneTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.sqlite")
        let new = root.appendingPathComponent("shared/new.sqlite")
        let entity = NSEntityDescription(); entity.name = "Record"; entity.managedObjectClassName = "NSManagedObject"
        let id = NSAttributeDescription(); id.name = "id"; id.attributeType = .UUIDAttributeType
        entity.properties = [id]
        let model = NSManagedObjectModel(); model.entities = [entity]
        let p = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try p.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: old, options: [NSPersistentHistoryTrackingKey: true])
        let c = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); c.persistentStoreCoordinator = p
        let row = NSManagedObject(entity: entity, insertInto: c); row.setValue(UUID(), forKey: "id")
        try c.save()
        let uri = row.objectID.uriRepresentation()
        let uuid = p.metadata(for: store)[NSStoreUUIDKey] as! String
        try p.remove(store)
        // 模拟业务模型之外的同步元数据，验证整库搬迁不会像对象迁移一样丢弃它。
        var db: OpaquePointer?
        precondition(sqlite3_open(old.path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "CREATE TABLE RelocationMetadataProbe (name TEXT); INSERT INTO RelocationMetadataProbe VALUES ('cloud-record-identity');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try CoreDataStack.migrateStore(at: old, to: new, model: model)
        let moved = NSPersistentStoreCoordinator(managedObjectModel: model)
        let loaded = try moved.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: new, options: [NSPersistentHistoryTrackingKey: true])
        precondition(moved.metadata(for: loaded)[NSStoreUUIDKey] as? String == uuid)
        precondition(moved.managedObjectID(forURIRepresentation: uri) != nil)
        precondition(FileManager.default.fileExists(atPath: old.path))
        precondition(sqlite3_open_v2(new.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "SELECT name FROM RelocationMetadataProbe", -1, &statement, nil) == SQLITE_OK)
        precondition(sqlite3_step(statement) == SQLITE_ROW)
        precondition(String(cString: sqlite3_column_text(statement, 0)) == "cloud-record-identity")
        sqlite3_finalize(statement); sqlite3_close(db)
        try moved.remove(loaded)
        print("PASS: 搬迁保留store UUID、对象URI、额外同步元数据和旧库")
    }
}
