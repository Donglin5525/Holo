import Foundation
@main struct ScalarEdgeProbe {
 static func main() {
  setvbuf(stdout, nil, _IONBF, 0)
  if CommandLine.arguments.dropFirst().first == "integer" {
   let input = Int(CommandLine.arguments[2])!
   print("input:",input)
   let interval = Int16(max(1, input))
   print(interval)
  } else {
   var calendar = Calendar(identifier: .gregorian)
   calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
   let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
   let end = calendar.startOfDay(for: day).addingTimeInterval(24 * 3600 - 60)
   let expected = calendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-60)
   print("actual end:",calendar.dateComponents([.day,.hour,.minute],from:end))
   print("calendar end:",calendar.dateComponents([.day,.hour,.minute],from:expected))
   print("same day:",calendar.isDate(day,inSameDayAs:end))
  }
 }
}
