//
//  ChecklistView.swift
//  Holo
//
//  检查清单视图
//

import SwiftUI
import CoreData

struct ChecklistView: View {
    @ObservedObject var repository: TodoRepository
    @State var task: TodoTask
    @Environment(\.dismiss) var dismiss
    @State private var newCheckItemTitle = ""

    var checkItems: [CheckItem] {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        return items.sorted { $0.order < $1.order }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("检查项") {
                    ForEach(checkItems, id: \.id) { item in
                        HStack {
                            Button(action: { toggleCheckItem(item) }) {
                                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundColor(item.isChecked ? .green : .gray)
                            }
                            .buttonStyle(.plain)

                            Text(item.title)
                                .strikethrough(item.isChecked)
                                .foregroundColor(item.isChecked ? .secondary : .primary)

                            Spacer()

                            Button(role: .destructive) {
                                deleteCheckItem(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    .onMove { source, destination in
                        moveCheckItem(source: source, destination: destination)
                    }
                }

                Section("添加检查项") {
                    HStack {
                        TextField("新的检查项", text: $newCheckItemTitle)
                        Button("添加") {
                            addCheckItem()
                        }
                        .disabled(newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("检查清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggleCheckItem(_ item: CheckItem) {
        do {
            try repository.toggleCheckItem(item)
        } catch {
            print("[ChecklistView] 切换检查项失败：\(error)")
        }
    }

    private func addCheckItem() {
        let trimmedTitle = newCheckItemTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        do {
            let order = Int16(checkItems.count)
            _ = try repository.addCheckItem(title: trimmedTitle, to: task, order: order)
            newCheckItemTitle = ""
        } catch {
            print("[ChecklistView] 添加检查项失败：\(error)")
        }
    }

    private func deleteCheckItem(_ item: CheckItem) {
        do {
            try repository.deleteCheckItem(item)
        } catch {
            print("[ChecklistView] 删除检查项失败：\(error)")
        }
    }

    private func moveCheckItem(source: IndexSet, destination: Int) {
        var items = checkItems
        items.move(fromOffsets: source, toOffset: destination)

        do {
            try repository.updateCheckItemOrder(items)
        } catch {
            print("[ChecklistView] 更新排序失败：\(error)")
        }
    }
}

#Preview {
    NavigationStack {
        ChecklistView(
            repository: TodoRepository.shared,
            task: createSampleTask()
        )
    }
}

private func createSampleTask() -> TodoTask {
    let context = CoreDataStack.shared.viewContext
    let task = TodoTask(context: context)
    task.id = UUID()
    task.title = "示例任务"
    task.createdAt = Date()
    task.updatedAt = Date()
    return task
}
