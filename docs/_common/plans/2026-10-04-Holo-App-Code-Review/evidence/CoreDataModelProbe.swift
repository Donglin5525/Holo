import Foundation
import CoreData
@main struct CoreDataModelProbe {
 static func model(extra: Bool) -> NSManagedObjectModel {
  let entity=NSEntityDescription();entity.name="ReviewItem";entity.managedObjectClassName="NSManagedObject"
  let value=NSAttributeDescription();value.name="value";value.attributeType = .stringAttributeType;value.isOptional=true
  entity.properties=[value]
  if extra { let note=NSAttributeDescription();note.name="note";note.attributeType = .stringAttributeType;note.isOptional=true;entity.properties.append(note) }
  let model=NSManagedObjectModel();model.entities=[entity];return model
 }
 static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("holo-review-model-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let url=root.appendingPathComponent("Review.sqlite")
  let old=NSPersistentStoreCoordinator(managedObjectModel:model(extra:false))
  let store=try old.addPersistentStore(type:.sqlite,at:url)
  let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=old
  let item=NSEntityDescription.insertNewObject(forEntityName:"ReviewItem",into:context);item.setValue("saved record",forKey:"value");try context.save();context.reset()
  try old.remove(store)
  let newer=NSPersistentStoreCoordinator(managedObjectModel:model(extra:true))
  do {
   _=try newer.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url,options:[NSMigratePersistentStoresAutomaticallyOption:true,NSInferMappingModelAutomaticallyOption:true])
   print("migration succeeded")
  } catch {
   let ns=error as NSError;print("migration failed:",ns.domain,ns.code)
   print("sourceModelProvided=false, oldStoreStillExists=",FileManager.default.fileExists(atPath:url.path))
  }
 }
}
