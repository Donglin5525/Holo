//
//  RepeatRuleView.swift
//  Holo
//
//  重复规则设置视图
//

import SwiftUI
import CoreData

struct RepeatRuleView: View {
    @ObservedObject var repository: TodoRepository
    @State var task: TodoTask
    @Environment(\.dismiss) var dismiss

    @State private var repeatType: RepeatType = .daily
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthDay: Int = 1
    @State private var monthWeekOrdinal: Int = 1
    @State private var monthWeekday: Weekday = .monday
    @State private var untilDate: Date?
    @State private var untilCount: Int?
    @State private var skipWeekends = false
    @State private var skipHolidays = false

    var body: some View {
        NavigationStack {
            Form {
                Section("重复类型") {
                    Picker("类型", selection: $repeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { type in
                            Text(type.displayTitle).tag(type)
                        }
                    }

                    if repeatType == .weekly {
                        Picker("每周", selection: $selectedWeekdays) {
                            ForEach(Weekday.allCases, id: \.self) { weekday in
                                Text(weekday.displayTitle).tag(weekday)
                            }
                        }

                        if selectedWeekdays.isEmpty {
                            Text("请至少选择一个星期几")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }

                    if repeatType == .monthly {
                        Picker("每月规则", selection: $monthDay) {
                            Text("按日期").tag(0)
                            Text("按第 N 周").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if monthDay == 0 {
                            Stepper("日期：\(monthDay)", value: $monthDay, in: 1...31)
                        } else {
                            Stepper("第\(ordinalNumber(monthWeekOrdinal))周", value: $monthWeekOrdinal, in: 1...5)
                            Picker("星期", selection: $monthWeekday) {
                                ForEach(Weekday.allCases, id: \.self) { weekday in
                                    Text(weekday.displayTitle).tag(weekday)
                                }
                            }
                        }
                    }
                }

                Section("结束条件") {
                    Picker("结束方式", selection: $untilDate) {
                        Text("永不结束").tag(nil as Date?)
                        Text("到指定日期").tag(Date())
                    }

                    if untilDate != nil {
                        DatePicker("结束日期", selection: Binding(
                            get: { untilDate ?? Date() },
                            set: { untilDate = $0 }
                        ), displayedComponents: .date)
                    }

                    //                    Stepper("重复次数：\(untilCount ?? 0)", value: Binding(
                    //                        get: { untilCount ?? 0 },
                    //                        set: { untilCount = $0 > 0 ? $0 : nil }
                    //                    ), in: 0...100)
                }

                Section("跳过规则") {
                    Toggle("跳过周末", isOn: $skipWeekends)
                    Toggle("跳过节假日", isOn: $skipHolidays)
                }

                if task.repeatRule != nil {
                    Section("当前规则") {
                        Button("删除重复规则", role: .destructive) {
                            deleteRepeatRule()
                        }
                    }
                }
            }
            .navigationTitle("重复规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveRepeatRule()
                    }
                    .disabled(!validateInput())
                }
            }
        }
    }

    /// 验证输入
    private func validateInput() -> Bool {
        if repeatType == .weekly && selectedWeekdays.isEmpty {
            return false
        }
        return true
    }

    /// 保存重复规则
    private func saveRepeatRule() {
        do {
            if task.repeatRule != nil {
                // 更新现有规则
                try repository.deleteRepeatRule(task.repeatRule!)
            }

            var weekdays: [Weekday]? = nil
            if repeatType == .weekly {
                weekdays = Array(selectedWeekdays)
            }

            _ = try repository.createRepeatRule(
                type: repeatType,
                for: task,
                weekdays: weekdays,
                untilDate: untilDate
            )

            // 设置跳过规则（需要额外实现）
            // ...

            dismiss()
        } catch {
            print("[RepeatRuleView] 保存重复规则失败：\(error)")
        }
    }

    /// 删除重复规则
    private func deleteRepeatRule() {
        do {
            if let rule = task.repeatRule {
                try repository.deleteRepeatRule(rule)
            }
            dismiss()
        } catch {
            print("[RepeatRuleView] 删除重复规则失败：\(error)")
        }
    }

    /// 序数词转换
    private func ordinalNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

#Preview {
    NavigationStack {
        RepeatRuleView(
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
