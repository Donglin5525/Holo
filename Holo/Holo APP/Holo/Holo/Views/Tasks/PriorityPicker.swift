//
//  PriorityPicker.swift
//  Holo
//
//  优先级选择器组件
//

import SwiftUI

struct PriorityPicker: View {
    @Binding var priority: TaskPriority
    @State private var selectedPriority: TaskPriority

    init(priority: Binding<TaskPriority>) {
        self._priority = priority
        self._selectedPriority = State(initialValue: priority.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ForEach(TaskPriority.allCasesSorted, id: \.self) { priorityOption in
                    PriorityButton(
                        priority: priorityOption,
                        isSelected: selectedPriority == priorityOption,
                        action: {
                            selectedPriority = priorityOption
                            priority = priorityOption
                        }
                    )
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Priority Button

private struct PriorityButton: View {
    let priority: TaskPriority
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? priority.color : Color.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: priority.iconName)
                            .font(.caption)
                            .foregroundColor(isSelected ? .white : .secondary)
                    )

                Text(priority.displayTitle)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct PriorityPickerPreview: View {
        @State var priority: TaskPriority = .medium

        var body: some View {
            Form {
                Section("优先级") {
                    PriorityPicker(priority: $priority)
                }
            }
        }
    }

    return PriorityPickerPreview()
}
