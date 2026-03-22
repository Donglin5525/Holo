//
//  ReminderPicker.swift
//  Holo
//
//  提醒时间选择器
//  支持多选预设提醒时间
//

import SwiftUI

/// 提醒选择器
struct ReminderPicker: View {

    @Binding var selectedReminders: Set<TaskReminder>
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isEnabled ? .holoTextSecondary : .holoTextSecondary.opacity(0.5))

                Text("提醒")
                    .font(.holoBody)
                    .foregroundColor(isEnabled ? .holoTextPrimary : .holoTextPlaceholder)

                if !selectedReminders.isEmpty {
                    Text("\(selectedReminders.count)")
                        .font(.holoCaption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }

                Spacer()

                if !isEnabled {
                    Text("需设置截止时间")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
            }

            if isEnabled {
                // 预设选项
                FlowLayout(spacing: HoloSpacing.sm) {
                    ForEach(TaskReminder.presetOptions, id: \.offsetMinutes) { reminder in
                        ReminderChip(
                            reminder: reminder,
                            isSelected: selectedReminders.contains(reminder),
                            onTap: {
                                toggleReminder(reminder)
                            }
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isEnabled ? Color.holoCardBackground : Color.holoCardBackground.opacity(0.5))
        .cornerRadius(HoloRadius.sm)
    }

    private func toggleReminder(_ reminder: TaskReminder) {
        if selectedReminders.contains(reminder) {
            selectedReminders.remove(reminder)
        } else {
            selectedReminders.insert(reminder)
        }
    }
}

// MARK: - Reminder Chip

/// 单个提醒选项标签
struct ReminderChip: View {
    let reminder: TaskReminder
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(reminder.displayTitle)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Hashable Extension for TaskReminder

extension TaskReminder: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(offsetMinutes)
    }

    static func == (lhs: TaskReminder, rhs: TaskReminder) -> Bool {
        lhs.offsetMinutes == rhs.offsetMinutes
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        ReminderPicker(
            selectedReminders: .constant(Set([TaskReminder(offsetMinutes: 15), TaskReminder(offsetMinutes: 60)])),
            isEnabled: true
        )

        ReminderPicker(
            selectedReminders: .constant([]),
            isEnabled: false
        )
    }
    .padding()
    .background(Color.holoBackground)
}
