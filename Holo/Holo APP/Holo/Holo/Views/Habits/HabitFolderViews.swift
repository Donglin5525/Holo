import SwiftUI

struct HabitFolderBadge: View {
    let emoji: String?
    let sticker: ResolvedPlacement

    var body: some View {
        Group {
            if case .assetReady = sticker {
                VisualPlacementView(placement: sticker, role: .icon)
            } else if let emoji {
                Text(emoji).font(.system(size: 19))
            } else {
                Image(systemName: "folder").foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

struct HabitFolderManagementPage: View {
    @ObservedObject var model: HabitModuleViewModel
    @State private var selectedFolder: HabitFolderSummary?
    @State private var showCreate = false
    @State private var pendingDelete: HabitFolderSummary?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Color.holoToolError)
            }
            if model.folders.isEmpty {
                Text("你可以把同一主题的习惯放在一起。")
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            ForEach(model.folders) { folder in
                Button {
                    selectedFolder = folder
                } label: {
                    HStack(spacing: HoloSpacing.sm) {
                        HabitFolderBadge(emoji: folder.emoji, sticker: folder.sticker)
                        Text(folder.name)
                    }
                    .foregroundStyle(Color.holoToolText)
                    .frame(minHeight: 44)
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingDelete = folder } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button("删除文件夹", role: .destructive) { pendingDelete = folder }
                }
            }
            .onMove(perform: moveFolders)

            Button {
                showCreate = true
            } label: {
                Label("新建文件夹", systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("habit.folders.create")
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoToolBackground)
        .navigationTitle("管理文件夹")
        .toolbar {
            if model.folders.count > 1 {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .sheet(item: $selectedFolder) { folder in
            HabitFolderEditSheet(model: model, folder: folder)
        }
        .sheet(isPresented: $showCreate) {
            HabitFolderEditSheet(model: model, folder: nil)
        }
        .alert("删除这个文件夹？", isPresented: deleteConfirmation, presenting: pendingDelete) { folder in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除文件夹", role: .destructive) {
                perform { try HabitRepository.shared.deleteFolder(id: folder.id) }
                pendingDelete = nil
            }
        } message: { _ in
            Text("其中的习惯将移到未分组。")
        }
    }

    private var deleteConfirmation: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func moveFolders(from source: IndexSet, to destination: Int) {
        var ids = model.folders.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        perform { try HabitRepository.shared.updateFolderOrder(ids) }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
            model.refresh()
        } catch {
            errorMessage = String(localized: "这次没有保存成功，请重试。")
        }
    }
}

struct HabitFolderEditSheet: View {
    @ObservedObject var model: HabitModuleViewModel
    let folder: HabitFolderSummary?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HabitFolderEditor(model: model, folder: folder, onFinish: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
    }
}

private struct HabitFolderEditor: View {
    @ObservedObject var model: HabitModuleViewModel
    let folder: HabitFolderSummary?
    let onFinish: () -> Void

    @State private var name: String
    @State private var selectedHabitIDs: Set<UUID>
    @State private var errorMessage: String?
    @State private var decoration: HabitFolderDecoration?
    @State private var showEmojiPicker = false
    /// 选择贴纸走栈内 push（减一层 Sheet；草稿随「保存」提交的 B 逻辑保持不变）
    @State private var pushStickerPicker = false

    init(model: HabitModuleViewModel, folder: HabitFolderSummary?, selectedHabitIDs: Set<UUID> = [],
         onFinish: @escaping () -> Void) {
        self.model = model
        self.folder = folder
        self.onFinish = onFinish
        _name = State(initialValue: folder?.name ?? "")
        _selectedHabitIDs = State(initialValue: selectedHabitIDs)
    }

    private var candidates: [HabitRowSnapshot] {
        guard let folder else { return model.todayRows }
        return model.todayRows.filter { $0.folderID != folder.id }
    }

    var body: some View {
        List {
            TextField("文件夹名称", text: $name)
                .accessibilityIdentifier("habit.folders.name")
            appearanceMenu

            if !candidates.isEmpty {
                Section("移入已有习惯") {
                    ForEach(candidates) { row in
                        candidateRow(row)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Color.holoToolError)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoToolBackground)
        .navigationTitle(folder == nil ? "新建文件夹" : "编辑文件夹")
        .sheet(isPresented: $showEmojiPicker) {
            EmojiIconPickerSheet(currentIcon: previewEmoji) { decoration = .emoji($0) }
        }
        .navigationDestination(isPresented: $pushStickerPicker) {
            VisualAppearancePickerView(isPushed: true,
                                       pickerTitle: String(localized: "选择贴纸"),
                                       currentPlacement: previewSticker,
                                       fallbackIcon: "folder",
                                       inUseAssetID: previewStickerAssetID) { id, presentation in
                decoration = .sticker(id, presentation)
                pushStickerPicker = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("habit.folders.save")
            }
        }
    }

    private var appearanceMenu: some View {
        Menu {
            Button { showEmojiPicker = true } label: { Label("选择 Emoji", systemImage: "face.smiling") }
            Button { pushStickerPicker = true } label: { Label("选择贴纸", systemImage: "seal") }
            if previewEmoji != nil || previewSticker != .none {
                Button { decoration = .clear } label: { Label("恢复默认", systemImage: "arrow.counterclockwise") }
            }
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                HabitFolderBadge(emoji: previewEmoji, sticker: previewSticker)
                Text("外观")
                Spacer()
                if folder?.sticker.allowsFolderDecoration == false {
                    Text("暂不可编辑")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
            .foregroundStyle(Color.holoToolText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(folder?.sticker.allowsFolderDecoration == false)
        .accessibilityIdentifier("habit.folders.appearance")
    }

    private var previewEmoji: String? {
        switch decoration {
        case .emoji(let emoji): return emoji
        case nil: return folder?.emoji
        default: return nil
        }
    }

    private var previewSticker: ResolvedPlacement {
        switch decoration {
        case .sticker(let id, let presentation):
            return .assetReady(VisualDescriptor(assetID: id, winningRevisionID: id,
                                                kind: .sticker, presentation: presentation))
        case nil: return folder?.sticker ?? .none
        default: return .none
        }
    }

    private var previewStickerAssetID: UUID? {
        if case .assetReady(let descriptor) = previewSticker { return descriptor.assetID }
        return nil
    }

    private func candidateRow(_ row: HabitRowSnapshot) -> some View {
        let selected = selectedHabitIDs.contains(row.id)
        return Button {
            if selected { selectedHabitIDs.remove(row.id) } else { selectedHabitIDs.insert(row.id) }
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.holoToolAction : Color.holoToolTextSecondary)
                    .accessibilityHidden(true)
                Text(row.name).foregroundStyle(Color.holoToolText)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("habit.folders.candidate.\(row.id)")
    }

    private func save() {
        do {
            try HabitRepository.shared.saveFolder(id: folder?.id, name: name, adding: selectedHabitIDs,
                                                  decoration: decoration, expectedSticker: folder?.sticker ?? .none)
            model.refresh()
            onFinish()
        } catch {
            errorMessage = String(localized: "这次没有保存成功，内容还在，可以重试。")
        }
    }
}

struct HabitFolderMoveSheet: View {
    @ObservedObject var model: HabitModuleViewModel
    let row: HabitRowSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.folders) { folder in
                    Button {
                        move(to: folder.id)
                    } label: {
                        HStack(spacing: HoloSpacing.sm) {
                            HabitFolderBadge(emoji: folder.emoji, sticker: folder.sticker)
                            Text(folder.name)
                            Spacer()
                            if row.folderID == folder.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(row.folderID == folder.id)
                }
                if row.folderID != nil {
                    Button("移出文件夹") { move(to: nil) }
                }
                NavigationLink {
                    HabitFolderEditor(model: model, folder: nil, selectedHabitIDs: [row.id]) { dismiss() }
                } label: {
                    Label("新建文件夹", systemImage: "plus")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Color.holoToolError)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoToolBackground)
            .navigationTitle("移到文件夹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func move(to folderID: UUID?) {
        do {
            try HabitRepository.shared.moveHabit(row.id, to: folderID)
            model.refresh()
            dismiss()
        } catch {
            errorMessage = String(localized: "移动失败，请重试。")
        }
    }
}
