import Foundation
import CoreData

@main struct AuditRepeat {
 static func main() {
  let entity=NSEntityDescription();entity.name="RepeatRule";entity.managedObjectClassName=NSStringFromClass(RepeatRule.self)
  let attrs:[(String,NSAttributeType)]=[("id",.UUIDAttributeType),("type",.stringAttributeType),("weekdays",.stringAttributeType),("monthDay",.integer16AttributeType),("monthWeekOrdinal",.integer16AttributeType),("monthWeekday",.stringAttributeType),("untilCount",.integer16AttributeType),("untilDate",.dateAttributeType),("interval",.integer16AttributeType),("skipHolidays",.booleanAttributeType),("skipWeekends",.booleanAttributeType),("createdAt",.dateAttributeType)]
  entity.properties=attrs.map { name,type in let a=NSAttributeDescription();a.name=name;a.attributeType=type;a.isOptional=true;return a }
  let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType)
  func rule(_ type:RepeatType)->RepeatRule {
   let r=RepeatRule(entity:entity,insertInto:context);r.type=type.rawValue;r.interval=1;r.monthDay=0;r.monthWeekOrdinal=0;r.untilCount=0;r.skipWeekends=false;r.skipHolidays=false;return r
  }
  let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd";formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=Calendar.current.timeZone
  func date(_ s:String)->Date { formatter.date(from:s)! }
  func str(_ d:Date?)->String { d.map{formatter.string(from:$0)} ?? "nil" }
  let weekly=rule(.weekly);weekly.weekdaysArray=[.monday,.friday]
  print("weekly Mon+Fri: actual=\(str(weekly.nextDueDate(from:date("2026-10-05")))) expected=2026-10-09")
  let monthly=rule(.monthly);monthly.interval=2;monthly.monthWeekOrdinal=1;monthly.monthWeekdayValue = .monday
  print("every2months firstMonday: actual=\(str(monthly.nextDueDate(from:date("2026-10-05")))) expected=2026-12-07")
  let fixed=rule(.monthly);fixed.monthDay=15
  print("monthly fixed15: actual=\(str(fixed.nextDueDate(from:date("2026-10-04")))) expected=2026-10-15 (or 2026-11-15 under next-cycle semantics)")
  let skip=rule(.daily);skip.skipWeekends=true
  print("daily skipWeekend: actual=\(str(skip.nextDueDate(from:date("2026-10-09")))) expected=2026-10-12")
  let count=rule(.daily);count.untilCount=1;var cursor=date("2026-10-05");var generated=0
  for _ in 0..<5 {if let next=count.nextDueDate(from:cursor){cursor=next;generated+=1}}
  print("repeat count=1: generated next dates=\(generated) (limit never checked)")
 }
}
