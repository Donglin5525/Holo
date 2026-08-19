import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath

func read(_ relativePath: String) throws -> String {
    try String(contentsOfFile: root + "/" + relativePath, encoding: .utf8)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let taskList = try read("Holo/Holo APP/Holo/Holo/Views/Tasks/TaskListView.swift")
let filterChip = try read("Holo/Holo APP/Holo/Holo/Components/HoloFilterChip.swift")

// 清单名称从短文案切换成长文案时，Menu 必须重建，不能复用旧的布局缓存。
expect(taskList.contains(".id(selectedList?.id)"), "任务清单 Menu 缺少随选中清单 ID 重建的布局契约")

// 横向胶囊必须按内容取宽，不能让父级提案压缩掉首字符或前置图标。
expect(taskList.contains(".fixedSize(horizontal: true, vertical: false)"), "任务页筛选胶囊缺少横向固定内容宽度契约")
expect(filterChip.contains(".fixedSize(horizontal: true, vertical: false)"), "共享筛选胶囊缺少横向固定内容宽度契约")

let dynamicHorizontalChipSources = [
    "Holo/Holo APP/Holo/Holo/Components/QuickTagBar.swift",
    "Holo/Holo APP/Holo/Holo/Views/AddTransaction/TransactionCategoryGrid.swift",
    "Holo/Holo APP/Holo/Holo/Views/Chat/QuickActionBar.swift",
    "Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtCardView.swift",
    "Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtDetailView.swift",
    "Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtEditorView.swift",
    "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Calendar/Detail/CalendarEventDetailSheet.swift"
]

for path in dynamicHorizontalChipSources {
    let source = try read(path)
    expect(
        source.contains(".fixedSize(horizontal: true, vertical: false)"),
        "横向动态胶囊缺少固定内容宽度契约：\(path)"
    )
}

print("TaskFilterChipLayoutStandaloneTests: PASS")
