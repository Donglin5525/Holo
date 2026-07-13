import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let migration = try String(
    contentsOfFile: root + "/Holo/Holo APP/Holo/Holo/Services/Migrations/SensitiveDebugDataMigration.swift",
    encoding: .utf8
)
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
expect(migration.contains("rawLogJSON != nil"), "迁移未筛选历史原始日志")
expect(migration.contains("setValue(nil, forKey: \"rawLogJSON\")"), "迁移未清空 rawLogJSON")
expect(!migration.contains("analysisContextJSON"), "迁移不应删除业务分析上下文")
expect(migration.contains("if context.hasChanges { try context.save() }"), "迁移标记前未保存 Core Data")
expect(migration.contains("defaults.set(true"), "迁移缺少幂等完成标记")
print("SensitiveDebugDataMigrationStandaloneTests: PASS")
