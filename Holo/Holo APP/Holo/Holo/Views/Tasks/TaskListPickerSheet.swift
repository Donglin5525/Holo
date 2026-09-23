//
//  TaskListPickerSheet.swift
//  Holo
//
//  AI 建任务确认卡的清单选择弹层：收件箱 + 已有清单 + 新建清单。
//  选择即回调（确认卡场景点击即写回并关闭）。
//

import SwiftUI

struct TaskListPickerSheet: View {
    @ObservedObject var repository: TodoRepository
    /// 当前选中清单 ID；nil = 收件箱
    @State private var selectedListId: UUID?
    /// 回调统一在点选时触发，返回 nil 表示收件箱
    let onSelect: (UUID?, _ listName: String?) -> Void

    @State private var showAddListSheet = false
    @Environment(\.dismiss) private var dismiss

    init(
        repository: TodoRepository,
        initialListId: UUID?,
        onSelect: @escaping (UUID?, _ listName: String?) -> Void
    ) {
        self.repository = repository
        self._selectedListId = State(initialValue: initialListId)
        self.onSelect = onSelect
    }

    private var allLists: [TodoList] {
        repository.allActiveLists()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.md) {
                        Button {
                            showAddListSheet = true
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoPrimary)

                                Text("新建清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoPrimary)

                                Spacer()
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onSelect(nil, nil)
                            dismiss()
                        } label: {
                            listRow(
                                icon: "tray",
                                iconColor: .holoTextSecondary,
                                name: String(localized: "收件箱"),
                                subtitle: String(localized: "不归入任何清单"),
                                selected: selectedListId == nil
                            )
                        }
                        .buttonStyle(.plain)

                        ForEach(allLists, id: \.id) { list in
                            Button {
                                selectedListId = list.id
                                onSelect(list.id, list.name)
                                dismiss()
                            } label: {
                                listRow(
                                    icon: nil,
                                    iconColor: .holoPrimary,
                                    name: list.name,
                                    subtitle: nil,
                                    selected: selectedListId == list.id,
                                    dotColor: Color(hex: list.color ?? "#007AFF")
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if allLists.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)

                                Text("点击上方\"新建清单\"创建")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary.opacity(0.7))
                            }
                            .padding(.top, HoloSpacing.xl)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("选择清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
            }
            .sheet(isPresented: $showAddListSheet) {
                AddListSheet(repository: repository, folder: nil)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func listRow(
        icon: String?,
        iconColor: Color,
        name: String,
        subtitle: String?,
        selected: Bool,
        dotColor: Color? = nil
    ) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 22)
            } else if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer()

            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(selected ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}
