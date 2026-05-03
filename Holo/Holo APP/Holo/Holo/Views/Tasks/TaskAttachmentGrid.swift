//
//  TaskAttachmentGrid.swift
//  Holo
//
//  附件网格视图 — 3 列 LazyVGrid，支持添加/删除/查看
//

import SwiftUI

struct TaskAttachmentGrid: View {
    let attachments: [TaskAttachment]
    let taskId: UUID
    let maxCount: Int
    let onAdd: () -> Void
    let onDelete: (TaskAttachment) -> Void
    let onTap: (Int) -> Void

    @State private var isEditing = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 8) {
            if isEditing {
                editModeBar
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(attachments, id: \.id) { attachment in
                    thumbnailCell(attachment)
                }

                if attachments.count < maxCount {
                    addButton
                }
            }
        }
    }

    // MARK: - 编辑模式顶栏

    private var editModeBar: some View {
        HStack {
            Text("点击附件以删除")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Button("完成") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isEditing = false
                }
            }
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)
        }
    }

    // MARK: - 缩略图卡片

    @ViewBuilder
    private func thumbnailCell(_ attachment: TaskAttachment) -> some View {
        let index = attachments.firstIndex(where: { $0.id == attachment.id }) ?? 0

        AttachmentThumbnailView(fileName: attachment.thumbnailFileName, taskId: taskId)
            .overlay(alignment: .topTrailing) {
                if isEditing {
                    deleteButton(attachment)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isEditing {
                    onDelete(attachment)
                } else {
                    onTap(index)
                }
            }
            .onLongPressGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isEditing = true
                }
            }
    }

    // MARK: - 删除按钮

    private func deleteButton(_ attachment: TaskAttachment) -> some View {
        Button {
            onDelete(attachment)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        }
        .padding(4)
    }

    // MARK: - 添加按钮

    private var addButton: some View {
        Button(action: onAdd) {
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundColor(.holoTextPlaceholder)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.holoTextPlaceholder)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
