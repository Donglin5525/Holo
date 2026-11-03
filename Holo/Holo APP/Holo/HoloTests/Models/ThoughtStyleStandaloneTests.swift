import CoreData
import Foundation

// 独立验证复用真实实体工厂，不加载用户数据库、CloudKit 或 App 启动服务。
final class CoreDataStack {}

@main
struct ThoughtStyleStandaloneTests {
    static var assertionCount = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func model(withStyle: Bool) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entities = CoreDataStack().createThoughtEntities()
        for entity in entities {
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            if entity.name == "Thought", !withStyle {
                entity.properties = entity.properties.filter { $0.name != "appearanceRaw" }
            }
        }
        model.entities = entities
        return model
    }

    static func main() throws {
        expect(ThoughtStyle(storedValue: nil) == .plain, "旧想法必须保持原样")
        expect(ThoughtStyle(storedValue: "future-style") == .plain, "未知样式应能阅读原文")
        expect(ThoughtStyle.plain.storedValue == nil, "恢复原样应清除样式值")
        expect(Set(ThoughtStyle.allCases.map(\.rawValue)).count == 9, "原样与八套模板不能重名")

        expect(ThoughtStyle(storedValue: "journal") == .post, "旧手账映射邮笺")
        expect(ThoughtStyle(storedValue: "midnight") == .post, "旧来信映射邮笺")
        expect(ThoughtStyle(storedValue: "book") == .bookmark, "旧书页映射书签")
        expect(ThoughtStyle(storedValue: "archive") == .field, "旧档案映射观察本")
        expect(ThoughtStyle.allCases.filter { $0.fontRole == .system }.count == 4, "系统字体供四个样式共用")
        expect(ThoughtStyle.allCases.filter { $0.fontRole == .serif }.count == 2, "宋体供两套模板共用")
        expect(ThoughtStyle.allCases.filter { $0.fontRole == .handwritten }.count == 3, "手写体供三套模板共用")
        expect(ThoughtStyle.film.photosLead && !ThoughtStyle.post.photosLead, "胶片在正文前展示照片")

        let current = model(withStyle: true)
        let attribute = current.entitiesByName["Thought"]?.attributesByName["appearanceRaw"]
        expect(attribute?.attributeType == .stringAttributeType && attribute?.isOptional == true, "升级必须只增加可空字符串")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holo-style-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        let text = "**原有文字** #阅读\n第二段仍然保留。"
        let richJSON = "[{\"type\":\"text\",\"text\":\"原有富文本\"}]"
        var originalURI: URL?
        try autoreleasepool {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model(withStyle: false))
            let store = try coordinator.addPersistentStore(type: .sqlite, at: url)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let note = NSEntityDescription.insertNewObject(forEntityName: "Thought", into: context)
            note.setValue(text, forKey: "content")
            note.setValue(richJSON, forKey: "richContentJSON")
            note.setValue("organized", forKey: "organizedStatus")
            let tag = NSEntityDescription.insertNewObject(forEntityName: "ThoughtTag", into: context)
            tag.setValue("阅读", forKey: "name")
            note.mutableSetValue(forKey: "tags").add(tag)
            try context.save()
            originalURI = note.objectID.uriRepresentation()
            try coordinator.remove(store)
        }
        try autoreleasepool {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
            let store = try coordinator.addPersistentStore(type: .sqlite, at: url, options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ])
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Thought"))
            expect(notes.count == 1, "迁移不能少记录或重建空库")
            let note = notes[0]
            expect(note.value(forKey: "content") as? String == text, "迁移不能重写正文")
            expect(note.value(forKey: "richContentJSON") as? String == richJSON, "迁移不能丢富文本")
            expect((note.value(forKey: "tags") as? NSSet)?.count == 1, "迁移不能丢标签关系")
            expect(note.objectID.uriRepresentation() == originalURI, "迁移不能重建记录身份")
            expect(note.value(forKey: "appearanceRaw") == nil, "旧记录默认原样")
            note.setValue(ThoughtStyle.calendar.storedValue, forKey: "appearanceRaw")
            try context.save()
            context.reset()
            let reloaded = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Thought"))[0]
            expect(reloaded.value(forKey: "appearanceRaw") as? String == "calendar", "重新加载必须保留样式")
            expect(reloaded.value(forKey: "organizedStatus") as? String == "organized", "换样式不能重新整理正文")
            reloaded.setValue(ThoughtStyle.plain.storedValue, forKey: "appearanceRaw")
            try context.save()
            context.reset()
            let restored = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Thought"))[0]
            expect(restored.value(forKey: "appearanceRaw") == nil, "重新加载后也应恢复原样")
            expect(restored.value(forKey: "content") as? String == text, "恢复原样不能改正文")
            for style in ThoughtStyle.allCases {
                restored.setValue(style.storedValue, forKey: "appearanceRaw")
                try context.save()
                context.refresh(restored, mergeChanges: false)
                expect(ThoughtStyle(storedValue: restored.value(forKey: "appearanceRaw") as? String) == style, "全部模板都可保存重载")
                expect(restored.value(forKey: "content") as? String == text, "换模板不能重写正文")
                expect(restored.value(forKey: "richContentJSON") as? String == richJSON, "换模板不能重写富文本")
            }
            try coordinator.remove(store)
        }
        print("PASS: \(assertionCount) 个断言；旧库迁移、旧样式映射、字体角色、原文/富文本/关系/身份与九种样式重载")
    }
}
