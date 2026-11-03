//
//  MacTaskCreationView.swift
//  HoloMac
//
//  新建任务 sheet（三区骨架：头部/表单/底部按钮，Return=创建、Esc=取消）。
//  与 iOS TaskCreationSheet 同语义的收敛版：标题、描述、检查清单、安排
//  （截止+全天+清单）、优先级。落库一次走 TodoRepository.createTask。
//

import SwiftUI

struct MacTaskCreationView: View {

    /// 预填上下文：清单范围新建预填该清单；今天范围新建预填今天全天截止
    var defaultListID: UUID?
    var defaultDueToday: Bool

    @Environment(\.dismiss) private var dismiss
    private let repository = TodoRepository.shared

    @State private var title = ""
    @State private var note = ""
    @State private var checkItemLines: [String] = [""]
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var isAllDay = true
    @State private var listID: UUID?
    @State private var priority: TaskPriority = .medium
    @State private var showDiscardConfirm = false
    /// 落库失败提示：失败不关弹层、内容保留待重试（2026-10-31 审计 M10）
    @State private var saveFailed = false

    init(defaultListID: UUID?, defaultDueToday: Bool) {
        self.defaultListID = defaultListID
        self.defaultDueToday = defaultDueToday
        // 今天范围：默认带上今天的全天截止（与 iOS TasksView defaultDueDateForNewTask 同口径）
        _hasDueDate = State(initialValue: defaultDueToday)
        _dueDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
        _listID = State(initialValue: defaultListID)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否有任何未保存输入（决定取消是否需要确认）
    private var hasInput: Bool {
        canCreate
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || checkItemLines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            || hasDueDate != defaultDueToday
            || priority != .medium
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            formView
            Divider()
            footerView
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: - 头部

    private var headerView: some View {
        HStack {
            Text(String(localized: "添加任务"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.holoToolText)
            Spacer()
        }
        .padding(HoloSpacing.lg)
    }

    // MARK: - 表单

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                // 标题
                TextField(String(localized: "想做什么？"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .medium))
                    .onSubmit(create)

                // 描述
                TextField(String(localized: "描述（可选）"), text: $note)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))

                // 检查清单
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(String(localized: "检查清单"))
                        .font(.holoLabel)
                        .foregroundColor(.holoToolTextSecondary)
                    ForEach(checkItemLines.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                            TextField(String(localized: "添加一项"), text: $checkItemLines[index])
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .onSubmit {
                                    if index == checkItemLines.count - 1 {
                                        checkItemLines.append("")
                                    }
                                }
                            if checkItemLines.count > 1 {
                                Button {
                                    checkItemLines.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10))
                                        .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Divider()

                // 安排
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text(String(localized: "安排"))
                        .font(.holoLabel)
                        .foregroundColor(.holoToolTextSecondary)

                    HStack(spacing: HoloSpacing.md) {
                        Toggle(String(localized: "有截止时间"), isOn: $hasDueDate)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13))
                        if hasDueDate {
                            DatePicker("", selection: $dueDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                                .labelsHidden()
                            Toggle(String(localized: "全天"), isOn: $isAllDay)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 13))
                        }
                    }

                    HStack(spacing: HoloSpacing.md) {
                        Text(String(localized: "清单"))
                            .font(.system(size: 13))
                            .foregroundColor(.holoToolTextSecondary)
                        Menu {
                            Button(String(localized: "收件箱")) { listID = nil }
                            ForEach(repository.allActiveLists(), id: \.id) { list in
                                Button(list.name ?? "") { listID = list.id }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if let id = listID, let list = repository.findList(by: id) {
                                    Circle()
                                        .fill(Color(hex: list.color ?? "#007AFF"))
                                        .frame(width: 8, height: 8)
                                    Text(list.name ?? "")
                                } else {
                                    Text(String(localized: "收件箱"))
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.holoToolText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .fill(Color.holoToolInset))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                    }
                }

                Divider()

                // 优先级
                HStack(spacing: HoloSpacing.md) {
                    Text(String(localized: "优先级"))
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolTextSecondary)
                    Picker("", selection: $priority) {
                        ForEach(TaskPriority.allCases, id: \.self) { level in
                            Text(level.displayTitle).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
            }
            .padding(HoloSpacing.lg)
        }
    }

    // MARK: - 底部按钮区

    private var footerView: some View {
        HStack {
            Spacer()
            Button(String(localized: "取消"), role: .cancel) {
                if hasInput {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            Button {
                create()
            } label: {
                Text(String(localized: "创建"))
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding(HoloSpacing.lg)
        .confirmationDialog(
            String(localized: "未保存的修改"),
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "继续编辑"), role: .cancel) {}
            Button(String(localized: "放弃修改"), role: .destructive) {
                dismiss()
            }
        } message: {
            Text(String(localized: "已有输入的内容还没有保存，确定要关闭吗？"))
        }
        .alert(
            String(localized: "创建失败"),
            isPresented: $saveFailed
        ) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(String(localized: "任务没有保存成功，内容已保留，请重试。"))
        }
    }

    // MARK: - 落库

    private func create() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let list = listID.flatMap { repository.findList(by: $0) }
        let items = checkItemLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            _ = try repository.createTask(
                title: trimmedTitle,
                description: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : note.trimmingCharacters(in: .whitespacesAndNewlines),
                list: list,
                priority: priority,
                dueDate: hasDueDate ? dueDate : nil,
                isAllDay: hasDueDate && isAllDay,
                checkItemTitles: items.isEmpty ? nil : items)
        } catch {
            saveFailed = true
            return
        }

        dismiss()
    }
}
